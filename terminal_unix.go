//go:build darwin || dragonfly || freebsd || linux || netbsd || openbsd

package main

import (
	"os"
	"syscall"
	"unsafe"
)

func isTerminal(file *os.File) bool {
	conn, err := file.SyscallConn()
	if err != nil {
		return false
	}
	var terminal bool
	err = conn.Control(func(fd uintptr) {
		var settings syscall.Termios
		_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, terminalSettings, uintptr(unsafe.Pointer(&settings)))
		terminal = errno == 0
	})
	return err == nil && terminal
}
