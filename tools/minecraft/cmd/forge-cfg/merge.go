package main

import (
	"bytes"
	"fmt"
	"regexp"
	"strings"
)

var (
	namePattern   = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
	intPattern    = regexp.MustCompile(`^[-+]?[0-9]+$`)
	doublePattern = regexp.MustCompile(`^[-+]?(([0-9]+([.][0-9]*)?)|([.][0-9]+))([eE][-+]?[0-9]+)?$`)
)

type property struct {
	typeCode byte
	value    string
}

type parser struct {
	categories []string
	inList     bool
}

// Ignore list contents so property-like values never become scalar patch targets.
func (p *parser) walk(data []byte, patch bool, visit func(string, property, []byte) ([]byte, error)) ([]byte, error) {
	var out bytes.Buffer
	for n, raw := range bytes.SplitAfter(data, []byte("\n")) {
		line := strings.TrimSpace(string(raw))
		if p.inList {
			if line == ">" {
				p.inList = false
			}
			out.Write(raw)
			continue
		}
		if key, prop, ok := parseProperty(line); ok {
			id := strings.Join(append(append([]string{}, p.categories...), key), "\x00")
			changed, err := visit(id, prop, raw)
			if err != nil {
				return nil, fmt.Errorf("line %d: %w", n+1, err)
			}
			out.Write(changed)
			continue
		}
		switch {
		case line == "" || strings.HasPrefix(line, "#"):
		case line == "}":
			if len(p.categories) == 0 {
				return nil, fmt.Errorf("unexpected closing brace at line %d", n+1)
			}
			p.categories = p.categories[:len(p.categories)-1]
		case strings.HasSuffix(line, "{"):
			name := strings.TrimSpace(strings.TrimSuffix(line, "{"))
			if len(name) >= 2 && name[0] == '"' && name[len(name)-1] == '"' && !strings.Contains(name[1:len(name)-1], "\"") {
				name = name[1 : len(name)-1]
				if name == "" || strings.ContainsRune(name, '\x00') {
					return nil, fmt.Errorf("invalid category at line %d", n+1)
				}
			} else if !namePattern.MatchString(name) {
				return nil, fmt.Errorf("unsupported category syntax at line %d", n+1)
			}
			p.categories = append(p.categories, name)
		default:
			if patch {
				return nil, fmt.Errorf("unsupported patch syntax at line %d", n+1)
			} else if strings.HasSuffix(line, "<") {
				p.inList = true
			}
		}
		out.Write(raw)
	}
	if p.inList {
		return nil, fmt.Errorf("unterminated list")
	}
	if len(p.categories) != 0 {
		return nil, fmt.Errorf("unbalanced category braces")
	}
	return out.Bytes(), nil
}

func parseProperty(line string) (string, property, bool) {
	if len(line) < 4 || line[1] != ':' || !strings.ContainsRune("BIDS", rune(line[0])) {
		return "", property{}, false
	}
	eq := strings.IndexByte(line, '=')
	if eq < 0 {
		return "", property{}, false
	}
	key := strings.TrimSpace(line[2:eq])
	if !namePattern.MatchString(key) {
		return "", property{}, false
	}
	return key, property{line[0], strings.TrimSpace(line[eq+1:])}, true
}

func valid(p property) bool {
	switch p.typeCode {
	case 'B':
		return p.value == "true" || p.value == "false"
	case 'I':
		return intPattern.MatchString(p.value)
	case 'D':
		return doublePattern.MatchString(p.value)
	case 'S':
		return true
	}
	return false
}

func display(id string) string { return strings.ReplaceAll(id, "\x00", ".") }

// Validate every target before returning any changes.
func merge(base, patch []byte, check bool) ([]byte, error) {
	wanted := map[string]property{}
	_, err := (&parser{}).walk(patch, true, func(id string, prop property, raw []byte) ([]byte, error) {
		if _, exists := wanted[id]; exists {
			return nil, fmt.Errorf("duplicate patch property %s", display(id))
		}
		if !valid(prop) {
			return nil, fmt.Errorf("invalid %c value for %s", prop.typeCode, display(id))
		}
		wanted[id] = prop
		return raw, nil
	})
	if err != nil {
		return nil, fmt.Errorf("patch: %w", err)
	}
	if len(wanted) == 0 {
		return nil, fmt.Errorf("patch contains no scalar properties")
	}
	seen := map[string]bool{}
	result, err := (&parser{}).walk(base, false, func(id string, prop property, raw []byte) ([]byte, error) {
		want, exists := wanted[id]
		if !exists {
			return raw, nil
		}
		if seen[id] {
			return nil, fmt.Errorf("duplicate base property %s", display(id))
		}
		seen[id] = true
		if prop.typeCode != want.typeCode {
			return nil, fmt.Errorf("type mismatch for %s: patch=%c, base=%c", display(id), want.typeCode, prop.typeCode)
		}
		if !valid(prop) {
			return nil, fmt.Errorf("invalid existing %c value for %s", prop.typeCode, display(id))
		}
		if check && prop.value != want.value {
			return nil, fmt.Errorf("value drift for %s: expected=%s, actual=%s", display(id), want.value, prop.value)
		}
		if check || prop.value == want.value {
			return raw, nil
		}
		eq := bytes.IndexByte(raw, '=')
		start, end := eq+1, len(raw)
		for start < end && strings.ContainsRune(" \t\r\n\v\f", rune(raw[start])) {
			start++
		}
		for end > start && strings.ContainsRune(" \t\r\n\v\f", rune(raw[end-1])) {
			end--
		}
		// Preserve the line ending for an empty string value too.
		if start == len(raw) {
			for start > eq+1 && (raw[start-1] == '\n' || raw[start-1] == '\r') {
				start--
			}
			end = start
		}
		changed := append([]byte{}, raw[:start]...)
		changed = append(changed, want.value...)
		return append(changed, raw[end:]...), nil
	})
	if err != nil {
		return nil, fmt.Errorf("base: %w", err)
	}
	for id := range wanted {
		if !seen[id] {
			return nil, fmt.Errorf("patch target is missing from base: %s", display(id))
		}
	}
	return result, nil
}
