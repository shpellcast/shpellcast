package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestCastPrintsReceiptBeforeInputEnds(t *testing.T) {
	h := newHub(config{bufferSize: 1024, maxStreams: 1, ttl: time.Hour})
	srv := httptest.NewUnstartedServer(h.routes())
	h.cfg.publicURL = "http://" + srv.Listener.Addr().String()
	srv.Start()
	defer srv.Close()

	input, producer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	defer producer.Close()
	consumer, output, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer consumer.Close()
	defer output.Close()

	complete := make(chan error, 1)
	go func() {
		defer output.Close()
		complete <- runCast([]string{"--server", srv.URL, "--json"}, input, output, os.Stderr)
	}()
	line := make(chan string, 1)
	go func() {
		text, _ := bufio.NewReader(consumer).ReadString('\n')
		line <- text
	}()
	var receipt castReceipt
	select {
	case text := <-line:
		if err := json.Unmarshal([]byte(text), &receipt); err != nil {
			t.Fatalf("expected an immediate JSON receipt, got %q: %v", text, err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cast link did not arrive while stdin was still open")
	}
	if receipt.TTL != "1h0m0s" || !strings.HasPrefix(receipt.URL, srv.URL+"/s/") {
		t.Fatalf("unexpected receipt: %+v", receipt)
	}
	if _, err := producer.WriteString("first line\n"); err != nil {
		t.Fatal(err)
	}
	if err := producer.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-complete:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cast client did not finish after stdin closed")
	}
	stream := h.get(strings.TrimPrefix(receipt.URL, srv.URL+"/s/"))
	if stream == nil || string(stream.history()) != "first line\n" {
		t.Fatal("cast output was not received intact")
	}
}

func TestCastPlainReceipts(t *testing.T) {
	for _, mode := range []string{"default", "quiet"} {
		t.Run(mode, func(t *testing.T) {
			h := newHub(config{bufferSize: 1024, maxStreams: 1, ttl: time.Hour})
			srv := httptest.NewUnstartedServer(h.routes())
			h.cfg.publicURL = "http://" + srv.Listener.Addr().String()
			srv.Start()
			defer srv.Close()

			input := castTestFile(t)
			if _, err := input.WriteString("plain output\n"); err != nil {
				t.Fatal(err)
			}
			if _, err := input.Seek(0, io.SeekStart); err != nil {
				t.Fatal(err)
			}
			output := castTestFile(t)
			diagnostics := castTestFile(t)
			args := []string{"--server", srv.URL}
			if mode == "quiet" {
				args = append(args, "--quiet")
			}
			if err := runCast(args, input, output, diagnostics); err != nil {
				t.Fatal(err)
			}
			receipt, err := os.ReadFile(output.Name())
			if err != nil {
				t.Fatal(err)
			}
			link := strings.TrimSuffix(string(receipt), "\n")
			id, ok := strings.CutPrefix(link, srv.URL+"/s/")
			if !ok || !validID(id) || string(receipt) != link+"\n" {
				t.Fatalf("expected a single plain URL, got %q", receipt)
			}
			if messages, err := os.ReadFile(diagnostics.Name()); err != nil || len(messages) != 0 {
				t.Fatalf("unexpected terminal output: %q (%v)", messages, err)
			}
		})
	}
}

func castTestFile(t *testing.T) *os.File {
	t.Helper()
	file, err := os.CreateTemp(t.TempDir(), "cast")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { file.Close() })
	return file
}
