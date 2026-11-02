package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

func (a *app) withLock(ctx context.Context, operation func() error) error {
	file, err := os.OpenFile(filepath.Join(a.cfg.dataDir, ".minecraft-admin-operation.lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	defer file.Close()
	lockContext, cancel := context.WithTimeout(ctx, a.cfg.waitTimeout)
	defer cancel()
	for {
		if err := lockContext.Err(); err != nil {
			return fmt.Errorf("Timed out waiting for another Minecraft admin operation: %w", err)
		}
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			return err
		}
		select {
		case <-lockContext.Done():
			return fmt.Errorf("Timed out waiting for another Minecraft admin operation: %w", lockContext.Err())
		case <-time.After(50 * time.Millisecond):
		}
	}
	defer syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	return operation()
}
