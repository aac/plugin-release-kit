#!/usr/bin/env bash
# verify-release — release-readiness checks.
# Regression guard for act-aa46c3: tracked docs/*.md files outside a small
# allowlist must be surfaced (WARN) as candidate internal artifacts before a
# public flip. Tests run against a minimal non-plugin repo so only the
# hygiene/privacy checks fire, isolating check [14].
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

VR="$BIN/verify-release"
EMPTY_DL="$WORK/empty-denylist"   # so check [9] passes (not WARN) and doesn't
: > "$EMPTY_DL"                    # confound the strict-mode exit assertions.

# Build a clean, non-plugin repo (no .claude-plugin / cmd/) with an origin remote
# so OWNER derivation doesn't error, plus the given docs/ files.
mkrepo_docs() {
  local name=$1; shift
  local r; r=$(mkrepo "$name")
  git -C "$r" remote add origin https://github.com/example/thing.git
  printf '# thing\n' > "$r/README.md"
  local f
  for f in "$@"; do
    mkdir -p "$r/$(dirname "$f")"
    printf 'internal or public prose\n' > "$r/$f"
  done
  git -C "$r" add -A && git -C "$r" commit -qm init >/dev/null
  printf '%s' "$r"
}

# --- act-aa46c3: an un-allowlisted internal doc is surfaced ---
r=$(mkrepo_docs internal-doc docs/distribution-readiness.md)
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "[14] tracked docs/ reviewed" "check [14] runs"
assert_out_has "docs/distribution-readiness.md" "surfaces the internal doc by path"
assert_out_has "candidate internal artifacts" "labels it a candidate internal artifact"
assert_rc 0 "un-allowlisted doc is only a WARN (exit 0 without --strict)"
# In --strict the docs WARN is the only warn (empty denylist ⇒ [9] passes), so exit 1.
run "$VR" --repo "$r" --denylist "$EMPTY_DL" --strict
assert_rc 1 "--strict promotes the docs WARN to a failure"

# --- allowlisting the doc via --docs-allow clears it ---
run "$VR" --repo "$r" --denylist "$EMPTY_DL" --docs-allow "docs/distribution-readiness.md" --strict
assert_rc 0 "--docs-allow allowlists the doc (no WARN, strict passes)"
assert_out_has "no tracked docs/*.md outside the allowlist" "reports clean docs tree"
assert_out_lacks "distribution-readiness" "allowlisted doc not surfaced"

# --- default allowlist covers docs/spec.md without any flag ---
r=$(mkrepo_docs default-spec docs/spec.md)
run "$VR" --repo "$r" --denylist "$EMPTY_DL" --strict
assert_rc 0 "default allowlist (docs/spec.md) passes with no flag"
assert_out_has "no tracked docs/*.md outside the allowlist" "spec.md accepted by default"

# --- $PLUGIN_KIT_DOCS_ALLOW env override works ---
r=$(mkrepo_docs env-allow docs/design.md)
run env PLUGIN_KIT_DOCS_ALLOW="docs/design.md" "$VR" --repo "$r" --denylist "$EMPTY_DL" --strict
assert_rc 0 "\$PLUGIN_KIT_DOCS_ALLOW allowlists docs/design.md"

# --- nested docs/ path is scanned too ---
r=$(mkrepo_docs nested docs/reviews/round1.md)
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "docs/reviews/round1.md" "nested docs/ file is surfaced"

# --- repo with no docs/ tree passes the check cleanly ---
r=$(mkrepo_docs no-docs)
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "no tracked docs/*.md outside the allowlist" "no-docs repo passes [14]"

# --- check [15] changelog guard (only fires for plugin repos) ---
# A .claude-plugin/ dir makes IS_PLUGIN_REPO=1. Other plugin checks FAIL on this
# skeletal repo, so we assert on [15]'s OUTPUT, not the overall exit code.
mkrepo_plugin_cl() {
  local name=$1 cl=$2
  local r; r=$(mkrepo "$name")
  git -C "$r" remote add origin https://github.com/example/thing.git
  mkdir -p "$r/.claude-plugin"
  printf '{"plugins":[{"name":"thing","source":"./"}]}\n' > "$r/.claude-plugin/marketplace.json"
  printf '# thing\n' > "$r/README.md"
  [ -n "$cl" ] && printf '%b' "$cl" > "$r/CHANGELOG.md"
  git -C "$r" add -A && git -C "$r" commit -qm init >/dev/null
  printf '%s' "$r"
}
r=$(mkrepo_plugin_cl plugin-empty-cl '# Changelog\n\n## [Unreleased]\n')
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "[15] CHANGELOG carries release notes" "check [15] runs for plugin repos"
assert_out_has "CHANGELOG has no release notes" "[15] fails an empty changelog"

r=$(mkrepo_plugin_cl plugin-full-cl '# Changelog\n\n## [Unreleased]\n### Added\n- a thing\n')
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "[Unreleased] section has content" "[15] passes a filled changelog"

r=$(mkrepo_plugin_cl plugin-no-cl '')
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "no CHANGELOG.md — changelog guard skipped" "[15] skips when no CHANGELOG"
