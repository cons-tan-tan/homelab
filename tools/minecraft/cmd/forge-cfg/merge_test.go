package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMergePreservesUnrelatedBytes(t *testing.T) {
	base := "# Configuration file\r\n\r\nworld {\r\n\tB:chunk_claiming = false  \r\n\tB:chunk_loading=true\r\n\tlogging {\r\n\t\tB:chunk_claiming=false\r\n\t}\r\n\tS:list <\r\nB:chunk_claiming=false\r\n}\r\nworld {\r\n>\r\n}\r\n"
	patch := "world {\nB:chunk_claiming=true\nB:chunk_loading=true\n}\n"
	want := strings.Replace(base, "B:chunk_claiming = false", "B:chunk_claiming = true", 1)
	merged, err := merge([]byte(base), []byte(patch), false)
	if err != nil {
		t.Fatal(err)
	}
	if string(merged) != want {
		t.Fatalf("unexpected rewrite:\n%q\nwant:\n%q", merged, want)
	}
	checked, err := merge(merged, []byte(patch), true)
	if err != nil || !bytes.Equal(checked, merged) {
		t.Fatalf("check: %q, %v", checked, err)
	}
	again, err := merge(merged, []byte(patch), false)
	if err != nil || !bytes.Equal(again, merged) {
		t.Fatalf("not idempotent: %q, %v", again, err)
	}
}

func TestScalarTypesAndCategories(t *testing.T) {
	tests := []struct{ name, base, patch, want string }{
		{"nested", "world {\nlogging {\nB:enabled=false\n}\n}\n", "world {\nlogging {\nB:enabled=true\n}\n}\n", "world {\nlogging {\nB:enabled=true\n}\n}\n"},
		{"quoted category", "\"a/b c\" {\nI:n=-1\n}\n", "\"a/b c\" {\nI:n=+2\n}\n", "\"a/b c\" {\nI:n=+2\n}\n"},
		{"exponent", "D:n=.5\n", "D:n=-1.5e+10\n", "D:n=-1.5e+10\n"},
		{"empty string", "S:s=  \r\n", "S:s=text\n", "S:s=  text\r\n"},
		{"no newline", "S:s=old", "S:s=new", "S:s=new"},
		{"literal brace", "S:s=literal {\n", "S:s=replacement {\n", "S:s=replacement {\n"},
		{"literal equals", "S:s=old\n", "S:s=a=b\n", "S:s=a=b\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := merge([]byte(tt.base), []byte(tt.patch), false)
			if err != nil || string(got) != tt.want {
				t.Fatalf("got %q, %v; want %q", got, err, tt.want)
			}
		})
	}
}

func TestRejectInvalidMerge(t *testing.T) {
	tests := []struct {
		name, base, patch, errorText string
		check                        bool
	}{
		{"missing", "B:another=false\n", "B:key=true\n", "missing", false},
		{"duplicate base", "B:key=false\nB:key=false\n", "B:key=true\n", "duplicate base", false},
		{"duplicate patch", "B:key=false\n", "B:key=true\nB:key=false\n", "duplicate patch", false},
		{"type mismatch", "I:key=1\n", "B:key=true\n", "type mismatch", false},
		{"invalid bool", "B:key=false\n", "B:key=yes\n", "invalid B", false},
		{"invalid int", "I:key=1\n", "I:key=1.5\n", "invalid I", false},
		{"invalid double", "D:key=1\n", "D:key=NaN\n", "invalid D", false},
		{"invalid existing", "B:key=maybe\n", "B:key=true\n", "invalid existing", false},
		{"empty", "B:key=false\n", "# no properties\n", "no scalar", false},
		{"list patch", "S:key <\nvalue\n>\n", "S:key <\nvalue\n>\n", "unsupported patch", false},
		{"list is not target", "S:list <\nB:key=false\n>\n", "B:key=true\n", "missing", false},
		{"unclosed list", "B:key=false\nS:list <\n", "B:key=true\n", "unterminated list", false},
		{"unbalanced patch", "world {\nB:key=false\n}\n", "world {\nB:key=true\n", "unbalanced", false},
		{"unbalanced base", "world {\nB:key=false\n", "world {\nB:key=true\n}\n", "unbalanced", false},
		{"closing brace", "B:key=false\n}\n", "B:key=true\n", "closing brace", false},
		{"drift", "B:key=false\n", "B:key=true\n", "drift", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := merge([]byte(tt.base), []byte(tt.patch), tt.check)
			if err == nil || !strings.Contains(err.Error(), tt.errorText) || got != nil {
				t.Fatalf("got %q, %v; expected %s", got, err, tt.errorText)
			}
		})
	}
}

func TestApplyFile(t *testing.T) {
	dir := t.TempDir()
	base, patch := filepath.Join(dir, "base.cfg"), filepath.Join(dir, "patch.cfg")
	write := func(path, content string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(content), 0640); err != nil {
			t.Fatal(err)
		}
	}
	write(base, "B:key=false\n")
	write(patch, "B:missing=true\n")
	mtime := time.Unix(1234567890, 0)
	if err := os.Chtimes(base, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(base)
	if _, err := apply(base, patch, false); err == nil {
		t.Fatal("accepted missing target")
	}
	data, _ := os.ReadFile(base)
	after, _ := os.Stat(base)
	if string(data) != "B:key=false\n" || !os.SameFile(before, after) {
		t.Fatal("failure changed original")
	}
	write(patch, "B:key=true\n")
	if _, err := apply(base, patch, true); err == nil {
		t.Fatal("check accepted drift")
	}
	if changed, err := apply(base, patch, false); err != nil || !changed {
		t.Fatalf("apply: %v, %v", changed, err)
	}
	after, _ = os.Stat(base)
	if after.Mode().Perm() != before.Mode().Perm() || !after.ModTime().Equal(mtime) {
		t.Fatal("file metadata changed")
	}
	for _, check := range []bool{false, true} {
		if changed, err := apply(base, patch, check); changed || err != nil {
			t.Fatalf("idempotence/check: %v, %v", changed, err)
		}
		current, _ := os.Stat(base)
		if !os.SameFile(after, current) {
			t.Fatal("no-op replaced file")
		}
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 2 {
		t.Fatalf("leaked temporary files: %v", entries)
	}
	link := filepath.Join(dir, "link.cfg")
	if err := os.Symlink(base, link); err != nil {
		t.Fatal(err)
	}
	if _, err := apply(link, patch, false); err == nil {
		t.Fatal("accepted symlink base")
	}
}

func TestInstallCopiesExecutable(t *testing.T) {
	destination := filepath.Join(t.TempDir(), "forge-cfg")
	if err := install(destination); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(destination)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0555 {
		t.Fatalf("installed binary: %v, %v", info, err)
	}
	executable, _ := os.Executable()
	want, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(destination)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatal("installation did not copy the executable bytes")
	}
	if err := install(destination); err != nil {
		t.Fatalf("retry: %v", err)
	}
}
