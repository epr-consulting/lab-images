//go:build mlstest

package main

import "os"

// A build with `-tags mlstest` lets a test of the platform run the program on a
// machine that is not a control pod: where the execute-only bash is, and which
// file says what kernel.yama.ptrace_scope is. The shipped image is built
// without the tag, and then nothing the program reads can set either.
func init() {
	if path := os.Getenv("MLS_HIDDEN_TEST_BASH"); path != "" {
		bashPath = path
	}
	if path := os.Getenv("MLS_HIDDEN_TEST_PTRACE_SCOPE"); path != "" {
		ptraceScopePath = path
	}
}
