# Quorum-CLI Makefile
# Usage:
#   make          → same as make help
#   make test     → run full test suite (inline + BATS)
#   make check    → ShellCheck all scripts
#   make demo     → run the end-to-end demo
#   make metrics  → print Prometheus metrics for any existing cluster
#   make clean    → wipe generated data (clusters, volumes, logs, snapshots)
#   make lint     → alias for check
#   make fast     → run tests without ShellCheck (for quick iteration)

.PHONY: all help test check lint demo metrics clean fast install-bats

SHELL  := /usr/bin/env bash
BATS   := ./tests/bats-vendor/bin/bats

# Colour helpers (only when writing to a terminal)
ifeq ($(shell tty -s && echo yes),yes)
  BOLD  := \033[1m
  GREEN := \033[0;32m
  RESET := \033[0m
else
  BOLD  :=
  GREEN :=
  RESET :=
endif

all: help

help:
	@printf "$(BOLD)Quorum-CLI — available targets$(RESET)\n\n"
	@printf "  $(GREEN)make test$(RESET)          Run inline unit/integration tests + BATS suite\n"
	@printf "  $(GREEN)make fast$(RESET)          Run tests without ShellCheck (faster iteration)\n"
	@printf "  $(GREEN)make check$(RESET)         ShellCheck all shell scripts\n"
	@printf "  $(GREEN)make demo$(RESET)          Run the end-to-end interactive demo\n"
	@printf "  $(GREEN)make metrics$(RESET)       Print Prometheus-format metrics for all clusters\n"
	@printf "  $(GREEN)make clean$(RESET)         Remove generated data, logs, and temp files\n"
	@printf "  $(GREEN)make install-bats$(RESET)  Download BATS into tests/bats-vendor (requires git)\n"
	@echo ""

# ── Tests ─────────────────────────────────────────────────────────────────────

test:
	@chmod +x tests/run_tests.sh bin/*.sh scripts/*.sh lib/*.sh 2>/dev/null || true
	@bash tests/run_tests.sh

fast:
	@chmod +x tests/run_tests.sh bin/*.sh scripts/*.sh lib/*.sh 2>/dev/null || true
	@bash tests/run_tests.sh --fast

bats: install-check-bats
	@$(BATS) tests/*.bats

install-check-bats:
	@if [[ ! -x "$(BATS)" ]]; then \
	  printf "BATS not found at $(BATS). Run: make install-bats\n" >&2; \
	  exit 1; \
	fi

# ── ShellCheck ────────────────────────────────────────────────────────────────

SCRIPTS := bin/cluster-manager.sh bin/storage-ops.sh bin/perf-monitor.sh \
           lib/logger.sh lib/cluster-lib.sh lib/network_checks.sh \
           scripts/chaos-engineering.sh scripts/demo.sh

check lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
	  printf "shellcheck not installed. Install with: apt-get install shellcheck\n" >&2; \
	  exit 1; }
	@printf "$(BOLD)Running ShellCheck…$(RESET)\n"
	@PASS=0; FAIL=0; \
	for s in $(SCRIPTS); do \
	  if [[ -f "$$s" ]]; then \
	    if shellcheck "$$s" 2>/dev/null; then \
	      printf "  \033[0;32m✓\033[0m $$s\n"; PASS=$$((PASS+1)); \
	    else \
	      printf "  \033[0;31m✗\033[0m $$s\n"; FAIL=$$((FAIL+1)); \
	    fi; \
	  fi; \
	done; \
	echo ""; \
	if [[ $$FAIL -eq 0 ]]; then \
	  printf "\033[0;32m✓ All scripts passed ShellCheck\033[0m\n"; \
	else \
	  printf "\033[0;31m✗ $$FAIL script(s) failed ShellCheck\033[0m\n"; exit 1; \
	fi

# ── Demo ──────────────────────────────────────────────────────────────────────

demo:
	@chmod +x scripts/demo.sh bin/*.sh 2>/dev/null || true
	@bash scripts/demo.sh

# ── Prometheus metrics ────────────────────────────────────────────────────────

metrics:
	@chmod +x bin/perf-monitor.sh 2>/dev/null || true
	@bash bin/perf-monitor.sh metrics

# ── Cleanup ───────────────────────────────────────────────────────────────────

clean:
	@printf "$(BOLD)Cleaning generated files…$(RESET)\n"
	@rm -rf data/clusters/* data/volumes/* data/snapshots/*
	@find logs/ -name "*.log" -delete 2>/dev/null || true
	@find logs/ -name "*.json.log" -delete 2>/dev/null || true
	@printf "\033[0;32m✓ Clean complete\033[0m\n"

# ── Install BATS ──────────────────────────────────────────────────────────────

install-bats:
	@printf "$(BOLD)Installing BATS into tests/bats-vendor…$(RESET)\n"
	@rm -rf tests/bats-vendor
	@git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-src 2>/dev/null
	@mkdir -p tests/bats-vendor/bin
	@cp /tmp/bats-src/bin/bats tests/bats-vendor/bin/bats
	@cp -r /tmp/bats-src/lib tests/bats-vendor/lib
	@rm -rf /tmp/bats-src
	@chmod +x tests/bats-vendor/bin/bats
	@printf "\033[0;32m✓ BATS installed at tests/bats-vendor/bin/bats\033[0m\n"
