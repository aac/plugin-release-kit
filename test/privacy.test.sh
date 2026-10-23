#!/usr/bin/env bash
# Privacy checks shared via lib-privacy.sh: the card/account-fragment pattern,
# the <denylist>.d/ generated-terms directory, and the verify-public command.
#
# NOTE: this file is tracked and public, and the kit scans itself, so it must
# carry no string the card pattern matches. Positive cases are written with
# NNNN / NNNNN placeholders and filled with made-up digits at runtime.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
. "$BIN/lib-privacy.sh"

VP="$BIN/verify-public"
CH="$BIN/check-history"
EMPTY_DL="$WORK/empty-denylist"; : > "$EMPTY_DL"

fill() { sed -e 's/NNNNN/12345/g' -e 's/NNNN/1234/g'; }

# --- the card pattern: should-match and must-not-match cases ---
POS="$WORK/pos.txt"; NEG="$WORK/neg.txt"
fill > "$POS" <<'EOF'
Atmos card (NNNN)
card ending in NNNN
Visa ending NNNNN.
acct #NNNN
Account: NNNN
account xNNNN
Amex …NNNN
Visa ...NNNN
card ****NNNN
XXXX-NNNN
paid with XXNNNN today
Visa xNNNN
Amex *NNNN
Sapphire (NNNN)
ending in NNNN
CARD NNNN
the card …NNNN on file
EOF
cat > "$NEG" <<'EOF'
year 2026
released in 2026
act-1234 ticket
issue #1234
localhost:8080
port 8080
listen on :3000
x * 1000
n*1000
0x1234
1080x1920
**2026**
*2026*
**4096 tokens per call
t.Fatalf("%s %q x1024: refused")
newlimArg(4096)
Smith (2019)
Copyright (2026)
card: 1000ms
card-1024px
card 1234.56
created account 2026-10-23
scorecard 1234
discard 1234
card 123456
0...1000
loading...2026
pending 1234
EOF

missed=$(LC_ALL=C grep -vE "$PRIV_CARD_ERE" "$POS")
[ -z "$missed" ] && ok "grep: every card-fragment case matches ($(wc -l < "$POS" | tr -d ' '))" || bad "grep: card cases missed" "$missed"
tripped=$(LC_ALL=C grep -E "$PRIV_CARD_ERE" "$NEG")
[ -z "$tripped" ] && ok "grep: no year/port/ticket/code case trips it ($(wc -l < "$NEG" | tr -d ' '))" || bad "grep: false positives" "$tripped"

# Same cases through `git log -G`, the engine check-history uses: one commit per
# line, subject says which side it is on.
r=$(mkrepo pattern-git)
i=0
while IFS= read -r l; do i=$((i+1)); printf '%s\n' "$l" > "$r/p$i"; git -C "$r" add "p$i"; git -C "$r" commit -qm "pos $i"; done < "$POS"
j=0
while IFS= read -r l; do j=$((j+1)); printf '%s\n' "$l" > "$r/n$j"; git -C "$r" add "n$j"; git -C "$r" commit -qm "neg $j"; done < "$NEG"
gp=$(git -C "$r" log --all --format=%s -G "$PRIV_CARD_ERE" | grep -c '^pos')
gn=$(git -C "$r" log --all --format=%s -G "$PRIV_CARD_ERE" | grep '^neg' || true)
[ "$gp" = "$i" ] && ok "git -G: every card case matches ($gp/$i)" || bad "git -G: matched $gp of $i card cases"
[ -z "$gn" ] && ok "git -G: no negative case matches" || bad "git -G: false positives" "$gn"

# --- verify-public: a clean plain repo passes ---
r=$(mkrepo vp-clean)
printf '# an app\n\nserves on port 8080 since 2026\n' > "$r/README.md"
git -C "$r" add -A && git -C "$r" commit -qm init
run "$VP" --repo "$r" --denylist "$EMPTY_DL"
assert_rc 0 "verify-public: clean plain repo exits 0"
assert_out_has "all privacy checks pass" "verify-public: clean repo reports all pass"
assert_out_has "[H] full git history" "verify-public: runs the history check"
assert_out_lacks "marketplace" "verify-public: no plugin-manifest checks run"
run "$VP" --repo "$r" --denylist "$EMPTY_DL" --strict
assert_rc 0 "verify-public: clean repo passes --strict"

# --- verify-public: a denylisted term only in HISTORY fails via [H] ---
TERM="Qzsecret"                       # synthetic denylisted term
DL="$WORK/dl"; printf '%s\n' "$TERM" > "$DL"
r=$(mkrepo vp-history)
printf 'ask %s first\n' "$TERM" > "$r/notes.md"
git -C "$r" add -A && git -C "$r" commit -qm "leak"
printf 'clean now\n' > "$r/notes.md"
git -C "$r" add -A && git -C "$r" commit -qm "scrub"
run "$VP" --repo "$r" --denylist "$DL"
assert_rc 1 "verify-public: denylisted term in history exits 1"
assert_out_has "PASS no denylisted proper nouns" "verify-public: working tree itself is clean"
assert_out_has "FAIL history carries leaks" "verify-public: [H] reports the history leak"
assert_out_has "not safe to make public" "verify-public: verdict line says not safe"

# --- verify-public: a card fragment in the working tree fails [8], digits not echoed ---
r=$(mkrepo vp-card)
printf 'pay with the Atmos card (NNNN) each month\n' | fill > "$r/fees.md"
git -C "$r" add -A && git -C "$r" commit -qm "fees"
run "$VP" --repo "$r" --denylist "$EMPTY_DL"
assert_rc 1 "verify-public: card fragment in tracked file exits 1"
assert_out_has "fees.md:1" "verify-public: names the file and line"
assert_out_has "card/account-number fragments appear in history" "verify-public: history scan sees the card pattern too"
assert_out_lacks "(1234)" "verify-public: never echoes the matched digits"

# verify-release [8] runs the same shared check (lockstep).
run "$BIN/verify-release" --repo "$r" --denylist "$EMPTY_DL"
assert_rc 1 "verify-release: same card fragment fails [8]"
assert_out_has "contain card/account-number fragments" "verify-release: [8] reports the card fragment"

# --- verify-public: no denylist anywhere is a WARN (strict makes it fail) ---
r=$(mkrepo vp-nodl)
printf 'hi\n' > "$r/README.md"; git -C "$r" add -A && git -C "$r" commit -qm init
run env XDG_CONFIG_HOME="$WORK/no-xdg" PLUGIN_KIT_DENYLIST= "$VP" --repo "$r"
assert_rc 0 "verify-public: no denylist is a WARN, exit 0"
assert_out_has "proper-noun scan skipped" "verify-public: says the noun scan was skipped"
run env XDG_CONFIG_HOME="$WORK/no-xdg" PLUGIN_KIT_DENYLIST= "$VP" --repo "$r" --strict
assert_rc 1 "verify-public: --strict promotes the no-denylist WARN"

# --- verify-public: usage errors exit 2 ---
run "$VP" --bogus
assert_rc 2 "verify-public: unknown flag exits 2"
git init -q --bare "$WORK/bare.git"
run "$VP" --repo "$WORK/bare.git"
assert_rc 2 "verify-public: bare repo (no working tree) exits 2"
assert_out_has "clone a bare repo first" "verify-public: tells you to clone a bare repo"

# --- <denylist>.d/: generated term files are read by both scans ---
GEN="Qzgenerated"
mkdir -p "$WORK/cfg/plugin-release-kit/denylist.d"
printf '# hand-kept\nQzhandkept\n' > "$WORK/cfg/plugin-release-kit/denylist"
printf '# generated, do not edit\n  %s  \n' "$GEN" > "$WORK/cfg/plugin-release-kit/denylist.d/ledger"
printf 'Qzhidden\n' > "$WORK/cfg/plugin-release-kit/denylist.d/.ignored"
r=$(mkrepo dl-dir)
printf 'see %s\n' "$GEN" > "$r/a.md"
git -C "$r" add -A && git -C "$r" commit -qm "gen term"
run env XDG_CONFIG_HOME="$WORK/cfg" PLUGIN_KIT_DENYLIST= "$VP" --repo "$r"
assert_rc 1 "denylist.d: a generated term in the tree fails verify-public"
assert_out_has "$GEN -> a.md" "denylist.d: [9] names the generated term (whitespace trimmed)"
run env XDG_CONFIG_HOME="$WORK/cfg" PLUGIN_KIT_DENYLIST= "$CH" --repo "$r"
assert_rc 1 "denylist.d: check-history reads the generated term too"
assert_out_has "\"$GEN\" appears in history" "denylist.d: history names the generated term"
# hidden files in denylist.d are ignored
r=$(mkrepo dl-hidden)
printf 'see Qzhidden\n' > "$r/a.md"; git -C "$r" add -A && git -C "$r" commit -qm "hidden term"
run env XDG_CONFIG_HOME="$WORK/cfg" PLUGIN_KIT_DENYLIST= "$VP" --repo "$r"
assert_rc 0 "denylist.d: a dotfile in denylist.d is not a term source"
# the .d directory works even with no main denylist file, next to --denylist too
mkdir -p "$WORK/only.d"; printf '%s\n' "$GEN" > "$WORK/only.d/x"
r=$(mkrepo dl-only-dir)
printf 'see %s\n' "$GEN" > "$r/a.md"; git -C "$r" add -A && git -C "$r" commit -qm "gen"
run "$VP" --repo "$r" --denylist "$WORK/only"
assert_rc 1 "denylist.d: <file>.d/ is read even when <file> does not exist"
assert_out_lacks "proper-noun scan skipped" "denylist.d: a .d-only denylist is not 'no denylist'"

# --- the kit's own tracked files are clean under the shared [8]/[9] checks ---
run "$BIN/verify-release" --repo "$KIT_ROOT" --denylist "$EMPTY_DL"
assert_out_has "PASS no card/account-number fragments" "kit: its own tracked files carry no card fragments"
assert_out_has "PASS no absolute personal/home paths" "kit: its own tracked files carry no home paths"

# --- .privacy-fixtures: declared synthetic files skip ONLY the card-shape check ---
r=$(mkrepo fixtures-declared)
mkdir -p "$r/fixtures/mail"
printf 'charged to card ending NNNN\n' | fill > "$r/fixtures/mail/a.json"
printf '# synthetic demo mail\nfixtures/**\n' > "$r/.privacy-fixtures"
git -C "$r" add -A && git -C "$r" commit -qm "demo fixtures"
run "$VP" --repo "$r" --denylist "$EMPTY_DL"
assert_rc 0 "fixtures: a declared synthetic file with a card shape passes (tree + history)"
assert_out_has "1 file(s) declared synthetic" "fixtures: says how many files it skipped"
# an undeclared file with the same text still fails, in the tree and in history
printf 'charged to card ending NNNN\n' | fill > "$r/notes.md"
git -C "$r" add -A && git -C "$r" commit -qm "real note"
run "$VP" --repo "$r" --denylist "$EMPTY_DL"
assert_rc 1 "fixtures: the same text outside the declared paths still fails"
assert_out_has "notes.md:1" "fixtures: names the undeclared file"
assert_out_has "real note" "fixtures: history names the undeclared commit"
assert_out_lacks "demo fixtures" "fixtures: history does not name the declared-fixture commit"
# the denylist still applies inside a declared fixture
r=$(mkrepo fixtures-denylist)
mkdir -p "$r/fixtures"
printf 'from %s\n' "$TERM" > "$r/fixtures/b.json"
printf 'fixtures/*\n' > "$r/.privacy-fixtures"
git -C "$r" add -A && git -C "$r" commit -qm "fixture with a real name"
run "$VP" --repo "$r" --denylist "$DL"
assert_rc 1 "fixtures: a denylisted term inside a declared fixture still fails"
assert_out_has "$TERM -> fixtures/b.json" "fixtures: [9] still scans declared fixtures"

# --- a relative --denylist is read relative to where verify-public was run ---
r=$(mkrepo rel-dl)
printf 'ask %s first\n' "$TERM" > "$r/notes.md"; git -C "$r" add -A && git -C "$r" commit -qm "leak"
OUT=$(cd "$WORK" && "$VP" --repo "$r" --denylist dl 2>&1); RC=$?
assert_rc 1 "relative --denylist: the term is still caught"
assert_out_has "$TERM -> notes.md" "relative --denylist: [9] read the file"
