package main

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
)

func (a *app) backups() ([]os.FileInfo, error) {
	entries, err := os.ReadDir(a.cfg.backupDir)
	if err != nil {
		return nil, err
	}
	var backups []os.FileInfo
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".zip") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return nil, err
		}
		if info.Mode().IsRegular() {
			backups = append(backups, info)
		}
	}
	slices.SortFunc(backups, func(a, b os.FileInfo) int {
		if c := b.ModTime().Compare(a.ModTime()); c != 0 {
			return c
		}
		return strings.Compare(b.Name(), a.Name())
	})
	return backups, nil
}

func (a *app) listBackups() error {
	backups, err := a.backups()
	if err != nil {
		return err
	}
	for _, backup := range backups {
		fmt.Fprintf(a.out, "%s  %10d %s\n", backup.ModTime().Format("2006-01-02 15:04:05"), backup.Size(), backup.Name())
	}
	return nil
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}

// Snapshot the opened inode so later backup writes cannot change the validated bytes.
func snapshotArchive(ctx context.Context, source, destination string) error {
	info, err := os.Lstat(source)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("Backup %s is not a regular file", filepath.Base(source))
	}
	in, err := os.OpenFile(source, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	defer in.Close()
	opened, err := in.Stat()
	if err != nil {
		return err
	}
	if !os.SameFile(info, opened) {
		return fmt.Errorf("Backup changed while being opened")
	}
	out, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, contextReader{ctx, in})
	return errors.Join(copyErr, out.Close())
}

func validateArchive(ctx context.Context, archive *zip.Reader, roots []string) error {
	seenRoots, seenPaths := map[string]bool{}, map[string]bool{}
	for _, entry := range archive.File {
		name := entry.Name
		clean := strings.TrimSuffix(name, "/")
		if clean == "" || strings.ContainsAny(name, "\\\x00") || strings.HasPrefix(name, "/") || path.Clean(clean) != clean {
			return fmt.Errorf("Archive contains an unsafe path: %q", name)
		}
		parts := strings.Split(clean, "/")
		for _, part := range parts {
			if part == "." || part == ".." {
				return fmt.Errorf("Archive contains an unsafe path: %q", name)
			}
		}
		if !slices.Contains(roots, parts[0]) {
			return fmt.Errorf("Archive contains an unexpected root: %s", name)
		}
		if seenPaths[clean] {
			return fmt.Errorf("Archive contains a duplicate path: %s", name)
		}
		seenPaths[clean], seenRoots[parts[0]] = true, true
		mode := entry.Mode()
		if !mode.IsRegular() && !mode.IsDir() {
			return fmt.Errorf("Archive contains a symbolic link or special file: %s", name)
		}
		if len(parts) == 1 && !mode.IsDir() {
			return fmt.Errorf("Archive root is not a directory: %s", name)
		}
		if mode.IsDir() && !strings.HasSuffix(name, "/") {
			return fmt.Errorf("Archive directory must end with '/': %s", name)
		}
		reader, err := entry.Open()
		if err != nil {
			return fmt.Errorf("Archive entry %s: %w", name, err)
		}
		// Reading through EOF verifies the ZIP checksum and uncompressed length.
		_, copyErr := io.Copy(io.Discard, contextReader{ctx, reader})
		if err := errors.Join(copyErr, reader.Close()); err != nil {
			return fmt.Errorf("Archive entry %s: %w", name, err)
		}
	}
	for _, root := range roots {
		if !seenRoots[root] {
			return fmt.Errorf("Archive must contain %s/", root)
		}
	}
	return nil
}

func extractArchive(ctx context.Context, archive *zip.Reader, destination string) error {
	var directories []*zip.File
	for _, entry := range archive.File {
		if err := ctx.Err(); err != nil {
			return err
		}
		target := filepath.Join(destination, filepath.FromSlash(entry.Name))
		if entry.Mode().IsDir() {
			if err := os.MkdirAll(target, 0777); err != nil {
				return err
			}
			directories = append(directories, entry)
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0777); err != nil {
			return err
		}
		in, err := entry.Open()
		if err != nil {
			return err
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, entry.Mode().Perm())
		if err != nil {
			in.Close()
			return err
		}
		_, copyErr := io.Copy(out, contextReader{ctx, in})
		if err := errors.Join(copyErr, in.Close(), out.Close()); err != nil {
			return err
		}
		if err := os.Chtimes(target, entry.Modified, entry.Modified); err != nil {
			return err
		}
	}
	// Set directory permissions last, deepest first, to keep children accessible during extraction.
	slices.SortFunc(directories, func(a, b *zip.File) int { return len(b.Name) - len(a.Name) })
	for _, entry := range directories {
		target := filepath.Join(destination, filepath.FromSlash(entry.Name))
		info, err := os.Stat(target)
		if err != nil {
			return err
		}
		// Preserve the caller's umask, including for Java/DOS archives with default 0777 directories.
		if err := os.Chmod(target, info.Mode().Perm()&entry.Mode().Perm()); err != nil {
			return err
		}
		if err := os.Chtimes(target, entry.Modified, entry.Modified); err != nil {
			return err
		}
	}
	return nil
}

func (a *app) restore(ctx context.Context, target string, yes bool) (err error) {
	roots, err := parseRoots(a.cfg.roots)
	if err != nil {
		return err
	}
	if err := a.assertStopped(ctx, a.cfg.deployment+" must be stopped with mc-admin stop before restoring a backup"); err != nil {
		return err
	}
	if target == "latest" {
		backups, err := a.backups()
		if err != nil {
			return err
		}
		if len(backups) == 0 {
			return fmt.Errorf("No ZIP backups found in %s", a.cfg.backupDir)
		}
		target = backups[0].Name()
	}
	if strings.ContainsAny(target, "/\\") || !strings.HasSuffix(target, ".zip") {
		return usage("Specify a ZIP filename from the backup directory, not a path")
	}
	staging, err := os.MkdirTemp(a.cfg.dataDir, stagingPrefix)
	if err != nil {
		return err
	}
	defer func() {
		var recovery *recoveryError
		if !errors.As(err, &recovery) {
			err = errors.Join(err, os.RemoveAll(staging))
		}
	}()
	snapshot := filepath.Join(staging, ".archive.zip")
	if err := snapshotArchive(ctx, filepath.Join(a.cfg.backupDir, target), snapshot); err != nil {
		return err
	}
	fmt.Fprintf(a.out, "Testing %s\n", target)
	archive, err := zip.OpenReader(snapshot)
	if err != nil {
		return err
	}
	defer archive.Close()
	if err := validateArchive(ctx, &archive.Reader, roots); err != nil {
		return err
	}
	if err := a.confirm(ctx, fmt.Sprintf("Replace %s with %s?", strings.Join(roots, " "), target), yes); err != nil {
		return err
	}
	if err := extractArchive(ctx, &archive.Reader, staging); err != nil {
		return err
	}
	for _, root := range roots {
		if err := directory(filepath.Join(staging, root), false); err != nil {
			return err
		}
	}
	if err := a.assertStopped(ctx, a.cfg.deployment+" was started while preparing the restore; refusing to continue"); err != nil {
		return err
	}
	if err := a.validateLive(roots); err != nil {
		return err
	}
	retained, err := a.switchData(ctx, staging, roots, false)
	if err != nil {
		return err
	}
	fmt.Fprintf(a.out, "Restored %s\nPrevious data is retained at %s\nRun mc-admin start after inspecting the restored files.\n", target, retained)
	return nil
}
