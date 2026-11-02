package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The helper under test is this test binary, started again as the program:
// real processes, real signals, real process groups.
func TestMain(m *testing.M) {
	if os.Getenv("MLS_HIDDEN_TEST_CHILD") == "1" {
		setNotDumpable()
		os.Exit(run(os.Args[1:], os.Stdin))
	}
	os.Exit(m.Run())
}

func digestOf(body string) string {
	sum := sha256.Sum256([]byte(body))
	return hex.EncodeToString(sum[:])
}

// helper returns the command that runs the helper, not yet started.
func helper(digest, workspace string) *exec.Cmd {
	cmd := exec.Command(os.Args[0], digest, workspace)
	cmd.Env = append(os.Environ(), "MLS_HIDDEN_TEST_CHILD=1", "WORKSPACE="+workspace)
	return cmd
}

// exitOf runs the helper with `input` as the test and `digest` as the digest
// the lab stored, and returns its exit status.
func exitOf(t *testing.T, digest, input, workspace string) int {
	t.Helper()
	cmd := helper(digest, workspace)
	cmd.Stdin = strings.NewReader(input)
	err := cmd.Run()
	var exited *exec.ExitError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &exited):
		return exited.ExitCode()
	default:
		t.Fatal(err)
		return -1
	}
}

// verdict runs `body` as a stored test.
func verdict(t *testing.T, body string) int {
	t.Helper()
	return exitOf(t, digestOf(body), body, t.TempDir())
}

// gone reports whether process pid is gone: no entry, or a zombie.
func gone(pid int) bool {
	deadline := time.Now().Add(3 * time.Second)
	for {
		stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
		if err != nil {
			return true
		}
		if i := strings.LastIndex(string(stat), ") "); i >= 0 && strings.HasPrefix(string(stat[i+2:]), "Z") {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestOnlyAZeroExitPasses(t *testing.T) {
	for body, want := range map[string]int{
		"exit 0\n":                0,
		"true\n":                  0,
		"#!/bin/bash\n# a test\n": 0,
		"exit 1\n":                1,
		"exit 7\n":                1,
		"false\n":                 1,
		"if then\n":               1, // a syntax error
		"kill -KILL $$\n":         1, // ended by a signal
		"exit 125\n":              1, // the test cannot choose the helper's statuses
		"exit 126\n":              1,
		"exit 143\n":              1,
	} {
		if got := verdict(t, body); got != want {
			t.Errorf("%q: exit %d, want %d", body, got, want)
		}
	}
}

func TestATestThatIsNotTheStoredOneNeverRuns(t *testing.T) {
	stored := "exit 1\n"
	digest := digestOf(stored)
	ws := t.TempDir()
	marker := filepath.Join(ws, "ran")
	for name, input := range map[string]string{
		"appended":      stored + "exit 0\n",
		"prepended":     "exit 0\n" + stored,
		"replaced":      "exit 0\n",
		"cut":           "exit",
		"empty":         "",
		"nul":           "exit 0\n\x00" + strings.Repeat("x", 4096),
		"too much":      "exit 0\n" + strings.Repeat("#", maxTestBytes),
		"much too much": strings.Repeat("#", 2*maxTestBytes),
		"ran":           "touch " + marker + "\nexit 0\n",
	} {
		if got := exitOf(t, digest, input, ws); got != exitNotAsStored {
			t.Errorf("%s: exit %d, want %d", name, got, exitNotAsStored)
		}
	}
	if _, err := os.Stat(marker); err == nil {
		t.Error("a test that was not the stored one ran")
	}
	// The largest test there is still runs.
	big := "exit 0\n#" + strings.Repeat("#", maxTestBytes-len("exit 0\n#"))
	if len(big) != maxTestBytes {
		t.Fatalf("test input is %d bytes", len(big))
	}
	if got := exitOf(t, digestOf(big), big, ws); got != 0 {
		t.Errorf("a test of %d bytes: exit %d", len(big), got)
	}
	over := big + "#"
	if got := exitOf(t, digestOf(over), over, ws); got != exitNotAsStored {
		t.Errorf("a test of %d bytes: exit %d, want %d", len(over), got, exitNotAsStored)
	}
}

func TestMisuseIsNotAPass(t *testing.T) {
	good := "exit 0\n"
	for name, args := range map[string][]string{
		"no arguments":      {},
		"one":               {digestOf(good)},
		"three":             {digestOf(good), t.TempDir(), "extra"},
		"short digest":      {digestOf(good)[:63], t.TempDir()},
		"upper-case digest": {strings.ToUpper(digestOf(good)), t.TempDir()},
		"relative dir":      {digestOf(good), "workspace"},
	} {
		cmd := exec.Command(os.Args[0], args...)
		cmd.Env = append(os.Environ(), "MLS_HIDDEN_TEST_CHILD=1")
		cmd.Stdin = strings.NewReader(good)
		err := cmd.Run()
		var exited *exec.ExitError
		if !errors.As(err, &exited) || exited.ExitCode() != exitNotAsStored {
			t.Errorf("%s: %v, want exit %d", name, err, exitNotAsStored)
		}
	}
}

func TestATestRunsAsTheWorkspaceNothingCanWrite(t *testing.T) {
	ws := t.TempDir()
	// The script is the only thing bash was given: its input is /dev/null, the
	// workspace is its directory, and the file it was read from, which it still
	// holds, takes no write, append, truncation or growth by any descriptor.
	body := `#!/bin/bash
fail() { echo "$1" > "$WORKSPACE/why"; exit 1; }
[ "$(readlink /proc/$$/fd/0)" = /dev/null ] || fail "input is not /dev/null"
[ "$(readlink /proc/$$/fd/1)" = /dev/null ] || fail "output is not /dev/null"
[ "$(pwd -P)" = "$(cd "$WORKSPACE" && pwd -P)" ] || fail "directory is $(pwd -P)"
[ -n "$(readlink /proc/$$/fd/3)" ] || fail "the script is not descriptor 3"
if echo evil >> /proc/self/fd/3 2>/dev/null; then fail "append"; fi
if : > /proc/self/fd/3 2>/dev/null; then fail "truncate by redirection"; fi
if exec 4<> /proc/self/fd/3 2>/dev/null && echo evil >&4 2>/dev/null; then fail "write"; fi
if truncate -s 0 /proc/self/fd/3 2>/dev/null; then fail "truncate"; fi
[ "$(head -c 11 /proc/self/fd/3)" = '#!/bin/bash' ] || fail "the script cannot be read"
exit 0
`
	if got := exitOf(t, digestOf(body), body, ws); got != 0 {
		why, _ := os.ReadFile(filepath.Join(ws, "why"))
		t.Fatalf("exit %d: %s", got, why)
	}
}

func TestWhatATestStartedIsKilledWhenItEnds(t *testing.T) {
	ws := t.TempDir()
	body := "sleep 300 &\necho $! > pid\nexit 0\n"
	if got := exitOf(t, digestOf(body), body, ws); got != 0 {
		t.Fatalf("exit %d", got)
	}
	raw, err := os.ReadFile(filepath.Join(ws, "pid"))
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(raw)))
	if pid == 0 || !gone(pid) {
		t.Errorf("process %d outlived its test", pid)
	}
}

func TestTermKillsTheGroupAndExits143(t *testing.T) {
	ws := t.TempDir()
	body := "sleep 300 &\necho $! > pid\nsleep 300\n"
	cmd := helper(digestOf(body), ws)
	cmd.Stdin = strings.NewReader(body)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	var pid int
	for i := 0; i < 200 && pid == 0; i++ {
		raw, _ := os.ReadFile(filepath.Join(ws, "pid"))
		pid, _ = strconv.Atoi(strings.TrimSpace(string(raw)))
		time.Sleep(20 * time.Millisecond)
	}
	if pid == 0 {
		t.Fatal("the test did not start")
	}
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	_ = cmd.Wait()
	if got := cmd.ProcessState.ExitCode(); got != exitTerminated {
		t.Errorf("exit %d, want %d", got, exitTerminated)
	}
	if !gone(pid) {
		t.Errorf("process %d outlived the helper", pid)
	}
}

// A process of the learner's, which is the same user, tries what the earlier
// runner fell to: it holds the helper's input, stops the helper and writes to
// it. Nothing it does turns a failing test into a pass.
func TestAProcessOfTheSameUserCannotTurnAFailingTestIntoAPass(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root opens every descriptor; the contract runs as uid 1000")
	}
	failing := "exit 1\n"
	cmd := helper(digestOf(failing), t.TempDir())
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pid := cmd.Process.Pid
	// The helper makes itself not dumpable first thing. Until then its
	// descriptors can be opened; after it they cannot. Take what can be had.
	var hostile *os.File
	deadline := time.Now().Add(3 * time.Second)
	refused := false
	for time.Now().Before(deadline) && !refused {
		f, err := os.OpenFile(fmt.Sprintf("/proc/%d/fd/0", pid), os.O_WRONLY, 0)
		switch {
		case err == nil && hostile == nil:
			hostile = f
		case err == nil:
			_ = f.Close()
		case errors.Is(err, os.ErrPermission):
			refused = true
		}
		time.Sleep(time.Millisecond)
	}
	if !refused {
		t.Fatal("the helper's descriptors stayed open to a process of its user")
	}
	// Stopped, it still cannot be opened, written through /proc or traced.
	if err := cmd.Process.Signal(syscall.SIGSTOP); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"fd/0", "mem"} {
		if f, err := os.OpenFile(fmt.Sprintf("/proc/%d/%s", pid, path), os.O_RDWR, 0); err == nil {
			_ = f.Close()
			t.Errorf("/proc/%d/%s opened for writing", pid, path)
		}
	}
	if err := syscall.PtraceAttach(pid); err == nil {
		_ = syscall.PtraceDetach(pid)
		t.Error("the helper could be traced")
	}
	// Whatever was put in the pipe, from the helper's side of it or the
	// other, is not the stored test.
	if hostile != nil {
		_, _ = hostile.WriteString("exit 0\n")
		_ = hostile.Close()
	}
	_ = cmd.Process.Signal(syscall.SIGCONT)
	_, _ = stdin.Write([]byte("exit 0\n" + strings.Repeat("#", 1024) + "\x00"))
	_ = stdin.Close()
	_ = cmd.Wait()
	if got := cmd.ProcessState.ExitCode(); got != exitNotAsStored {
		t.Errorf("exit %d, want %d", got, exitNotAsStored)
	}
}
