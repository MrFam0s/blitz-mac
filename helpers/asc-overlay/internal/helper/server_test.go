package helper

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/asc"
	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/cli/shared"
)

type stubRequester struct {
	lastRequest asc.RawRequest
	response    *asc.RawResponse
	err         error
	stdout      string
	stderr      string
}

func (s *stubRequester) DoRaw(_ context.Context, request asc.RawRequest) (*asc.RawResponse, error) {
	s.lastRequest = request
	if s.stdout != "" {
		_, _ = fmt.Fprint(os.Stdout, s.stdout)
	}
	if s.stderr != "" {
		_, _ = fmt.Fprint(os.Stderr, s.stderr)
	}
	return s.response, s.err
}

func TestServiceSessionRequestUsesOpenedSession(t *testing.T) {
	requester := &stubRequester{
		response: &asc.RawResponse{
			StatusCode: 202,
			Headers: map[string][]string{
				"Content-Type": {"application/json"},
			},
			Body: []byte(`{"data":{"id":"app-1"}}`),
		},
	}

	service := NewService("1.2.3")
	service.resolveCredentials = func(profile string) (shared.ResolvedAuthCredentials, error) {
		return shared.ResolvedAuthCredentials{
			KeyID:    "KEY123",
			IssuerID: "ISS456",
			KeyPEM:   "PEM",
			Profile:  profile,
		}, nil
	}
	service.newClient = func(creds shared.ResolvedAuthCredentials) (rawRequester, error) {
		return requester, nil
	}

	openResponse := service.Handle(context.Background(), Request{
		ID:     "open",
		Method: "session.open",
		Params: mustJSON(t, SessionOpenParams{Profile: "work"}),
	})
	if openResponse.Error != nil {
		t.Fatalf("session.open returned error: %#v", openResponse.Error)
	}
	openResult, ok := openResponse.Result.(SessionOpenResult)
	if !ok {
		t.Fatalf("unexpected session.open result type: %T", openResponse.Result)
	}
	if openResult.Session.Profile != "work" {
		t.Fatalf("expected profile work, got %q", openResult.Session.Profile)
	}

	requestResponse := service.Handle(context.Background(), Request{
		ID:     "request",
		Method: "session.request",
		Params: mustJSON(t, SessionRequestParams{
			Method:    "PATCH",
			Path:      "/v1/apps/app-1",
			Headers:   map[string]string{"If-Match": "etag-1"},
			Body:      json.RawMessage(`{"data":{"id":"app-1"}}`),
			TimeoutMS: 2500,
		}),
	})
	if requestResponse.Error != nil {
		t.Fatalf("session.request returned error: %#v", requestResponse.Error)
	}
	requestResult, ok := requestResponse.Result.(SessionRequestResult)
	if !ok {
		t.Fatalf("unexpected session.request result type: %T", requestResponse.Result)
	}
	if requestResult.StatusCode != 202 {
		t.Fatalf("expected status 202, got %d", requestResult.StatusCode)
	}
	if requestResult.ContentType != "application/json" {
		t.Fatalf("expected content type application/json, got %q", requestResult.ContentType)
	}
	if requester.lastRequest.Method != "PATCH" {
		t.Fatalf("expected PATCH method, got %s", requester.lastRequest.Method)
	}
	if requester.lastRequest.Path != "/v1/apps/app-1" {
		t.Fatalf("unexpected request path: %s", requester.lastRequest.Path)
	}
	if string(requester.lastRequest.Body) != `{"data":{"id":"app-1"}}` {
		t.Fatalf("unexpected request body: %s", string(requester.lastRequest.Body))
	}
}

func TestServerStreamsResponses(t *testing.T) {
	service := NewService("9.9.9")
	service.cliRunner = func(args []string, version string) (CLIExecResult, error) {
		return CLIExecResult{
			ExitCode: 0,
			Stdout:   version,
			Stderr:   "",
		}, nil
	}

	input := bytes.NewBufferString("{\"id\":\"1\",\"method\":\"ping\"}\n{\"id\":\"2\",\"method\":\"cli.exec\",\"params\":{\"args\":[\"--version\"]}}\n")
	var output bytes.Buffer

	server := NewServerWithService(input, &output, service)
	if err := server.Run(context.Background()); err != nil {
		t.Fatalf("Run() error: %v", err)
	}

	decoder := json.NewDecoder(&output)

	var pingResponse Response
	if err := decoder.Decode(&pingResponse); err != nil {
		t.Fatalf("decode ping response: %v", err)
	}
	var pingResult PingResult
	if err := remarshalResult(pingResponse.Result, &pingResult); err != nil {
		t.Fatalf("decode ping result: %v", err)
	}
	if pingResult.ProtocolVersion != ProtocolVersion {
		t.Fatalf("expected protocol version %q, got %q", ProtocolVersion, pingResult.ProtocolVersion)
	}

	var execResponse Response
	if err := decoder.Decode(&execResponse); err != nil {
		t.Fatalf("decode exec response: %v", err)
	}
	var execResult CLIExecResult
	if err := remarshalResult(execResponse.Result, &execResult); err != nil {
		t.Fatalf("decode exec result: %v", err)
	}
	if execResult.Stdout != "9.9.9" {
		t.Fatalf("expected stdout 9.9.9, got %q", execResult.Stdout)
	}
}

func TestServiceSessionRequestSuppressesUnexpectedStdout(t *testing.T) {
	requester := &stubRequester{
		response: &asc.RawResponse{
			StatusCode: 200,
			Headers: map[string][]string{
				"Content-Type": {"application/json"},
			},
			Body: []byte(`{"data":{"type":"appPricePoints","id":"pp-1"}}`),
		},
		stdout: "{\n  \"data\": [\n    {\n      \"type\": \"appPricePoints\"\n    }\n  ]\n}\n",
	}

	service := NewService("1.2.3")
	service.resolveCredentials = func(profile string) (shared.ResolvedAuthCredentials, error) {
		return shared.ResolvedAuthCredentials{
			KeyID:    "KEY123",
			IssuerID: "ISS456",
			KeyPEM:   "PEM",
			Profile:  profile,
		}, nil
	}
	service.newClient = func(creds shared.ResolvedAuthCredentials) (rawRequester, error) {
		return requester, nil
	}

	openResponse := service.Handle(context.Background(), Request{
		ID:     "open",
		Method: "session.open",
		Params: mustJSON(t, SessionOpenParams{}),
	})
	if openResponse.Error != nil {
		t.Fatalf("session.open returned error: %#v", openResponse.Error)
	}

	var requestResponse Response
	stdout, stderr, captureErr := captureOutput(func() {
		requestResponse = service.Handle(context.Background(), Request{
			ID:     "request",
			Method: "session.request",
			Params: mustJSON(t, SessionRequestParams{
				Method:    "GET",
				Path:      "/v1/apps/app-1/appPricePoints?filter[territory]=USA&limit=200",
				TimeoutMS: 2500,
			}),
		})
	})
	if captureErr != nil {
		t.Fatalf("captureOutput() error: %v", captureErr)
	}
	if strings.TrimSpace(stdout) != "" {
		t.Fatalf("expected stray stdout to be suppressed, got %q", stdout)
	}
	if !strings.Contains(stderr, "suppressed unexpected stdout during session.request") {
		t.Fatalf("expected suppression warning in stderr, got %q", stderr)
	}
	if requestResponse.Error != nil {
		t.Fatalf("session.request returned error: %#v", requestResponse.Error)
	}
	requestResult, ok := requestResponse.Result.(SessionRequestResult)
	if !ok {
		t.Fatalf("unexpected session.request result type: %T", requestResponse.Result)
	}
	if requestResult.StatusCode != 200 {
		t.Fatalf("expected status 200, got %d", requestResult.StatusCode)
	}
}

func mustJSON(t *testing.T, value any) json.RawMessage {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("Marshal() error: %v", err)
	}
	return data
}

func remarshalResult(input any, target any) error {
	data, err := json.Marshal(input)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, target)
}
