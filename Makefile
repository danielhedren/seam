.PHONY: setup check format lint build test test-all bench

setup:
	git config core.hooksPath .githooks

check: lint build test

lint:
	swift format lint --strict --recursive Package.swift Sources Tests

format:
	swift format --in-place --recursive Package.swift Sources Tests

build:
	swift build

test:
	swift test

# Opt-in suites (SPEC §10): the real-repo acceptance check and performance budgets.
test-all: check
	SEAM_REAL_REPO=$${SEAM_REAL_REPO:-$$HOME/Code/work-repo/.worktrees/feat-b} \
	SEAM_BENCH=1 swift test
