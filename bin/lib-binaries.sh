#!/usr/bin/env bash
# lib-binaries.sh — the single definition of the kit's binary-staging pieces:
# the target arch list and the uname launcher shim. Sourced by both
# stage-binaries (which writes the committed bin/) and any other kit script that
# needs the same launcher/arch list — so there is exactly one copy, not a per-
# script duplicate that can drift.
#
# Sourced, not executed: it sets KIT_ARCHES and defines functions, and does not
# touch shell options of the caller.

# The platform matrix every binary tool ships. Keep in lockstep with the launcher
# arch normalization below.
KIT_ARCHES="darwin/amd64 darwin/arm64 linux/amd64 linux/arm64"

# kit_write_launcher <dest_file>
# Write the tool-agnostic uname launcher (name derived from its own filename, so
# it is identical across tools) and mark it executable.
kit_write_launcher() {
  local dest=$1
  cat > "$dest" <<'WRAP'
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
  chmod +x "$dest"
}

# kit_build_arches <repo> <tool> <dest_bin_dir> [ldflags]
# Cross-compile ./cmd/<tool> for every KIT_ARCHES target into <dest_bin_dir> as
# <tool>-<os>-<arch>, ad-hoc-codesign the darwin binaries (an unsigned darwin/
# arm64 binary is SIGKILL'd at launch), and write the launcher as
# <dest_bin_dir>/<tool>. Returns non-zero on any build/sign failure.
#
# [ldflags] (optional) is passed verbatim to `go build -ldflags` — the caller
# uses it to stamp the version (-X <module>/internal/version.Binary=<v>). This is
# the ONLY place the committed binaries get a version: under the commit-to-main
# model there is no release-time rebuild, so an unstamped binary ships as `dev`.
#
# Darwin signing requires macOS `codesign`; on a host without it this fails
# rather than silently emit unsigned darwin binaries that would die for macOS
# users. (The Go linker only auto-signs when target==host with no cross env, so
# we sign explicitly to cover the cross-compiled darwin targets too.)
kit_build_arches() {
  local repo=$1 tool=$2 dest=$3 ldflags=${4:-}
  [ -d "$repo/cmd/$tool" ] || { echo "lib-binaries: no cmd/$tool in $repo (not a binary tool)" >&2; return 1; }
  mkdir -p "$dest"

  local need_codesign=0 a
  for a in $KIT_ARCHES; do case "$a" in darwin/*) need_codesign=1 ;; esac; done
  if [ "$need_codesign" = 1 ] && ! command -v codesign >/dev/null 2>&1; then
    echo "lib-binaries: codesign not found — run on macOS to ad-hoc sign darwin binaries" >&2
    echo "  (an unsigned darwin/arm64 binary is SIGKILL'd at launch; refusing to stage unsigned)" >&2
    return 1
  fi

  local os arch out
  for a in $KIT_ARCHES; do
    os=${a%/*}; arch=${a#*/}
    out="$dest/$tool-$os-$arch"
    ( cd "$repo" && GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 \
        go build -trimpath ${ldflags:+-ldflags "$ldflags"} -o "$out" "./cmd/$tool" ) \
      || { echo "lib-binaries: build failed for $a" >&2; return 1; }
    if [ "$os" = darwin ]; then
      codesign --sign - --force "$out" >/dev/null 2>&1 || { echo "lib-binaries: codesign failed for $out" >&2; return 1; }
    fi
  done

  kit_write_launcher "$dest/$tool"
}
