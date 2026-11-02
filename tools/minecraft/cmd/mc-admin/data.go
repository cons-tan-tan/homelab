package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"
	"time"
)

const (
	rollbackDirectory = ".minecraft-admin-rollbacks"
	incompleteMarker  = ".incomplete"
	rootsManifest     = ".roots"
	stagingPrefix     = ".minecraft-admin-restore."
)

var rootPattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
var idPattern = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z\.[A-Za-z0-9]{6}$`)

func parseRoots(value string) ([]string, error) {
	roots := strings.Fields(value)
	if len(roots) == 0 {
		return nil, errors.New("MINECRAFT_RESTORE_ROOTS is required for restore and rollback operations")
	}
	seen := map[string]bool{}
	for _, root := range roots {
		if !rootPattern.MatchString(root) || root == "." || root == ".." {
			return nil, fmt.Errorf("Invalid restore root: %s", root)
		}
		if root == rootsManifest || root == incompleteMarker || strings.HasPrefix(root, ".minecraft-admin-") {
			return nil, fmt.Errorf("Reserved restore root: %s", root)
		}
		if seen[root] {
			return nil, fmt.Errorf("Duplicate restore root: %s", root)
		}
		seen[root] = true
	}
	return roots, nil
}

func exists(path string) (bool, error) {
	_, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

func directory(path string, optional bool) error {
	info, err := os.Lstat(path)
	if optional && errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("not a directory (or is a symbolic link): %s", path)
	}
	return nil
}

func (a *app) rollbackRoot() string { return filepath.Join(a.cfg.dataDir, rollbackDirectory) }

func (a *app) validateLive(roots []string) error {
	for _, root := range roots {
		if err := directory(filepath.Join(a.cfg.dataDir, root), true); err != nil {
			return fmt.Errorf("Current data root is not a directory: %s: %w", root, err)
		}
	}
	return nil
}

func (a *app) assertComplete() error {
	if err := directory(a.rollbackRoot(), true); err != nil {
		return err
	}
	entries, err := os.ReadDir(a.rollbackRoot())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		marker := filepath.Join(a.rollbackRoot(), entry.Name(), incompleteMarker)
		present, err := exists(marker)
		if err != nil {
			return err
		}
		if present {
			return incompleteError(marker)
		}
	}
	entries, err = os.ReadDir(a.cfg.dataDir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), stagingPrefix) {
			return incompleteError(filepath.Join(a.cfg.dataDir, entry.Name()))
		}
	}
	return nil
}

func incompleteError(path string) error {
	return fmt.Errorf("Refusing to start while an incomplete data operation exists: %s\nInspect the retained and live data before removing the incomplete operation.", path)
}

func (a *app) createRollback(roots []string) (string, error) {
	parent := a.rollbackRoot()
	if err := directory(parent, true); err != nil {
		return "", err
	}
	if err := os.MkdirAll(parent, 0755); err != nil {
		return "", err
	}
	// Keep the six-character suffix compatible with existing rollback IDs.
	for range 10 {
		var random [3]byte
		if _, err := rand.Read(random[:]); err != nil {
			return "", err
		}
		id := time.Now().UTC().Format("20060102T150405Z") + fmt.Sprintf(".%x", random)
		path := filepath.Join(parent, id)
		if err := os.Mkdir(path, 0700); err != nil {
			if errors.Is(err, os.ErrExist) {
				continue
			}
			return "", err
		}
		if err := markIncomplete(path); err != nil {
			return "", errors.Join(err, os.Remove(path))
		}
		if err := os.WriteFile(filepath.Join(path, rootsManifest), []byte(strings.Join(roots, "\n")+"\n"), 0600); err != nil {
			return "", errors.Join(err, discardEmptyRollback(path))
		}
		return path, nil
	}
	return "", errors.New("could not allocate a unique rollback ID")
}

func markIncomplete(path string) error {
	f, err := os.OpenFile(filepath.Join(path, incompleteMarker), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	return f.Close()
}

func finalizeRollback(path string) error {
	marker := filepath.Join(path, incompleteMarker)
	info, err := os.Lstat(marker)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("Rollback transaction marker is invalid: %s", filepath.Base(path))
	}
	return os.Remove(marker)
}

func discardEmptyRollback(path string) error {
	entries, err := os.ReadDir(path)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.Name() != incompleteMarker && entry.Name() != rootsManifest {
			return fmt.Errorf("refusing to discard retained data in %s", path)
		}
	}
	// Keep the incomplete marker until all other cleanup has succeeded.
	if err := os.Remove(filepath.Join(path, rootsManifest)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.Remove(filepath.Join(path, incompleteMarker)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return os.Remove(path)
}

func (a *app) rollbackIDs() ([]string, error) {
	if err := directory(a.rollbackRoot(), true); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(a.rollbackRoot())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, entry := range entries {
		if entry.IsDir() && idPattern.MatchString(entry.Name()) {
			ids = append(ids, entry.Name())
		}
	}
	slices.Reverse(ids)
	return ids, nil
}

func rollbackStatus(path string) (string, error) {
	present, err := exists(filepath.Join(path, incompleteMarker))
	if err != nil {
		return "", err
	}
	if present {
		return "INCOMPLETE", nil
	}
	info, err := os.Lstat(filepath.Join(path, rootsManifest))
	if errors.Is(err, os.ErrNotExist) {
		return "INVALID", nil
	}
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "INVALID", nil
	}
	return "READY", nil
}

func (a *app) resolveRollback(id string) (string, error) {
	if err := directory(a.rollbackRoot(), true); err != nil {
		return "", err
	}
	if id == "latest" {
		ids, err := a.rollbackIDs()
		if err != nil {
			return "", err
		}
		id = ""
		for _, candidate := range ids {
			status, err := rollbackStatus(filepath.Join(a.rollbackRoot(), candidate))
			if err != nil {
				return "", err
			}
			if status == "READY" {
				id = candidate
				break
			}
		}
		if id == "" {
			return "", fmt.Errorf("No rollbacks found in %s", a.rollbackRoot())
		}
	}
	if !idPattern.MatchString(id) {
		return "", usage("Invalid rollback ID: " + id)
	}
	path := filepath.Join(a.rollbackRoot(), id)
	if err := directory(path, false); err != nil {
		return "", fmt.Errorf("Rollback does not exist: %s: %w", id, err)
	}
	return path, nil
}

func validateRollback(path string, roots []string) error {
	if err := directory(path, false); err != nil {
		return err
	}
	status, err := rollbackStatus(path)
	if err != nil {
		return err
	}
	if status != "READY" {
		return fmt.Errorf("Rollback is %s: %s", status, filepath.Base(path))
	}
	data, err := os.ReadFile(filepath.Join(path, rootsManifest))
	if err != nil {
		return err
	}
	saved := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	if !slices.Equal(saved, roots) {
		return fmt.Errorf("Rollback roots do not match MINECRAFT_RESTORE_ROOTS: %s", filepath.Base(path))
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.Name() == rootsManifest {
			continue
		}
		if !slices.Contains(roots, entry.Name()) {
			return fmt.Errorf("Rollback contains an unexpected root: %s", entry.Name())
		}
		if !entry.IsDir() {
			return fmt.Errorf("Rollback root is not a directory: %s", entry.Name())
		}
	}
	return nil
}

func (a *app) listRollbacks() error {
	ids, err := a.rollbackIDs()
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "%-24s %10s %8s  %s\n", "ID", "STATUS", "SIZE", "ROOTS")
	for _, id := range ids {
		path := filepath.Join(a.rollbackRoot(), id)
		status, err := rollbackStatus(path)
		if err != nil {
			return err
		}
		entries, err := os.ReadDir(path)
		if err != nil {
			return err
		}
		var names []string
		for _, entry := range entries {
			if entry.Name() != incompleteMarker && entry.Name() != rootsManifest {
				names = append(names, entry.Name())
			}
		}
		var size int64
		if err := filepath.WalkDir(path, func(_ string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if stat, ok := info.Sys().(*syscall.Stat_t); ok {
				size += stat.Blocks * 512
			} else {
				size += info.Size()
			}
			return nil
		}); err != nil {
			return err
		}
		nameList := strings.Join(names, " ")
		if nameList == "" {
			nameList = "-"
		}
		fmt.Fprintf(a.out, "%-24s %10s %8s  %s\n", id, status, humanSize(size), nameList)
	}
	if len(ids) == 0 {
		fmt.Fprintln(a.out, "No rollbacks found")
	}
	return nil
}

func humanSize(size int64) string {
	n := float64(size)
	for _, unit := range []string{"B", "K", "M", "G", "T"} {
		if n < 1024 || unit == "T" {
			return fmt.Sprintf("%.0f%s", n, unit)
		}
		n /= 1024
	}
	return ""
}

func (a *app) confirm(ctx context.Context, prompt string, yes bool) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if yes {
		return nil
	}
	fmt.Fprint(a.out, prompt+" [y/N] ")
	type answer struct {
		text string
		err  error
	}
	result := make(chan answer, 1)
	go func() { text, err := bufio.NewReader(a.in).ReadString('\n'); result <- answer{text, err} }()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case reply := <-result:
		if reply.err != nil {
			return fmt.Errorf("confirmation cancelled: %w", reply.err)
		}
		if strings.TrimSpace(reply.text) != "y" && strings.TrimSpace(reply.text) != "Y" {
			return errors.New("Operation cancelled")
		}
		return nil
	}
}

func (a *app) applyRollback(ctx context.Context, target string, yes bool) error {
	roots, err := parseRoots(a.cfg.roots)
	if err != nil {
		return err
	}
	path, err := a.resolveRollback(target)
	if err != nil {
		return err
	}
	if err := validateRollback(path, roots); err != nil {
		return err
	}
	if err := a.validateLive(roots); err != nil {
		return err
	}
	if err := a.assertStopped(ctx, a.cfg.deployment+" must be stopped with mc-admin stop before applying a rollback"); err != nil {
		return err
	}
	id := filepath.Base(path)
	if err := a.confirm(ctx, fmt.Sprintf("Replace %s with rollback %s?", strings.Join(roots, " "), id), yes); err != nil {
		return err
	}
	if err := a.assertStopped(ctx, a.cfg.deployment+" was started while preparing the rollback; refusing to continue"); err != nil {
		return err
	}
	if err := validateRollback(path, roots); err != nil {
		return err
	}
	if err := a.validateLive(roots); err != nil {
		return err
	}
	retained, err := a.switchData(ctx, path, roots, true)
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "Applied rollback %s\nPrevious data is retained at %s\nRun mc-admin start after inspecting the restored files.\n", id, retained)
	return nil
}

func (a *app) deleteRollback(ctx context.Context, target string, yes bool) error {
	if target == "latest" {
		return usage("Specify an explicit rollback ID to delete")
	}
	path, err := a.resolveRollback(target)
	if err != nil {
		return err
	}
	if err := a.confirm(ctx, "Permanently delete rollback "+filepath.Base(path)+"?", yes); err != nil {
		return err
	}
	if err := os.RemoveAll(path); err != nil {
		return err
	}
	fmt.Fprintf(a.out, "Deleted rollback %s\n", filepath.Base(path))
	return nil
}
