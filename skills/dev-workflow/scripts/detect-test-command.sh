#!/usr/bin/env bash
# fast-tier-detect.sh (installed as detect-test-command.sh)
#
# Best-effort detection of a project's FAST-TIER commands — the checks that
# run on every push and are all runnable on a dev machine: test, build, lint.
# `dw_preflight` runs the three as the local CI mirror before every push.
#
# Sourced by host.sh (runtime: dw_preflight / dw_run_tests) and adopt.sh
# (one-shot: write the suggested commands into AGENTS.md). Each list lives
# in ONE place on purpose — adding a language or runner edits this file, not
# two copies.
#
# ── precedence (applies to all three detectors) ──────────────────────────────
#
# A skill script cannot keep up with every project's real invocation (build
# dirs, presets, containers, monorepo selectors, custom harnesses, version
# pins). So the project OWNS its commands. Precedence, highest first:
#
#   1. CI_TEST_COMMAND / CI_BUILD_COMMAND / CI_LINT_COMMAND env vars
#                                     explicit session overrides
#   2. a committed runner in the repo   project-owned, language-agnostic
#        - scripts/test|lint|build (executable)  preferred — any stack
#        - a Makefile with a matching target   →  make test|lint|build
#   3. language heuristics (below)      zero-config convenience, extended
#                                      sparingly; lint/build heuristics are
#                                      deliberately CONSERVATIVE — a missed
#                                      command is reported as skipped by
#                                      dw_preflight; a wrong one fails green
#                                      code. When in doubt: return "".
#
# For anything (3) can't nail — C/CMake variants, C++ without CMake, monorepos,
# containerised suites, bespoke harnesses — the project COMMITS a runner (2) or
# sets the env var (1). No skill edit is required for a new language; that
# is the whole point of the precedence above.

# dw_detect_test_command  → echoes the test command, or "" if nothing detected.
# Run from the project root (it checks the current directory).
dw_detect_test_command() {
  local t

  # 1) explicit override
  [ -n "${CI_TEST_COMMAND:-}" ] && { echo "$CI_TEST_COMMAND"; return; }

  # 2) committed, project-owned runner (language-agnostic — preferred over guesses)
  local r
  for r in scripts/test scripts/test.sh bin/test; do
    [ -f "$r" ] && { echo "./$r"; return; }
  done
  if [ -f Makefile ] && grep -qE '^test:' Makefile 2>/dev/null; then
    echo 'make test'; return
  fi

  # 3) zero-config heuristics for common stacks (extend sparingly — prefer (2))
  if [ -f package.json ]; then
    t=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
    # `npm init` leaves a placeholder script — don't suggest it
    case "$t" in
      ''|'echo "Error: no test specified"'*|'exit 1') ;;
      *) echo 'npm test'; return ;;
    esac
  fi
  [ -f go.mod ]     && { echo 'go test ./...';  return; }
  [ -f build.zig ]  && { echo 'zig build test'; return; }   # Zig — build.zig is its build system
  [ -f Cargo.toml ] && { echo 'cargo test';     return; }
  { [ -f pyproject.toml ] || [ -f setup.py ]; } && { echo 'pytest'; return; }
  [ -f meson.build ] && { echo 'meson test';    return; }
  # C / C++ via CMake. Test invocation is build-config dependent — this configures
  # + builds + runs ctest in one go. Non-trivial C projects should commit
  # scripts/test (path 2) so the real flags/presets/build-dir are authoritative.
  [ -f CMakeLists.txt ] && {
    echo 'cmake -B build -S . && cmake --build build && ctest --test-dir build --output-on-failure'
    return
  }

  echo ""
}

# dw_detect_build_command → echoes the build command, or "" if nothing
#   detected (compilation is already covered when the test command builds
#   too — cargo test, go test, the CMake line above — so "" is a fine answer).
#   Same precedence as dw_detect_test_command. Run from the project root.
dw_detect_build_command() {
  # 1) explicit override
  [ -n "${CI_BUILD_COMMAND:-}" ] && { echo "$CI_BUILD_COMMAND"; return; }

  # 2) committed, project-owned runner
  local r
  for r in scripts/build scripts/build.sh bin/build; do
    [ -f "$r" ] && { echo "./$r"; return; }
  done
  if [ -f Makefile ] && grep -qE '^build:' Makefile 2>/dev/null; then
    echo 'make build'; return
  fi

  # 3) zero-config heuristics — only where build ≠ what `test` already does
  if [ -f package.json ]; then
    local b; b=$(jq -r '.scripts.build // empty' package.json 2>/dev/null)
    case "$b" in ''|'echo "Error:'*) ;; *) echo 'npm run build'; return ;; esac
  fi
  [ -f go.mod ]     && { echo 'go build ./...'; return; }  # go test skips main-link errors
  [ -f build.zig ]  && { echo 'zig build';       return; }

  echo ""
}

# dw_detect_lint_command → echoes the lint command, or "" if nothing
#   detected. Same precedence as dw_detect_test_command. Deliberately
#   conservative (config-gated): a false "green" lint is worse than no lint —
#   undetected is reported as skipped by dw_preflight, which prompts a
#   by-hand run. Run from the project root.
dw_detect_lint_command() {
  # 1) explicit override
  [ -n "${CI_LINT_COMMAND:-}" ] && { echo "$CI_LINT_COMMAND"; return; }

  # 2) committed, project-owned runner
  local r
  for r in scripts/lint scripts/lint.sh; do
    [ -f "$r" ] && { echo "./$r"; return; }
  done
  if [ -f Makefile ] && grep -qE '^lint:' Makefile 2>/dev/null; then
    echo 'make lint'; return
  fi

  # 3) zero-config heuristics — gated on config files / installed tooling so
  #    we never invent a lint that isn't the project's own
  if [ -f package.json ]; then
    local l; l=$(jq -r '.scripts.lint // empty' package.json 2>/dev/null)
    case "$l" in ''|'echo "Error:'*) ;; *) echo 'npm run lint'; return ;; esac
  fi
  if [ -f go.mod ]; then
    if { [ -f .golangci.yml ] || [ -f .golangci.yaml ] || [ -f .golangci.toml ]; } \
      && command -v golangci-lint >/dev/null 2>&1; then
      echo 'golangci-lint run'; return
    fi
    echo 'go vet ./...'; return   # stdlib, always available with Go
  fi
  [ -f build.zig ] && { echo 'zig fmt --check .'; return; }
  if { [ -f ruff.toml ] || [ -f .ruff.toml ] || grep -q '^\[tool\.ruff' pyproject.toml 2>/dev/null; } \
    && command -v ruff >/dev/null 2>&1; then
    echo 'ruff check .'; return
  fi

  echo ""
}
