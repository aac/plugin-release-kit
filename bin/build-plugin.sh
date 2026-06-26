#!/usr/bin/env bash
# build-plugin.sh — assemble an installable plugin zip for an agent-tools
# primitive (act, ask, surface, reach).
#
# This is the exact step the tag-triggered release workflow runs. It is also
# runnable locally to produce a zip for upload/testing.
#
# Design notes:
#   * Skill + manifest payload comes from `git archive` (TRACKED files only),
#     so gitignored scope-review drafts (*.revised.md, *.annotated.md) and
#     cruft (.DS_Store) are excluded by construction — no manual scrub, and
#     once revisions land over canonical the archive just picks them up.
#   * Binary tools (those with cmd/<tool>) get multi-arch binaries
#     cross-compiled into bin/, plus a bin/<tool> launcher that selects the
#     right one at runtime via uname. The launcher derives the tool name from
#     its own filename, so it is identical across tools.
#   * Skill-only tools (surface, reach — no cmd/<tool>) ship no binary.
#
# Usage:
#   build-plugin.sh --repo <path> [--tool <name>] [--ref <git-ref>] [--out <zip>]
#   (--repo defaults to cwd; --tool to the repo basename; --ref to HEAD;
#    --out to /tmp/<tool>-plugin.zip. CI passes --ref <tag> and --out <dist>.)
set -euo pipefail

REPO="" TOOL="" REF="HEAD" OUT=""
ARCHES="darwin/amd64 darwin/arm64 linux/amd64 linux/arm64"

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

# 1. Skill + manifest payload — tracked files only at $REF.
# Archive skills/<tool> (not all of skills/) so the go:embed source at
# skills/skill.go and any other non-skill files stay out of the plugin.
# Include both host manifests (.claude-plugin, .codex-plugin) and the MCP
# config (.mcp.json) so the installed plugin actually delivers the MCP server on
# both Claude and Codex. The Codex marketplace (.agents/) is repo-level discovery,
# not plugin payload, so it stays out. Absent paths (e.g. skill-only tools with
# no .mcp.json) are skipped.
paths=""
for p in .claude-plugin .codex-plugin .mcp.json "skills/$TOOL"; do
  if git -C "$REPO" ls-tree "$REF" -- "$p" | grep -q .; then paths="$paths $p"; fi
done
[ -n "$paths" ] || { echo "build-plugin: no .claude-plugin/ or skills/$TOOL tracked at $REF" >&2; exit 1; }
# shellcheck disable=SC2086
git -C "$REPO" archive --format=tar "$REF" $paths | tar -x -C "$ROOT"

# 2. License at the plugin root.
[ -f "$REPO/LICENSE" ] && cp "$REPO/LICENSE" "$ROOT/LICENSE.txt"

# 3. Binary tools: cross-compile every arch + the launcher. Skill-only tools skip.
if [ -d "$REPO/cmd/$TOOL" ]; then
  mkdir -p "$ROOT/bin"
  for a in $ARCHES; do
    os=${a%/*}; arch=${a#*/}
    ( cd "$REPO" && GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 \
        go build -trimpath -o "$ROOT/bin/$TOOL-$os-$arch" "./cmd/$TOOL" )
  done
  # Tool-agnostic launcher: name derived from its own filename.
  cat > "$ROOT/bin/$TOOL" <<'WRAP'
#!/bin/sh
# Selects the bundled platform binary (sibling <name>-<os>-<arch>).
name=$(basename "$0")
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
bin="$dir/$name-$os-$arch"
[ -x "$bin" ] || { echo "$name: no bundled binary for $os/$arch at $bin" >&2; exit 127; }
exec "$bin" "$@"
WRAP
  chmod +x "$ROOT/bin/$TOOL" "$ROOT/bin/$TOOL"-*
  payload="multi-arch binary + bin/$TOOL launcher ($ARCHES)"
else
  payload="skill-only (no cmd/$TOOL)"
fi

# 4. Zip with <tool>/ at the archive root.
rm -f "$OUT"
( cd "$STAGE" && zip -rqX "$OUT" "$TOOL" )

echo "build-plugin: wrote $OUT"
echo "  tool=$TOOL  ref=$REF  payload: $payload"
( cd "$STAGE" && find "$TOOL" -type f | sort | sed 's/^/  /' )
