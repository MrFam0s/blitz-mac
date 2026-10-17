package helper

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/asc"
	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/cli/shared"
)

const defaultRequestTimeout = 30 * time.Second

type rawRequester interface {
	DoRaw(context.Context, asc.RawRequest) (*asc.RawResponse, error)
}

type sessionState struct {
	client rawRequester
	info   SessionInfo
}

type Service struct {
	mu sync.Mutex

	version string
	session *sessionState

	resolveCredentials func(string) (shared.ResolvedAuthCredentials, error)
	newClient          func(shared.ResolvedAuthCredentials) (rawRequester, error)
	cliRunner          func([]string, string) (CLIExecResult, error)
}

var cliRunMu sync.Mutex
var captureIOMu sync.Mutex
var cliExecutablePath = os.Executable

func NewService(version string) *Service {
	return &Service{
		version:            version,
		resolveCredentials: shared.ResolveAuthCredentials,
		newClient:          defaultNewClient,
		cliRunner:          runCLI,
	}
}

func (s *Service) Handle(ctx context.Context, request Request) Response {
	switch request.Method {
	case "ping":
		return Response{
			ID: request.ID,
			Result: PingResult{
				ProtocolVersion: ProtocolVersion,
				Version:         s.version,
				SessionOpen:     s.hasSession(),
			},
		}
	case "session.open":
		var params SessionOpenParams
		if err := decodeParams(request.Params, &params); err != nil {
			return newErrorResponse(request.ID, CodeInvalidRequest, "invalid session.open params", err)
		}
		result, err := s.openSession(params)
		if err != nil {
			return newErrorResponse(request.ID, CodeInternalError, "session open failed", err)
		}
		return Response{ID: request.ID, Result: result}
	case "session.close":
		s.closeSession()
		return Response{ID: request.ID, Result: map[string]bool{"closed": true}}
	case "session.request":
		var params SessionRequestParams
		if err := decodeParams(request.Params, &params); err != nil {
			return newErrorResponse(request.ID, CodeInvalidRequest, "invalid session.request params", err)
		}
		result, err := s.requestWithSession(ctx, params)
		if err != nil {
			return newErrorResponse(request.ID, CodeInternalError, "session request failed", err)
		}
		return Response{ID: request.ID, Result: result}
	case "cli.exec":
		var params CLIExecParams
		if err := decodeParams(request.Params, &params); err != nil {
			return newErrorResponse(request.ID, CodeInvalidRequest, "invalid cli.exec params", err)
		}
		result, err := s.cliRunner(params.Args, s.version)
		if err != nil {
			return newErrorResponse(request.ID, CodeInternalError, "cli exec failed", err)
		}
		return Response{ID: request.ID, Result: result}
	default:
		return Response{
			ID:    request.ID,
			Error: &ResponseError{Code: CodeMethodNotFound, Message: fmt.Sprintf("unknown method %q", request.Method)},
		}
	}
}

func (s *Service) hasSession() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.session != nil
}

func (s *Service) openSession(params SessionOpenParams) (SessionOpenResult, error) {
	creds, err := s.resolveCredentials(strings.TrimSpace(params.Profile))
	if err != nil {
		return SessionOpenResult{}, err
	}

	client, err := s.newClient(creds)
	if err != nil {
		return SessionOpenResult{}, err
	}

	info := SessionInfo{
		Profile:         firstNonEmpty(creds.Profile, strings.TrimSpace(params.Profile)),
		UsesInMemoryKey: strings.TrimSpace(creds.KeyPEM) != "",
	}

	s.mu.Lock()
	s.session = &sessionState{client: client, info: info}
	s.mu.Unlock()

	return SessionOpenResult{Session: info}, nil
}

func (s *Service) closeSession() {
	s.mu.Lock()
	s.session = nil
	s.mu.Unlock()
	shared.CleanupTempPrivateKeys()
}

func (s *Service) requestWithSession(ctx context.Context, params SessionRequestParams) (SessionRequestResult, error) {
	s.mu.Lock()
	session := s.session
	s.mu.Unlock()
	if session == nil {
		return SessionRequestResult{}, fmt.Errorf("session is not open")
	}

	timeout := defaultRequestTimeout
	if params.TimeoutMS > 0 {
		timeout = time.Duration(params.TimeoutMS) * time.Millisecond
	}

	requestCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	request := asc.RawRequest{
		Method:  params.Method,
		Path:    params.Path,
		Headers: params.Headers,
		Body:    cloneBytes(params.Body),
	}

	var (
		response       *asc.RawResponse
		requestErr     error
		captureErr     error
		capturedStdout string
		capturedStderr string
	)

	captureIOMu.Lock()
	capturedStdout, capturedStderr, captureErr = captureOutput(func() {
		response, requestErr = session.client.DoRaw(requestCtx, request)
	})
	captureIOMu.Unlock()
	if captureErr != nil {
		return SessionRequestResult{}, fmt.Errorf("capture request output: %w", captureErr)
	}
	if strings.TrimSpace(capturedStderr) != "" {
		_, _ = fmt.Fprint(os.Stderr, capturedStderr)
	}
	if trimmed := strings.TrimSpace(capturedStdout); trimmed != "" {
		snippet := trimmed
		if len(snippet) > 800 {
			snippet = snippet[:800] + "..."
		}
		_, _ = fmt.Fprintf(
			os.Stderr,
			"ascd: suppressed unexpected stdout during session.request (%d bytes): %s\n",
			len(capturedStdout),
			snippet,
		)
	}
	if requestErr != nil {
		return SessionRequestResult{}, requestErr
	}

	return SessionRequestResult{
		StatusCode:  response.StatusCode,
		Headers:     response.Headers,
		ContentType: firstHeaderValue(response.Headers, "Content-Type"),
		Body:        string(response.Body),
	}, nil
}

func decodeParams(raw json.RawMessage, target any) error {
	if len(bytes.TrimSpace(raw)) == 0 || string(bytes.TrimSpace(raw)) == "null" {
		return nil
	}
	return json.Unmarshal(raw, target)
}

func newErrorResponse(id string, code int, message string, err error) Response {
	responseErr := &ResponseError{
		Code:    code,
		Message: message,
	}
	if err != nil {
		responseErr.Data = err.Error()
	}
	return Response{ID: id, Error: responseErr}
}

func defaultNewClient(creds shared.ResolvedAuthCredentials) (rawRequester, error) {
	if strings.TrimSpace(creds.KeyPEM) != "" {
		return asc.NewClientFromPEM(creds.KeyID, creds.IssuerID, creds.KeyPEM)
	}
	return asc.NewClient(creds.KeyID, creds.IssuerID, creds.KeyPath)
}

func runCLI(args []string, version string) (CLIExecResult, error) {
	cliRunMu.Lock()
	defer cliRunMu.Unlock()

	executable, err := cliExecutablePath()
	if err != nil {
		return CLIExecResult{}, fmt.Errorf("resolve helper executable: %w", err)
	}

	command := exec.Command(executable, append([]string{CLISubprocessModeArg}, args...)...)
	command.Env = append(os.Environ(), fmt.Sprintf("%s=%s", CLIVersionEnvVar, version))

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	err = command.Run()
	exitCode := 0
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
		} else {
			return CLIExecResult{}, fmt.Errorf("run cli subprocess: %w", err)
		}
	}

	return CLIExecResult{
		ExitCode: exitCode,
		Stdout:   stdout.String(),
		Stderr:   stderr.String(),
	}, nil
}

func captureOutput(fn func()) (string, string, error) {
	oldStdout := os.Stdout
	oldStderr := os.Stderr

	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		return "", "", err
	}
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		_ = stdoutR.Close()
		_ = stdoutW.Close()
		return "", "", err
	}

	os.Stdout = stdoutW
	os.Stderr = stderrW
	defer func() {
		os.Stdout = oldStdout
		os.Stderr = oldStderr
	}()

	outC := make(chan string)
	errC := make(chan string)

	go func() {
		var buf bytes.Buffer
		_, _ = io.Copy(&buf, stdoutR)
		_ = stdoutR.Close()
		outC <- buf.String()
	}()

	go func() {
		var buf bytes.Buffer
		_, _ = io.Copy(&buf, stderrR)
		_ = stderrR.Close()
		errC <- buf.String()
	}()

	fn()

	_ = stdoutW.Close()
	_ = stderrW.Close()

	return <-outC, <-errC, nil
}

func firstHeaderValue(headers map[string][]string, name string) string {
	for key, values := range headers {
		if strings.EqualFold(key, name) && len(values) > 0 {
			return values[0]
		}
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func cloneBytes(raw json.RawMessage) []byte {
	if len(raw) == 0 {
		return nil
	}
	return append([]byte(nil), raw...)
}
