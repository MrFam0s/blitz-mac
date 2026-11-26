package helper

import (
	"errors"
	"fmt"
	"testing"

	webcore "github.com/rudrankriyam/App-Store-Connect-CLI/internal/web"
)

func TestBlitzReleaseChinaRequiresFreshTerritoryEvidence(t *testing.T) {
	row := func(territory, selection string) string {
		return fmt.Sprintf(`{"id":"id-%s","type":"territoryAvailabilities","attributes":{%s},"relationships":{"territory":{"data":{"type":"territories","id":"%s"}}}}`, territory, selection, territory)
	}
	available := row("CHN", `"available":true`)
	hongKong := row("HKG", `"available":true`)
	tests := []struct {
		name, rows, meta   string
		selected, verified bool
	}{
		{"selected", available, "", true, true},
		{"explicitly excluded", row("CHN", `"available":false`), "", false, true},
		{"only Hong Kong complete", hongKong, `,"meta":{"paging":{"total":1}}`, false, true},
		{"partial", hongKong, `,"meta":{"paging":{"total":175}}`, false, false},
		{"unverified omission", hongKong, "", false, false},
		{"no linkage", row("", `"available":true`), "", false, false},
		{"no selection", row("CHN", ""), "", false, false},
		{"null selection", row("CHN", `"available":null`), "", false, false},
		{"duplicate", available + "," + available, "", false, false},
		{"missing rows", "", "", false, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := chinaSelectedFromTerritories([]byte(`{"data":[` + tc.rows + `]` + tc.meta + `}`))
			if (err == nil) != tc.verified || got != tc.selected {
				t.Fatalf("selection=%t, err=%v", got, err)
			}
		})
	}
}

func TestBlitzReleaseChinaRequirementEvidence(t *testing.T) {
	const name = "AI_GENERATED_CONTENT"
	row := webcore.AppComplianceRequirement{RequirementID: "form", AppID: "app1", RequirementName: name, Required: true, CountriesOrRegions: []string{"CHN"}, Status: "PENDING_COLLECT"}
	for _, tc := range []struct {
		test, want string
		edit       func(*webcore.AppComplianceRequirement)
	}{
		{"missing answer", "blocked", func(*webcore.AppComplianceRequirement) {}},
		{"not required", "notApplicable", func(r *webcore.AppComplianceRequirement) { r.Required = false }},
		{"other region", "notApplicable", func(r *webcore.AppComplianceRequirement) { r.CountriesOrRegions = []string{"HKG"} }},
		{"answered", "passed", func(r *webcore.AppComplianceRequirement) { r.Status = "COLLECTED_VERIFY_NOT_NECESSARY" }},
		{"answered ambiguous action", "unverified", func(r *webcore.AppComplianceRequirement) {
			r.Status = "COLLECTED_VERIFY_NOT_NECESSARY"
			r.RequiredActions = []string{"UNKNOWN"}
		}},
		{"pending Apple verification", "passed", func(r *webcore.AppComplianceRequirement) {
			r.FormID = "saved"
			r.Status = "COLLECTED_VERIFY_PENDING"
			r.RequiredActions = []string{"APP_BINARY_SUBMISSION"}
		}},
		{"pending without action", "passed", func(r *webcore.AppComplianceRequirement) { r.Status = "COLLECTED_VERIFY_PENDING"; r.FormID = "saved" }},
		{"pending confirmation unverifiable", "unverified", func(r *webcore.AppComplianceRequirement) { r.Status = "COLLECTED_VERIFY_PENDING" }},
		{"additional action", "unverified", func(r *webcore.AppComplianceRequirement) {
			r.Status = "COLLECTED_VERIFY_PENDING"
			r.FormID = "saved"
			r.RequiredActions = []string{"APP_BINARY_SUBMISSION", "UNKNOWN"}
		}},
		{"two-character territory", "unverified", func(r *webcore.AppComplianceRequirement) { r.CountriesOrRegions = []string{"CN"} }},
		{"empty territory", "unverified", func(r *webcore.AppComplianceRequirement) { r.CountriesOrRegions = []string{""} }},
		{"lowercase territory", "unverified", func(r *webcore.AppComplianceRequirement) { r.CountriesOrRegions = []string{"chn"} }},
		{"unknown", "unverified", func(r *webcore.AppComplianceRequirement) { r.Status = "NEW_STATUS" }},
		{"missing territory", "unverified", func(r *webcore.AppComplianceRequirement) { r.CountriesOrRegions = nil }},
		{"wrong app", "unverified", func(r *webcore.AppComplianceRequirement) { r.AppID = "other" }},
	} {
		t.Run(tc.test, func(t *testing.T) {
			r := row
			tc.edit(&r)
			got := chinaDeclarationEvidence([]webcore.AppComplianceRequirement{r}, "app1", name)
			if got.Status != tc.want {
				t.Fatalf("got %#v", got)
			}
		})
	}
	if got := chinaDeclarationEvidence([]webcore.AppComplianceRequirement{row, row}, "app1", name); got.Status != "unverified" {
		t.Fatal(got)
	}
	other := row
	other.RequirementName = "NEW_APP_FORM"
	if got := chinaDeclarationEvidence([]webcore.AppComplianceRequirement{other}, "app1", name); got.Status != "unverified" {
		t.Fatalf("unknown CHN form in place of expected one: %#v", got)
	}
	other.CountriesOrRegions = []string{"USA"}
	if got := chinaDeclarationEvidence([]webcore.AppComplianceRequirement{other}, "app1", name); got.Status != "notApplicable" {
		t.Fatalf("unrelated form affects CHN: %#v", got)
	}
	if got := chinaDeclarationEvidence(nil, "app1", name); got.Status != "notApplicable" {
		t.Fatal(got)
	}
	for _, err := range []error{nil, errors.New("territory API unavailable")} {
		client := &fakeReleaseWeb{}
		ai, sa := releaseChinaEvidence(t.Context(), client, "PROVIDER", "app1", false, err)
		if ai != sa || client.complianceReads != 0 || (ai.Status == "notApplicable") != (err == nil) {
			t.Fatalf("unexpected regional evidence %#v", ai)
		}
	}
}
