package helper

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	webcore "github.com/rudrankriyam/App-Store-Connect-CLI/internal/web"
)

type chinaTestClient struct {
	app           *webcore.AppResponse
	before, after []webcore.AppComplianceRequirement
	receipt       *webcore.AppComplianceDeclarationResult
	writeErr      error
	reads, writes int
}

func (c *chinaTestClient) GetApp(context.Context, string) (*webcore.AppResponse, error) {
	return c.app, nil
}
func (c *chinaTestClient) ListBlitzReleaseComplianceRequirements(_ context.Context, provider, app string) ([]webcore.AppComplianceRequirement, error) {
	if provider != "provider" || app != "123" {
		return nil, errors.New("wrong target")
	}
	c.reads++
	if c.reads == 1 {
		return c.before, nil
	}
	return c.after, nil
}
func (c *chinaTestClient) SetBlitzSelectedComplianceDeclaration(_ context.Context, provider, app string, row webcore.AppComplianceRequirement, d webcore.AppComplianceDeclaration) (*webcore.AppComplianceDeclarationResult, error) {
	c.writes++
	if provider != "provider" || app != "123" || row.RequirementID != "req" || row.RequirementName != d.Requirement {
		return nil, errors.New("wrong declaration")
	}
	return c.receipt, c.writeErr
}
func chinaFixture() (chinaFormParams, *chinaTestClient) {
	negative := false
	p := chinaFormParams{AppID: "123", BundleID: "example.ui", ProviderID: "provider", RequirementID: "req", Requirement: "AI_GENERATED_CONTENT", Confirm: true, Declared: &negative}
	app := &webcore.AppResponse{}
	app.Data.ID = p.AppID
	app.Data.Attributes = map[string]any{"bundleId": p.BundleID}
	before := webcore.AppComplianceRequirement{AppID: p.AppID, RequirementID: p.RequirementID, RequirementName: p.Requirement, FormName: "AIGENERATEFD1DE", Required: true, CountriesOrRegions: []string{"CHN"}, Status: "PENDING_COLLECT"}
	after := before
	after.Status, after.FormID = "COLLECTED_VERIFY_PENDING", "form"
	receipt := &webcore.AppComplianceDeclarationResult{AppID: p.AppID, RequirementID: p.RequirementID, RequirementName: p.Requirement, Status: after.Status, FormID: after.FormID}
	return p, &chinaTestClient{app: app, before: []webcore.AppComplianceRequirement{before}, after: []webcore.AppComplianceRequirement{after}, receipt: receipt}
}
func TestChinaFormsReadAndVerifiedSave(t *testing.T) {
	p, c := chinaFixture()
	result, err := performChinaForms(t.Context(), p, false, "provider", c)
	if err != nil || c.writes != 0 || result.Receipt != nil || len(result.Requirements) != 1 || result.ProviderID != "provider" {
		t.Fatalf("read: %+v, %v", result, err)
	}
	p, c = chinaFixture()
	result, err = performChinaForms(t.Context(), p, true, "provider", c)
	if err != nil || c.writes != 1 || c.reads != 2 || result.Outcome != "saved" || result.Receipt == nil || result.Receipt.Declared || result.Requirements[0].Status != "COLLECTED_VERIFY_PENDING" {
		t.Fatalf("write: %+v, %v", result, err)
	}
}
func TestChinaFormsRefuseChangedTargetOrPendingForm(t *testing.T) {
	for name, change := range map[string]func(*chinaFormParams, *chinaTestClient){
		"provider":     func(p *chinaFormParams, c *chinaTestClient) { p.ProviderID = "other" },
		"bundle":       func(p *chinaFormParams, c *chinaTestClient) { p.BundleID = "other" },
		"requirement":  func(p *chinaFormParams, c *chinaTestClient) { p.RequirementID = "other" },
		"other region": func(p *chinaFormParams, c *chinaTestClient) { c.before[0].CountriesOrRegions = []string{"HKG"} },
		"duplicate": func(p *chinaFormParams, c *chinaTestClient) {
			r := c.before[0]
			r.RequirementID = "other"
			c.before = append(c.before, r)
		},
		"pending": func(p *chinaFormParams, c *chinaTestClient) { c.before = c.after; p.ReplacingFormID = "form" },
		"existing": func(p *chinaFormParams, c *chinaTestClient) {
			c.before = c.after
			c.before[0].Status = "COLLECTED_VERIFY_NOT_NECESSARY"
		},
		"confirmation": func(p *chinaFormParams, c *chinaTestClient) { p.Confirm = false },
	} {
		t.Run(name, func(t *testing.T) {
			p, c := chinaFixture()
			change(&p, c)
			_, err := performChinaForms(t.Context(), p, true, "provider", c)
			if err == nil || c.writes != 0 {
				t.Fatalf("writes %d, error %v", c.writes, err)
			}
		})
	}
}
func TestChinaFormsReadAfterUncertainSaveWithoutRetry(t *testing.T) {
	for name, change := range map[string]func(*chinaTestClient){
		"lost reply":           func(c *chinaTestClient) { c.writeErr = errors.New("lost reply") },
		"wrong answer receipt": func(c *chinaTestClient) { c.receipt.Declared = true },
		"wrong readback":       func(c *chinaTestClient) { c.after[0].FormID = "unrelated" },
		"still open":           func(c *chinaTestClient) { c.after = c.before },
	} {
		t.Run(name, func(t *testing.T) {
			p, c := chinaFixture()
			change(c)
			result, err := performChinaForms(t.Context(), p, true, "provider", c)
			if err != nil || c.writes != 1 || c.reads != 2 || result.Outcome != "unconfirmed" || result.Receipt != nil {
				t.Fatalf("%+v, %v", result, err)
			}
		})
	}
}
func TestChinaFormsAffirmativeEvidence(t *testing.T) {
	yes := true
	path := filepath.Join(t.TempDir(), "proof.pdf")
	if err := os.WriteFile(path, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	p := chinaFormParams{Requirement: "SECURITY_ASSESSMENT", Declared: &yes, Confirm: true, ProofPath: path}
	if _, err := p.declaration(); err == nil {
		t.Fatal("missing report accepted")
	}
	p.ReportPath = path
	d, err := p.declaration()
	if err != nil || string(d.Proof.Data) != "fixture" || d.Report.Name != "proof.pdf" {
		t.Fatalf("%+v, %v", d, err)
	}
	p = chinaFormParams{Requirement: "AI_GENERATED_CONTENT", Declared: &yes, Confirm: true, FilingType: "LLM", FilingName: "M", FilingNumber: "01", ThirdPartyTechnology: &yes}
	if _, err := p.declaration(); err == nil {
		t.Fatal("missing third-party permission accepted")
	}
	p.ThirdPartyAuthorizationPath = path
	d, err = p.declaration()
	if err != nil || !d.ThirdPartyTechnology || d.ThirdPartyAuthorization == nil || d.FilingNumber != "01" {
		t.Fatalf("%+v, %v", d, err)
	}
}
