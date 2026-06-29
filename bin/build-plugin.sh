#!/usr/bin/env bash
# build-plugin.sh — assemble an installable plugin zip for an agent-tools
# primitive (act, ask, surface, reach).
#
# This is the exact step the tag-triggered release workflow runs. It is also
# runnable locally to produce a zip for upload/testing.
#
# Design notes:
#   * The whole payload — skill, manifests, AND (for binary tools) the committed
#     bin/ launcher + per-arch binaries — comes from `git archive` (TRACKED files
#     only). git archive preserves the executable bit and copies the committed
#     binaries byte-for-byte, so the launcher stays executable and the ad-hoc
#     darwin signatures survive into the zip. Gitignored scope-review drafts
#     (*.revised.md) and cruft (.DS_Store) are excluded by construction.
#   * Binaries are NOT cross-compiled here. They are produced ahead of the tag by
#     `stage-binaries` and committed under bin/ (lib-binaries.sh holds the one
#     definition of the arch list + launcher). Because the zip and `/plugin
#     install` both read the same committed tree at the tag, they stay in lockstep
#     automatically — no separate build that could drift from what was installed.
#   * Skill-only tools (surface, reach — no cmd/<tool>, no bin/) ship no binary.
#
# Usage:
#   build-plugin.sh --repo <path> [--tool <name>] [--ref <git-ref>] [--out <zip>]
#   (--repo defaults to cwd; --tool to the repo basename; --ref to HEAD;
#    --out to /tmp/<tool>-plugin.zip. CI passes --ref <tag> and --out <dist>.)
set -euo pipefail

REPO="" TOOL="" REF="HEAD" OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=$2; shift 2 ;;
    --tool) TOOL=$2; shift 2 ;;
    --ref)  REF=$2;  shift 2 ;;
    --out)  OUT=$2;  shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "build-plugin: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] || REPO=$(pwd)
REPO=$(CDPATH= cd -- "$REPO" && pwd)
[ -e "$REPO/.git" ] || { echo "build-plugin: not a git repo: $REPO" >&2; exit 1; }
[ -n "$TOOL" ] || TOOL=$(basename "$REPO")
[ -n "$OUT" ]  || OUT="/tmp/$TOOL-plugin.zip"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/$TOOL"
mkdir -p "$ROOT"

# 1. Payload — tracked files only at $REF.
# Archive skills/<tool> (not all of skills/) so the go:embed source at
# skills/skill.go and any other non-skill files stay out of the plugin.
# Include both host manifests (.claude-plugin, .codex-plugin) and the MCP
# config (.mcp.json) so the installed plugin actually delivers the MCP server on
# both Claude and Codex. For binary tools, `bin` carries the committed launcher +
# per-arch binaries (the same tree `/plugin install` checks out), so the zip is a
# faithful copy of the installed plugin rather than a separately-built artifact.
# The Codex marketplace (.agents/) is repo-level discovery, not plugin payload, so
# it stays out. Absent paths (skill-only tools have no bin/ or .mcp.json) are
# skipped.
paths=""
for p in .claude-plugin .codex-plugin .mcp.json bin "skills/$TOOL"; do
  if git -C "$REPO" ls-tree "$REF" -- "$p" | grep -q .; then paths="$paths $p"; fi
done
[ -n "$paths" ] || { echo "build-plugin: no .claude-plugin/ or skills/$TOOL tracked at $REF" >&2; exit 1; }
# shellcheck disable=SC2086
git -C "$REPO" archive --format=tar "$REF" $paths | tar -x -C "$ROOT"

# 2. License at the plugin root.
[ -f "$REPO/LICENSE" ] && cp "$REPO/LICENSE" "$ROOT/LICENSE.txt"

# 3. Payload summary. Binaries (if any) came from the committed bin/ above; a
# binary tool that reaches here with no bin/ in the archive was never staged
# (verify-release's check [7] is the gate that catches that before a tag).
if [ -d "$REPO/cmd/$TOOL" ]; then
  if [ -d "$ROOT/bin" ]; then
    payload="committed bin/ (launcher + per-arch binaries) from $REF"
  else
    payload="WARNING: binary tool but no committed bin/ at $REF — run stage-binaries"
  fi
else
  payload="skill-only (no cmd/$TOOL)"
fi

# 4. Zip with <tool>/ at the archive root.
rm -f "$OUT"
( cd "$STAGE" && zip -rqX "$OUT" "$TOOL" )

echo "build-plugin: wrote $OUT"
echo "  tool=$TOOL  ref=$REF  payload: $payload"
( cd "$STAGE" && find "$TOOL" -type f | sort | sed 's/^/  /' )
