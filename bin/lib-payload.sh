#!/usr/bin/env bash
# lib-payload.sh — the single definition of the minimum plugin PAYLOAD allowlist
# and its matcher. Sourced by both stage-payload (which COPIES the allowlisted
# tracked files into the curated dist/) and verify-release [16] (which ASSERTS
# the payload is a subset of this allowlist and surfaces what's excluded) — so
# the producer and the verifier read one list and cannot drift.
#
# Sourced, not executed: it defines PAYLOAD_DEFAULT_ALLOW + functions and does not
# touch the caller's shell options.
#
# WHY AN ALLOWLIST (not a denylist). `/plugin install` (Claude + Codex) ships every
# git-tracked file of a "source":"./" repo — the whole dev work tree, not a curated
# product. A denylist (verify-release [8]/[9]) blocks KNOWN-bad terms; an allowlisted
# payload structurally prevents shipping ANYTHING unlisted, including future internal
# artifacts the denylist has never heard of (the act-aa46c3 class: an internal
# docs/*.md that carries no denylisted token slips past [8]/[9] but can never enter an
# allowlisted payload). FAIL-CLOSED: the default verdict for any path is EXCLUDE; only
# an explicit allowlist match ships.
#
# The patterns are matched with bash `case` globs against a repo-relative path. A `*`
# in a case pattern spans '/', so "bin/*" matches bin/<tool> AND bin/nested/x — i.e.
# it behaves like a "bin/**" prefix. Keep the list MINIMAL; a tool's long tail is
# added per-repo via --payload-allow / $PLUGIN_KIT_PAYLOAD_ALLOW, not by widening this.

# The minimum product surface every plugin tool ships. Each entry is a case glob.
PAYLOAD_DEFAULT_ALLOW='bin/*
skills/*
.mcp.json
.claude-plugin/*
.codex-plugin/*
.agents/*
README.md
README
LICENSE*
SECURITY.md
CHANGELOG.md'

# payload_load_allow [extra_csv]
# Populate the PAYLOAD_ALLOW array from the default list plus any extra patterns
# (comma- or newline-separated) — e.g. a tool that genuinely ships a doc or asset
# in its install adds "docs/spec.md,assets/*". Extras are case globs too.
payload_load_allow() {
  local extra=${1:-} line
  PAYLOAD_ALLOW=()
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}   # ltrim
    line=${line%"${line##*[![:space:]]}"}    # rtrim
    [ -n "$line" ] && PAYLOAD_ALLOW+=("$line")
  done <<EOF
$PAYLOAD_DEFAULT_ALLOW
EOF
  if [ -n "$extra" ]; then
    # split on comma or newline
    local IFS=$',\n' tok
    for tok in $extra; do
      tok=${tok#"${tok%%[![:space:]]*}"}
      tok=${tok%"${tok##*[![:space:]]}"}
      [ -n "$tok" ] && PAYLOAD_ALLOW+=("$tok")
    done
  fi
}

# payload_is_allowed <repo-relative-path>
# 0 if the path matches any loaded allow pattern (ships), 1 otherwise (excluded).
# Requires payload_load_allow to have run first.
payload_is_allowed() {
  local p=$1 pat
  for pat in "${PAYLOAD_ALLOW[@]}"; do
    # shellcheck disable=SC2254  # $pat is an intentional glob, not a literal
    case "$p" in $pat) return 0 ;; esac
  done
  return 1
}

# payload_partition <extra_csv>
# Read repo-relative paths on stdin; print two TSV-free, prefixed lines per path:
#   SHIP\t<path>   or   DROP\t<path>
# Fail-closed: anything not matched is DROP. Callers filter on the SHIP/DROP tag.
payload_partition() {
  payload_load_allow "${1:-}"
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if payload_is_allowed "$p"; then printf 'SHIP\t%s\n' "$p"
    else printf 'DROP\t%s\n' "$p"; fi
  done
}
