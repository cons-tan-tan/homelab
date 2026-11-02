package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const mainHelp = `Usage: mc-admin <command> [options]

Operate a Minecraft server and restore its data from local ZIP backups.

Commands:
  status    Show desired and available server replicas
  stop      Stop the server and wait for its Pods to terminate
  start     Start the server and wait for it to become available
  backups   List available ZIP backups, newest first
  restore   Restore configured data roots from a ZIP backup
  rollback  List, apply, or delete retained data states

Run 'mc-admin <command> --help' for command-specific help.
`

var commandHelp = map[string]string{
	"status":  "Usage: mc-admin status\n\nShow the configured server Deployment and its desired and available replicas.\n",
	"stop":    "Usage: mc-admin stop\n\nStop the configured server Deployment and wait for all matching Pods to terminate.\n",
	"start":   "Usage: mc-admin start\n\nStart the server and wait for it to become available. Refuse to start while an\ninterrupted restore or rollback requires manual recovery.\n",
	"backups": "Usage: mc-admin backups\n\nList ZIP files in the configured backup directory, newest first.\n",
	"restore": `Usage: mc-admin restore [--yes] <backup.zip|latest>

Restore the configured data roots from a ZIP file in the backup directory.
The server must first be stopped with 'mc-admin stop'. Current data is retained
under .minecraft-admin-rollbacks, and the server is not started automatically.
Use 'latest' to select the newest ZIP by modification time.

Options:
  -y, --yes  Skip the confirmation prompt
  -h, --help Show this help
`,
	"rollback": `Usage: mc-admin rollback <command> [options]

Commands:
  list    List rollback IDs, status, sizes, and retained data roots
  apply   Replace current data with a rollback, retaining the current data
  delete  Permanently delete an explicit rollback ID

Run 'mc-admin rollback <command> --help' for command-specific help.
`,
	"rollback list": "Usage: mc-admin rollback list\n\nList rollback IDs, status, sizes, and retained data roots, newest first.\nINCOMPLETE and INVALID entries cannot be applied.\n",
	"rollback apply": `Usage: mc-admin rollback apply [--yes] <id|latest>

Replace the configured data roots with a rollback. The server must first be
stopped. Current data is retained as a new rollback. The server is not started
automatically. Use 'latest' to select the newest complete rollback.

Options:
  -y, --yes  Skip the confirmation prompt
  -h, --help Show this help
`,
	"rollback delete": "Usage: mc-admin rollback delete [--yes] <id>\n\nPermanently delete one explicit rollback ID.\n\nOptions:\n  -y, --yes  Skip the confirmation prompt\n  -h, --help Show this help\n",
}

type invocation struct {
	command, target, help string
	yes                   bool
}

type usageError struct{ message string }

func (e usageError) Error() string { return e.message }
func usage(message string) error   { return usageError{message} }

func parse(args []string) (invocation, error) {
	if len(args) == 0 {
		return invocation{}, usage(mainHelp)
	}
	if args[0] == "--help" || args[0] == "-h" {
		if len(args) != 1 {
			return invocation{}, usage("Unexpected argument after --help\n" + mainHelp)
		}
		return invocation{help: mainHelp}, nil
	}
	inv := invocation{command: args[0]}
	args = args[1:]
	if inv.command == "rollback" && len(args) > 0 && args[0] != "--help" && args[0] != "-h" {
		inv.command += " " + args[0]
		args = args[1:]
	}
	help, ok := commandHelp[inv.command]
	if !ok {
		return invocation{}, usage("Unknown command: " + inv.command + "\n" + mainHelp)
	}
	if len(args) == 1 && (args[0] == "--help" || args[0] == "-h") {
		inv.help = help
		return inv, nil
	}
	switch inv.command {
	case "rollback":
		return invocation{}, usage(help)
	case "restore", "rollback apply", "rollback delete":
		for _, arg := range args {
			switch {
			case arg == "--yes" || arg == "-y":
				inv.yes = true
			case strings.HasPrefix(arg, "-"):
				return invocation{}, usage("Unexpected option: " + arg + "\n" + help)
			case inv.target != "":
				return invocation{}, usage("Only one target may be specified\n" + help)
			default:
				inv.target = arg
			}
		}
		if inv.target == "" {
			return invocation{}, usage(help)
		}
		if inv.command == "rollback delete" && inv.target == "latest" {
			return invocation{}, usage("Specify an explicit rollback ID to delete\n" + help)
		}
	default:
		if len(args) != 0 {
			return invocation{}, usage("mc-admin " + inv.command + " does not accept arguments\n" + help)
		}
	}
	return inv, nil
}

type config struct {
	namespace, deployment, selector, dataDir, backupDir, roots string
	waitTimeout                                                time.Duration
}

func loadConfig(env func(string) string) (config, error) {
	cfg := config{namespace: env("MINECRAFT_NAMESPACE"), deployment: env("MINECRAFT_DEPLOYMENT"), selector: env("MINECRAFT_POD_SELECTOR"), dataDir: env("MINECRAFT_DATA_DIR"), backupDir: env("MINECRAFT_BACKUP_DIR"), roots: env("MINECRAFT_RESTORE_ROOTS"), waitTimeout: 180 * time.Second}
	if cfg.deployment == "" {
		return cfg, errors.New("MINECRAFT_DEPLOYMENT is required")
	}
	if cfg.selector == "" {
		return cfg, errors.New("MINECRAFT_POD_SELECTOR is required")
	}
	if cfg.dataDir == "" {
		cfg.dataDir = "/data"
	}
	var err error
	cfg.dataDir, err = filepath.Abs(cfg.dataDir)
	if err != nil {
		return cfg, err
	}
	if cfg.backupDir == "" {
		cfg.backupDir = filepath.Join(cfg.dataDir, "backups")
	}
	if timeout := env("MINECRAFT_WAIT_TIMEOUT"); timeout != "" {
		n, err := strconv.ParseUint(timeout, 10, 32)
		if err != nil || n == 0 {
			return cfg, errors.New("MINECRAFT_WAIT_TIMEOUT must be a positive number of seconds")
		}
		cfg.waitTimeout = time.Duration(n) * time.Second
	}
	if cfg.namespace == "" {
		data, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace")
		if err != nil {
			return cfg, errors.New("service account namespace is missing; set MINECRAFT_NAMESPACE explicitly")
		}
		cfg.namespace = strings.TrimSpace(string(data))
		if cfg.namespace == "" {
			return cfg, errors.New("MINECRAFT_NAMESPACE is required")
		}
	}
	return cfg, nil
}

// Help must work without cluster credentials or data paths.
func run(ctx context.Context, args []string, env func(string) string, in io.Reader, out, stderr io.Writer) int {
	inv, err := parse(args)
	if err == nil && inv.help != "" {
		fmt.Fprint(out, inv.help)
		return 0
	}
	if err == nil {
		var cfg config
		cfg, err = loadConfig(env)
		if err == nil {
			err = newApp(cfg, &kubectl{cfg: cfg}, in, out).execute(ctx, inv)
		}
	}
	if err != nil {
		fmt.Fprintln(stderr, err)
		var badUsage usageError
		if errors.As(err, &badUsage) {
			return 2
		}
		return 1
	}
	return 0
}

type app struct {
	cfg     config
	cluster cluster
	in      io.Reader
	out     io.Writer
	rename  func(string, string) error
}

func newApp(cfg config, cluster cluster, in io.Reader, out io.Writer) *app {
	return &app{cfg: cfg, cluster: cluster, in: in, out: out, rename: os.Rename}
}

func (a *app) execute(ctx context.Context, inv invocation) error {
	if inv.command == "status" {
		return a.status(ctx)
	}
	if inv.command == "backups" {
		return a.listBackups()
	}
	return a.withLock(ctx, func() error {
		switch inv.command {
		case "stop":
			return a.stop(ctx)
		case "start":
			return a.start(ctx)
		case "restore":
			return a.restore(ctx, inv.target, inv.yes)
		case "rollback list":
			return a.listRollbacks()
		case "rollback apply":
			return a.applyRollback(ctx, inv.target, inv.yes)
		case "rollback delete":
			return a.deleteRollback(ctx, inv.target, inv.yes)
		}
		return usage("Unknown command: " + inv.command)
	})
}
