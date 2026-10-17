package asc

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestDoRawExecutesAuthenticatedRequest(t *testing.T) {
	client := newTestClient(t, func(req *http.Request) {
		assertAuthorized(t, req)
		if req.Method != http.MethodPost {
			t.Fatalf("expected POST request, got %s", req.Method)
		}
		if req.URL.String() != BaseURL+"/v1/apps" {
			t.Fatalf("unexpected request URL: %s", req.URL.String())
		}
		if got := req.Header.Get("If-Match"); got != "etag-1" {
			t.Fatalf("expected If-Match header, got %q", got)
		}
		body, err := io.ReadAll(req.Body)
		if err != nil {
			t.Fatalf("ReadAll() error: %v", err)
		}
		if string(body) != `{"name":"Blitz"}` {
			t.Fatalf("unexpected request body: %s", string(body))
		}
	}, jsonResponse(http.StatusAccepted, `{"data":{"id":"app-1"}}`))

	resp, err := client.DoRaw(context.Background(), RawRequest{
		Method: http.MethodPost,
		Path:   "/v1/apps",
		Headers: map[string]string{
			"If-Match": "etag-1",
		},
		Body: []byte(`{"name":"Blitz"}`),
	})
	if err != nil {
		t.Fatalf("DoRaw() error: %v", err)
	}
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("expected status %d, got %d", http.StatusAccepted, resp.StatusCode)
	}
	if got := string(resp.Body); got != `{"data":{"id":"app-1"}}` {
		t.Fatalf("unexpected response body: %s", got)
	}
	if got := strings.Join(resp.Headers["Content-Type"], ","); got != "application/json" {
		t.Fatalf("expected content type application/json, got %q", got)
	}
}

func TestDoRawRejectsAuthorizationHeader(t *testing.T) {
	client := newTestClient(t, nil, jsonResponse(http.StatusOK, `{}`))

	_, err := client.DoRaw(context.Background(), RawRequest{
		Method: http.MethodGet,
		Path:   "/v1/apps",
		Headers: map[string]string{
			"Authorization": "Bearer test",
		},
	})
	if err == nil || !strings.Contains(err.Error(), "Authorization header is managed by the ASC client") {
		t.Fatalf("expected authorization header error, got %v", err)
	}
}

func TestDoRawRejectsUntrustedAbsoluteURL(t *testing.T) {
	client := newTestClient(t, nil, jsonResponse(http.StatusOK, `{}`))

	_, err := client.DoRaw(context.Background(), RawRequest{
		Method: http.MethodGet,
		Path:   "https://example.com/v1/apps",
	})
	if err == nil || !strings.Contains(err.Error(), "untrusted host") {
		t.Fatalf("expected untrusted host error, got %v", err)
	}
}

func TestDoRawPreservesErrorResponse(t *testing.T) {
	for _, status := range []int{404, 409, 429} {
		response := jsonResponse(status, `{"errors":[{"code":"TEST"}]}`)
		response.Header.Set("Retry-After", "7")
		client := newTestClient(t, nil, response)
		got, err := client.DoRaw(context.Background(), RawRequest{Method: "GET", Path: "/v1/apps"})
		if err != nil || got.StatusCode != status || string(got.Body) != `{"errors":[{"code":"TEST"}]}` || got.Headers["Retry-After"][0] != "7" {
			t.Fatalf("response contract lost: %#v, %v", got, err)
		}
	}
}

func TestDoRawDoesNotFollowRedirect(t *testing.T) {
	calls := 0
	response := jsonResponse(http.StatusTemporaryRedirect, `{}`)
	response.Header.Set("Location", "https://example.com/secret")
	client := newTestClient(t, func(req *http.Request) { calls++ }, response)
	got, err := client.DoRaw(context.Background(), RawRequest{Method: "GET", Path: "/v1/apps"})
	if err != nil || got.StatusCode != http.StatusTemporaryRedirect || calls != 1 {
		t.Fatalf("redirect followed: calls=%d response=%#v err=%v", calls, got, err)
	}
}

func TestDoRawRejectsMutationQuery(t *testing.T) {
	calls := 0
	client := newTestClient(t, func(req *http.Request) { calls++ }, jsonResponse(200, `{}`))
	_, err := client.DoRaw(context.Background(), RawRequest{Method: "PATCH", Path: "/v1/apps/app-1?fields[apps]=name"})
	if err == nil || calls != 0 {
		t.Fatalf("unsafe mutation target accepted: calls=%d err=%v", calls, err)
	}
}
