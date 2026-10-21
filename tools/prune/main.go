// prune removes Go code that is no longer used from a package main.
//
// Written for splitting one API into two: once routes() registers only one
// service's endpoints, most of the remaining code becomes unreachable.
// Removing it by hand means hundreds of edits; this tool repeats until there
// is nothing left to remove:
//
//  1. deadcode  — functions and methods unreachable from main
//  2. go/types  — types, vars and consts referenced from nowhere but their own
//     declaration (including exported names, which staticcheck treats as
//     "possibly used")
//  3. goimports — tidies the imports that are left
//  4. files reduced to just "package main" are deleted
//
// Struct fields are never removed: their JSON shape is a contract with the
// web apps, not a matter of use inside Go.
//
// Needs deadcode and goimports in $GOPATH/bin. Run from the package folder:
//
//	go build -o prune .
//	cd ../../api && ../tools/prune/prune .
//
// To protect code that was already dead BEFORE this change (removing it is a
// separate change's business), record it first and pass it with -keep:
//
//	deadcode . > ../already-dead.txt
//	../tools/prune/prune -keep ../already-dead.txt .
package main

import (
	"bufio"
	"bytes"
	"fmt"
	"go/ast"
	"go/build"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"
)

type position struct {
	file      string
	line, col int
}

var finding = regexp.MustCompile(`^(.+?\.go):(\d+):(\d+): (.*)$`)

func main() {
	// -keep file: functions (one per line, as deadcode prints them) that must
	// not be removed even though they are unreachable.
	keep := map[string]bool{}
	args := os.Args[1:]
	if len(args) >= 2 && args[0] == "-keep" {
		raw, err := os.ReadFile(args[1])
		if err != nil {
			fail(err)
		}
		for _, line := range strings.Split(text(raw), "\n") {
			if i := strings.Index(line, "unreachable func: "); i >= 0 {
				line = line[i+len("unreachable func: "):]
			}
			if line = strings.TrimSpace(line); line != "" {
				keep[line] = true
			}
		}
		args = args[2:]
	}
	dir := "."
	if len(args) > 0 {
		dir = args[0]
	}
	if err := os.Chdir(dir); err != nil {
		fail(err)
	}
	gobin := filepath.Join(goenv("GOPATH"), "bin")
	round := 0
	for {
		round++
		targets := map[position]bool{}
		deadNames := map[string]bool{}
		for _, f := range run(filepath.Join(gobin, "deadcode"), ".") {
			if i := strings.Index(f.message, "unreachable func: "); i >= 0 {
				name := f.message[i+len("unreachable func: "):]
				if keep[name] {
					continue
				}
				targets[f.pos] = true
				deadNames[name] = true
			}
		}
		for _, p := range unreferenced() {
			targets[p] = true
		}
		if len(targets) == 0 {
			break
		}
		removed := remove(targets, deadNames)
		fmt.Printf("round %d: %d declarations removed\n", round, removed)
		files, _ := filepath.Glob("*.go")
		gi := append([]string{"-w"}, files...)
		if out, err := exec.Command(filepath.Join(gobin, "goimports"), gi...).CombinedOutput(); err != nil {
			fail(fmt.Errorf("goimports: %v\n%s", err, out))
		}
		deleteEmptyFiles()
		if removed == 0 {
			fmt.Println("some findings could not be removed automatically; see above")
			break
		}
	}
	fmt.Println("done")
}

type result struct {
	pos     position
	message string
}

func run(name string, args ...string) []result {
	out, _ := exec.Command(name, args...).CombinedOutput()
	var results []result
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		m := finding.FindStringSubmatch(strings.TrimSpace(sc.Text()))
		if m == nil {
			continue
		}
		line, _ := strconv.Atoi(m[2])
		col, _ := strconv.Atoi(m[3])
		f := filepath.Base(filepath.FromSlash(m[1]))
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		results = append(results, result{position{f, line, col}, m[4]})
	}
	return results
}

type cut struct{ start, end int }

func remove(targets map[position]bool, deadNames map[string]bool) int {
	byFile := map[string][]position{}
	for p := range targets {
		byFile[p.file] = append(byFile[p.file], p)
	}
	total := 0
	// `var _ = f` exists only to keep f "used". If f goes, its guard must go
	// too, or the file stops compiling - so every file is visited.
	all, _ := filepath.Glob("*.go")
	for _, f := range all {
		if !strings.HasSuffix(f, "_test.go") {
			if _, ok := byFile[f]; !ok {
				byFile[f] = nil
			}
		}
	}
	for file, list := range byFile {
		src, err := os.ReadFile(file)
		if err != nil {
			fail(err)
		}
		fset := token.NewFileSet()
		af, err := parser.ParseFile(fset, file, src, parser.ParseComments)
		if err != nil {
			fail(err)
		}
		matches := func(id *ast.Ident) bool {
			p := fset.Position(id.Pos())
			for _, t := range list {
				if t.line == p.Line && t.col == p.Column {
					return true
				}
			}
			return false
		}
		startWithDoc := func(doc *ast.CommentGroup, pos token.Pos) token.Pos {
			if doc != nil {
				return doc.Pos()
			}
			return pos
		}
		var cuts []cut
		for _, d := range af.Decls {
			switch d := d.(type) {
			case *ast.FuncDecl:
				if matches(d.Name) {
					cuts = append(cuts, cut{offset(fset, startWithDoc(d.Doc, d.Pos())), offset(fset, d.End())})
				}
			case *ast.GenDecl:
				var dead []ast.Spec
				for _, s := range d.Specs {
					switch s := s.(type) {
					case *ast.TypeSpec:
						if matches(s.Name) {
							dead = append(dead, s)
						}
					case *ast.ValueSpec:
						if len(s.Names) == 1 && s.Names[0].Name == "_" && len(s.Values) == 1 {
							if id, ok := s.Values[0].(*ast.Ident); ok && deadNames[id.Name] {
								dead = append(dead, s)
								continue
							}
						}
						n := 0
						for _, id := range s.Names {
							if matches(id) {
								n++
							}
						}
						if n == len(s.Names) && n > 0 {
							dead = append(dead, s)
						} else if n > 0 {
							fmt.Printf("skipped %s: only some names in one declaration\n", fset.Position(s.Pos()))
						}
					}
				}
				switch {
				case len(dead) == 0:
				case len(dead) == len(d.Specs):
					cuts = append(cuts, cut{offset(fset, startWithDoc(d.Doc, d.Pos())), offset(fset, d.End())})
				default:
					for _, s := range dead {
						var doc *ast.CommentGroup
						switch s := s.(type) {
						case *ast.TypeSpec:
							doc = s.Doc
						case *ast.ValueSpec:
							doc = s.Doc
						}
						cuts = append(cuts, cut{offset(fset, startWithDoc(doc, s.Pos())), offset(fset, s.End())})
					}
				}
			}
		}
		if len(cuts) == 0 {
			continue
		}
		sort.Slice(cuts, func(i, j int) bool { return cuts[i].start > cuts[j].start })
		for _, c := range cuts {
			end := c.end
			for end < len(src) && (src[end] == ' ' || src[end] == '\t') {
				end++
			}
			if end < len(src) && src[end] == '\n' {
				end++
			}
			src = append(src[:c.start:c.start], src[end:]...)
		}
		total += len(cuts)
		if err := os.WriteFile(file, src, 0o644); err != nil {
			fail(err)
		}
	}
	return total
}

func offset(fset *token.FileSet, p token.Pos) int { return fset.Position(p).Offset }

func deleteEmptyFiles() {
	files, _ := filepath.Glob("*.go")
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(token.NewFileSet(), f, nil, 0)
		if err != nil {
			fail(err)
		}
		if onlyGuards(af) {
			fmt.Println("deleted empty file:", f)
			if err := os.Remove(f); err != nil {
				fail(err)
			}
		}
	}
}

func goenv(k string) string {
	out, err := exec.Command("go", "env", k).Output()
	if err != nil {
		fail(err)
	}
	return strings.TrimSpace(string(out))
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "prune:", err)
	os.Exit(1)
}

// unreferenced finds top-level types, vars and consts that nothing outside
// their own declaration refers to. Functions are deadcode's job, since it
// knows what is reachable from main; here it is only "does anything name it".
func unreferenced() []position {
	fset := token.NewFileSet()
	names, _ := filepath.Glob("*.go")
	var files []*ast.File
	for _, f := range names {
		// Honour build constraints (*_linux.go vs *_other.go) exactly like
		// `go build` does on this machine.
		if ok, _ := build.Default.MatchFile(".", f); strings.HasSuffix(f, "_test.go") || !ok {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			fail(err)
		}
		files = append(files, af)
	}
	info := &types.Info{
		Defs: map[*ast.Ident]types.Object{},
		Uses: map[*ast.Ident]types.Object{},
	}
	conf := types.Config{Importer: importer.ForCompiler(fset, "source", nil)}
	if _, err := conf.Check("main", fset, files, info); err != nil {
		// A package that does not compile must not be pruned any further.
		fmt.Println("package does not compile:", err)
		return nil
	}
	type span struct{ start, end token.Pos }
	candidates := map[types.Object]span{}
	for _, af := range files {
		for _, d := range af.Decls {
			g, ok := d.(*ast.GenDecl)
			if !ok || g.Tok == token.IMPORT {
				continue
			}
			for _, sp := range g.Specs {
				switch sp := sp.(type) {
				case *ast.TypeSpec:
					candidates[info.Defs[sp.Name]] = span{sp.Pos(), sp.End()}
				case *ast.ValueSpec:
					for _, id := range sp.Names {
						if id.Name != "_" {
							candidates[info.Defs[id]] = span{sp.Pos(), sp.End()}
						}
					}
				}
			}
		}
	}
	used := map[types.Object]bool{}
	for id, obj := range info.Uses {
		if s, ok := candidates[obj]; ok && (id.Pos() < s.start || id.Pos() >= s.end) {
			used[obj] = true
		}
	}
	var out []position
	for obj := range candidates {
		if obj == nil || used[obj] {
			continue
		}
		p := fset.Position(obj.Pos())
		out = append(out, position{filepath.Base(p.Filename), p.Line, p.Column})
	}
	return out
}

// onlyGuards reports a file that holds nothing but imports and
// `var _ = pkg.Name` guards (which only keep an import from being unused).
// Such a file contributes nothing.
func onlyGuards(af *ast.File) bool {
	for _, d := range af.Decls {
		g, ok := d.(*ast.GenDecl)
		if !ok {
			return false
		}
		if g.Tok == token.IMPORT {
			continue
		}
		if g.Tok != token.VAR {
			return false
		}
		for _, sp := range g.Specs {
			v := sp.(*ast.ValueSpec)
			for _, id := range v.Names {
				if id.Name != "_" {
					return false
				}
			}
			for _, val := range v.Values {
				if _, ok := val.(*ast.SelectorExpr); !ok {
					return false
				}
			}
		}
	}
	return true
}

// text reads the keep list as UTF-8 or UTF-16. Redirecting with ">" in
// Windows PowerShell 5.1 writes UTF-16LE with a BOM; without this, no name
// matches and -keep silently keeps nothing - which is exactly how it was found.
func text(b []byte) string {
	switch {
	case len(b) >= 2 && b[0] == 0xFF && b[1] == 0xFE:
		u := make([]uint16, 0, len(b)/2)
		for i := 2; i+1 < len(b); i += 2 {
			u = append(u, uint16(b[i])|uint16(b[i+1])<<8)
		}
		return string(utf16.Decode(u))
	case len(b) >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF:
		return string(b[3:])
	}
	return string(b)
}
