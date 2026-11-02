// Command mls-hidden-test runs one hidden test of a MyLabSkills lab in the
// learner's control pod and gives its verdict as its own exit status
// (epr-consulting/backend#486).
//
//	mls-hidden-test <sha256> <workspace> <seconds>      the test is the standard input
//
// A learner runs processes as the same user as this program, so the program
// never lets the verdict, or the test, travel through a channel such a process
// could write: a pipe, a file or a child's answer. It keeps to the channels
// one cannot reach, which are its arguments, its own memory and its exit
// status, and it is the process that reports that status: nothing stands
// between it and the container runtime, not even GNU timeout.
//
// It is installed with mode 0711 (execute-only), so the kernel makes it
// non-dumpable when it starts: another process of its user can neither open
// its descriptors or memory in /proc nor trace it, with no window at startup.
// It does the same with prctl as well. Both are hardening on top of the one
// setting everything else depends on, which it checks:
//
//	kernel.yama.ptrace_scope must be 1 or more.
//
// At 0 a process of the learner's, the program under test, could attach to its
// ancestors (bash, this program) and set the verdict. The program reads
// /proc/sys/kernel/yama/ptrace_scope first and, if the file is missing or says 0,
// refuses (126) and says why on standard error. The check is then unavailable
// on that node, never forgeable.
//
// Then it
//
//  1. starts its time limit, the third argument in seconds (fractions allowed),
//     over everything below: when it runs out the program kills the test's
//     group and exits 124;
//  2. reads the test from standard input, up to 100 KiB, and closes standard
//     input;
//  3. hashes it in-process and compares the SHA-256 with the digest in its
//     arguments, so a test that is not the one the lab stored is never run;
//  4. writes it to a memfd that it seals against writing, growing and
//     shrinking, and checks the sealed bytes against the digest again, since
//     a file that was open for writing before the seals could have changed
//     them;
//  5. starts an execute-only bash (mode 0711, a copy of /bin/bash that is not
//     readable and so not dumpable) as a process group of its own, with
//     standard input, output and error on /dev/null and the workspace as its
//     directory, and the sealed file as its descriptor 3. The bash reads the
//     test from it into a variable, closes the descriptor and evals the
//     variable: the test lives only in the memory of a process that nothing of
//     the learner's can read, and the code under test, which bash starts, has
//     no descriptor to read it from;
//  6. has the kernel kill that bash if this program dies (PR_SET_PDEATHSIG);
//  7. on SIGTERM (or SIGINT or SIGHUP) kills the group and exits 143;
//  8. when the test ends, kills the group, and exits 0 only if the test exited
//     0, and 1 otherwise.
//
// Exit statuses: 0 the test passed; 1 it did not; 124 the time limit ran out;
// 125 the test is not what the digest names, or the program was misused; 126
// the node does not enforce ptrace_scope, or the program could not start the
// test; 143 it was told to stop. 137 is a kill.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const (
	// maxTestBytes is the largest artifact the platform stores.
	maxTestBytes = 100 * 1024

	// The longest time limit the program accepts, in seconds.
	maxSeconds = 3600

	exitPassed      = 0
	exitFailed      = 1
	exitTimedOut    = 124
	exitNotAsStored = 125
	exitCannotRun   = 126
	exitTerminated  = 143

	// What bash runs: it reads the test from descriptor 3, which is the sealed
	// file, into a variable, closes the descriptor and evals the variable.
	script = `IFS= read -r -d '' t </proc/self/fd/3; exec 3<&-; eval "$t"`

	// Linux constants the syscall package does not export.
	prSetDumpable  = 4
	mfdCloexec     = 0x1
	mfdAllowSeal   = 0x2
	fAddSeals      = 0x409
	fSealSeal      = 0x1
	fSealShrink    = 0x2
	fSealGrow      = 0x4
	fSealWrite     = 0x8
	sealsOfTheTest = fSealSeal | fSealShrink | fSealGrow | fSealWrite
)

var (
	// bashPath is the bash a test runs under: a copy of /bin/bash that the
	// image installs with mode 0711, which the kernel does not let a process of
	// the learner's trace or read once it runs. A variable for the tests'
	// sake; nothing the program reads sets it.
	bashPath = "/usr/local/libexec/mls-bash"
	// ptraceScopePath is the node setting the program requires to be 1 or more.
	ptraceScopePath = "/proc/sys/kernel/yama/ptrace_scope"

	// group is the process group of the test while one runs, else 0.
	group atomic.Int64
	// starting is held while the test is started and `group` is set, so a
	// signal that arrives in between still finds the group.
	starting sync.Mutex
)

func main() {
	setNotDumpable()
	os.Exit(run(os.Args[1:], os.Stdin))
}

// setNotDumpable makes the process not dumpable. The error is ignored: the
// rest does not depend on it.
func setNotDumpable() {
	_, _, _ = syscall.RawSyscall(syscall.SYS_PRCTL, prSetDumpable, 0, 0)
}

// run runs the test on `stdin` as `args` (the digest, the workspace and the
// time limit) say and returns the program's exit status.
func run(args []string, stdin *os.File) int {
	limit, ok := parseLimit(args)
	if !ok || !isDigest(args[0]) || !filepath.IsAbs(args[1]) {
		fmt.Fprintln(os.Stderr, "usage: mls-hidden-test <sha256> <absolute workspace> <seconds>")
		return exitNotAsStored
	}
	digest, workspace := args[0], args[1]
	if reason := nodeRefuses(); reason != "" {
		fmt.Fprintln(os.Stderr, "mls-hidden-test: refused: "+reason)
		return exitCannotRun
	}
	// The kernel's parent-death signal belongs to the thread that starts the
	// child: keep this one until the process ends.
	runtime.LockOSThread()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		<-stop
		starting.Lock()
		killGroup()
		os.Exit(exitTerminated)
	}()
	time.AfterFunc(limit, func() {
		starting.Lock()
		killGroup()
		os.Exit(exitTimedOut)
	})
	body, err := io.ReadAll(io.LimitReader(stdin, maxTestBytes+1))
	_ = stdin.Close()
	if err != nil || len(body) > maxTestBytes || strings.ContainsRune(string(body), 0) || !matches(body, digest) {
		return exitNotAsStored
	}
	file, code := seal(body, digest)
	if code != exitPassed {
		return code
	}
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		return exitCannotRun
	}
	cmd := exec.Command(bashPath, "-c", script, "mls-test")
	cmd.Dir = workspace
	cmd.ExtraFiles = []*os.File{file}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
	starting.Lock()
	err = cmd.Start()
	if err == nil {
		group.Store(int64(cmd.Process.Pid))
	}
	starting.Unlock()
	_ = file.Close()
	if err != nil {
		return exitCannotRun
	}
	waitErr := cmd.Wait()
	killGroup()
	if waitErr != nil {
		var exited *exec.ExitError
		if errors.As(waitErr, &exited) {
			return exitFailed
		}
		return exitCannotRun
	}
	return exitPassed
}

// parseLimit reads the third argument, the time limit in seconds, and whether
// the arguments are three with a limit from a millisecond to an hour.
func parseLimit(args []string) (time.Duration, bool) {
	if len(args) != 3 {
		return 0, false
	}
	seconds, err := strconv.ParseFloat(args[2], 64)
	if err != nil || !(seconds >= 0.001 && seconds <= maxSeconds) {
		return 0, false
	}
	return time.Duration(seconds * float64(time.Second)), true
}

// nodeRefuses returns why this node cannot give a trustworthy verdict, or ""
// when it can: kernel.yama.ptrace_scope must be 1 or more, since at 0 any
// process of the learner's may trace another, bash and this program included.
func nodeRefuses() string {
	raw, err := os.ReadFile(ptraceScopePath)
	if err != nil {
		return "cannot read " + ptraceScopePath + ": the node does not say it restricts ptrace (kernel.yama.ptrace_scope must be 1 or more)"
	}
	scope, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		return ptraceScopePath + " holds no number (kernel.yama.ptrace_scope must be 1 or more)"
	}
	if scope < 1 {
		return "kernel.yama.ptrace_scope is " + strconv.Itoa(scope) + " on this node: a process of the learner's could trace bash and set the verdict (it must be 1 or more)"
	}
	return ""
}

// killGroup kills the test's process group, whatever is left of it.
func killGroup() {
	if pgid := group.Load(); pgid > 0 {
		_ = syscall.Kill(-int(pgid), syscall.SIGKILL)
	}
}

// isDigest reports whether s is a lowercase hex SHA-256.
func isDigest(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// matches reports whether body's SHA-256 is digest.
func matches(body []byte, digest string) bool {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:]) == digest
}

// seal writes body to a memfd, seals it against any change, and returns it
// once the sealed bytes are shown to be the ones the digest names. The
// status is exitPassed when it succeeds.
func seal(body []byte, digest string) (*os.File, int) {
	name, err := syscall.BytePtrFromString("mls-hidden-test")
	if err != nil {
		return nil, exitCannotRun
	}
	fd, _, errno := syscall.Syscall(sysMemfdCreate,
		uintptr(unsafe.Pointer(name)), mfdCloexec|mfdAllowSeal, 0)
	if errno != 0 {
		return nil, exitCannotRun
	}
	file := os.NewFile(fd, "hidden-test")
	if _, err := file.Write(body); err != nil {
		_ = file.Close()
		return nil, exitCannotRun
	}
	if _, _, errno := syscall.Syscall(syscall.SYS_FCNTL, fd, fAddSeals, sealsOfTheTest); errno != 0 {
		_ = file.Close()
		// A file that is mapped writable refuses the seal: something else
		// holds it.
		if errno == syscall.EBUSY {
			return nil, exitNotAsStored
		}
		return nil, exitCannotRun
	}
	// From here on no descriptor of any process can change the file. What it
	// holds is checked once, now.
	sealed := make([]byte, len(body)+1)
	n, err := file.ReadAt(sealed, 0)
	if err != nil && !errors.Is(err, io.EOF) {
		_ = file.Close()
		return nil, exitCannotRun
	}
	if n != len(body) || !matches(sealed[:n], digest) {
		_ = file.Close()
		return nil, exitNotAsStored
	}
	return file, exitPassed
}
