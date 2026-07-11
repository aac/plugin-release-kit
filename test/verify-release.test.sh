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

# --- act-5972d5: [9] WORD-BOUNDARY denylist matching on tracked text files ---
# A short token must NOT substring-match a longer word (the token-as-substring-of-a-longer-word
# false-positive), but a genuine word-bounded occurrence is still flagged.
WB="/qcm"                              # synthetic token; a substring of "/qcmd"
DLWB="$WORK/dl-wb"; printf '%s\n' "$WB" > "$DLWB"
# collision-only: file contains "launcher/qcmd" (token as substring, not bounded)
r=$(mkrepo_docs wb-collision)
printf '# needs the same launcher%sd list and %sd paths\n' "$WB" "$WB" > "$r/lib.sh"
git -C "$r" add -A && git -C "$r" commit -qm collision >/dev/null
run "$VR" --repo "$r" --denylist "$DLWB"
assert_out_has "no denylisted proper nouns" "[9] passes: substring of a longer word not flagged"
assert_out_lacks "leak denylisted terms" "[9] reports no leak for the collision"
assert_rc 0 "collision-only repo passes verify-release"
# a genuine word-bounded occurrence of the same token IS flagged by [9]
r=$(mkrepo_docs wb-real)
printf 'run %s now\n' "$WB" > "$r/notes.md"
git -C "$r" add -A && git -C "$r" commit -qm real >/dev/null
run "$VR" --repo "$r" --denylist "$DLWB"
assert_out_has "leak denylisted terms" "[9] flags a genuine word-bounded token"
assert_rc 1 "repo with a real word-bounded leak fails verify-release"

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

# --- act-4428ca: [5]/[6] find scans must not descend into gitignored .claude/ ---
# A live agent-worktree drain leaves git worktrees under .claude/worktrees/<name>/, each
# a full tracked checkout including skills/*/SKILL.md and any *.revised.md drafts. [6]
# (single canonical skill tree) and [5] (pre-release drafts) must scope to the PARENT
# repo's tracked surface — else they count the worktree copies and false-FAIL exactly
# when a maintainer runs verify-release mid-drain. Regression guard: build a repo with
# one canonical SKILL.md + a gitignored worktree copy (plus a draft in the worktree)
# and assert [6] still sees exactly one tree and [5] finds no drafts.
r=$(mkrepo wt-scan)
git -C "$r" remote add origin https://github.com/example/thing.git
printf '# thing\n' > "$r/README.md"
mkdir -p "$r/skills/thing"
printf -- '---\nname: thing\n---\n' > "$r/skills/thing/SKILL.md"
printf '.claude/\n' > "$r/.gitignore"   # mirror real tool repos: .claude/ is gitignored
git -C "$r" add -A && git -C "$r" commit -qm init >/dev/null
# Simulate a live git worktree: an untracked full copy under .claude/worktrees/,
# carrying its own SKILL.md and a scope-review draft.
mkdir -p "$r/.claude/worktrees/act-demo/skills/thing"
printf -- '---\nname: thing\n---\n' > "$r/.claude/worktrees/act-demo/skills/thing/SKILL.md"
printf 'draft\n' > "$r/.claude/worktrees/act-demo/skills/thing/SKILL.revised.md"
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "one SKILL.md" "[6] counts only the canonical tracked SKILL.md, not worktree copies"
assert_out_lacks "multiple SKILL.md trees" "[6] does not false-FAIL on a live .claude/worktrees/"
assert_out_has "no .revised.md/.annotated.md drafts" "[5] ignores a draft inside a live worktree"
assert_rc 0 "verify-release is clean with live .claude/worktrees/ present"

# --- act-834d34: [17] opt-in doc-reconciliation ADVISORY ---
# These assert on the EXIT CODE (especially under --strict), so the fixture must be
# a FULLY GREEN skill-only plugin repo (0 FAIL) — else an unrelated FAIL would set
# exit 1 and mask what [17] does. A baseline 'release ...' commit fixes the delta
# origin (check-changelog --draft ranges since it), so each scenario controls its
# own delta with --allow-empty commits. The reconcile command is a canned STUB
# written into the test's temp fixture — NO real model call, fully hermetic.
mkrepo_green_plugin() {
  local name=$1 ver=${2:-0.1.0}
  local r; r=$(mkrepo "$name")
  git -C "$r" remote add origin https://github.com/example/thing.git
  mkdir -p "$r/.claude-plugin" "$r/.codex-plugin" "$r/.agents/plugins" "$r/skills/thing"
  printf -- '---\nname: thing\ndescription: A synthetic test skill for the kit fixture.\nmetadata:\n  version: %s\n---\n# thing\n' "$ver" > "$r/skills/thing/SKILL.md"
  printf '{"name":"thing","version":"%s"}\n' "$ver" > "$r/.claude-plugin/plugin.json"
  printf '{"name":"thing","version":"%s","skills":"./skills/"}\n' "$ver" > "$r/.codex-plugin/plugin.json"
  printf '{"plugins":[{"name":"thing","source":"./","version":"%s"}]}\n' "$ver" > "$r/.claude-plugin/marketplace.json"
  printf '{"plugins":[{"name":"thing","source":{"source":"url","url":"https://github.com/example/thing.git"},"policy":{"installation":"AVAILABLE","authentication":"ON_USE"},"category":"tools"}]}\n' > "$r/.agents/plugins/marketplace.json"
  printf '# thing\n\n    /plugin marketplace add example/thing\n    /plugin install thing@thing\n' > "$r/README.md"
  git -C "$r" add -A && git -C "$r" commit -qm "release thing v$ver" >/dev/null
  printf '%s' "$r"
}

# (1) reconcile cmd set + a feature delta + a stub that emits a contradiction =>
# the advisory surfaces the contradiction AND exit 0 EVEN UNDER --strict.
# STRICT-EXEMPTION REGRESSION GUARD: this must go RED if advise() in check [17]
# were swapped for warn() — the WARN would gate under --strict and flip this to
# exit 1. (Verified by hand during development by making exactly that swap:
# `warn` yields "1 WARN (strict) — not release-ready", exit 1.)
r=$(mkrepo_green_plugin r17-contra)
git -C "$r" commit -q --allow-empty -m "feat: add feature Q" >/dev/null
STUB="$WORK/reconcile-contra.sh"
printf '#!/bin/sh\ncat >/dev/null\necho "DOC-CONTRADICTION-TOKEN: README calls feature Q planned but the delta shows it shipped."\n' > "$STUB"
chmod +x "$STUB"
run env PLUGIN_KIT_RECONCILE_CMD="$STUB" "$VR" --repo "$r" --denylist "$EMPTY_DL" --strict
assert_out_has "[17] docs reconciled against the shipped delta" "[17] runs for a plugin repo with a reconcile cmd"
assert_out_has "DOC-CONTRADICTION-TOKEN" "[17] surfaces the model's contradiction verdict"
assert_out_has "ADVISORY" "[17] verdict is a prominent ADVISORY line"
assert_rc 0 "[17] advisory never gates — exit 0 even under --strict (strict-exemption guard)"

# (2) reconcile cmd UNSET => a skip notice appears and nothing gates (rc 0), even
# with a feature delta present.
r=$(mkrepo_green_plugin r17-unset)
git -C "$r" commit -q --allow-empty -m "feat: add feature Q" >/dev/null
run "$VR" --repo "$r" --denylist "$EMPTY_DL" --strict
assert_out_has "doc-reconciliation advisory skipped" "[17] skips when no reconcile command is configured"
assert_rc 0 "[17] unset reconcile command does not gate (exit 0 under --strict)"

# (3) reconcile cmd SET but the delta has NO feature-ish commits => the stub would
# write a sentinel file IFF invoked; its ABSENCE proves the deterministic trigger
# skipped the model call (bounded cost — a docs/chore release makes no model call).
r=$(mkrepo_green_plugin r17-nofeat)
git -C "$r" commit -q --allow-empty -m "chore: tidy build" >/dev/null
git -C "$r" commit -q --allow-empty -m "docs: reword readme" >/dev/null
SENT="$WORK/r17-model-was-called"
rm -f "$SENT"
STUB3="$WORK/reconcile-sentinel.sh"
printf '#!/bin/sh\ncat >/dev/null\necho called > "%s"\necho verdict\n' "$SENT" > "$STUB3"
chmod +x "$STUB3"
run env PLUGIN_KIT_RECONCILE_CMD="$STUB3" "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "no user-facing commits" "[17] recognizes a chore/docs-only delta as nothing-to-reconcile"
[ ! -f "$SENT" ] \
  && ok "[17] no model call on a non-feature delta (sentinel absent)" \
  || bad "[17] no model call on a non-feature delta (sentinel absent)" "sentinel exists — the trigger called the model on a non-feature delta"
assert_rc 0 "[17] non-feature-delta path exits 0"
