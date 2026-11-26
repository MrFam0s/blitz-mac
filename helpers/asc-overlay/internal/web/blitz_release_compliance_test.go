package web

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestBlitzReleaseComplianceRequiresCompleteAppScopedResponse(t *testing.T) {
	cases := []struct {
		body  string
		valid bool
	}{
		{`{}`, true}, {`{"data":[]}`, true}, {`null`, false}, {`{"error":"inaccessible"}`, false},
		{`{"data":[],"links":{"self":"/requirements","next":null}}`, true},
		{`{"data":[],"links":{"next":"/requirements?page=2"}}`, false},
		{`{"data":null}`, false}, {`{"data":[],"next":"other"}`, false},
		{`{"data":[{"id":"req","formName":"AIGENERATEFD1DE","entityId":"app","entityType":"APP","status":"PENDING_COLLECT","isRequired":true,"countries":["CHN"]}]}`, true},
		{`{"data":[{"id":"req","formName":"AIGENERATEFD1DE","status":"PENDING_COLLECT","countries":["CHN"]}]}`, false},
		{`{"data":[{"id":"req","formName":"AIGENERATEFD1DE","entityId":"other","status":"PENDING_COLLECT","isRequired":true,"countries":["CHN"]}]}`, false},
	}
	for _, tc := range cases {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != "GET" || r.URL.Path != "/ppm/compliancerequirements/v1/accounts/provider/requirements" || r.URL.Query().Get("entity_id") != "app" {
				t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
			}
			_, _ = w.Write([]byte(tc.body))
		}))
		_, err := testWebClient(server).ListBlitzReleaseComplianceRequirements(t.Context(), "provider", "app")
		server.Close()
		if (err == nil) != tc.valid {
			t.Fatalf("response %s: %v", tc.body, err)
		}
	}
}
