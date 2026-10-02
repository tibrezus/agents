#!/usr/bin/env bash
# fast-tier-detect.sh (installed as detect-test-command.sh)
#
# Resolution of a project's FAST-TIER commands — the checks that run on every
# push and are runnable on a dev machine: test, build, lint. `dw_preflight`
# runs them as the local CI mirror before every push.
#
# Sourced by host.sh (runtime: dw_preflight / dw_run_tests) and adopt.sh
# (one-shot: seed the declarations into AGENTS.md).
#
# ── THE SKILL NEVER PRESCRIBES WHERE COMMANDS LIVE ──────────────────────────
#
# Projects own their conventions (`make test`, `just check`, `pnpm test`,
# a runner binary, nix flake checks — anything). The skill only READS:
#
#   1. CI_TEST_COMMAND / CI_BUILD_COMMAND / CI_LINT_COMMAND env vars
#                                     explicit session overrides
#   2. the project's DECLARATION in AGENTS.md   the project-owned channel
#        - **Test command:** `<command>`   (same for Lint/Build)
#      The declaration is data — edit it freely, it is never doctrine.
#      The `none` sentinel marks a deliberately absent command (sanctioned
#      skip; gaps surface on the issue, never invented).
#   3. language-standard observation    zero-config convenience ONLY: reads
#      what the project already declares in its own standard files
#      (package.json scripts, go.mod, build.zig, Cargo.toml…). Never a path
#      convention, never a guess beyond the standard.
#
# Anything (3) can't nail — custom runners, monorepo selectors, containerised
# suites, bespoke harnesses — the project DECLARES (2) or overrides (1).
# No skill edit is ever required for a new convention; that is the point.

# _dw_declared <Test|Lint|Build> → the value declared in AGENTS.md, or "".
#   Placeholder seeds from older adopts (values starting with "(") read as
#   undeclared — they were detection output, not a project decision.
_dw_declared() {
  [ -f AGENTS.md ] || return 0
  local v
  v=$(sed -n "s/^- \*\*${1} command:\*\* \`\([^\`]*\)\`.*/\1/p" AGENTS.md | head -1)
  case "$v" in ""|\(*) return 0 ;; esac
  printf '%s\n' "$v"
}

# dw_detect_test_command → command | "none" (declared absent) | "".
dw_detect_test_command() {
  # 1) explicit override
  [ -n "${CI_TEST_COMMAND:-}" ] && { echo "$CI_TEST_COMMAND"; return; }
  # 2) project declaration
  local d; d=$(_dw_declared Test); [ -n "$d" ] && { echo "$d"; return; }
  # 3) language-standard observation
  if [ -f package.json ]; then
    local t; t=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
    # `npm init` leaves a placeholder script — don't observe it
    case "$t" in
      ''|'echo "Error: no test specified"'*|'exit 1') ;;
      *) echo 'npm test'; return ;;
    esac
  fi
  [ -f go.mod ]     && { echo 'go test ./...';  return; }
  [ -f build.zig ]  && { echo 'zig build test'; return; }
  [ -f Cargo.toml ] && { echo 'cargo test';     return; }
  { [ -f pyproject.toml ] || [ -f setup.py ]; } && { echo 'pytest'; return; }
  [ -f meson.build ] && { echo 'meson test';    return; }
  # C/CMake — configure + build + ctest; non-trivial C projects should
  # declare their real invocation (flags/presets/build-dir) in AGENTS.md.
  [ -f CMakeLists.txt ] && {
    echo 'cmake -B build -S . && cmake --build build && ctest --test-dir build --output-on-failure'
    return
  }
  echo ""
}

# dw_detect_build_command → command | "none" | "".
#   "" is a fine answer when the test command already builds (cargo/go/zig/
#   the CMake line); "none" is the project saying so explicitly.
dw_detect_build_command() {
  [ -n "${CI_BUILD_COMMAND:-}" ] && { echo "$CI_BUILD_COMMAND"; return; }
  local d; d=$(_dw_declared Build); [ -n "$d" ] && { echo "$d"; return; }
  if [ -f package.json ]; then
    local b; b=$(jq -r '.scripts.build // empty' package.json 2>/dev/null)
    case "$b" in ''|'echo "Error:'*) ;; *) echo 'npm run build'; return ;; esac
  fi
  [ -f go.mod ]     && { echo 'go build ./...'; return; }  # go test skips main-link errors
  [ -f build.zig ]  && { echo 'zig build';       return; }
  echo ""
}

# dw_detect_lint_command → command | "none" | "".
#   Deliberately conservative (config-gated): a false "green" lint is worse
#   than no lint. Projects linting via a build chain or custom runner
#   declare `none` (with the chain noted) or their real command.
dw_detect_lint_command() {
  [ -n "${CI_LINT_COMMAND:-}" ] && { echo "$CI_LINT_COMMAND"; return; }
  local d; d=$(_dw_declared Lint); [ -n "$d" ] && { echo "$d"; return; }
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
  # NB: NO zig lint heuristic — fmt scope is project-specific (generated/
  # vendored files are often deliberately outside it) and usually part of the
  # build chain; zig projects declare their lint (or `none` + the chain).
  if { [ -f ruff.toml ] || [ -f .ruff.toml ] || grep -q '^\[tool\.ruff' pyproject.toml 2>/dev/null; } \
    && command -v ruff >/dev/null 2>&1; then
    echo 'ruff check .'; return
  fi
  echo ""
}
