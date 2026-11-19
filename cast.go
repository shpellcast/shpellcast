package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
	"unicode"
)

type castReceipt struct {
	URL string `json:"url"`
	TTL string `json:"ttl,omitempty"`
}

func runCast(args []string, input, output, diagnostics *os.File) error {
	flags := flag.NewFlagSet("cast", flag.ContinueOnError)
	flags.SetOutput(diagnostics)
	server := flags.String("server", envOr("SHPELLCAST_PUBLIC_URL", "http://localhost:8080"), "base URL of the shpellcast server")
	quiet := flags.Bool("quiet", false, "print only the URL")
	asJSON := flags.Bool("json", false, "print one JSON object with the URL and available TTL")
	flags.Usage = func() {
		fmt.Fprintln(flags.Output(), "Usage: command | shpellcast cast [--server URL] [--quiet | --json]")
		flags.PrintDefaults()
	}
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 || (*quiet && *asJSON) {
		return errors.New("see shpellcast cast --help for valid options")
	}
	if isTerminal(input) {
		return errors.New("pipe a command into shpellcast cast or redirect a file to stdin")
	}
	endpoint, err := url.Parse(*server)
	if err != nil || endpoint.Hostname() == "" || endpoint.User != nil ||
		endpoint.RawQuery != "" || endpoint.ForceQuery || endpoint.Fragment != "" ||
		(endpoint.Scheme != "https" && endpoint.Scheme != "http") {
		return errors.New("--server must be an HTTP or HTTPS base URL without credentials, a query, or a fragment")
	}
	reqURL := strings.TrimRight(endpoint.String(), "/") + "/ingest"
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, reqURL, input)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	client := &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}

	interactive := !*quiet && !*asJSON && isTerminal(output) && isTerminal(diagnostics)
	finishEffect := func() {}
	if interactive {
		finishEffect = castEffect(diagnostics)
	}
	resp, err := client.Do(req)
	finishEffect()
	if err != nil {
		return fmt.Errorf("opening cast: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("opening cast: server returned %s", resp.Status)
	}
	body := bufio.NewReaderSize(resp.Body, 4096)
	line, err := body.ReadSlice('\n')
	if err != nil {
		return fmt.Errorf("reading cast link: %w", err)
	}
	link := strings.TrimSuffix(string(line), "\n")
	parsed, err := url.Parse(link)
	if err != nil || parsed.Hostname() == "" || parsed.User != nil ||
		(parsed.Scheme != "https" && parsed.Scheme != "http") || strings.IndexFunc(link, unsafeLinkRune) >= 0 {
		return errors.New("server returned an invalid cast URL")
	}
	receipt := castReceipt{URL: link}
	ttl, ttlErr := time.ParseDuration(resp.Header.Get("Shpellcast-TTL"))
	if ttlErr == nil && ttl > 0 {
		receipt.TTL = ttl.String()
	}
	if *asJSON {
		err = json.NewEncoder(output).Encode(receipt)
	} else {
		if interactive {
			fmt.Fprintln(diagnostics, randomCastPhrase("✨ Your portal is ready.", "The spell took hold. Share this link:", "✦ Your cast has a doorway."))
		}
		_, err = fmt.Fprintln(output, receipt.URL)
	}
	if err != nil {
		return err
	}
	if interactive {
		if receipt.TTL != "" {
			fmt.Fprintf(diagnostics, "Expires %s after output stops. ", formatCastTTL(ttl))
		}
		fmt.Fprintln(diagnostics, "Open in a browser. Anyone with the link can watch.")
	}
	if _, err := io.Copy(io.Discard, body); err != nil {
		return fmt.Errorf("streaming cast: %w", err)
	}
	return nil
}

func unsafeLinkRune(r rune) bool {
	return unicode.IsSpace(r) || unicode.IsControl(r) || unicode.In(r, unicode.Cf)
}

func formatCastTTL(ttl time.Duration) string {
	text := ttl.String()
	if ttl >= time.Minute && ttl%time.Minute == 0 {
		text = strings.TrimSuffix(text, "0s")
	}
	if ttl >= time.Hour && ttl%time.Hour == 0 {
		text = strings.TrimSuffix(text, "0m")
	}
	return text
}

func randomCastPhrase(phrases ...string) string {
	return phrases[rand.IntN(len(phrases))]
}

func castEffect(w io.Writer) func() {
	phrase := randomCastPhrase("🪄 Casting your stream into the ether", "Opening a doorway for your output", "Conjuring your watch link")
	if term := os.Getenv("TERM"); term == "" || term == "dumb" || os.Getenv("SHPELLCAST_REDUCED_MOTION") != "" {
		fmt.Fprintln(w, phrase+"…")
		return func() {}
	}
	mark := "."
	if os.Getenv("NO_COLOR") == "" {
		mark = "\x1b[32m.\x1b[0m"
	}
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(140 * time.Millisecond)
		defer ticker.Stop()
		frame := 0
		for {
			select {
			case <-stop:
				if frame > 0 {
					fmt.Fprint(w, "\r\x1b[2K")
				}
				return
			case <-ticker.C:
				fmt.Fprintf(w, "\r\x1b[2K%s %s", phrase, strings.Repeat(mark, frame%3+1))
				frame++
			}
		}
	}()
	return func() {
		close(stop)
		<-done
	}
}
