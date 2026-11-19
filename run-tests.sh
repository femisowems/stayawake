#!/bin/bash
# Run StayAwake's logic tests (tests.swift). CI runs this before
# building the app; a failure here fails the whole run.
#
# The test runner is built from a copy of main.swift with the
# app entry stripped (everything from the "// MARK: - Main"
# line to the end of the file), so tests.swift's @main is the
# only entry point.
set -e
cd "$(dirname "$0")"

sed '/^\/\/ MARK: - Main/,$d' main.swift > .tests-main.swift
trap 'rm -f .tests-main.swift stayawake-tests' EXIT

swiftc -parse-as-library -O -o stayawake-tests .tests-main.swift tests.swift \
    -framework Cocoa -framework Carbon -framework IOKit -framework ServiceManagement

./stayawake-tests
