package helper

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	webcore "github.com/rudrankriyam/App-Store-Connect-CLI/internal/web"
)

func TestWebSessionImportRPCSurvivesInputEOFAndReturnsOnlyReceipt(t *testing.T) {
	service := NewService("test")
	service.webSessionImporter = func(_ context.Context, p webcore.BlitzSessionImportParams) (webcore.BlitzSessionImportResult, error) {
		if p.ExpectedProviderID != "PUBLIC" || p.Bundle == nil || p.Bundle.Cookies[0].Value != "cookie-secret" {
			t.Fatal("request lost target or input bundle")
		}
		return webcore.BlitzSessionImportResult{Outcome: "existingPreserved", Reason: "existing_session_at_least_as_capable",
			ASC:             webcore.BlitzSessionEvidence{Status: "verified", Reason: "exact_account_and_provider_verified"},
			DeveloperPortal: webcore.BlitzSessionEvidence{Status: "verified", Reason: "exact_provider_team_verified"}}, nil
	}
	input := `{"id":"import-1","method":"web.session.import","params":{"expectedProviderId":"PUBLIC","bundle":{"kind":"asc-web-session","version":1,"appleId":"fixture@example.invalid","cookies":[{"url":"https://appstoreconnect.apple.com/","name":"a","value":"cookie-secret"}]}}}`
	var out bytes.Buffer
	if err := NewServerWithService(strings.NewReader(input+"\n"), &out, service).Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	var response struct {
		ID     string                           `json:"id"`
		Result webcore.BlitzSessionImportResult `json:"result"`
	}
	if err := json.Unmarshal(out.Bytes(), &response); err != nil || response.ID != "import-1" || response.Result.Outcome != "existingPreserved" {
		t.Fatalf("unexpected RPC receipt %s / %v", out.String(), err)
	}
	if strings.Contains(out.String(), "cookie-secret") {
		t.Fatal("RPC reflected credential")
	}
}

func TestWebSessionImportRPCErrorsNeverReflectSecretData(t *testing.T) {
	for _, params := range []string{`{"secret-field":"cookie-secret"}`, `{"bundle":null,"expectedProviderId":"PUBLIC"}`} {
		service := NewService("test")
		service.webSessionImporter = func(context.Context, webcore.BlitzSessionImportParams) (webcore.BlitzSessionImportResult, error) {
			return webcore.BlitzSessionImportResult{}, errors.New("raw error cookie-secret")
		}
		response := service.Handle(context.Background(), Request{ID: "bad", Method: "web.session.import", Params: json.RawMessage(params)})
		raw, _ := json.Marshal(response)
		if response.Error == nil || response.Error.Data != "" || strings.Contains(string(raw), "cookie-secret") {
			t.Fatalf("unsafe error response %s", raw)
		}
	}
}
