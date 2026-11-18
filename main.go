package main

import (
	"context"
	"embed"
	"errors"
	"flag"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

//go:embed index.html assets
var siteFS embed.FS

type config struct {
	httpAddr   string
	tcpAddr    string
	publicURL  string
	dataDir    string
	ttl        time.Duration
	bufferSize int
	maxStreams int
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func loadConfig() config {
	ttl, err := time.ParseDuration(envOr("SHPELLCAST_TTL", "24h"))
	if err != nil {
		ttl = 24 * time.Hour
	}
	buf, _ := strconv.Atoi(envOr("SHPELLCAST_BUFFER_BYTES", "262144"))
	maxStreams, _ := strconv.Atoi(envOr("SHPELLCAST_MAX_STREAMS", "10000"))
	return config{
		httpAddr:   envOr("SHPELLCAST_HTTP_ADDR", ":8080"),
		tcpAddr:    envOr("SHPELLCAST_TCP_ADDR", ":9000"),
		publicURL:  envOr("SHPELLCAST_PUBLIC_URL", ""),
		dataDir:    envOr("SHPELLCAST_DATA_DIR", ""),
		ttl:        ttl,
		bufferSize: buf,
		maxStreams: maxStreams,
	}
}

func portOf(addr string) string {
	if i := strings.LastIndex(addr, ":"); i >= 0 {
		return addr[i:]
	}
	return ":8080"
}

func main() {
	cfg := loadConfig()
	flag.StringVar(&cfg.httpAddr, "http", cfg.httpAddr, "web and curl listen address")
	flag.StringVar(&cfg.tcpAddr, "tcp", cfg.tcpAddr, "raw TCP listen address for nc")
	flag.StringVar(&cfg.publicURL, "public-url", cfg.publicURL, "public base URL used in links, e.g. https://shpellcast.godtech.in")
	flag.StringVar(&cfg.dataDir, "data-dir", cfg.dataDir, "directory for disk spill (empty = memory only)")
	flag.DurationVar(&cfg.ttl, "ttl", cfg.ttl, "how long a link lives after output stops")
	flag.IntVar(&cfg.bufferSize, "buffer-bytes", cfg.bufferSize, "in-memory history kept per cast")
	flag.IntVar(&cfg.maxStreams, "max-streams", cfg.maxStreams, "maximum casts running at once")
	flag.Parse()

	if cfg.bufferSize < 1024 {
		cfg.bufferSize = 1024
	}
	if cfg.maxStreams < 1 {
		cfg.maxStreams = 1
	}
	if cfg.publicURL == "" {
		cfg.publicURL = "http://localhost" + portOf(cfg.httpAddr)
	}
	cfg.publicURL = strings.TrimRight(cfg.publicURL, "/")

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	h := newHub(cfg)
	if cfg.dataDir != "" {
		if err := os.MkdirAll(cfg.dataDir, 0o700); err != nil {
			log.Fatalf("data directory: %v", err)
		}
		n, err := h.restore(time.Now())
		if err != nil {
			log.Fatalf("restoring casts: %v", err)
		}
		log.Printf("restored %d casts from %s", n, cfg.dataDir)
	}
	go h.janitor(ctx)

	tcpLn, err := net.Listen("tcp", cfg.tcpAddr)
	if err != nil {
		log.Fatalf("nc listener %s: %v", cfg.tcpAddr, err)
	}
	go h.serveTCP(tcpLn)

	srv := &http.Server{
		Addr:              cfg.httpAddr,
		Handler:           h.routes(),
		ReadHeaderTimeout: 15 * time.Second,
	}
	go func() {
		<-ctx.Done()
		tcpLn.Close()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdownCtx)
	}()

	log.Printf("shpellcast ready: web %s, nc %s, links at %s", cfg.httpAddr, cfg.tcpAddr, cfg.publicURL)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func (h *hub) routes() http.Handler {
	assets, err := fs.Sub(siteFS, "assets")
	if err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", h.page("index.html"))
	mux.HandleFunc("GET /s/{id}", h.page("assets/viewer.html"))
	mux.HandleFunc("GET /s/{id}/events", h.handleEvents)
	mux.HandleFunc("GET /s/{id}/raw", h.handleRaw)
	mux.HandleFunc("POST /ingest", h.handleIngest)
	mux.HandleFunc("PUT /ingest", h.handleIngest)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("ok\n"))
	})
	mux.Handle("GET /assets/", http.StripPrefix("/assets/", http.FileServer(http.FS(assets))))
	return mux
}

func (h *hub) page(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		b, err := fs.ReadFile(siteFS, name)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		hd := w.Header()
		hd.Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")
		hd.Set("X-Content-Type-Options", "nosniff")
		hd.Set("Referrer-Policy", "no-referrer")
		hd.Set("X-Robots-Tag", "noindex, nofollow")
		hd.Set("Content-Type", "text/html; charset=utf-8")
		w.Write(b)
	}
}
