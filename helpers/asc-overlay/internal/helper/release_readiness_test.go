package helper

import (
	"context"
	"errors"
	"net/http"
	"testing"

	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/asc"
	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/cli/validate"
	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/validation"
	webcore "github.com/rudrankriyam/App-Store-Connect-CLI/internal/web"
)

func TestBlitzProgramLicenseSeparatesMissingTeamAndPendingAgreement(t *testing.T) {
	active := asc.WebAgreement{AgreementID: "pla", IsProgramLicenseAgreement: true, Status: "active", DateEffective: "2026-01-01", Version: "10"}
	cases := []struct {
		name           string
		result         *asc.WebAgreementsStatusResult
		err            error
		status, reason string
	}{
		{"team unresolved", &asc.WebAgreementsStatusResult{}, errors.New("apple account has no Developer Portal team; private detail"), "unverified", "developer_team_unresolved"},
		{"portal unauthorized", nil, &webcore.APIError{Status: 401}, "unverified", "developer_portal_auth_required"},
		{"history absent", &asc.WebAgreementsStatusResult{TeamID: "TEAM"}, nil, "unverified", "program_license_history_missing"},
		{"active", &asc.WebAgreementsStatusResult{TeamID: "TEAM", Agreements: []asc.WebAgreement{active}}, nil, "passed", "current_program_license_active"},
		{"partial active history", &asc.WebAgreementsStatusResult{TeamID: "TEAM", Agreements: []asc.WebAgreement{active}}, errors.New("notifications unavailable"), "unverified", "developer_portal_unavailable"},
		{"pending", &asc.WebAgreementsStatusResult{TeamID: "TEAM", Agreements: []asc.WebAgreement{active, {IsProgramLicenseAgreement: true, Pending: true}}}, nil, "blocked", "program_license_acceptance_required"},
		{"unclassified outstanding", &asc.WebAgreementsStatusResult{TeamID: "TEAM", Agreements: []asc.WebAgreement{active, {Pending: true, ProgramLicenseClassificationUnknown: true}}}, nil, "unverified", "outstanding_agreement_classification_unknown"},
		{"old expired", &asc.WebAgreementsStatusResult{TeamID: "TEAM", Agreements: []asc.WebAgreement{{IsProgramLicenseAgreement: true, Status: "expired", DateEffective: "2026-01-01", Version: "9"}, active}}, nil, "passed", "current_program_license_active"},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			got := programLicenseEvidence(test.result, test.err)
			if got.Status != test.status || got.Reason != test.reason {
				t.Fatalf("got %#v", got)
			}
		})
	}
}
func businessFixture() *webcore.BusinessAgreementsResponse {
	yes, empty := true, ""
	return &webcore.BusinessAgreementsResponse{Agreements: []webcore.BusinessAgreement{
		{ContractDisplayName: "Free Applications", Status: "ITC.ATB.Agmnt.Status.Active", IsInEffect: &yes, ConfigIsLatestVersion: &yes, AvailableNewContractConfigID: &empty},
		{ContractDisplayName: "Paid Applications", Status: "ITC.ATB.Agmnt.Status.Active", IsInEffect: &yes, ConfigIsLatestVersion: &yes, AvailableNewContractConfigID: &empty},
	}}
}
func TestBlitzBusinessEvidenceRequiresCurrentConfigurationAndKnownRelevance(t *testing.T) {
	got := businessEvidence(businessFixture(), nil, "Paid Applications", true, true)
	if got.Status != "passed" {
		t.Fatalf("got %#v", got)
	}
	result := businessFixture()
	replacement := "next"
	result.Agreements[1].AvailableNewContractConfigID = &replacement
	if got := businessEvidence(result, nil, "Paid Applications", true, true); got.Status != "blocked" {
		t.Fatalf("got %#v", got)
	}
	if got := businessEvidence(result, nil, "Paid Applications", false, true); got.Status != "notApplicable" {
		t.Fatalf("got %#v", got)
	}
	if got := businessEvidence(result, nil, "Paid Applications", false, false); got.Reason != "paid_agreement_relevance_unknown" {
		t.Fatalf("got %#v", got)
	}
	result.Agreements[0].IsInEffect = nil
	if got := businessEvidence(result, nil, "Free Applications", true, true); got.Status != "unverified" {
		t.Fatalf("got %#v", got)
	}
}

type fakeReleaseWeb struct {
	wrongApp                      bool
	wrongPortalTeam               bool
	agreementReads, businessReads int
}

func (f *fakeReleaseWeb) BindBlitzReleaseDeveloperTeam(context.Context) error {
	if f.wrongPortalTeam {
		return errors.New("developer portal team has no unique exact binding to selected provider")
	}
	return nil
}

func (f *fakeReleaseWeb) GetApp(context.Context, string) (*webcore.AppResponse, error) {
	app := &webcore.AppResponse{}
	app.Data.ID = "app1"
	if f.wrongApp {
		app.Data.ID = "other"
	}
	app.Data.Attributes = map[string]any{"bundleId": "org.example.App"}
	return app, nil
}
func (f *fakeReleaseWeb) GetAgreementsStatus(context.Context) (*asc.WebAgreementsStatusResult, error) {
	f.agreementReads++
	return &asc.WebAgreementsStatusResult{}, errors.New("apple account has no Developer Portal team")
}
func (f *fakeReleaseWeb) ListBusinessAgreements(context.Context) (*webcore.BusinessAgreementsResponse, error) {
	f.businessReads++
	return businessFixture(), nil
}
func (f *fakeReleaseWeb) GetAppDataUsagesPublishState(context.Context, string) (*webcore.AppDataUsagesPublishState, error) {
	return nil, errors.New("fixture privacy unavailable")
}
func (f *fakeReleaseWeb) ListReviewSubscriptions(context.Context, string) ([]webcore.ReviewSubscription, error) {
	return nil, nil
}

func TestBlitzReadinessBindsProviderBeforeReadingAgreementsAndKeepsUnknownPLA(t *testing.T) {
	for _, scenario := range []struct{ wrongApp, wrongPortal bool }{{}, {wrongApp: true}, {wrongPortal: true}} {
		wrong := scenario.wrongApp
		fake := &fakeReleaseWeb{wrongApp: wrong, wrongPortalTeam: scenario.wrongPortal}
		params := ReleaseReadinessParams{AppID: "app1", BundleID: "org.example.App", VersionID: "version1", Platform: "IOS"}
		result, err := collectReleaseReadiness(context.Background(), params, releaseReadinessDependencies{
			buildReport: func(_ context.Context, options validate.ReadinessOptions) (validation.Report, error) {
				if options.AppID != "app1" || options.VersionID != "version1" || options.Platform != "IOS" || !options.Strict || !options.Deep {
					t.Fatal("wrong fixed target")
				}
				return validation.Report{AppID: "app1", VersionID: "version1", Platform: "IOS", Strict: true, HasPaidAppPrice: true, HasActiveMonetization: false}, nil
			},
			resume: func(context.Context) (*webcore.AuthSession, bool, error) {
				return &webcore.AuthSession{Client: &http.Client{}, UserEmail: "fixture@example.invalid", PublicProviderID: "PROVIDER"}, true, nil
			},
			newWebClient: func(*webcore.AuthSession) releaseWebClient { return fake },
		})
		if err != nil {
			t.Fatal(err)
		}
		if result.Web.BindingVerified == wrong {
			t.Fatal("wrong provider binding outcome")
		}
		if wrong {
			if fake.agreementReads != 0 || fake.businessReads != 0 {
				t.Fatal("read agreements before app binding")
			}
		} else {
			expectedReads := 1
			if scenario.wrongPortal {
				expectedReads = 0
			}
			if fake.agreementReads != expectedReads || fake.businessReads != 1 {
				t.Fatal("deep validator must reuse exact same agreement result")
			}
			if result.Web.ProgramLicense.Reason != "developer_team_unresolved" || result.Web.BusinessPaid.Status != "passed" {
				t.Fatalf("got %#v", result.Web)
			}
		}
	}
}

func TestBlitzReadinessRejectsInvalidTargetBeforeAnyNetwork(t *testing.T) {
	service := NewService("fixture")
	response := service.Handle(context.Background(), Request{ID: "1", Method: "release.readiness", Params: []byte(`{"appId":"../other","bundleId":"org.example.App","versionId":"v1","platform":"IOS"}`)})
	if response.Error == nil || response.Error.Code != CodeInvalidRequest {
		t.Fatalf("got %#v", response)
	}
}
