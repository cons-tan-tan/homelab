package main

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

type fakeCluster struct {
	state      replicas
	podNames   []string
	err        error
	scales     []int
	onReplicas func()
}

func (c *fakeCluster) replicas(context.Context) (replicas, error) {
	if c.onReplicas != nil {
		c.onReplicas()
	}
	return c.state, c.err
}
func (c *fakeCluster) pods(context.Context) ([]string, error) { return c.podNames, c.err }
func (c *fakeCluster) scale(_ context.Context, n int) error {
	c.scales = append(c.scales, n)
	c.state = replicas{n, n, n}
	return c.err
}

func fixture(t *testing.T) (*app, *fakeCluster) {
	t.Helper()
	data := t.TempDir()
	writeFile(t, filepath.Join(data, "world/state.txt"), "old world")
	writeFile(t, filepath.Join(data, "visualprospecting/state.txt"), "old visualprospecting")
	if err := os.Mkdir(filepath.Join(data, "backups"), 0755); err != nil {
		t.Fatal(err)
	}
	c := &fakeCluster{}
	a := newApp(config{namespace: "minecraft", deployment: "gtnh-minecraft", selector: "app=gtnh", dataDir: data, backupDir: filepath.Join(data, "backups"), roots: "world visualprospecting", waitTimeout: 100 * time.Millisecond}, c, strings.NewReader(""), &bytes.Buffer{})
	makeZip(t, filepath.Join(a.cfg.backupDir, "good.zip"), goodEntries())
	return a, c
}

func writeFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0640); err != nil {
		t.Fatal(err)
	}
}
func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
func checkState(t *testing.T, root, prefix string) {
	t.Helper()
	for _, name := range []string{"world", "visualprospecting"} {
		if got := readFile(t, filepath.Join(root, name, "state.txt")); got != prefix+" "+name {
			t.Fatalf("%s: got %q; want %q", root, got, prefix+" "+name)
		}
	}
}

type zipEntry struct {
	name, text string
	mode       os.FileMode
}

func goodEntries() []zipEntry {
	return []zipEntry{{"world/state.txt", "new world", 0640}, {"visualprospecting/state.txt", "new visualprospecting", 0644}}
}
func makeZip(t *testing.T, path string, entries []zipEntry) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	w := zip.NewWriter(f)
	for _, entry := range entries {
		h := &zip.FileHeader{Name: entry.name, Method: zip.Store, Modified: time.Unix(1700000000, 0)}
		h.SetMode(entry.mode)
		out, err := w.CreateHeader(h)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(out, entry.text); err != nil {
			t.Fatal(err)
		}
	}
	if err := errors.Join(w.Close(), f.Close()); err != nil {
		t.Fatal(err)
	}
}

func TestRestoreAndRollback(t *testing.T) {
	a, c := fixture(t)
	ctx := context.Background()
	if err := a.execute(ctx, invocation{command: "restore", target: "good.zip", yes: true}); err != nil {
		t.Fatal(err)
	}
	checkState(t, a.cfg.dataDir, "new")
	ids, err := a.rollbackIDs()
	if err != nil || len(ids) != 1 {
		t.Fatalf("rollbacks: %v, %v", ids, err)
	}
	old := filepath.Join(a.rollbackRoot(), ids[0])
	checkState(t, old, "old")
	if err := a.assertComplete(); err != nil {
		t.Fatal(err)
	}
	if err := a.execute(ctx, invocation{command: "rollback apply", target: "latest", yes: true}); err != nil {
		t.Fatal(err)
	}
	checkState(t, a.cfg.dataDir, "old")
	if present, _ := exists(old); present {
		t.Fatal("consumed rollback remains")
	}
	ids, err = a.rollbackIDs()
	if err != nil || len(ids) != 1 {
		t.Fatalf("replacement rollbacks: %v, %v", ids, err)
	}
	checkState(t, filepath.Join(a.rollbackRoot(), ids[0]), "new")
	if len(c.scales) != 0 {
		t.Fatal("restore or rollback started the server")
	}
	// Listing and deletion must still work after the configured roots change.
	a.cfg.roots = "world"
	if err := a.execute(ctx, invocation{command: "rollback list"}); err != nil {
		t.Fatal(err)
	}
	if err := a.execute(ctx, invocation{command: "rollback delete", target: ids[0], yes: true}); err != nil {
		t.Fatal(err)
	}
	ids, err = a.rollbackIDs()
	if err != nil || len(ids) != 0 {
		t.Fatalf("deleted rollbacks: %v, %v", ids, err)
	}
}

func TestRestoreMissingLiveRoot(t *testing.T) {
	a, _ := fixture(t)
	if err := os.RemoveAll(filepath.Join(a.cfg.dataDir, "world")); err != nil {
		t.Fatal(err)
	}
	if err := a.restore(context.Background(), "good.zip", true); err != nil {
		t.Fatal(err)
	}
	if err := a.applyRollback(context.Background(), "latest", true); err != nil {
		t.Fatal(err)
	}
	if present, _ := exists(filepath.Join(a.cfg.dataDir, "world")); present {
		t.Fatal("rollback did not restore absent root")
	}
	if got := readFile(t, filepath.Join(a.cfg.dataDir, "visualprospecting/state.txt")); got != "old visualprospecting" {
		t.Fatal(got)
	}
}

func TestArchivePermissionsRespectUmask(t *testing.T) {
	a, _ := fixture(t)
	oracle := t.TempDir()
	if err := os.WriteFile(filepath.Join(oracle, "file"), nil, 0666); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(oracle, "dir"), 0777); err != nil {
		t.Fatal(err)
	}
	fileInfo, _ := os.Stat(filepath.Join(oracle, "file"))
	dirInfo, _ := os.Stat(filepath.Join(oracle, "dir"))
	makeZip(t, filepath.Join(a.cfg.backupDir, "permissions.zip"), []zipEntry{
		{"world/", "", os.ModeDir | 0777},
		{"world/state.txt", "new world", 0666},
		{"visualprospecting/state.txt", "new visualprospecting", 0666},
	})
	if err := a.restore(context.Background(), "permissions.zip", true); err != nil {
		t.Fatal(err)
	}
	for _, root := range []string{"world", "visualprospecting"} {
		gotDir, err := os.Stat(filepath.Join(a.cfg.dataDir, root))
		if err != nil {
			t.Fatal(err)
		}
		gotFile, err := os.Stat(filepath.Join(a.cfg.dataDir, root, "state.txt"))
		if err != nil {
			t.Fatal(err)
		}
		if gotDir.Mode().Perm() != dirInfo.Mode().Perm() || gotFile.Mode().Perm() != fileInfo.Mode().Perm() {
			t.Fatalf("%s: directory=%o file=%o; want %o and %o", root, gotDir.Mode().Perm(), gotFile.Mode().Perm(), dirInfo.Mode().Perm(), fileInfo.Mode().Perm())
		}
	}
}

func TestArchiveRejectionsLeaveDataUntouched(t *testing.T) {
	tests := []struct {
		name  string
		entry zipEntry
	}{
		{"absolute", zipEntry{"/world/escape", "", 0644}},
		{"traversal", zipEntry{"world/../../escape", "", 0644}},
		{"dot", zipEntry{"world/./escape", "", 0644}},
		{"backslash", zipEntry{"world\\escape", "", 0644}},
		{"unexpected root", zipEntry{"unexpected/file", "", 0644}},
		{"symlink", zipEntry{"world/link", "../../outside", os.ModeSymlink | 0777}},
		{"fifo", zipEntry{"world/fifo", "", os.ModeNamedPipe | 0600}},
		{"root file", zipEntry{"world", "", 0644}},
		{"duplicate", zipEntry{"world/state.txt", "duplicate", 0644}},
		{"file as parent", zipEntry{"world/state.txt/nested", "", 0644}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a, _ := fixture(t)
			makeZip(t, filepath.Join(a.cfg.backupDir, "bad.zip"), append(goodEntries(), tt.entry))
			if err := a.restore(context.Background(), "bad.zip", true); err == nil {
				t.Fatal("accepted unsafe archive")
			}
			checkState(t, a.cfg.dataDir, "old")
			if err := a.assertComplete(); err != nil {
				t.Fatal("failed validation left staging:", err)
			}
		})
	}
	for _, mode := range []string{"missing root", "crc", "truncated", "archive symlink", "path target"} {
		t.Run(mode, func(t *testing.T) {
			a, _ := fixture(t)
			archive := filepath.Join(a.cfg.backupDir, "good.zip")
			target := "good.zip"
			switch mode {
			case "missing root":
				makeZip(t, archive, goodEntries()[:1])
			case "crc":
				data, _ := os.ReadFile(archive)
				index := bytes.Index(data, []byte("new world"))
				if index < 0 {
					t.Fatal("fixture payload missing")
				}
				data[index] ^= 1
				if err := os.WriteFile(archive, data, 0600); err != nil {
					t.Fatal(err)
				}
			case "truncated":
				if err := os.Truncate(archive, 30); err != nil {
					t.Fatal(err)
				}
			case "archive symlink":
				if err := os.Symlink(archive, filepath.Join(a.cfg.backupDir, "link.zip")); err != nil {
					t.Fatal(err)
				}
				target = "link.zip"
			case "path target":
				target = "../backups/good.zip"
			}
			if err := a.restore(context.Background(), target, true); err == nil {
				t.Fatal("accepted invalid backup")
			}
			checkState(t, a.cfg.dataDir, "old")
			if err := a.assertComplete(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestEveryRenameFailureRecoversData(t *testing.T) {
	for _, operation := range []string{"restore", "rollback"} {
		for failAt := 1; failAt <= 4; failAt++ {
			t.Run(fmt.Sprintf("%s/%d", operation, failAt), func(t *testing.T) {
				a, _ := fixture(t)
				ctx := context.Background()
				if operation == "rollback" {
					if err := a.restore(ctx, "good.zip", true); err != nil {
						t.Fatal(err)
					}
				}
				calls := 0
				a.rename = func(from, to string) error {
					calls++
					if calls == failAt {
						return errors.New("injected rename failure")
					}
					return os.Rename(from, to)
				}
				var err error
				if operation == "rollback" {
					err = a.applyRollback(ctx, "latest", true)
				} else {
					err = a.restore(ctx, "good.zip", true)
				}
				if err == nil || !strings.Contains(err.Error(), "injected rename failure") {
					t.Fatalf("operation: %v", err)
				}
				ids, err := a.rollbackIDs()
				if err != nil {
					t.Fatal(err)
				}
				if operation == "rollback" {
					checkState(t, a.cfg.dataDir, "new")
					if len(ids) != 1 {
						t.Fatalf("lost original rollback or leaked replacement: %v", ids)
					}
					checkState(t, filepath.Join(a.rollbackRoot(), ids[0]), "old")
				} else {
					checkState(t, a.cfg.dataDir, "old")
					if len(ids) != 0 {
						t.Fatalf("leaked rollback: %v", ids)
					}
				}
				if err := a.assertComplete(); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

func TestFailedRecoveryRetainsDataAndBlocksStart(t *testing.T) {
	for _, operation := range []string{"restore", "rollback"} {
		t.Run(operation, func(t *testing.T) {
			a, c := fixture(t)
			ctx := context.Background()
			if operation == "rollback" {
				if err := a.restore(ctx, "good.zip", true); err != nil {
					t.Fatal(err)
				}
			}
			calls := 0
			a.rename = func(from, to string) error {
				calls++
				if calls >= 2 {
					return errors.New("persistent filesystem failure")
				}
				return os.Rename(from, to)
			}
			var err error
			if operation == "rollback" {
				err = a.applyRollback(ctx, "latest", true)
			} else {
				err = a.restore(ctx, "good.zip", true)
			}
			var recovery *recoveryError
			if !errors.As(err, &recovery) {
				t.Fatalf("expected retained recovery error: %v", err)
			}
			if err := a.start(ctx); err == nil || !strings.Contains(err.Error(), "incomplete data operation") {
				t.Fatalf("start: %v", err)
			}
			if len(c.scales) != 0 {
				t.Fatal("started with incomplete data")
			}
			var worlds []string
			err = filepath.WalkDir(a.cfg.dataDir, func(path string, entry os.DirEntry, err error) error {
				if err != nil {
					return err
				}
				if filepath.Base(filepath.Dir(path)) == "world" && entry.Name() == "state.txt" {
					worlds = append(worlds, readFile(t, path))
				}
				return nil
			})
			if err != nil || len(worlds) != 2 || !slices.Contains(worlds, "old world") || !slices.Contains(worlds, "new world") {
				t.Fatalf("data lost: %v, %v", worlds, err)
			}
		})
	}
}

func TestCancellationRecoversCompletedRenames(t *testing.T) {
	for cancelAt := 1; cancelAt <= 4; cancelAt++ {
		t.Run(fmt.Sprint(cancelAt), func(t *testing.T) {
			a, _ := fixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			calls := 0
			a.rename = func(from, to string) error {
				err := os.Rename(from, to)
				calls++
				if calls == cancelAt {
					cancel()
				}
				return err
			}
			if err := a.restore(ctx, "good.zip", true); !errors.Is(err, context.Canceled) {
				t.Fatalf("cancellation: %v", err)
			}
			checkState(t, a.cfg.dataDir, "old")
			if err := a.assertComplete(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestClusterGuards(t *testing.T) {
	for _, operation := range []string{"restore", "rollback"} {
		for _, state := range []string{"api error", "desired", "available", "terminating pod", "started during preparation"} {
			t.Run(operation+"/"+state, func(t *testing.T) {
				a, c := fixture(t)
				ctx := context.Background()
				if operation == "rollback" {
					if err := a.restore(ctx, "good.zip", true); err != nil {
						t.Fatal(err)
					}
				}
				switch state {
				case "api error":
					c.err = errors.New("API unavailable")
				case "desired":
					c.state.desired = 1
				case "available":
					c.state.available = 1
				case "terminating pod":
					c.podNames = []string{"pod/terminating"}
				case "started during preparation":
					calls := 0
					c.onReplicas = func() {
						calls++
						if calls >= 2 {
							c.state.desired = 1
						}
					}
				}
				var err error
				if operation == "rollback" {
					err = a.applyRollback(ctx, "latest", true)
				} else {
					err = a.restore(ctx, "good.zip", true)
				}
				if err == nil {
					t.Fatal("ignored server state")
				}
				if operation == "rollback" {
					checkState(t, a.cfg.dataDir, "new")
				} else {
					checkState(t, a.cfg.dataDir, "old")
				}
				if err := a.assertComplete(); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

func TestInvalidRollbackAndLiveRoots(t *testing.T) {
	for _, mode := range []string{"roots changed", "incomplete", "missing manifest", "symlink manifest", "unexpected root", "symlink rollback root", "symlink live root"} {
		t.Run(mode, func(t *testing.T) {
			a, _ := fixture(t)
			ctx := context.Background()
			if err := a.restore(ctx, "good.zip", true); err != nil {
				t.Fatal(err)
			}
			ids, _ := a.rollbackIDs()
			path := filepath.Join(a.rollbackRoot(), ids[0])
			switch mode {
			case "roots changed":
				a.cfg.roots = "world"
			case "incomplete":
				if err := markIncomplete(path); err != nil {
					t.Fatal(err)
				}
			case "missing manifest":
				if err := os.Remove(filepath.Join(path, rootsManifest)); err != nil {
					t.Fatal(err)
				}
			case "symlink manifest":
				if err := os.Rename(filepath.Join(path, rootsManifest), filepath.Join(path, "manifest")); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink("manifest", filepath.Join(path, rootsManifest)); err != nil {
					t.Fatal(err)
				}
			case "unexpected root":
				writeFile(t, filepath.Join(path, "unexpected/file"), "unexpected")
			case "symlink rollback root":
				if err := os.Rename(filepath.Join(path, "world"), filepath.Join(path, "saved")); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink("saved", filepath.Join(path, "world")); err != nil {
					t.Fatal(err)
				}
			case "symlink live root":
				if err := os.Rename(filepath.Join(a.cfg.dataDir, "world"), filepath.Join(a.cfg.dataDir, "saved")); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink("missing", filepath.Join(a.cfg.dataDir, "world")); err != nil {
					t.Fatal(err)
				}
			}
			if err := a.applyRollback(ctx, ids[0], true); err == nil {
				t.Fatal("accepted invalid rollback")
			}
			if mode != "symlink live root" {
				checkState(t, a.cfg.dataDir, "new")
			}
		})
	}
}

func TestLatestAndConfirmation(t *testing.T) {
	a, _ := fixture(t)
	ctx := context.Background()
	newest := filepath.Join(a.cfg.backupDir, "newest backup.zip")
	makeZip(t, newest, goodEntries())
	future := time.Now().Add(time.Hour)
	if err := os.Chtimes(newest, future, future); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(newest, filepath.Join(a.cfg.backupDir, "zzz.zip")); err != nil {
		t.Fatal(err)
	}
	if err := a.restore(ctx, "latest", false); err == nil {
		t.Fatal("EOF accepted as confirmation")
	}
	checkState(t, a.cfg.dataDir, "old")
	a.in = strings.NewReader("n\n")
	if err := a.restore(ctx, "latest", false); err == nil {
		t.Fatal("decline accepted")
	}
	checkState(t, a.cfg.dataDir, "old")
	a.in = readerFunc(func(p []byte) (int, error) {
		// The original archive is replaced after validation, at the prompt.
		if err := os.WriteFile(newest, []byte("no longer a ZIP"), 0640); err != nil {
			return 0, err
		}
		return copy(p, "y\n"), nil
	})
	if err := a.restore(ctx, "latest", false); err != nil {
		t.Fatal(err)
	}
	checkState(t, a.cfg.dataDir, "new")
	if !strings.Contains(a.out.(*bytes.Buffer).String(), "Restored newest backup.zip") {
		t.Fatal("latest did not select by modification time")
	}
	// latest skips incomplete/invalid entries, including newer IDs.
	writeFile(t, filepath.Join(a.rollbackRoot(), "99999999T999999Z.ABC123", incompleteMarker), "")
	if err := os.Mkdir(filepath.Join(a.rollbackRoot(), "99999999T999999Z.ABC124"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := a.applyRollback(ctx, "latest", true); err != nil {
		t.Fatal(err)
	}
	checkState(t, a.cfg.dataDir, "old")
	for _, target := range []string{"latest", "../world"} {
		if err := a.deleteRollback(ctx, target, true); err == nil {
			t.Fatalf("accepted delete %s", target)
		}
	}
	ids, _ := a.rollbackIDs()
	a.in = strings.NewReader("n\n")
	if err := a.deleteRollback(ctx, ids[0], false); err == nil {
		t.Fatal("delete ignored decline")
	}
	if present, _ := exists(filepath.Join(a.rollbackRoot(), ids[0])); !present {
		t.Fatal("deleted after decline")
	}
}

type readerFunc func([]byte) (int, error)

func (f readerFunc) Read(p []byte) (int, error) { return f(p) }

func TestStartStopAndLock(t *testing.T) {
	a, c := fixture(t)
	ctx := context.Background()
	if err := a.execute(ctx, invocation{command: "start"}); err != nil {
		t.Fatal(err)
	}
	if err := a.execute(ctx, invocation{command: "stop"}); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(c.scales, []int{1, 0}) {
		t.Fatalf("scales: %v", c.scales)
	}
	c.podNames = []string{"pod/terminating"}
	if err := a.stop(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("stop failed to wait for pods: %v", err)
	}
	writeFile(t, filepath.Join(a.cfg.dataDir, stagingPrefix+"abandoned", "file"), "interrupted")
	if err := a.start(ctx); err == nil {
		t.Fatal("start ignored abandoned restore")
	}
	if err := a.withLock(ctx, func() error {
		return a.withLock(ctx, func() error { t.Error("entered concurrent operation"); return nil })
	}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("lock did not exclude concurrent operation: %v", err)
	}
	if err := a.withLock(ctx, func() error { return nil }); err != nil {
		t.Fatalf("lock not released: %v", err)
	}
}

func TestParsingAndHelpWithoutEnvironment(t *testing.T) {
	for command := range commandHelp {
		var out, stderr bytes.Buffer
		if code := run(context.Background(), append(strings.Fields(command), "--help"), func(string) string { t.Fatal("help read configuration"); return "" }, strings.NewReader(""), &out, &stderr); code != 0 || !strings.Contains(out.String(), "Usage: mc-admin "+command) {
			t.Fatalf("help for %s: exit=%d, stderr=%s", command, code, &stderr)
		}
	}
	for _, args := range [][]string{nil, {"unknown"}, {"status", "extra"}, {"restore"}, {"restore", "--help", "good.zip"}, {"rollback", "delete", "latest"}} {
		var errOut bytes.Buffer
		if code := run(context.Background(), args, func(string) string { return "" }, strings.NewReader(""), io.Discard, &errOut); code != 2 {
			t.Fatalf("%v: code=%d, stderr=%s", args, code, &errOut)
		}
	}
	for _, root := range []string{"", "..", "world/other", "world world", ".roots", ".incomplete", ".minecraft-admin-rollbacks", ".minecraft-admin-restore.test", ".minecraft-admin-operation.lock"} {
		if _, err := parseRoots(root); err == nil {
			t.Fatalf("accepted root %q", root)
		}
	}
	if roots, err := parseRoots("world\nvisualprospecting"); err != nil || len(roots) != 2 {
		t.Fatalf("valid roots: %v, %v", roots, err)
	}
}

func TestDecodeDeployment(t *testing.T) {
	for _, data := range []string{"", `{}`, `{"spec":{"replicas":-1}}`, `{"spec":{"replicas":"0"}}`, `{"spec":{"replicas":0},"status":{"availableReplicas":-1}}`} {
		if _, err := decodeReplicas([]byte(data)); err == nil {
			t.Fatalf("accepted deployment %s", data)
		}
	}
	got, err := decodeReplicas([]byte(`{"spec":{"replicas":0},"status":{}}`))
	if err != nil || got != (replicas{}) {
		t.Fatalf("scaled down deployment: %+v, %v", got, err)
	}
}
