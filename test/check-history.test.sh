#!/usr/bin/env bash
# check-history — history privacy scan.
# Regression guard: a denylist substring sitting incidentally inside a committed
# BINARY must NOT be reported as a history leak (the -S pickaxe searched blob
# bytes; the fix uses -G, which reads the textual diff and so skips binaries).
# Real text-file leaks must still be caught.
#
# NOTE: this file is tracked and public, so it must carry no real denylisted token
# and no literal personal path — the kit's own verify-release [8]/[9] scan it.
# We use a synthetic token ('/qcmd', in no denylist) and assemble the /home path
# at runtime so the literal never appears in the source.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

CH="$BIN/check-history"
TOKEN="/qcmd"                       # stand-in for a private slash-command token
DL="$WORK/dl"; printf '%s\n' "$TOKEN" > "$DL"

# --- denylist substring inside a committed binary is NOT a leak ---
r=$(mkrepo bin-substr)
# A file git treats as binary (embedded NUL) whose bytes incidentally contain the
# token as a substring of a package-path-like string — the false-positive shape.
printf 'ELF\000\000stuff internal%s/x.go more\000\000tail' "$TOKEN" > "$r/tool-bin"
git -C "$r" add -A && git -C "$r" commit -qm "commit a binary"
# Sanity: git must actually classify the blob as binary, else the test proves nothing.
if git -C "$r" show --numstat HEAD | grep -qE '^-[[:space:]]+-[[:space:]]+tool-bin'; then
  ok "fixture: committed tool-bin is a binary blob (numstat shows '- -')"
else
  bad "fixture: tool-bin not detected as binary — test would not exercise the bug"
fi
run "$CH" --repo "$r" --denylist "$DL"
assert_rc 0 "binary substring does not flag history as leaked"
assert_out_has "history is clean" "reports clean history for binary-only substring"

# --- a REAL text-file leak of the same token IS still caught ---
r=$(mkrepo text-leak)
printf 'run %s to finish\n' "$TOKEN" > "$r/notes.md"
git -C "$r" add -A && git -C "$r" commit -qm "leak in text"
run "$CH" --repo "$r" --denylist "$DL"
assert_rc 1 "text-file leak of the token is flagged"
assert_out_has "appears in history" "names the leaked term"

# --- personal/home path in history is still caught (existing behavior) ---
# Assemble the path at runtime so this source file carries no literal home path.
hp="/ho"; hp="${hp}me/nobody/secret"
r=$(mkrepo path-leak)
printf 'export P=%s\n' "$hp" > "$r/env.sh"
git -C "$r" add -A && git -C "$r" commit -qm "path leak"
run "$CH" --repo "$r" --denylist "$DL"
assert_rc 1 "personal home path in history is flagged"
assert_out_has "personal/home paths" "reports the personal-path leak"

# --- a denylist term with regex metacharacters matches LITERALLY (escaping) ---
r=$(mkrepo meta-term)
printf 'a.b appears here\n' > "$r/f.md"          # literal "a.b"
git -C "$r" add -A && git -C "$r" commit -qm "literal a.b"
printf 'axb is different\n' > "$r/g.md"           # would match unescaped "a.b"
git -C "$r" add -A && git -C "$r" commit -qm "axb"
printf 'a.b\n' > "$WORK/dl-dot"
run "$CH" --repo "$r" --denylist "$WORK/dl-dot"
assert_rc 1 "literal 'a.b' leak is caught"
# Escaping means it matched the literal, not the '.' wildcard: the literal-bearing
# commit must be the reported hit.
assert_out_has "literal a.b" "matched the literal-'a.b' commit (metachar escaped)"

# --- act-5972d5: WORD-BOUNDARY matching in the text (-G) path ---
# A short token must NOT substring-match a longer word (the token-as-substring-of-a-longer-word
# false-positive), but a genuine word-bounded occurrence is still caught.
WB="/qcm"                              # synthetic token; a substring of "/qcmd"
DLWB="$WORK/dl-wb"; printf '%s\n' "$WB" > "$DLWB"
# collision only: "launcher/qcmd" contains "/qcm" but the trailing 'm' abuts 'd'
r=$(mkrepo wb-collision)
printf '# needs the same launcher%sd list\n' "$WB" > "$r/lib.sh"   # -> launcher/qcmd
git -C "$r" add -A && git -C "$r" commit -qm "arch-like collision"
run "$CH" --repo "$r" --denylist "$DLWB"
assert_rc 0 "word-boundary: token as a substring of a longer word is not a leak"
assert_out_has "history is clean" "collision-only history reports clean"
# a genuine word-bounded occurrence of the same token IS still caught
r=$(mkrepo wb-real)
printf 'run %s now\n' "$WB" > "$r/notes.md"
git -C "$r" add -A && git -C "$r" commit -qm "real token"
run "$CH" --repo "$r" --denylist "$DLWB"
assert_rc 1 "word-boundary: a real word-bounded occurrence is still flagged"
assert_out_has "appears in history" "names the word-bounded leak"

# --- clean repo with a configured denylist exits 0 ---
r=$(mkrepo clean)
printf '# hello\n' > "$r/README.md"
git -C "$r" add -A && git -C "$r" commit -qm "clean"
run "$CH" --repo "$r" --denylist "$DL"
assert_rc 0 "clean repo passes"
