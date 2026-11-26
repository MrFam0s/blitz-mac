package validate

import (
	"encoding/json"
	"testing"

	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/asc"
	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/validation"
)

func TestBlitzLocationAndDatingAnswers(t *testing.T) {
	for _, tc := range []struct {
		body        string
		wantMissing map[string]bool
	}{
		{`{}`, map[string]bool{"sharedLocation": true, "datingAndRelationships": true}},
		{`{"sharedLocation":null,"datingAndRelationships":false}`, map[string]bool{"sharedLocation": true}},
		{`{"sharedLocation":true,"datingAndRelationships":null}`, map[string]bool{"datingAndRelationships": true}},
		{`{"sharedLocation":false,"datingAndRelationships":false}`, nil},
		{`{"sharedLocation":true,"datingAndRelationships":true}`, nil},
	} {
		t.Run(tc.body, func(t *testing.T) {
			var attrs asc.AgeRatingDeclarationAttributes
			if err := json.Unmarshal([]byte(tc.body), &attrs); err != nil {
				t.Fatal(err)
			}
			missing := map[string]bool{}
			for _, check := range validation.AgeRatingChecks(mapAgeRatingDeclaration(attrs)) {
				if check.ID == "age_rating.missing_field" && check.Severity == validation.SeverityError {
					missing[check.Field] = true
				}
			}
			for _, field := range []string{"sharedLocation", "datingAndRelationships"} {
				if missing[field] != tc.wantMissing[field] {
					t.Errorf("%s missing = %v, want %v", field, missing[field], tc.wantMissing[field])
				}
			}
		})
	}
}
