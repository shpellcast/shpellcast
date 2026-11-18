package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type hub struct {
	cfg     config
	mu      sync.RWMutex
	streams map[string]*stream
	live    int64
}

func newHub(cfg config) *hub {
	return &hub{cfg: cfg, streams: make(map[string]*stream)}
}

type msg struct {
	kind string
	data []byte
	n    int
}

type summary struct {
	Duration float64 `json:"duration"`
	Bytes    int64   `json:"bytes"`
	Lines    int64   `json:"lines"`
}

type stream struct {
	id        string
	hub       *hub
	bufMax    int
	created   time.Time
	spillPath string

	mu       sync.Mutex
	buf      []byte
	bytes    int64
	lines    int64
	updated  time.Time
	ended    time.Time
	finished bool
	subs     map[chan msg]struct{}
	spill    *os.File
}

func newID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}

func validID(id string) bool {
	if len(id) != 22 {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func (h *hub) link(id string) string {
	return h.cfg.publicURL + "/s/" + id
}

func (h *hub) create() (*stream, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if int(atomic.LoadInt64(&h.live)) >= h.cfg.maxStreams {
		return nil, errors.New("too many casts running right now, try again in a moment")
	}
	now := time.Now()
	s := &stream{
		id:      newID(),
		hub:     h,
		bufMax:  h.cfg.bufferSize,
		created: now,
		updated: now,
		subs:    make(map[chan msg]struct{}),
	}
	if h.cfg.dataDir != "" {
		s.spillPath = filepath.Join(h.cfg.dataDir, s.id+".log")
		f, err := os.OpenFile(s.spillPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			return nil, fmt.Errorf("disk spill unavailable: %w", err)
		}
		s.spill = f
	}
	h.streams[s.id] = s
	atomic.AddInt64(&h.live, 1)
	return s, nil
}

func (h *hub) get(id string) *stream {
	if !validID(id) {
		return nil
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.streams[id]
}

func (s *stream) write(p []byte) {
	chunk := append([]byte(nil), p...)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.finished {
		return
	}
	s.updated = time.Now()
	s.bytes += int64(len(chunk))
	s.lines += int64(bytes.Count(chunk, []byte{'\n'}))
	s.buf = append(s.buf, chunk...)
	if len(s.buf) > 2*s.bufMax {
		s.buf = append([]byte(nil), s.buf[len(s.buf)-s.bufMax:]...)
	}
	if s.spill != nil {
		if _, err := s.spill.Write(chunk); err != nil {
			log.Printf("disk spill stopped for one cast: %v", err)
			s.spill.Close()
			s.spill = nil
		}
	}
	s.broadcastLocked(msg{kind: "data", data: chunk})
}

func (s *stream) pump(r io.Reader) {
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			s.write(buf[:n])
		}
		if err != nil || s.isFinished() {
			return
		}
	}
}

func (s *stream) isFinished() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.finished
}

// broadcastLocked must be called with s.mu held. A viewer that cannot keep up
// is disconnected; its browser reconnects and replays the history.
func (s *stream) broadcastLocked(m msg) {
	for ch := range s.subs {
		select {
		case ch <- m:
		default:
			close(ch)
			delete(s.subs, ch)
		}
	}
}

func (s *stream) finish() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.finished {
		return
	}
	s.finished = true
	s.ended = time.Now()
	s.updated = s.ended
	if s.spill != nil {
		s.spill.Close()
		s.spill = nil
	}
	s.broadcastLocked(msg{kind: "end"})
	s.subs = make(map[chan msg]struct{})
	if s.hub != nil {
		atomic.AddInt64(&s.hub.live, -1)
	}
}

func (s *stream) subscribe() (chan msg, []byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	snap := append([]byte(nil), s.buf...)
	if s.finished {
		return nil, snap, true
	}
	ch := make(chan msg, 256)
	s.subs[ch] = struct{}{}
	s.broadcastLocked(msg{kind: "viewers", n: len(s.subs)})
	return ch, snap, false
}

func (s *stream) unsubscribe(ch chan msg) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.subs[ch]; ok {
		delete(s.subs, ch)
		close(ch)
		s.broadcastLocked(msg{kind: "viewers", n: len(s.subs)})
	}
}

func (s *stream) summary() summary {
	s.mu.Lock()
	defer s.mu.Unlock()
	end := s.ended
	if end.IsZero() {
		end = time.Now()
	}
	return summary{Duration: end.Sub(s.created).Seconds(), Bytes: s.bytes, Lines: s.lines}
}

func (s *stream) history() []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]byte(nil), s.buf...)
}

func (h *hub) janitor(ctx context.Context) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			h.sweep(now)
		}
	}
}

func (h *hub) sweep(now time.Time) {
	var gone []*stream
	h.mu.Lock()
	for id, s := range h.streams {
		s.mu.Lock()
		stale := now.Sub(s.updated) > h.cfg.ttl
		s.mu.Unlock()
		if stale {
			delete(h.streams, id)
			gone = append(gone, s)
		}
	}
	h.mu.Unlock()
	for _, s := range gone {
		s.finish()
		if s.spillPath != "" {
			os.Remove(s.spillPath)
		}
	}
}

func (h *hub) restore(now time.Time) (int, error) {
	entries, err := os.ReadDir(h.cfg.dataDir)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".log") {
			continue
		}
		id := strings.TrimSuffix(name, ".log")
		if !validID(id) {
			continue
		}
		path := filepath.Join(h.cfg.dataDir, name)
		info, err := e.Info()
		if err != nil {
			continue
		}
		if now.Sub(info.ModTime()) > h.cfg.ttl {
			os.Remove(path)
			continue
		}
		s, err := h.loadSpilled(id, path, info)
		if err != nil {
			log.Printf("skipping a cast that could not be restored: %v", err)
			continue
		}
		h.streams[id] = s
		n++
	}
	return n, nil
}

func (h *hub) loadSpilled(id, path string, info fs.FileInfo) (*stream, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	mod := info.ModTime()
	s := &stream{
		id:        id,
		bufMax:    h.cfg.bufferSize,
		created:   mod,
		updated:   mod,
		ended:     mod,
		finished:  true,
		spillPath: path,
		subs:      make(map[chan msg]struct{}),
		bytes:     info.Size(),
	}
	counter := make([]byte, 64*1024)
	for {
		n, rerr := f.Read(counter)
		s.lines += int64(bytes.Count(counter[:n], []byte{'\n'}))
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return nil, rerr
		}
	}
	tailStart := info.Size() - int64(h.cfg.bufferSize)
	if tailStart < 0 {
		tailStart = 0
	}
	if _, err := f.Seek(tailStart, io.SeekStart); err != nil {
		return nil, err
	}
	tail, err := io.ReadAll(f)
	if err != nil {
		return nil, err
	}
	s.buf = tail
	return s, nil
}
