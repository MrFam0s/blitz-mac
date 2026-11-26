package helper

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"slices"

	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/asc"
	webcore "github.com/rudrankriyam/App-Store-Connect-CLI/internal/web"
)

// Use public API selection data, including all pages. A storefront's live
// content status and future-territories default cannot establish its selection.
func releaseChinaSelected(ctx context.Context, client *asc.Client, appID string) (bool, error) {
	info, err := client.GetAppAvailabilityV2(ctx, appID)
	if err != nil {
		return false, err
	}
	if info == nil || info.Data.Type != "appAvailabilities" || !releaseResourceID.MatchString(info.Data.ID) {
		return false, errors.New("missing app availability")
	}
	path := "/v2/appAvailabilities/" + info.Data.ID + "/territoryAvailabilities?include=territory&limit=200"
	data, err := client.RawPaginatedGET(ctx, path, nil)
	if err != nil {
		return false, err
	}
	return chinaSelectedFromTerritories(data)
}

var territoryCode = regexp.MustCompile(`^[A-Z]{3}$`)

func chinaSelectedFromTerritories(data []byte) (bool, error) {
	var collection struct {
		Data []struct {
			ID            string
			Type          string
			Attributes    struct{ Available *bool }
			Relationships struct {
				Territory struct{ Data struct{ ID, Type string } }
			}
		}
		Meta   struct{ Paging struct{ Total *int } }
		Errors json.RawMessage
	}
	invalid := errors.New("incomplete app territory selection")
	if err := json.Unmarshal(data, &collection); err != nil || collection.Data == nil || collection.Errors != nil {
		return false, invalid
	}
	if total := collection.Meta.Paging.Total; total != nil && *total != len(collection.Data) {
		return false, invalid
	}
	seen := map[string]bool{}
	selected := false
	for _, item := range collection.Data {
		territory := item.Relationships.Territory.Data
		if item.ID == "" || item.Type != "territoryAvailabilities" || item.Attributes.Available == nil ||
			territory.Type != "territories" || !territoryCode.MatchString(territory.ID) || seen[territory.ID] {
			return false, invalid
		}
		seen[territory.ID] = true
		if territory.ID == "CHN" {
			selected = *item.Attributes.Available
		}
	}
	// Accept omission only when Apple supplied a matching total. This prevents
	// a partial collection missing CHN from granting a regional exemption.
	if !seen["CHN"] && collection.Meta.Paging.Total == nil {
		return false, invalid
	}
	return selected, nil
}

func releaseChinaEvidence(ctx context.Context, client releaseWebClient, providerID, appID string, selected bool, availabilityErr error) (releaseEvidenceCheck, releaseEvidenceCheck) {
	if availabilityErr != nil {
		item := releaseEvidenceCheck{"unverified", "china_storefront_unverified"}
		return item, item
	}
	if !selected {
		item := releaseEvidenceCheck{"notApplicable", "china_storefront_excluded"}
		return item, item
	}
	rows, err := client.ListBlitzReleaseComplianceRequirements(ctx, providerID, appID)
	if err != nil {
		item := releaseEvidenceCheck{"unverified", "china_requirements_unavailable"}
		return item, item
	}
	return chinaDeclarationEvidence(rows, appID, "AI_GENERATED_CONTENT"), chinaDeclarationEvidence(rows, appID, "SECURITY_ASSESSMENT")
}

func chinaDeclarationEvidence(rows []webcore.AppComplianceRequirement, appID, name string) releaseEvidenceCheck {
	result := releaseEvidenceCheck{"notApplicable", "china_requirement_not_applicable"}
	found, unknownRequired := false, false
	for _, row := range rows {
		if row.AppID != appID || row.RequirementID == "" || (row.Required && len(row.CountriesOrRegions) == 0) {
			return releaseEvidenceCheck{"unverified", "china_requirement_ambiguous"}
		}
		for _, country := range row.CountriesOrRegions {
			if !territoryCode.MatchString(country) {
				return releaseEvidenceCheck{"unverified", "china_requirement_ambiguous"}
			}
		}
		if !slices.Contains(row.CountriesOrRegions, "CHN") {
			continue
		}
		if row.RequirementName != name {
			if row.Required && row.RequirementName != "AI_GENERATED_CONTENT" && row.RequirementName != "SECURITY_ASSESSMENT" {
				unknownRequired = true
			}
			continue
		}
		if found {
			return releaseEvidenceCheck{"unverified", "china_requirement_ambiguous"}
		}
		found = true
		if !row.Required {
			continue
		}
		switch row.Status {
		case "PENDING_COLLECT":
			result = releaseEvidenceCheck{"blocked", "china_declaration_required"}
		case "COLLECTED_VERIFY_NOT_NECESSARY":
			result = releaseEvidenceCheck{"passed", "china_declaration_collected"}
			if len(row.RequiredActions) > 0 {
				result = releaseEvidenceCheck{"unverified", "china_requirement_status_unknown"}
			}
		case "COLLECTED_VERIFY_PENDING":
			// Apple reviews this information with the next version submission:
			// https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties/ (footnote 4).
			result = releaseEvidenceCheck{"passed", "china_declaration_collected_verification_pending"}
			if row.FormID == "" || slices.ContainsFunc(row.RequiredActions, func(action string) bool { return action != "APP_BINARY_SUBMISSION" }) {
				result = releaseEvidenceCheck{"unverified", "china_verification_pending"}
			}
		default:
			result = releaseEvidenceCheck{"unverified", "china_requirement_status_unknown"}
		}
	}
	if !found && unknownRequired {
		return releaseEvidenceCheck{"unverified", "china_requirement_ambiguous"}
	}
	return result
}
