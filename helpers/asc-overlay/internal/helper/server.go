package helper

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
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

func (s *Server) Run(ctx context.Context) error {
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
			if encodeErr := s.encoder.Encode(response); encodeErr != nil {
				return fmt.Errorf("decode request: %w (encode parse error response: %v)", err, encodeErr)
			}
			return fmt.Errorf("decode request: %w", err)
		}

		if request.Method == "" {
			if err := s.encoder.Encode(Response{
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

		response := s.service.Handle(ctx, request)
		if err := s.encoder.Encode(response); err != nil {
			return fmt.Errorf("encode response: %w", err)
		}
	}
}
