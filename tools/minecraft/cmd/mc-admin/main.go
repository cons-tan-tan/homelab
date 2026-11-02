package main

import (
	"context"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
)

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	var interrupted atomic.Int32
	go func() {
		select {
		case sig := <-signals:
			interrupted.Store(int32(128 + sig.(syscall.Signal)))
			cancel()
		case <-ctx.Done():
		}
	}()
	code := run(ctx, os.Args[1:], os.Getenv, os.Stdin, os.Stdout, os.Stderr)
	cancel()
	signal.Stop(signals)
	if sig := interrupted.Load(); sig != 0 {
		code = int(sig)
	}
	os.Exit(code)
}
