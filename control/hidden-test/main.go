// Command mls-hidden-test runs one hidden test of a MyLabSkills lab in the
// learner's control pod and gives its verdict as its own exit status
// (epr-consulting/backend#486).
//
//	mls-hidden-test <sha256> <workspace>      the test is the standard input
//
// A learner runs processes as the same user as this program, so the program
// never lets the verdict, or the test, travel through a channel such a process
// could write: a pipe, a file or a child's answer. It keeps to the channels
// one cannot reach, which are its arguments, its own memory and its exit
// status, and it
//
//  1. reads the test from standard input, up to 100 KiB, and closes standard
//     input;
//  2. hashes it in-process and compares the SHA-256 with the digest in its
//     arguments, so a test that is not the one the lab stored is never run;
//  3. writes it to a memfd that it seals against writing, growing and
//     shrinking, and checks the sealed bytes against the digest again, since
//     a file that was open for writing before the seals could have changed
//     them;
//  4. starts /bin/bash on that file, as a process group of its own, with
//     standard input, output and error on /dev/null and the workspace as its
//     directory;
//  5. on SIGTERM (or SIGINT or SIGHUP) kills the group and exits 143;
//  6. when the test ends, kills the group, and exits 0 only if the test
//     exited 0, and 1 otherwise.
//
// It is also not dumpable (PR_SET_DUMPABLE 0), so that another process of
// its user can neither open its descriptors in /proc nor trace it, whatever
// kernel.yama.ptrace_scope says. That is a hardening: nothing above relies on
// it.
//
// Exit statuses: 0 the test passed; 1 it did not; 125 the test is not what
// the digest names, or the program was misused; 126 it could not start the
// test; 143 it was told to stop. GNU timeout adds 124 and 137 around it.
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
	"sync"
	"sync/atomic"
	"syscall"
	"unsafe"
)

const (
	// maxTestBytes is the largest artifact the platform stores.
	maxTestBytes = 100 * 1024

	exitPassed      = 0
	exitFailed      = 1
	exitNotAsStored = 125
	exitCannotRun   = 126
	exitTerminated  = 143

	// The bash a test runs under, by absolute path.
	bash = "/bin/bash"

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

// run runs the test on `stdin` as `args` (the digest and the workspace) say
// and returns the program's exit status.
func run(args []string, stdin *os.File) int {
	if len(args) != 2 || !isDigest(args[0]) || !filepath.IsAbs(args[1]) {
		fmt.Fprintln(os.Stderr, "usage: mls-hidden-test <sha256> <absolute workspace>")
		return exitNotAsStored
	}
	digest, workspace := args[0], args[1]
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		<-stop
		starting.Lock()
		killGroup()
		os.Exit(exitTerminated)
	}()
	body, err := io.ReadAll(io.LimitReader(stdin, maxTestBytes+1))
	_ = stdin.Close()
	if err != nil || len(body) > maxTestBytes || !matches(body, digest) {
		return exitNotAsStored
	}
	script, code := seal(body, digest)
	if code != exitPassed {
		return code
	}
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		return exitCannotRun
	}
	cmd := exec.Command(bash, "/proc/self/fd/3")
	cmd.Dir = workspace
	cmd.ExtraFiles = []*os.File{script}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	starting.Lock()
	err = cmd.Start()
	if err == nil {
		group.Store(int64(cmd.Process.Pid))
	}
	starting.Unlock()
	_ = script.Close()
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
