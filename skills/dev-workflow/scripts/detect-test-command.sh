#!/usr/bin/env bash
# detect-test-command.sh — best-effort detection of a project's test command.
#
# Sourced by host.sh (runtime: dw_run_tests) and adopt.sh (one-shot: write the
# suggested "Test command" into AGENTS.md). The list lives in ONE place on
# purpose — adding a language or runner edits this file, not two copies.
#
# ── THIS IS A FALLBACK, NOT THE SOURCE OF TRUTH ──────────────────────────────
#
# A skill script cannot keep up with every project's real test invocation
# (build dirs, presets, containers, monorepo selectors, custom harnesses,
# version pins). So the project OWNS its command. Precedence, highest first:
#
#   1. CI_TEST_COMMAND env var          explicit session override
#   2. a committed runner in the repo   project-owned, language-agnostic
#        - scripts/test   (executable)        preferred — works for ANY stack
#        - scripts/test.sh
#        - bin/test
#        - a Makefile with a `test:` target  →  make test
#   3. language heuristics (below)      zero-config convenience for common stacks
#
# For anything (3) can't nail — C/CMake variants, C++ without CMake, monorepos,
# containerised suites, bespoke harnesses — the project COMMITS a runner (2) or
# sets CI_TEST_COMMAND (1). No skill edit is required for a new language; that
# is the whole point of the precedence above. The heuristics below cover only
# the common zero-config stacks and are extended sparingly.

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
