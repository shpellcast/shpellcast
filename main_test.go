package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHomepageIndexing(t *testing.T) {
	for _, tt := range []struct {
		name      string
		indexHome bool
		homeTag   string
	}{
		{name: "default", homeTag: noIndex},
		{name: "enabled", indexHome: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			h := newHub(config{indexHome: tt.indexHome, maxStreams: 1, bufferSize: 1024})
			cast, err := h.create()
			if err != nil {
				t.Fatal(err)
			}
			cast.write([]byte("build completed\n"))
			cast.finish()
			routes := h.routes()
			path := "/s/" + cast.id

			for _, page := range []struct{ path, tag string }{
				{"/", tt.homeTag},
				{path, noIndex},
				{path + "/events", noIndex},
				{path + "/raw", noIndex},
			} {
				response := httptest.NewRecorder()
				routes.ServeHTTP(response, httptest.NewRequest(http.MethodGet, page.path, nil))
				if response.Code != http.StatusOK {
					t.Errorf("GET %s returned %d", page.path, response.Code)
				}
				if got := response.Header().Get("X-Robots-Tag"); got != page.tag {
					t.Errorf("GET %s X-Robots-Tag = %q, want %q", page.path, got, page.tag)
				}
			}
		})
	}
}
