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
// real processes, real signals, real process groups. The execute-only bash of
// the images is installed at its path by the Dockerfile's test stage
// (`--target hidden-test-tests`), root-owned with mode 0711; where it is not,
// the tests that need it say so and skip, and the others run under /bin/bash.
// The node's ptrace_scope is a file the tests write, never the node's own.

// scope1 is a file that says ptrace_scope is 1.
var scope1 string

func TestMain(m *testing.M) {
	switch os.Getenv("MLS_TEST_MODE") {
	case "helper":
		setNotDumpable()
		if path := os.Getenv("MLS_TEST_BASH"); path != "" {
			bashPath = path
		}
		ptraceScopePath = os.Getenv("MLS_TEST_SCOPE")
		os.Exit(run(os.Args[1:], os.Stdin))
	case "attacker":
		os.Exit(attack(os.Args[1:]))
	}
	dir, err := os.MkdirTemp("", "mls-hidden-test-")
	if err != nil {
		panic(err)
	}
	scope1 = filepath.Join(dir, "ptrace_scope")
	if err := os.WriteFile(scope1, []byte("1\n"), 0o644); err != nil {
		panic(err)
	}
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}

// testBash is the bash the tests run under: the image's execute-only one when
// it is installed, else /bin/bash.
func testBash() string {
	if _, err := os.Stat(bashPath); err == nil {
		return bashPath
	}
	return "/bin/bash"
}

// requireExecuteOnlyBash skips the test unless bash is the image's copy, which
// the user of the tests cannot read.
func requireExecuteOnlyBash(t *testing.T) {
	t.Helper()
	if testBash() != bashPath || syscall.Access(bashPath, 4) == nil {
		t.Skip(bashPath + " is not installed execute-only; run `docker build --target hidden-test-tests control`")
	}
}

func digestOf(body string) string {
	sum := sha256.Sum256([]byte(body))
	return hex.EncodeToString(sum[:])
}

// helperWith returns the command that runs the helper with the arguments
// given, not yet started.
func helperWith(scope string, args ...string) *exec.Cmd {
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = append(os.Environ(),
		"MLS_TEST_MODE=helper", "MLS_TEST_SCOPE="+scope, "MLS_TEST_BASH="+testBash(),
		"MLS_TEST_SELF="+os.Args[0])
	if len(args) > 1 {
		cmd.Env = append(cmd.Env, "WORKSPACE="+args[1])
	}
	return cmd
}

// helper returns the command that runs the helper on a test of digest
// `digest`, with `seconds` as its limit.
func helper(digest, workspace, seconds string) *exec.Cmd {
	return helperWith(scope1, digest, workspace, seconds)
}

func statusOf(t *testing.T, err error) int {
	t.Helper()
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

// exitOf runs the helper with `input` as the test and `digest` as the digest
// the lab stored, and returns its exit status.
func exitOf(t *testing.T, digest, input, workspace string) int {
	t.Helper()
	cmd := helper(digest, workspace, "60")
	cmd.Stdin = strings.NewReader(input)
	return statusOf(t, cmd.Run())
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

// pidIn reads the process ID a test wrote to `name` in the workspace, waiting
// for it.
func pidIn(workspace, name string) int {
	for i := 0; i < 250; i++ {
		raw, _ := os.ReadFile(filepath.Join(workspace, name))
		if pid, _ := strconv.Atoi(strings.TrimSpace(string(raw))); pid != 0 {
			return pid
		}
		time.Sleep(20 * time.Millisecond)
	}
	return 0
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
		"exit 124\n":              1, // the test cannot choose the helper's statuses
		"exit 125\n":              1,
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
	// A stored test with a NUL in it is no test: bash would read it up to the
	// NUL, and what runs would not be what the digest names.
	withNul := "touch " + marker + "\n\x00exit 0\n"
	if got := exitOf(t, digestOf(withNul), withNul, ws); got != exitNotAsStored {
		t.Errorf("a stored test with a NUL: exit %d, want %d", got, exitNotAsStored)
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
	d, ws := digestOf(good), t.TempDir()
	for name, args := range map[string][]string{
		"no arguments":      {},
		"one":               {d},
		"two":               {d, ws},
		"four":              {d, ws, "60", "extra"},
		"short digest":      {d[:63], ws, "60"},
		"upper-case digest": {strings.ToUpper(d), ws, "60"},
		"relative dir":      {d, "workspace", "60"},
		"no limit":          {d, ws, ""},
		"zero limit":        {d, ws, "0"},
		"negative limit":    {d, ws, "-1"},
		"not a number":      {d, ws, "soon"},
		"nan":               {d, ws, "NaN"},
		"infinite":          {d, ws, "Inf"},
		"too long a limit":  {d, ws, "3601"},
	} {
		cmd := helperWith(scope1, args...)
		cmd.Stdin = strings.NewReader(good)
		if got := statusOf(t, cmd.Run()); got != exitNotAsStored {
			t.Errorf("%s: exit %d, want %d", name, got, exitNotAsStored)
		}
	}
}

// Everything else rests on the node restricting ptrace, so the program says
// no, with a reason, on a node that does not say so.
func TestTheNodeMustRestrictPtrace(t *testing.T) {
	good := "exit 0\n"
	d := digestOf(good)
	dir := t.TempDir()
	marker := filepath.Join(dir, "ran")
	run := func(scope string) (int, string) {
		cmd := helperWith(scope, d, dir, "60")
		cmd.Stdin = strings.NewReader("touch " + marker + "\n")
		var stderr strings.Builder
		cmd.Stderr = &stderr
		return statusOf(t, cmd.Run()), stderr.String()
	}
	files := 0
	write := func(content string) string {
		files++
		path := filepath.Join(dir, "scope-"+strconv.Itoa(files))
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		return path
	}
	for name, scope := range map[string]string{
		"scope 0":         write("0\n"),
		"scope -1":        write("-1\n"),
		"no number":       write("yama\n"),
		"nothing":         write(""),
		"no such file":    filepath.Join(dir, "missing"),
		"a directory":     dir,
		"an unset":        "",
		"scope 0 padded":  write(" 0 \n\n"),
		"scope 00":        write("00\n"),
		"scope 0 and one": write("0 1\n"),
	} {
		code, why := run(scope)
		if code != exitCannotRun || !strings.Contains(why, "refused") || !strings.Contains(why, "ptrace_scope") {
			t.Errorf("%s: exit %d, %q; want exit %d and a reason", name, code, why, exitCannotRun)
		}
	}
	if _, err := os.Stat(marker); err == nil {
		t.Error("a test ran on a node that does not restrict ptrace")
	}
	// 1 and more run the test.
	for _, scope := range []string{"1\n", "2\n", "3\n", "1"} {
		cmd := helperWith(write(scope), d, dir, "60")
		cmd.Stdin = strings.NewReader(good)
		if got := statusOf(t, cmd.Run()); got != 0 {
			t.Errorf("scope %q: exit %d", scope, got)
		}
	}
}

// The code under test is a child of the bash that evals the test. It finds no
// descriptor to read the test from, cannot open its parent's descriptors or
// memory, and no readable process, file or command line holds the test.
func TestTheCodeUnderTestCannotReadTheTest(t *testing.T) {
	requireExecuteOnlyBash(t)
	ws := t.TempDir()
	body := `#!/bin/bash
# MLS-CANARY: only this test has this word
fail() { echo "$1" > "$WORKSPACE/why"; exit 1; }
# Bash's input is /dev/null: it ends at once. (Its descriptors are not links a
# child may read, which is the point; only bash itself looks at them.)
if read -r -t 1 line; then fail "there is input"; fi
[ "$(pwd -P)" = "$(cd "$WORKSPACE" && pwd -P)" ] || fail "directory is $(pwd -P)"
[ ! -e /proc/$$/fd/3 ] || fail "descriptor 3 is open"
# A child of this bash, as the code under test is, and the helper above it.
bash -c '
  [ ! -e /proc/$PPID/fd/3 ] || exit 11
  if ls /proc/$PPID/fd >/dev/null 2>&1; then exit 12; fi
  if cat /proc/$PPID/mem >/dev/null 2>&1; then exit 13; fi
  if ls /proc/$(sed "s/^.*) [A-Za-z] //; s/ .*//" /proc/$PPID/stat)/fd >/dev/null 2>&1; then exit 14; fi
' || fail "a child read what it must not: $?"
if grep -a -D skip -d skip -l 'MLS-CANAR[Y]' /proc/[0-9]*/fd/* /proc/[0-9]*/cmdline /proc/[0-9]*/environ 2>/dev/null | grep -q .; then
  fail "the test's text is readable"
fi
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
	pid := pidIn(ws, "pid")
	if pid == 0 || !gone(pid) {
		t.Errorf("process %d outlived its test", pid)
	}
}

func TestTermKillsTheGroupAndExits143(t *testing.T) {
	ws := t.TempDir()
	body := "sleep 300 &\necho $! > pid\nsleep 300\n"
	cmd := helper(digestOf(body), ws, "60")
	cmd.Stdin = strings.NewReader(body)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pid := pidIn(ws, "pid")
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

// The limit is the helper's own, over the reading of the input and the test:
// it kills the group and exits 124, with no other program to carry the status.
func TestTheTimeLimitIsTheHelpersAndKillsTheGroup(t *testing.T) {
	for _, seconds := range []string{"1", "0.4"} {
		ws := t.TempDir()
		body := "sleep 300 &\necho $! > pid\nsleep 300\n"
		cmd := helper(digestOf(body), ws, seconds)
		cmd.Stdin = strings.NewReader(body)
		started := time.Now()
		got := statusOf(t, cmd.Run())
		if got != exitTimedOut {
			t.Errorf("limit %s: exit %d, want %d", seconds, got, exitTimedOut)
		}
		if elapsed := time.Since(started); elapsed > 5*time.Second {
			t.Errorf("limit %s: took %v", seconds, elapsed)
		}
		if pid := pidIn(ws, "pid"); pid == 0 || !gone(pid) {
			t.Errorf("limit %s: process %d outlived the limit", seconds, pid)
		}
	}
	// An input that never ends is cut off by it too.
	body := "exit 0\n"
	cmd := helper(digestOf(body), t.TempDir(), "1")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	_, _ = stdin.Write([]byte("exit"))
	if got := statusOf(t, cmd.Wait()); got != exitTimedOut {
		t.Errorf("an input that never ends: exit %d, want %d", got, exitTimedOut)
	}
	_ = stdin.Close()
}

// A test that is ended by the limit, or by SIGTERM, is always 124, or 143:
// never the 1 of a test that failed. The timer and the signal handler kill the
// group and exit, and the main path wakes from the death of bash at the same
// moment, so the status cannot depend on who gets to exit first.
func TestAnEndedTestAlwaysGivesTheStatusOfWhatEndedIt(t *testing.T) {
	body := "sleep 300\n"
	d := digestOf(body)
	for i := 0; i < 300; i++ {
		// A limit that falls while bash is running, or just before it starts.
		cmd := helper(d, t.TempDir(), "0.05")
		cmd.Stdin = strings.NewReader(body)
		if got := statusOf(t, cmd.Run()); got != exitTimedOut {
			t.Fatalf("run %d: the limit ended the test and the status is %d, want %d", i, got, exitTimedOut)
		}
	}
	for i := 0; i < 150; i++ {
		ws := t.TempDir()
		body := "echo $$ > pid\nsleep 300\n"
		cmd := helper(digestOf(body), ws, "60")
		cmd.Stdin = strings.NewReader(body)
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		if pidIn(ws, "pid") == 0 {
			t.Fatalf("run %d: the test did not start", i)
		}
		if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
			t.Fatal(err)
		}
		_ = cmd.Wait()
		if got := cmd.ProcessState.ExitCode(); got != exitTerminated {
			t.Fatalf("run %d: SIGTERM ended the test and the status is %d, want %d", i, got, exitTerminated)
		}
	}
}

// Once the limit or a signal has acted, the main path returns its status, not
// the 1 of a test that bash ended by a kill.
func TestTheMainPathReturnsWhatTheLimitOrASignalExitsWith(t *testing.T) {
	failed := exec.Command("/bin/sh", "-c", "exit 3").Run()
	if failed == nil {
		t.Fatal("the stand-in did not fail")
	}
	defer forced.Store(0)
	for _, tc := range []struct {
		forced int32
		err    error
		want   int
	}{
		{0, nil, exitPassed},
		{0, failed, exitFailed},
		{0, errors.New("wait: no child"), exitCannotRun},
		{exitTimedOut, failed, exitTimedOut},
		{exitTerminated, failed, exitTerminated},
		{exitTimedOut, nil, exitTimedOut},
	} {
		forced.Store(tc.forced)
		if got := outcome(tc.err); got != tc.want {
			t.Errorf("forced %d, wait %v: status %d, want %d", tc.forced, tc.err, got, tc.want)
		}
	}
}

// If the helper is killed outright, the kernel takes its bash with it.
func TestAHelperThatIsKilledTakesItsBashWithIt(t *testing.T) {
	ws := t.TempDir()
	body := "echo $$ > bash.pid\nsleep 300 &\necho $! > sleep.pid\nsleep 300\n"
	cmd := helper(digestOf(body), ws, "60")
	cmd.Stdin = strings.NewReader(body)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	bash, sleeper := pidIn(ws, "bash.pid"), pidIn(ws, "sleep.pid")
	defer func() {
		if sleeper != 0 {
			_ = syscall.Kill(sleeper, syscall.SIGKILL)
		}
	}()
	if bash == 0 {
		t.Fatal("the test did not start")
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = cmd.Wait()
	if !gone(bash) {
		t.Errorf("bash %d outlived the helper", bash)
		_ = syscall.Kill(bash, syscall.SIGKILL)
	}
}

// What a process of the learner's, which is the same user, can do to the
// ancestors of the code under test: nothing it tries gets a descriptor, the
// memory or a trace of them.
func TestTheCodeUnderTestCannotTraceItsAncestors(t *testing.T) {
	requireExecuteOnlyBash(t)
	ws := t.TempDir()
	body := `MLS_TEST_MODE=attacker "$MLS_TEST_SELF" "$WORKSPACE/attack.log"
exit 1
`
	if got := exitOf(t, digestOf(body), body, ws); got != 1 {
		t.Fatalf("exit %d", got)
	}
	log, err := os.ReadFile(filepath.Join(ws, "attack.log"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(log)), "\n")
	if len(lines) != 2 {
		t.Fatalf("the attacker reached %d ancestors, want its bash and the helper:\n%s", len(lines), log)
	}
	for _, line := range lines {
		if !strings.HasSuffix(line, "denied") {
			t.Errorf("an ancestor was reachable: %s", line)
		}
	}
}

// attack is the code under test of a hostile learner: it tries to trace, to
// write the memory of and to list the descriptors of its two nearest ancestors
// (its bash and the helper) and logs what it got.
func attack(args []string) int {
	var log strings.Builder
	pid := os.Getppid()
	for i := 0; i < 2 && pid > 1; i++ {
		got := []string{}
		if err := syscall.PtraceAttach(pid); err == nil {
			_, _ = syscall.Wait4(pid, nil, 0, nil)
			_ = syscall.PtraceDetach(pid)
			got = append(got, "trace")
		}
		if f, err := os.OpenFile(fmt.Sprintf("/proc/%d/mem", pid), os.O_RDWR, 0); err == nil {
			_ = f.Close()
			got = append(got, "memory")
		}
		if _, err := os.ReadDir(fmt.Sprintf("/proc/%d/fd", pid)); err == nil {
			got = append(got, "descriptors")
		}
		verdict := "denied"
		if len(got) > 0 {
			verdict = "OPEN: " + strings.Join(got, ",")
		}
		fmt.Fprintf(&log, "%d %s\n", pid, verdict)
		stat, _ := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
		if i := strings.LastIndex(string(stat), ") "); i >= 0 {
			fields := strings.Fields(string(stat[i+2:]))
			pid, _ = strconv.Atoi(fields[1])
		}
	}
	if len(args) == 1 {
		_ = os.WriteFile(args[0], []byte(log.String()), 0o644)
	}
	return 0
}

// A process of the same user holds the helper's input, stops the helper and
// writes to it. Nothing it does turns a failing test into a pass.
func TestAProcessOfTheSameUserCannotTurnAFailingTestIntoAPass(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root opens every descriptor; the contract runs as uid 1000")
	}
	failing := "exit 1\n"
	cmd := helper(digestOf(failing), t.TempDir(), "60")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pid := cmd.Process.Pid
	// The helper makes itself not dumpable first thing (the image's mode 0711
	// does it before the first instruction). Until then its descriptors can be
	// opened; after it they cannot. Take what can be had.
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
