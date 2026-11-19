//go:build darwin || dragonfly || freebsd || netbsd || openbsd

package main

import "syscall"

const terminalSettings = syscall.TIOCGETA
