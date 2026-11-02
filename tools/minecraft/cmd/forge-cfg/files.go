package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

// Failed validation must leave contents and metadata untouched.
func apply(basePath, patchPath string, check bool) (bool, error) {
	info, err := os.Lstat(basePath)
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() {
		return false, fmt.Errorf("base is not a regular file: %s", basePath)
	}
	file, err := os.OpenFile(basePath, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return false, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return false, err
	}
	if !os.SameFile(info, opened) {
		return false, fmt.Errorf("base file changed while being opened")
	}
	base, err := io.ReadAll(file)
	if err != nil {
		return false, err
	}
	patch, err := os.ReadFile(patchPath)
	if err != nil {
		return false, err
	}
	merged, err := merge(base, patch, check)
	if err != nil {
		return false, err
	}
	if check || bytes.Equal(base, merged) {
		return false, nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(basePath), ".forge-cfg-*")
	if err != nil {
		return false, err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		if err := tmp.Chown(int(stat.Uid), int(stat.Gid)); err != nil {
			return false, err
		}
	}
	if err := tmp.Chmod(info.Mode().Perm()); err != nil {
		return false, err
	}
	if _, err := tmp.Write(merged); err != nil {
		return false, err
	}
	if err := tmp.Sync(); err != nil {
		return false, err
	}
	if err := tmp.Close(); err != nil {
		return false, err
	}
	if err := os.Chtimes(tmp.Name(), info.ModTime(), info.ModTime()); err != nil {
		return false, err
	}
	current, err := os.Lstat(basePath)
	if err != nil {
		return false, err
	}
	if !os.SameFile(info, current) || info.Size() != current.Size() || !info.ModTime().Equal(current.ModTime()) {
		return false, fmt.Errorf("base file changed while preparing the merge")
	}
	if err := os.Rename(tmp.Name(), basePath); err != nil {
		return false, err
	}
	return true, nil
}

// Copy executable bytes so the main container needs no Nix store.
func install(destination string) error {
	source, err := os.Executable()
	if err != nil {
		return err
	}
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.CreateTemp(filepath.Dir(destination), ".forge-cfg-install-*")
	if err != nil {
		return err
	}
	defer os.Remove(out.Name())
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	if err := out.Chmod(0555); err != nil {
		return err
	}
	if err := out.Sync(); err != nil {
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(out.Name(), destination)
}
