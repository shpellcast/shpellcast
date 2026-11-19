package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"time"
)

func (h *hub) serveTCP(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("nc listener: %v", err)
			time.Sleep(50 * time.Millisecond)
			continue
		}
		go h.handleTCP(conn)
	}
}

func (h *hub) handleTCP(conn net.Conn) {
	defer conn.Close()
	s, err := h.create()
	if err != nil {
		fmt.Fprintf(conn, "shpellcast: %v\n", err)
		return
	}
	defer s.finish()
	fmt.Fprintf(conn, "%s\n", h.link(s.id))
	s.pump(conn)
}

func (h *hub) handleIngest(w http.ResponseWriter, r *http.Request) {
	rc := http.NewResponseController(w)
	_ = rc.EnableFullDuplex()
	s, err := h.create()
	if err != nil {
		http.Error(w, "shpellcast: "+err.Error()+"\n", http.StatusServiceUnavailable)
		return
	}
	defer s.finish()
	hd := w.Header()
	hd.Set("Content-Type", "text/plain; charset=utf-8")
	hd.Set("Cache-Control", "no-store")
	hd.Set("X-Accel-Buffering", "no")
	hd.Set("Shpellcast-TTL", h.cfg.ttl.String())
	fmt.Fprintf(w, "%s\n", h.link(s.id))
	if err := rc.Flush(); err != nil {
		return
	}
	s.pump(r.Body)
}

func writeEvent(w io.Writer, event string, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, b)
}

func (h *hub) handleEvents(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Robots-Tag", noIndex)
	s := h.get(r.PathValue("id"))
	if s == nil {
		http.NotFound(w, r)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	ch, snap, finished := s.subscribe()
	if ch != nil {
		defer s.unsubscribe(ch)
	}
	hd := w.Header()
	hd.Set("Content-Type", "text/event-stream")
	hd.Set("Cache-Control", "no-cache")
	hd.Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	writeEvent(w, "snapshot", map[string]string{"t": string(snap)})
	flusher.Flush()
	if finished {
		writeEvent(w, "end", s.summary())
		flusher.Flush()
		return
	}
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
			fmt.Fprint(w, ": ping\n\n")
			flusher.Flush()
		case m, ok := <-ch:
			if !ok {
				return
			}
			switch m.kind {
			case "data":
				writeEvent(w, "data", map[string]string{"t": string(m.data)})
			case "viewers":
				writeEvent(w, "viewers", map[string]int{"n": m.n})
			case "end":
				writeEvent(w, "end", s.summary())
				flusher.Flush()
				return
			}
			flusher.Flush()
		}
	}
}

func (h *hub) handleRaw(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Robots-Tag", noIndex)
	s := h.get(r.PathValue("id"))
	if s == nil {
		http.NotFound(w, r)
		return
	}
	hd := w.Header()
	hd.Set("Content-Type", "text/plain; charset=utf-8")
	hd.Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.log"`, s.id))
	hd.Set("X-Content-Type-Options", "nosniff")
	if s.spillPath != "" {
		f, err := os.Open(s.spillPath)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		defer f.Close()
		io.Copy(w, f)
		return
	}
	w.Write(s.history())
}
