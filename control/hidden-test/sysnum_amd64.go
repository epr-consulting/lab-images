package main

// sysMemfdCreate is memfd_create(2) on linux/amd64, which the frozen syscall
// package does not name.
const sysMemfdCreate = 319
