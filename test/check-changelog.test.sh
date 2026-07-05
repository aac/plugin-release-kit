#!/usr/bin/env bash
# check-changelog — release changelog guard + draft generator (act-d2027d).
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

CC="$BIN/check-changelog"

# repo with a CHANGELOG of the given content ($2), no CHANGELOG if $2 unset.
mkcl() {
  local r; r=$(mkrepo "$1")
  printf '# t\n' > "$r/README.md"
  git -C "$r" add -A && git -C "$r" commit -qm init >/dev/null
  [ -n "${2:-}" ] && printf '%b' "$2" > "$r/CHANGELOG.md"
  printf '%s' "$r"
}

# --- guard: no CHANGELOG.md -> skip (exit 0) ---
r=$(mkcl no-cl)
run "$CC" --repo "$r"
assert_rc 0 "no CHANGELOG.md skips the guard"
assert_out_has "no CHANGELOG.md" "reports the skip reason"

# --- guard: empty [Unreleased], no matching version section -> FAIL ---
r=$(mkcl empty-unrel '# Changelog\n\n## [Unreleased]\n\n## [0.1.0]\n- initial\n')
run "$CC" --repo "$r" --version 0.2.0
assert_rc 1 "empty [Unreleased] with no [0.2.0] fails the guard"
assert_out_has "[Unreleased] is empty" "differentiates the empty-Unreleased cause"

# --- guard: non-empty [Unreleased] -> ok ---
r=$(mkcl full-unrel '# Changelog\n\n## [Unreleased]\n### Added\n- a feature\n')
run "$CC" --repo "$r" --version 0.2.0
assert_rc 0 "non-empty [Unreleased] passes"

# --- guard: matching non-empty [<version>] section (empty Unreleased) -> ok ---
r=$(mkcl ver-section '# Changelog\n\n## [Unreleased]\n\n## [0.2.0]\n### Fixed\n- a bug\n')
run "$CC" --repo "$r" --version 0.2.0
assert_rc 0 "non-empty [0.2.0] passes even with empty [Unreleased]"
assert_out_has "[0.2.0] section has content" "credits the version section"

# --- guard: Unreleased with only an HTML comment counts as empty -> FAIL ---
r=$(mkcl comment-only '# Changelog\n\n## [Unreleased]\n<!-- nothing yet -->\n')
run "$CC" --repo "$r" --version 0.2.0
assert_rc 1 "an Unreleased body of only an HTML comment is treated as empty"

# --- draft: groups conventional commits, drops non-user-facing, since last release ---
r=$(mkrepo draft-repo)
printf 'x\n' > "$r/a"; git -C "$r" add -A && git -C "$r" commit -qm "release t v0.1.0" >/dev/null
printf 'x\n' > "$r/b"; git -C "$r" add -A && git -C "$r" commit -qm "feat: add widget" >/dev/null
printf 'x\n' > "$r/c"; git -C "$r" add -A && git -C "$r" commit -qm "fix(ui): stop flicker" >/dev/null
printf 'x\n' > "$r/d"; git -C "$r" add -A && git -C "$r" commit -qm "docs: tweak readme" >/dev/null
printf 'x\n' > "$r/e"; git -C "$r" add -A && git -C "$r" commit -qm "feat!: remove legacy path" >/dev/null
run "$CC" --repo "$r" --draft
assert_rc 0 "draft exits 0"
assert_out_has "## [Unreleased]" "draft emits an Unreleased heading"
assert_out_has "- add widget" "draft lists the feat under Added"
assert_out_has "ui: stop flicker" "draft carries the fix scope"
assert_out_has "BREAKING" "draft marks the breaking change"
assert_out_lacks "tweak readme" "draft drops non-user-facing docs commits"
# The release commit itself is before the range, so it must not appear.
assert_out_lacks "release t v0.1.0" "draft excludes the prior release commit"
