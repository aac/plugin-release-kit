#!/usr/bin/env bash
# Shared helpers for the kit's bash tests. Each *.test.sh sources this, calls
# ok/bad on assertions, and relies on the EXIT trap to print a summary and exit
# non-zero if any assertion failed. No dependencies beyond git + coreutils
# (same baseline the kit scripts already require).
set -uo pipefail

KIT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$KIT_ROOT/bin"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kit-test.XXXXXX")

PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /'; }

# run <command...> — capture combined output in $OUT and exit code in $RC.
run() { OUT=$("$@" 2>&1); RC=$?; return 0; }

# Assertions operate on the last run's $OUT/$RC.
assert_rc()          { [ "$RC" = "$1" ] && ok "$2" || bad "$2" "expected exit $1, got $RC. output:\n$OUT"; }
assert_out_has()     { printf '%s' "$OUT" | grep -qF -- "$1" && ok "$2" || bad "$2" "output missing '$1':\n$OUT"; }
assert_out_lacks()   { printf '%s' "$OUT" | grep -qF -- "$1" && bad "$2" "output unexpectedly contains '$1':\n$OUT" || ok "$2"; }

mkrepo() {
  local d="$WORK/$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name  test
  git -C "$d" config commit.gpgsign false
  printf '%s' "$d"
}

_summary() {
  printf '  -> %d passed, %d failed\n' "$PASS" "$FAIL"
  rm -rf "$WORK"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}
trap _summary EXIT
