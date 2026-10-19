package helper

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"sync"
)

type Server struct {
	decoder *json.Decoder
	encoder *json.Encoder
	service *Service
}

func NewServer(in io.Reader, out io.Writer, version string) *Server {
	return NewServerWithService(in, out, NewService(version))
}

func NewServerWithService(in io.Reader, out io.Writer, service *Service) *Server {
	decoder := json.NewDecoder(in)
	decoder.DisallowUnknownFields()

	encoder := json.NewEncoder(out)
	encoder.SetEscapeHTML(false)

	return &Server{
		decoder: decoder,
		encoder: encoder,
		service: service,
	}
}

// Only safe reads may overlap. Session changes, CLI calls and mutations form
// barriers so callers retain the original ordered write semantics.
func (s *Server) Run(ctx context.Context) (result error) {
	var pending sync.WaitGroup
	var outputMu sync.Mutex
	var outputError error
	slots := make(chan struct{}, 4)
	encode := func(response Response) error {
		outputMu.Lock()
		defer outputMu.Unlock()
		if outputError != nil {
			return outputError
		}
		outputError = s.encoder.Encode(response)
		return outputError
	}
	defer func() {
		pending.Wait()
		outputMu.Lock()
		defer outputMu.Unlock()
		if result == nil {
			result = outputError
		}
	}()
	for {
		var request Request
		if err := s.decoder.Decode(&request); err != nil {
			if err == io.EOF {
				return nil
			}
			response := Response{
				Error: &ResponseError{
					Code:    CodeParseError,
					Message: "failed to decode request",
					Data:    err.Error(),
				},
			}
			if encodeErr := encode(response); encodeErr != nil {
				return fmt.Errorf("decode request: %w (encode parse error response: %v)", err, encodeErr)
			}
			return fmt.Errorf("decode request: %w", err)
		}

		if request.Method == "" {
			if err := encode(Response{
				ID: request.ID,
				Error: &ResponseError{
					Code:    CodeInvalidRequest,
					Message: "method is required",
				},
			}); err != nil {
				return err
			}
			continue
		}

		var params SessionRequestParams
		isRead := request.Method == "session.request" && json.Unmarshal(request.Params, &params) == nil &&
			(strings.EqualFold(strings.TrimSpace(params.Method), "GET") || strings.EqualFold(strings.TrimSpace(params.Method), "HEAD"))
		if isRead {
			select {
			case slots <- struct{}{}:
			case <-ctx.Done():
				return ctx.Err()
			}
			pending.Add(1)
			go func(request Request) {
				defer pending.Done()
				defer func() { <-slots }()
				_ = encode(s.service.Handle(ctx, request))
			}(request)
		} else {
			pending.Wait()
			if err := encode(s.service.Handle(ctx, request)); err != nil {
				return fmt.Errorf("encode response: %w", err)
			}
		}
	}
}
