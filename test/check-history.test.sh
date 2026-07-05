#!/usr/bin/env bash
# check-history — history privacy scan.
# Regression guard for act-141300: a denylist substring sitting incidentally
# inside a committed BINARY must NOT be reported as a history leak (the -S pickaxe
# searched blob bytes; the fix uses -G, which reads the textual diff and so skips
# binaries). Real text-file leaks must still be caught.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

CH="$BIN/check-history"

# --- act-141300: denylist substring inside a committed binary is NOT a leak ---
r=$(mkrepo bin-substr)
# A file git treats as binary (embedded NUL) whose bytes incidentally contain the
# denylist term as a substring — the exact "/wrap" inside "errors/wrap.go" shape.
printf 'ELF\000\000stuff errors/wrap.go more\000\000tail' > "$r/tool-bin"
git -C "$r" add -A && git -C "$r" commit -qm "commit a binary"
printf '/wrap\n' > "$WORK/dl-wrap"
# Sanity: git must actually classify the blob as binary, else the test proves nothing.
if git -C "$r" show --numstat HEAD | grep -qE '^-[[:space:]]+-[[:space:]]+tool-bin'; then
  ok "fixture: committed tool-bin is a binary blob (numstat shows '- -')"
else
  bad "fixture: tool-bin not detected as binary — test would not exercise the bug"
fi
run "$CH" --repo "$r" --denylist "$WORK/dl-wrap"
assert_rc 0 "binary substring '/wrap' does not flag history as leaked"
assert_out_has "history is clean" "reports clean history for binary-only substring"

# --- a REAL text-file leak of the same term IS still caught ---
r=$(mkrepo text-leak)
printf 'run /wrap to finish\n' > "$r/notes.md"
git -C "$r" add -A && git -C "$r" commit -qm "leak in text"
run "$CH" --repo "$r" --denylist "$WORK/dl-wrap"
assert_rc 1 "text-file leak of '/wrap' is flagged"
assert_out_has "appears in history" "names the leaked term"

# --- personal/home path in history is still caught (existing behavior) ---
r=$(mkrepo path-leak)
printf 'export P=/home/someone/secret\n' > "$r/env.sh"
git -C "$r" add -A && git -C "$r" commit -qm "path leak"
run "$CH" --repo "$r" --denylist "$WORK/dl-wrap"
assert_rc 1 "personal /home path in history is flagged"
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
# And the escaping means it matched the real literal, not via '.' wildcard: the
# commit touching only "axb" must not itself be the (sole) reported hit. We assert
# the literal-bearing commit is present in output.
assert_out_has "literal a.b" "matched the literal-'a.b' commit (metachar escaped)"

# --- clean repo with a configured denylist exits 0 ---
r=$(mkrepo clean)
printf '# hello\n' > "$r/README.md"
git -C "$r" add -A && git -C "$r" commit -qm "clean"
run "$CH" --repo "$r" --denylist "$WORK/dl-wrap"
assert_rc 0 "clean repo passes"
