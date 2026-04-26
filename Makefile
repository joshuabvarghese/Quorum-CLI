SHELL := /bin/bash

SCRIPTS := bin/cluster-manager.sh \
           bin/storage-ops.sh \
           bin/perf-monitor.sh \
           lib/logger.sh \
           lib/cluster-lib.sh \
           lib/network_checks.sh \
           scripts/chaos-engineering.sh \
           scripts/demo.sh

.PHONY: check test clean help

## check: Run ShellCheck on all shell scripts (zero-warning policy)
check:
	@echo "Running ShellCheck on all scripts..."
	@shellcheck --severity=warning $(SCRIPTS)
	@echo "✓ ShellCheck passed — no warnings or errors"

## test: Run the full inline test suite
test:
	@bash tests/run_tests.sh --fast

## test-bats: Run all BATS tests (requires bats-vendor to be set up)
test-bats:
	@./tests/bats-vendor/bin/bats tests/quorum_math.bats
	@./tests/bats-vendor/bin/bats tests/cluster_manager.bats
	@./tests/bats-vendor/bin/bats tests/chaos_engineering.bats
	@./tests/bats-vendor/bin/bats tests/network_checks.bats
	@./tests/bats-vendor/bin/bats tests/logging.bats

## demo: Run the interactive demo
demo:
	@bash scripts/demo.sh

## clean: Remove generated log and data files
clean:
	@rm -rf logs/cluster/* logs/storage/* logs/monitoring/* data/metrics/*
	@echo "✓ Cleaned generated files"

## help: Show this help message
help:
	@grep -E '^## ' Makefile | sed 's/## /  /'
