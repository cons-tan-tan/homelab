package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestCLI(t *testing.T) {
	dir := t.TempDir()
	base, patch, installed := filepath.Join(dir, "base"), filepath.Join(dir, "patch"), filepath.Join(dir, "installed")
	if err := os.WriteFile(base, []byte("B:key=false\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(patch, []byte("B:key=true\n"), 0644); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		args []string
		code int
	}{
		{nil, 64}, {[]string{"--help"}, 0}, {[]string{"--check"}, 64},
		{[]string{"--install", installed}, 64},
		{[]string{"--check", base, patch}, 65}, {[]string{base, "missing"}, 66},
		{[]string{"--install", installed, base, patch}, 0},
		{[]string{"--check", base, patch}, 0}, {[]string{base, patch}, 0},
	}
	for _, tt := range tests {
		var out, stderr bytes.Buffer
		if code := run(tt.args, &out, &stderr); code != tt.code {
			t.Errorf("%v: exit %d, want %d; stderr=%s", tt.args, code, tt.code, &stderr)
		}
	}
	if _, err := os.Stat(installed); err != nil {
		t.Fatal(err)
	}
}
