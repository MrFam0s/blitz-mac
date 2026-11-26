package metadata

import (
	"encoding/json"
	"maps"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestBlitzAgeRatingMetadataRoundTrip(t *testing.T) {
	for _, test := range []struct {
		name        string
		apple       string
		wantFile    map[string]any
		replacement string
		wantPatch   map[string]any
	}{
		{"explicit values", `{"sharedLocation":false,"datingAndRelationships":true}`,
			map[string]any{"sharedLocation": false, "datingAndRelationships": true},
			`{"sharedLocation":true}`, map[string]any{"sharedLocation": true}},
		{"unanswered", `{"sharedLocation":null}`, map[string]any{},
			`{"datingAndRelationships":false}`, map[string]any{"datingAndRelationships": false}},
	} {
		t.Run(test.name, func(t *testing.T) {
			const prefix = `{"data":{"type":"ageRatingDeclarations","id":"rating","attributes":`
			writes := 0
			metadataConcurrencyTransport(t, func(req *http.Request) (*http.Response, error) {
				switch {
				case req.Method == "GET" && req.URL.Path == "/v1/appInfos/info/ageRatingDeclaration":
				case req.Method == "PATCH" && req.URL.Path == "/v1/ageRatingDeclarations/rating":
					writes++
					var body struct {
						Data struct {
							Attributes map[string]any
						}
					}
					if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
						t.Fatal(err)
					}
					if !maps.Equal(body.Data.Attributes, test.wantPatch) {
						t.Fatalf("PATCH attributes = %v, want %v", body.Data.Attributes, test.wantPatch)
					}
				default:
					t.Fatalf("unexpected request %s %s", req.Method, req.URL.Path)
				}
				return metadataFetchJSONResponse(prefix + test.apple + "}}"), nil
			})

			client, deps := newMetadataFetchClient(t), metadataTestDeps()
			target := metadataSettingTarget{appInfoID: "info"}
			scope := ageRatingSettingScope
			remote, err := scope.fetch(t.Context(), deps, client, target)
			if err != nil {
				t.Fatal(err)
			}
			file, err := encodeMetadataSettingFile(scope, remote)
			if err != nil {
				t.Fatal(err)
			}
			var decoded map[string]any
			if err := json.Unmarshal(file, &decoded); err != nil || !maps.Equal(decoded, test.wantFile) {
				t.Fatalf("pulled file = %s, want %v (error %v)", file, test.wantFile, err)
			}
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, scope.fileName), []byte(test.replacement), 0600); err != nil {
				t.Fatal(err)
			}
			values, err := readMetadataSettingFile(deps, dir, scope)
			if err != nil {
				t.Fatal(err)
			}
			plan, _, _ := buildMetadataSettingPlan(scope, values, remote)
			if _, err := scope.update(t.Context(), deps, client, target, plan.changed); err != nil {
				t.Fatal(err)
			}
			if writes != 1 {
				t.Fatalf("unexpected number of writes: %d", writes)
			}
		})
	}
}
