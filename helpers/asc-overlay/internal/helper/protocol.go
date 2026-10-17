package helper

import "encoding/json"

const ProtocolVersion = "1"

const (
	CLISubprocessModeArg = "__ascd_run_cli__"
	CLIVersionEnvVar     = "ASC_HELPER_CLI_VERSION"
)

const (
	CodeParseError     = -32700
	CodeInvalidRequest = -32600
	CodeMethodNotFound = -32601
	CodeInternalError  = -32603
)

type Request struct {
	ID     string          `json:"id,omitempty"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	ID     string         `json:"id,omitempty"`
	Result any            `json:"result,omitempty"`
	Error  *ResponseError `json:"error,omitempty"`
}

type ResponseError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    string `json:"data,omitempty"`
}

type PingResult struct {
	ProtocolVersion string `json:"protocolVersion"`
	Version         string `json:"version"`
	SessionOpen     bool   `json:"sessionOpen"`
}

type SessionOpenParams struct {
	Profile string `json:"profile,omitempty"`
}

type SessionInfo struct {
	Profile         string `json:"profile,omitempty"`
	UsesInMemoryKey bool   `json:"usesInMemoryKey"`
}

type SessionOpenResult struct {
	Session SessionInfo `json:"session"`
}

type SessionRequestParams struct {
	Method    string            `json:"method"`
	Path      string            `json:"path"`
	Headers   map[string]string `json:"headers,omitempty"`
	Body      json.RawMessage   `json:"body,omitempty"`
	TimeoutMS int               `json:"timeoutMs,omitempty"`
}

type SessionRequestResult struct {
	StatusCode  int                 `json:"statusCode"`
	Headers     map[string][]string `json:"headers,omitempty"`
	ContentType string              `json:"contentType,omitempty"`
	Body        string              `json:"body,omitempty"`
}

type CLIExecParams struct {
	Args []string `json:"args"`
}

type CLIExecResult struct {
	ExitCode int    `json:"exitCode"`
	Stdout   string `json:"stdout,omitempty"`
	Stderr   string `json:"stderr,omitempty"`
}
