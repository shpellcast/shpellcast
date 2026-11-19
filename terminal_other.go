//go:build !darwin && !dragonfly && !freebsd && !linux && !netbsd && !openbsd && !windows

package main

import "os"

func isTerminal(*os.File) bool { return false }
