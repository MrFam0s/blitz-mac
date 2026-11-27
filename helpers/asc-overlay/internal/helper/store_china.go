package helper

import (
	"context"
	"errors"
	"io"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/asc"
	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/cli/shared"
	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/rootfs"
	webcore "github.com/rudrankriyam/App-Store-Connect-CLI/internal/web"
)

type chinaFormParams struct {
	AppID, BundleID, ProviderID, RequirementID, Requirement, ReplacingFormID                 string
	Confirm                                                                                  bool
	Declared, ThirdPartyTechnology                                                           *bool
	FilingType, FilingName, FilingNumber, ProofPath, ReportPath, ThirdPartyAuthorizationPath string
}

type chinaFormResult struct {
	AppID        string                                 `json:"appId"`
	ProviderID   string                                 `json:"providerId"`
	Requirements asc.WebAppComplianceRequirementList    `json:"requirements"`
	Outcome      string                                 `json:"outcome"`
	HTTPStatus   int                                    `json:"httpStatus,omitempty"`
	Receipt      *asc.WebAppComplianceDeclarationResult `json:"receipt,omitempty"`
}

type chinaFormsClient interface {
	GetApp(context.Context, string) (*webcore.AppResponse, error)
	ListBlitzReleaseComplianceRequirements(context.Context, string, string) ([]webcore.AppComplianceRequirement, error)
	SetBlitzSelectedComplianceDeclaration(context.Context, string, string, webcore.AppComplianceRequirement, webcore.AppComplianceDeclaration) (*webcore.AppComplianceDeclarationResult, error)
}

func storeChinaForms(ctx context.Context, p chinaFormParams, writing bool) (chinaFormResult, error) {
	if !releaseResourceID.MatchString(p.AppID) || p.BundleID == "" || (writing && (!p.Confirm || p.ProviderID == "" || p.RequirementID == "")) {
		return chinaFormResult{}, errors.New("invalid app, provider or requirement identity")
	}
	ctx, cancel := context.WithTimeout(ctx, 4*time.Minute)
	defer cancel()
	session, ok, err := webcore.ResumeLastCachedSessionWithoutPersist(ctx, shared.DefaultDeps().HTTPTransport())
	if err != nil || !ok || session == nil || session.Client == nil || session.UserEmail == "" || session.PublicProviderID == "" {
		return chinaFormResult{}, errors.New("Apple web session unavailable; use asc_web_auth and retry the read")
	}
	return performChinaForms(ctx, p, writing, session.PublicProviderID, webcore.NewClient(session))
}

func performChinaForms(ctx context.Context, p chinaFormParams, writing bool, provider string, client chinaFormsClient) (chinaFormResult, error) {
	if p.ProviderID != "" && p.ProviderID != provider {
		return chinaFormResult{}, errors.New("Apple web provider changed; read declarations for the intended provider")
	}
	app, err := client.GetApp(ctx, p.AppID)
	if err != nil || app == nil || app.Data.ID != p.AppID || app.Data.Attributes["bundleId"] != p.BundleID {
		return chinaFormResult{}, errors.New("Apple web provider does not confirm the requested app and bundle identity")
	}
	read := func() (asc.WebAppComplianceRequirementList, error) {
		rows, err := client.ListBlitzReleaseComplianceRequirements(ctx, provider, p.AppID)
		if err != nil {
			return nil, errors.New("Apple compliance requirements could not be verified")
		}
		result := make(asc.WebAppComplianceRequirementList, 0, len(rows))
		seen := make(map[string]bool)
		for _, row := range rows {
			if row.AppID != p.AppID || row.RequirementID == "" || seen[row.RequirementID] || (row.Required && len(row.CountriesOrRegions) == 0) {
				return nil, errors.New("ambiguous Apple compliance requirements")
			}
			seen[row.RequirementID] = true
			for _, region := range row.CountriesOrRegions {
				if !territoryCode.MatchString(region) {
					return nil, errors.New("invalid region on Apple compliance requirement")
				}
			}
			if slices.Contains(row.CountriesOrRegions, "CHN") {
				result = append(result, asc.WebAppComplianceRequirement(row))
			}
		}
		return result, nil
	}
	rows, err := read()
	if err != nil {
		return chinaFormResult{}, err
	}
	result := chinaFormResult{AppID: p.AppID, ProviderID: provider, Requirements: rows, Outcome: "read"}
	if !writing {
		return result, nil
	}
	var target *asc.WebAppComplianceRequirement
	for i := range rows {
		if rows[i].RequirementName != p.Requirement {
			continue
		}
		if target != nil {
			return chinaFormResult{}, errors.New("multiple matching China requirements")
		}
		target = &rows[i]
	}
	if target == nil || target.RequirementID != p.RequirementID || len(target.CountriesOrRegions) != 1 || !target.Required {
		return chinaFormResult{}, errors.New("China requirement identity or scope changed; read the current requirements")
	}
	newAnswer := target.Status == "PENDING_COLLECT" && target.FormID == "" && p.ReplacingFormID == ""
	replacement := target.Status == "COLLECTED_VERIFY_NOT_NECESSARY" && p.ReplacingFormID != "" && p.ReplacingFormID == target.FormID
	if !newAnswer && !replacement {
		return chinaFormResult{}, errors.New("Apple requirement is not open for this filing; preserve pending forms and specify replacingFormId only for an authorized correction")
	}
	declaration, err := p.declaration()
	if err != nil {
		return chinaFormResult{}, err
	}
	receipt, writeErr := client.SetBlitzSelectedComplianceDeclaration(ctx, provider, p.AppID, webcore.AppComplianceRequirement(*target), declaration)
	// Never repeat a save. Only a matching receipt establishes which Yes/No
	// was sent; the independent readback identifies the collected form.
	fresh, readErr := read()
	result.Requirements, result.Outcome = fresh, "unconfirmed"
	var apiErr *webcore.APIError
	if errors.As(writeErr, &apiErr) && apiErr.Status >= 400 && apiErr.Status < 500 {
		result.HTTPStatus = apiErr.Status
		result.Outcome = "rejected"
	}
	if writeErr != nil || receipt == nil || receipt.DryRun || readErr != nil || receipt.AppID != p.AppID || receipt.RequirementID != p.RequirementID || receipt.RequirementName != p.Requirement || receipt.Declared != declaration.Declared || receipt.FormID == "" {
		return result, nil
	}
	for _, row := range fresh {
		if row.RequirementID == receipt.RequirementID && row.RequirementName == receipt.RequirementName && row.FormID == receipt.FormID && (row.Status == "COLLECTED_VERIFY_NOT_NECESSARY" || row.Status == "COLLECTED_VERIFY_PENDING") {
			value := asc.WebAppComplianceDeclarationResult(*receipt)
			result.Receipt, result.Outcome = &value, "saved"
			break
		}
	}
	return result, nil
}

func (p chinaFormParams) declaration() (webcore.AppComplianceDeclaration, error) {
	d := webcore.AppComplianceDeclaration{Requirement: p.Requirement}
	if !p.Confirm || p.Declared == nil || (p.Requirement != "AI_GENERATED_CONTENT" && p.Requirement != "SECURITY_ASSESSMENT") {
		return d, errors.New("an explicit confirmed answer for one supported requirement is required")
	}
	d.Declared = *p.Declared
	ai := p.FilingName != "" || p.FilingNumber != "" || p.FilingType != "" || p.ThirdPartyTechnology != nil || p.ThirdPartyAuthorizationPath != ""
	security := p.ProofPath != "" || p.ReportPath != ""
	if !d.Declared {
		if ai || security {
			return d, errors.New("a No answer accepts no supporting evidence")
		}
		return d, nil
	}
	if p.Requirement == "AI_GENERATED_CONTENT" {
		if security || (p.FilingType != "LLM" && p.FilingType != "ALGORITHM") || strings.TrimSpace(p.FilingName) == "" || strings.TrimSpace(p.FilingNumber) == "" || p.ThirdPartyTechnology == nil || *p.ThirdPartyTechnology != (p.ThirdPartyAuthorizationPath != "") {
			return d, errors.New("affirmative AI answer requires its filing and matching third-party evidence")
		}
		d.FilingType, d.FilingName, d.FilingNumber, d.ThirdPartyTechnology = p.FilingType, p.FilingName, p.FilingNumber, *p.ThirdPartyTechnology
		if d.ThirdPartyTechnology {
			file, err := readChinaEvidence(p.ThirdPartyAuthorizationPath)
			d.ThirdPartyAuthorization = file
			return d, err
		}
		return d, nil
	}
	if ai || p.ProofPath == "" || p.ReportPath == "" {
		return d, errors.New("affirmative assessment requires the proof and the report")
	}
	var err error
	d.Proof, err = readChinaEvidence(p.ProofPath)
	if err != nil {
		return d, err
	}
	d.Report, err = readChinaEvidence(p.ReportPath)
	return d, err
}

func readChinaEvidence(path string) (*webcore.AppComplianceFile, error) {
	const limit = 20 << 20
	badFile := errors.New("evidence must be a nonempty supported document up to 20 MiB")
	if !filepath.IsAbs(path) || !slices.Contains([]string{".doc", ".docx", ".jpg", ".jpeg", ".png", ".pdf"}, strings.ToLower(filepath.Ext(path))) {
		return nil, badFile
	}
	file, err := rootfs.OpenFile(path)
	if err != nil {
		return nil, badFile
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() == 0 || info.Size() > limit {
		return nil, badFile
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || len(data) == 0 || len(data) > limit {
		return nil, badFile
	}
	return &webcore.AppComplianceFile{Name: filepath.Base(path), Data: data}, nil
}
