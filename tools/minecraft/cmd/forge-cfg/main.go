package main

import (
	"errors"
	"fmt"
	"io"
	"os"
)

func run(args []string, out, stderr io.Writer) int {
	const help = "Usage: forge-cfg [--check] BASE_CFG PATCH_CFG\n       forge-cfg --install DESTINATION BASE_CFG PATCH_CFG"
	if len(args) == 1 && (args[0] == "--help" || args[0] == "-h") {
		fmt.Fprintln(out, help)
		return 0
	}
	destination := ""
	if len(args) == 4 && args[0] == "--install" {
		destination, args = args[1], args[2:]
		if destination == "" {
			fmt.Fprintln(stderr, help)
			return 64
		}
	}
	check := len(args) > 0 && args[0] == "--check"
	if check {
		args = args[1:]
	}
	if len(args) != 2 || len(args[0]) == 0 || args[0][0] == '-' {
		fmt.Fprintln(stderr, help)
		return 64
	}
	if destination != "" {
		if err := install(destination); err != nil {
			fmt.Fprintln(stderr, "forge-cfg:", err)
			return 1
		}
	}
	changed, err := apply(args[0], args[1], check)
	if err != nil {
		fmt.Fprintln(stderr, "forge-cfg:", err)
		if errors.Is(err, os.ErrNotExist) {
			return 66
		}
		return 65
	}
	switch {
	case check:
		fmt.Fprintf(out, "forge-cfg: verified %s against %s\n", args[0], args[1])
	case changed:
		fmt.Fprintf(out, "forge-cfg: merged %s into %s\n", args[1], args[0])
	default:
		fmt.Fprintf(out, "forge-cfg: %s already matches %s\n", args[0], args[1])
	}
	return 0
}

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }
