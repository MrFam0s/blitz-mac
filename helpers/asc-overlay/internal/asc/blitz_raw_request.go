package asc

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// RawRequest is a generic App Store Connect HTTP request executed with the
// client's cached auth and transport state.
type RawRequest struct {
	Method  string
	Path    string
	Headers map[string]string
	Body    []byte
}

// RawResponse contains the raw HTTP response returned by App Store Connect.
type RawResponse struct {
	StatusCode int
	Headers    map[string][]string
	Body       []byte
}

// DoRaw executes an authenticated App Store Connect request without mapping it
// to a typed client method. It preserves response status, headers, and body so
// higher layers can build their own abstractions on top.
func (c *Client) DoRaw(ctx context.Context, request RawRequest) (*RawResponse, error) {
	method := strings.ToUpper(strings.TrimSpace(request.Method))
	if method == "" {
		return nil, fmt.Errorf("HTTP method is required")
	}

	path, err := normalizeRawPath(request.Path)
	if err != nil {
		return nil, err
	}

	if err := validateMutatingRequestTarget(method, path); err != nil {
		return nil, err
	}

	run := func(requestCtx context.Context) (*RawResponse, error) {
		return c.doRawOnce(requestCtx, method, path, request.Headers, request.Body)
	}

	if shouldLimitMutatingMethod(method) {
		return c.doRawWithMutatingRequestLimiter(ctx, run)
	}

	return run(ctx)
}

func (c *Client) doRawWithMutatingRequestLimiter(ctx context.Context, request func(context.Context) (*RawResponse, error)) (*RawResponse, error) {
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("wait for mutating request slot: %w", err)
	}

	requestTimeout, hasDeadline := requestTimeoutBudget(ctx)
	limiter := c.getMutatingRequestLimiter()

	select {
	case limiter <- struct{}{}:
		defer func() { <-limiter }()
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("wait for mutating request slot: %w", err)
		}
	case <-ctx.Done():
		return nil, fmt.Errorf("wait for mutating request slot: %w", ctx.Err())
	}

	requestCtx, cancel := deriveMutatingRequestContext(ctx, requestTimeout, hasDeadline)
	defer cancel()
	return request(requestCtx)
}

func (c *Client) doRawOnce(ctx context.Context, method, path string, headers map[string]string, body []byte) (*RawResponse, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}

	req, err := c.newRequest(ctx, method, path, reader)
	if err != nil {
		return nil, err
	}
	if err := applyRawHeaders(req, headers); err != nil {
		return nil, err
	}

	resp, err := clientWithoutRedirects(c.httpClient).Do(req)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	return &RawResponse{
		StatusCode: resp.StatusCode,
		Headers:    resp.Header.Clone(),
		Body:       respBody,
	}, nil
}

func normalizeRawPath(path string) (string, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", fmt.Errorf("request path is required")
	}
	if !strings.HasPrefix(path, "/") && !strings.Contains(path, "://") {
		path = "/" + path
	}
	if err := validateRawRequestTarget(path); err != nil {
		return "", err
	}
	return path, nil
}

func applyRawHeaders(req *http.Request, headers map[string]string) error {
	for name, value := range headers {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		if strings.EqualFold(name, "Authorization") {
			return fmt.Errorf("Authorization header is managed by the ASC client")
		}
		if containsControlCharacter(name) || containsControlCharacter(value) {
			return fmt.Errorf("header %q contains control characters", name)
		}
		req.Header.Set(name, value)
	}
	return nil
}

func containsControlCharacter(value string) bool {
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return true
		}
	}
	return false
}
