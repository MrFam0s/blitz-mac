package helper

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/asc"
	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/cli/validate"
	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/validation"
	webcore "github.com/rudrankriyam/App-Store-Connect-CLI/internal/web"
)

type ReleaseReadinessParams struct {
	AppID     string `json:"appId"`
	BundleID  string `json:"bundleId"`
	VersionID string `json:"versionId"`
	Platform  string `json:"platform"`
}
type releaseEvidenceCheck struct {
	Status string `json:"status"`
	Reason string `json:"reason"`
}
type releaseWebEvidence struct {
	AppID           string               `json:"appId"`
	BundleID        string               `json:"bundleId"`
	BindingVerified bool                 `json:"bindingVerified"`
	BindingReason   string               `json:"bindingReason"`
	AppleID         string               `json:"appleId,omitempty"`
	ProviderID      string               `json:"providerId,omitempty"`
	DeveloperTeamID string               `json:"developerTeamId,omitempty"`
	ProgramLicense  releaseEvidenceCheck `json:"programLicense"`
	BusinessFree    releaseEvidenceCheck `json:"businessFree"`
	BusinessPaid    releaseEvidenceCheck `json:"businessPaid"`
}
type releaseReadinessResult struct {
	Report   validation.Report  `json:"report"`
	Web      releaseWebEvidence `json:"web"`
	ExitCode int                `json:"exitCode"`
}
type releaseWebClient interface {
	validate.BlitzDeepClient
	BindBlitzReleaseDeveloperTeam(context.Context) error
	GetApp(context.Context, string) (*webcore.AppResponse, error)
	ListBusinessAgreements(context.Context) (*webcore.BusinessAgreementsResponse, error)
}
type releaseReadinessDependencies struct {
	buildReport  func(context.Context, validate.ReadinessOptions) (validation.Report, error)
	resume       func(context.Context) (*webcore.AuthSession, bool, error)
	newWebClient func(*webcore.AuthSession) releaseWebClient
}

func releaseReadiness(ctx context.Context, p ReleaseReadinessParams) (releaseReadinessResult, error) {
	return collectReleaseReadiness(ctx, p, releaseReadinessDependencies{
		buildReport: validate.BuildReadinessReport,
		resume:      webcore.ResumeLastCachedSessionWithoutPersist,
		newWebClient: func(session *webcore.AuthSession) releaseWebClient {
			// Never let an old cached Developer Portal team override the current
			// ASC provider. Upstream resolves the fresh team list by that provider.
			session.DeveloperTeamID = ""
			return webcore.NewClient(session)
		},
	})
}

var releaseResourceID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

func validReleaseReadinessParams(p ReleaseReadinessParams) bool {
	return releaseResourceID.MatchString(p.AppID) && releaseResourceID.MatchString(p.VersionID) &&
		strings.TrimSpace(p.BundleID) == p.BundleID && p.BundleID != "" && len(p.BundleID) <= 255 &&
		(p.Platform == "IOS" || p.Platform == "MAC_OS" || p.Platform == "TV_OS" || p.Platform == "VISION_OS")
}
func collectReleaseReadiness(ctx context.Context, p ReleaseReadinessParams, deps releaseReadinessDependencies) (releaseReadinessResult, error) {
	ctx, cancel := context.WithTimeout(ctx, 210*time.Second)
	defer cancel()
	// Public validation retains the selected daemon API credentials; no fallback
	// to web authentication can turn a failed API-account check into success.
	report, err := deps.buildReport(ctx, validate.ReadinessOptions{AppID: p.AppID, VersionID: p.VersionID, Platform: p.Platform, Strict: true, Deep: true})
	if err != nil {
		return releaseReadinessResult{}, errors.New("release readiness public validation unavailable")
	}
	unknown := releaseEvidenceCheck{"unverified", "web_session_unavailable"}
	evidence := releaseWebEvidence{AppID: p.AppID, BundleID: p.BundleID, BindingReason: "web_session_unavailable",
		ProgramLicense: unknown, BusinessFree: unknown, BusinessPaid: unknown}
	session, ok, sessionErr := deps.resume(ctx)
	var bound validate.BlitzDeepClient
	if sessionErr == nil && ok && session != nil && session.Client != nil && session.UserEmail != "" && session.PublicProviderID != "" {
		client := deps.newWebClient(session)
		app, appErr := client.GetApp(ctx, p.AppID)
		if appErr == nil && app != nil && app.Data.ID == p.AppID && app.Data.Attributes["bundleId"] == p.BundleID {
			evidence.BindingVerified = true
			evidence.BindingReason = "exact_app_and_bundle_verified_in_selected_provider"
			evidence.AppleID, evidence.ProviderID = session.UserEmail, session.PublicProviderID
			var agreements *asc.WebAgreementsStatusResult
			agreementErr := client.BindBlitzReleaseDeveloperTeam(ctx)
			if agreementErr == nil {
				agreements, agreementErr = client.GetAgreementsStatus(ctx)
			}
			evidence.ProgramLicense = programLicenseEvidence(agreements, agreementErr)
			if agreements != nil {
				evidence.DeveloperTeamID = agreements.TeamID
			}
			business, businessErr := client.ListBusinessAgreements(ctx)
			evidence.BusinessFree = businessEvidence(business, businessErr, "Free Applications", true, true)
			paidRequired := report.HasActiveMonetization || report.HasPaidAppPrice
			paidKnown := paidRequired || (report.MonetizationKnown && report.AppPricingKnown)
			evidence.BusinessPaid = businessEvidence(business, businessErr, "Paid Applications", paidRequired, paidKnown)
			bound = &releaseBoundDeepClient{releaseWebClient: client, agreements: agreements, agreementErr: agreementErr}
		} else {
			evidence.BindingReason = "web_provider_app_mismatch_or_inaccessible"
		}
	} else if errors.Is(sessionErr, webcore.ErrCachedSessionExpired) {
		evidence.BindingReason = "web_session_expired"
	} else if session != nil && session.PublicProviderID == "" {
		evidence.BindingReason = "web_provider_unresolved"
	}
	report = validate.ApplyBlitzDeepValidation(ctx, report, bound)
	code := 0
	if report.Summary.Blocking > 0 {
		code = 1
	}
	return releaseReadinessResult{Report: report, Web: evidence, ExitCode: code}, nil
}

type releaseBoundDeepClient struct {
	releaseWebClient
	agreements   *asc.WebAgreementsStatusResult
	agreementErr error
}

func (c *releaseBoundDeepClient) GetAgreementsStatus(context.Context) (*asc.WebAgreementsStatusResult, error) {
	return c.agreements, c.agreementErr
}

func programLicenseEvidence(result *asc.WebAgreementsStatusResult, err error) releaseEvidenceCheck {
	// An empty or partial history is never equivalent to an accepted license.
	if err != nil {
		reason := "developer_portal_unavailable"
		text := strings.ToLower(err.Error())
		if strings.Contains(text, "team") {
			reason = "developer_team_unresolved"
		}
		var apiErr *webcore.APIError
		if errors.As(err, &apiErr) && (apiErr.Status == 401 || apiErr.Status == 403) {
			reason = "developer_portal_auth_required"
		}
		return releaseEvidenceCheck{"unverified", reason}
	}
	if result == nil || result.TeamID == "" {
		return releaseEvidenceCheck{"unverified", "developer_team_unresolved"}
	}
	var current *asc.WebAgreement
	for _, agreement := range result.Agreements {
		if agreement.Pending && agreement.ProgramLicenseClassificationUnknown {
			return releaseEvidenceCheck{"unverified", "outstanding_agreement_classification_unknown"}
		}
		if !agreement.IsProgramLicenseAgreement {
			continue
		}
		if agreement.Pending {
			return releaseEvidenceCheck{"blocked", "program_license_acceptance_required"}
		}
		if current == nil || agreement.DateEffective > current.DateEffective ||
			(agreement.DateEffective == current.DateEffective && (len(agreement.Version) > len(current.Version) ||
				(len(agreement.Version) == len(current.Version) && agreement.Version > current.Version))) {
			copy := agreement
			current = &copy
		} else if agreement.DateEffective == current.DateEffective && agreement.Version == current.Version && agreement.Status != current.Status {
			return releaseEvidenceCheck{"unverified", "program_license_conflicting_history"}
		}
	}
	if current == nil {
		return releaseEvidenceCheck{"unverified", "program_license_history_missing"}
	}
	switch strings.ToLower(strings.TrimSpace(current.Status)) {
	case "active", "active (pending user)":
		return releaseEvidenceCheck{"passed", "current_program_license_active"}
	case "new", "expired", "disabled", "pending user info", "processing", "verifying":
		return releaseEvidenceCheck{"blocked", "program_license_acceptance_required"}
	default:
		return releaseEvidenceCheck{"unverified", "program_license_status_unknown"}
	}
}

func businessEvidence(result *webcore.BusinessAgreementsResponse, err error, name string, required, relevanceKnown bool) releaseEvidenceCheck {
	if relevanceKnown && !required {
		return releaseEvidenceCheck{"notApplicable", "no_paid_price_or_active_monetization"}
	}
	if !relevanceKnown {
		return releaseEvidenceCheck{"unverified", "paid_agreement_relevance_unknown"}
	}
	if err != nil || result == nil {
		return releaseEvidenceCheck{"unverified", "business_agreements_unavailable"}
	}
	var matching []webcore.BusinessAgreement
	for _, agreement := range result.Agreements {
		if strings.EqualFold(strings.TrimSpace(agreement.ContractDisplayName), name) {
			matching = append(matching, agreement)
		}
	}
	if len(matching) != 1 {
		return releaseEvidenceCheck{"unverified", "business_agreement_missing_or_ambiguous"}
	}
	agreement := matching[0]
	if agreement.IsInEffect == nil || agreement.ConfigIsLatestVersion == nil || agreement.AvailableNewContractConfigID == nil {
		return releaseEvidenceCheck{"unverified", "business_agreement_fields_missing"}
	}
	if !*agreement.IsInEffect || !*agreement.ConfigIsLatestVersion || strings.TrimSpace(*agreement.AvailableNewContractConfigID) != "" {
		return releaseEvidenceCheck{"blocked", "business_agreement_action_required"}
	}
	if agreement.Status != "ITC.ATB.Agmnt.Status.Active" {
		return releaseEvidenceCheck{"unverified", "business_agreement_status_unknown"}
	}
	return releaseEvidenceCheck{"passed", "current_business_agreement_active"}
}
