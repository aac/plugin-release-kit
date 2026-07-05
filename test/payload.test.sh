#!/usr/bin/env bash
# payload allowlist (act-c3a9bb) — the curated-payload mechanism:
#   * lib-payload.sh  — fail-closed allowlist matcher / partition
#   * stage-payload   — the curation producer (copies only allowlisted files)
#   * verify-release  — [16] completeness + adopted-dist subset teeth; [1] source shape
#
# Every FAIL-path assertion below is a red control: the check is proven to bite the
# exact defect (a load-bearing file outside the allowlist, a stray file in dist/),
# not just to stay green. Fixtures are synthetic — no real tool repo — so the suite
# runs in CI without the sibling checkouts.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

VR="$BIN/verify-release"
SP="$BIN/stage-payload"
EMPTY_DL="$WORK/empty-denylist"; : > "$EMPTY_DL"

# ---------------------------------------------------------------------------
# lib-payload.sh — the partition matcher, sourced directly.
# ---------------------------------------------------------------------------
part() { printf '%s\n' "$1" | ( . "$BIN/lib-payload.sh"; payload_partition "${2:-}" ); }

# Fail-closed: an unlisted path is DROP.
run bash -c "printf 'internal/foo.go\n' | ( . '$BIN/lib-payload.sh'; payload_partition '' )"
assert_out_has "DROP	internal/foo.go" "fail-closed: unlisted path is DROP"

# Allowlisted product files SHIP.
OUT=$(part $'bin/act\nskills/act/SKILL.md\n.mcp.json\n.claude-plugin/plugin.json\n.codex-plugin/mcp.json\n.agents/plugins/marketplace.json\nREADME.md\nLICENSE\nSECURITY.md\nCHANGELOG.md'); RC=0
for f in "bin/act" "skills/act/SKILL.md" ".mcp.json" ".claude-plugin/plugin.json" \
         ".codex-plugin/mcp.json" ".agents/plugins/marketplace.json" "README.md" \
         "LICENSE" "SECURITY.md" "CHANGELOG.md"; do
  assert_out_has "SHIP	$f" "allowlisted: $f ships"
done

# Prefix globs span '/': nested files under bin/ and skills/ ship.
OUT=$(part $'skills/x/references/a.md\nbin/nested/thing\nskills/x/examples/rust/src/main.rs'); RC=0
assert_out_has "SHIP	skills/x/references/a.md" "skills/ prefix spans nested dirs"
assert_out_has "SHIP	bin/nested/thing" "bin/ prefix spans nested dirs"
assert_out_has "SHIP	skills/x/examples/rust/src/main.rs" "deep skill example ships"

# Dev/process files DROP.
OUT=$(part $'Makefile\ngo.mod\ngo.sum\nAGENTS.md\nCLAUDE.md\nCONTRIBUTING.md\ninstall.sh\ncmd/act/main.go\ndocs/spec.md\n.github/workflows/ci.yml\nscripts/x.sh\ntest/run\n_kit/x\nfoo.revised.md'); RC=0
for f in "Makefile" "go.mod" "AGENTS.md" "CLAUDE.md" "CONTRIBUTING.md" "install.sh" \
         "cmd/act/main.go" "docs/spec.md" ".github/workflows/ci.yml" "scripts/x.sh" \
         "_kit/x" "foo.revised.md"; do
  assert_out_has "DROP	$f" "excluded: $f drops"
done

# LICENSE variants covered (LICENSE-MIT, LICENSE.txt).
OUT=$(part $'LICENSE-MIT\nLICENSE.txt'); RC=0
assert_out_has "SHIP	LICENSE-MIT" "LICENSE-MIT ships"
assert_out_has "SHIP	LICENSE.txt" "LICENSE.txt ships"

# Extras add to the allowlist; a sibling not listed still drops.
OUT=$(part $'docs/spec.md\ndocs/other.md' "docs/spec.md"); RC=0
assert_out_has "SHIP	docs/spec.md" "--payload-allow adds docs/spec.md"
assert_out_has "DROP	docs/other.md" "unlisted sibling still drops (fail-closed holds under extras)"

# ---------------------------------------------------------------------------
# stage-payload — the producer.
# ---------------------------------------------------------------------------
# A repo with product files + operator artifacts + dev files.
mk_tool() {
  local r; r=$(mkrepo "$1")
  git -C "$r" remote add origin https://github.com/example/tool.git
  mkdir -p "$r/bin" "$r/skills/tool/references" "$r/.claude-plugin" "$r/cmd/tool" "$r/docs" "$r/_kit"
  printf '#!/bin/sh\necho tool\n' > "$r/bin/tool"; chmod +x "$r/bin/tool"
  printf 'skill\n' > "$r/skills/tool/SKILL.md"
  printf 'ref\n' > "$r/skills/tool/references/a.md"
  printf '{"plugins":[{"name":"tool","source":"./"}]}\n' > "$r/.claude-plugin/marketplace.json"
  printf '# tool\n' > "$r/README.md"
  printf 'Apache-2.0\n' > "$r/LICENSE"
  printf 'go\n' > "$r/cmd/tool/main.go"
  printf 'handoff\n' > "$r/docs/session-handoff.md"
  printf 'draft\n' > "$r/foo.revised.md"
  printf 'kit\n' > "$r/_kit/notes.md"
  git -C "$r" add -A && git -C "$r" commit -qm init >/dev/null
  printf '%s' "$r"
}
r=$(mk_tool stage-tool)

# --list: ships product, excludes work tree + operator artifacts.
run "$SP" --repo "$r" --list
assert_out_has "bin/tool" "list: bin launcher ships"
assert_out_has "skills/tool/references/a.md" "list: nested skill ref ships"
assert_out_has ".claude-plugin/marketplace.json" "list: manifest ships"
assert_out_has "cmd/tool/main.go" "list: work-tree file surfaced as excluded"
assert_out_has "docs/session-handoff.md" "list: operator handoff surfaced as excluded"
assert_out_has "foo.revised.md" "list: draft surfaced as excluded"
assert_out_has "_kit/notes.md" "list: _kit surfaced as excluded"

# --out: copies ONLY allowlisted files, preserving structure; drops stay out.
run "$SP" --repo "$r" --out "$WORK/dist-tool"
[ -f "$WORK/dist-tool/bin/tool" ] && ok "out: bin/tool copied" || bad "out: bin/tool copied"
[ -x "$WORK/dist-tool/bin/tool" ] && ok "out: launcher exec bit preserved" || bad "out: launcher exec bit preserved"
[ -f "$WORK/dist-tool/skills/tool/references/a.md" ] && ok "out: nested skill ref copied" || bad "out: nested skill ref copied"
[ -f "$WORK/dist-tool/.claude-plugin/marketplace.json" ] && ok "out: manifest copied" || bad "out: manifest copied"
[ ! -e "$WORK/dist-tool/cmd" ] && ok "out: cmd/ NOT copied (fail-closed)" || bad "out: cmd/ NOT copied (fail-closed)"
[ ! -e "$WORK/dist-tool/docs" ] && ok "out: docs/ (operator handoff) NOT copied" || bad "out: docs/ NOT copied"
[ ! -e "$WORK/dist-tool/foo.revised.md" ] && ok "out: draft NOT copied" || bad "out: draft NOT copied"
[ ! -e "$WORK/dist-tool/_kit" ] && ok "out: _kit NOT copied" || bad "out: _kit NOT copied"

# refuses to write payload to the repo root.
run "$SP" --repo "$r" --out "$r"
assert_rc 1 "refuses --out = repo root"

# ---------------------------------------------------------------------------
# verify-release [16] — completeness teeth (a load-bearing file outside allowlist).
# ---------------------------------------------------------------------------
# RED control: Codex manifest points mcpServers at a NON-allowlisted path.
mk_ptr_tool() {
  local r ptr=$2; r=$(mkrepo "$1")
  git -C "$r" remote add origin https://github.com/example/tool.git
  mkdir -p "$r/.claude-plugin" "$r/.codex-plugin" "$r/skills/tool" "$(dirname "$r/$ptr")"
  printf '{"plugins":[{"name":"tool","source":"./"}]}\n' > "$r/.claude-plugin/marketplace.json"
  printf '{"name":"tool","skills":"./skills/","mcpServers":"./%s"}\n' "$ptr" > "$r/.codex-plugin/plugin.json"
  printf '{}\n' > "$r/$ptr"
  printf 'skill\n' > "$r/skills/tool/SKILL.md"
  printf '# tool\n' > "$r/README.md"; printf 'Apache-2.0\n' > "$r/LICENSE"
  git -C "$r" add -A && git -C "$r" commit -qm init >/dev/null
  printf '%s' "$r"
}
r=$(mk_ptr_tool ptr-bad "config/mcp.json")   # pointer target outside the allowlist
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "load-bearing files fall OUTSIDE the payload allowlist" "[16] FAILs a load-bearing file outside the allowlist"
assert_out_has "config/mcp.json" "[16] names the dropped load-bearing file"
assert_rc 1 "repo whose Codex pointer target can't ship fails verify-release"

# GREEN control: same tool with the pointer target under .codex-plugin/ (allowlisted).
r=$(mk_ptr_tool ptr-ok ".codex-plugin/mcp.json")
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "payload allowlist covers all load-bearing files" "[16] PASSes when all load-bearing files are allowlisted"
assert_out_lacks "load-bearing files fall OUTSIDE" "[16] raises no completeness FAIL for a well-formed tool"

# ---------------------------------------------------------------------------
# verify-release [1] + [16] — curated-dist adoption (source shape + subset teeth).
# ---------------------------------------------------------------------------
mk_dist_tool() {
  local r stray=$2; r=$(mkrepo "$1")
  git -C "$r" remote add origin https://github.com/example/tool.git
  mkdir -p "$r/.claude-plugin" "$r/dist/skills/tool" "$r/dist/.claude-plugin"
  printf '{"plugins":[{"name":"tool","source":{"source":"local","path":"./dist"},"version":"0.1.0"}]}\n' \
    > "$r/.claude-plugin/marketplace.json"
  printf '# tool\n' > "$r/README.md"; printf 'Apache-2.0\n' > "$r/LICENSE"
  # curated payload inside dist/
  printf 'skill\n' > "$r/dist/skills/tool/SKILL.md"
  printf '{"plugins":[{"name":"tool"}]}\n' > "$r/dist/.claude-plugin/marketplace.json"
  printf '# tool\n' > "$r/dist/README.md"
  [ -n "$stray" ] && { mkdir -p "$r/dist/$(dirname "$stray")"; printf 'x\n' > "$r/dist/$stray"; }
  git -C "$r" add -A && git -C "$r" commit -qm init >/dev/null
  printf '%s' "$r"
}
# [1] accepts a curated-dist object source.
r=$(mk_dist_tool dist-clean "")
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "curated-dist source" "[1] accepts an object source under ./dist"
assert_out_has "curated dist (dist/) payload is a subset of the allowlist" "[16] PASSes a clean curated dist"

# RED control: a stray non-allowlisted file inside dist/ would ship.
r=$(mk_dist_tool dist-stray "internal/secret.txt")
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "carries files OUTSIDE the payload allowlist" "[16] FAILs a stray file in the curated dist"
assert_out_has "internal/secret.txt" "[16] names the stray dist file"
assert_rc 1 "curated dist with a stray file fails verify-release"

# [1] rejects an object source NOT under ./dist.
mk_badsrc_tool() {
  local r; r=$(mkrepo "$1")
  git -C "$r" remote add origin https://github.com/example/tool.git
  mkdir -p "$r/.claude-plugin"
  printf '{"plugins":[{"name":"tool","source":{"source":"local","path":"./build"}}]}\n' \
    > "$r/.claude-plugin/marketplace.json"
  printf '# tool\n' > "$r/README.md"
  git -C "$r" add -A && git -C "$r" commit -qm init >/dev/null
  printf '%s' "$r"
}
r=$(mk_badsrc_tool badsrc)
run "$VR" --repo "$r" --denylist "$EMPTY_DL"
assert_out_has "is not under ./dist" "[1] FAILs an object source outside ./dist"
