package helper

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rudrankriyam/App-Store-Connect-CLI/internal/asc"
)

type requestFunc func(context.Context, asc.RawRequest) (*asc.RawResponse, error)

func (f requestFunc) DoRaw(ctx context.Context, req asc.RawRequest) (*asc.RawResponse, error) {
	return f(ctx, req)
}

func TestServerOverlapsReadsButOrdersMutationsAndDrainsEOF(t *testing.T) {
	entered := make(chan string, 8)
	release := make(chan struct{})
	var active atomic.Int32
	var writeDone atomic.Bool
	service := NewServiceWithIsolatedOutput("test")
	service.session = &sessionState{client: requestFunc(func(ctx context.Context, req asc.RawRequest) (*asc.RawResponse, error) {
		switch req.Path {
		case "/read-1", "/read-2":
			active.Add(1)
			entered <- req.Path
			select {
			case <-release:
			case <-ctx.Done():
				return nil, ctx.Err()
			}
			active.Add(-1)
		case "/write":
			if active.Load() != 0 {
				t.Error("mutation overtook pending reads")
			}
			writeDone.Store(true)
		case "/after":
			if !writeDone.Load() {
				t.Error("read overtook mutation")
			}
		}
		return &asc.RawResponse{StatusCode: 200, Body: []byte(req.Path)}, nil
	})}
	input := bytes.NewBuffer(nil)
	enc := json.NewEncoder(input)
	for _, row := range []struct{ id, method, path string }{
		{"1", "GET", "/read-1"}, {"2", "GET", "/read-2"},
		{"3", "PATCH", "/write"}, {"4", "GET", "/after"},
	} {
		_ = enc.Encode(Request{ID: row.id, Method: "session.request", Params: mustJSON(t, SessionRequestParams{Method: row.method, Path: row.path})})
	}
	var output bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- NewServerWithService(input, &output, service).Run(context.Background()) }()
	timer := time.NewTimer(3 * time.Second)
	defer timer.Stop()
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-timer.C:
			close(release)
			<-done
			t.Fatal("second read was blocked by the first read")
		}
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(&output)
	seen := map[string]string{}
	for i := 0; i < 4; i++ {
		var response Response
		if err := dec.Decode(&response); err != nil {
			t.Fatal(err)
		}
		var result SessionRequestResult
		if err := remarshalResult(response.Result, &result); err != nil {
			t.Fatal(err)
		}
		seen[response.ID] = result.Body
	}
	if len(seen) != 4 || seen["1"] != "/read-1" || seen["2"] != "/read-2" || seen["4"] != "/after" {
		t.Fatalf("lost or mismatched response IDs: %#v", seen)
	}
}

func TestServerLimitsConcurrentReads(t *testing.T) {
	entered := make(chan struct{}, 12)
	release := make(chan struct{})
	var active, maximum atomic.Int32
	service := NewServiceWithIsolatedOutput("test")
	service.session = &sessionState{client: requestFunc(func(ctx context.Context, req asc.RawRequest) (*asc.RawResponse, error) {
		current := active.Add(1)
		for {
			old := maximum.Load()
			if current <= old || maximum.CompareAndSwap(old, current) {
				break
			}
		}
		entered <- struct{}{}
		select {
		case <-release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		active.Add(-1)
		return &asc.RawResponse{StatusCode: 200, Body: []byte(`{}`)}, nil
	})}
	input := bytes.NewBuffer(nil)
	for i := 0; i < 12; i++ {
		fmt.Fprintf(input, "{\"id\":\"%d\",\"method\":\"session.request\",\"params\":{\"method\":\"GET\",\"path\":\"/read\"}}\n", i)
	}
	var output bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- NewServerWithService(input, &output, service).Run(context.Background()) }()
	timer := time.NewTimer(3 * time.Second)
	defer timer.Stop()
	for i := 0; i < 4; i++ {
		select {
		case <-entered:
		case <-timer.C:
			close(release)
			<-done
			t.Fatal("read concurrency did not reach four")
		}
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if maximum.Load() != 4 {
		t.Fatalf("expected a maximum of four reads, got %d", maximum.Load())
	}
}
