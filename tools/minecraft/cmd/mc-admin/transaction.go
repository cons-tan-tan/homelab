package main

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
)

type move struct{ from, to string }

// Keep staging data and markers when recovery fails so start cannot hide an incomplete operation.
type recoveryError struct{ err error }

func (e *recoveryError) Error() string { return e.err.Error() }
func (e *recoveryError) Unwrap() error { return e.err }

func (a *app) moveDirectory(from, to string) error {
	if err := directory(from, false); err != nil {
		return err
	}
	present, err := exists(to)
	if err != nil {
		return err
	}
	if present {
		return fmt.Errorf("refusing to replace an existing path: %s", to)
	}
	return a.rename(from, to)
}

// Each rename is atomic, but switching several roots requires recovery and persistent markers.
func (a *app) switchData(ctx context.Context, source string, roots []string, consume bool) (retained string, err error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	retained, err = a.createRollback(roots)
	if err != nil {
		return "", err
	}
	var moves []move
	sourceMarked, committed := false, false
	defer func() {
		if err == nil || committed {
			return
		}
		var recovery []error
		for i := len(moves) - 1; i >= 0; i-- {
			// Ignore cancellation during recovery to avoid leaving partially installed live data.
			if e := a.moveDirectory(moves[i].to, moves[i].from); e != nil {
				recovery = append(recovery, e)
			}
		}
		if len(recovery) == 0 {
			if e := discardEmptyRollback(retained); e != nil {
				recovery = append(recovery, e)
			}
		}
		if len(recovery) == 0 && sourceMarked {
			if e := finalizeRollback(source); e != nil {
				recovery = append(recovery, e)
			}
		}
		if len(recovery) != 0 {
			err = &recoveryError{errors.Join(err, fmt.Errorf("Data recovery failed; inspect %s and %s", retained, source), errors.Join(recovery...))}
		}
	}()
	if consume {
		if err = markIncomplete(source); err != nil {
			return retained, err
		}
		sourceMarked = true
	}
	moveRoot := func(from, to string) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		present, err := exists(from)
		if err != nil || !present {
			return err
		}
		if err := a.moveDirectory(from, to); err != nil {
			return err
		}
		moves = append(moves, move{from, to})
		return nil
	}
	for _, root := range roots {
		if err = moveRoot(filepath.Join(a.cfg.dataDir, root), filepath.Join(retained, root)); err != nil {
			return retained, err
		}
	}
	for _, root := range roots {
		if err = moveRoot(filepath.Join(source, root), filepath.Join(a.cfg.dataDir, root)); err != nil {
			return retained, err
		}
	}
	if err = ctx.Err(); err != nil {
		return retained, err
	}
	if err = finalizeRollback(retained); err != nil {
		return retained, err
	}
	committed = true
	if consume {
		if err = discardEmptyRollback(source); err != nil {
			return retained, fmt.Errorf("Applied rollback but failed to remove %s: %w", source, err)
		}
	}
	return retained, nil
}
