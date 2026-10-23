#!/usr/bin/env bash
# lib-privacy.sh — the working-tree privacy checks and the patterns behind them,
# shared by verify-release [8]/[9], verify-public, and check-history. Sourced,
# never executed, so the three cannot drift: one definition of each pattern, one
# denylist resolution, one implementation of each working-tree check.
#
# Callers must define pass/fail/warn (one-line verdict printers) before calling
# the priv_check_* functions; the checks report through them so verify-release
# and verify-public print identical lines and count them the same way.
#
# Portability: every pattern here is POSIX ERE with no \b, \d or lookaround, so
# it behaves the same under BSD grep (run it with LC_ALL=C) and `git log -G`.
# See lib-denylist.sh for the word-boundary construct.

# shellcheck source=lib-denylist.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib-denylist.sh"

# priv_ci <word> -> an ERE matching <word> in any letter case ("ab" -> "[Aa][Bb]").
# Spelled out instead of grep -i so the same pattern works in `git log -G`.
priv_ci() {
  local w=$1 out="" c i
  for ((i = 0; i < ${#w}; i++)); do
    c=${w:i:1}
    case "$c" in
      [A-Za-z]) out="${out}[$(printf '%s' "$c" | tr '[:lower:]' '[:upper:]')$(printf '%s' "$c" | tr '[:upper:]' '[:lower:]')]" ;;
      *) out="$out$c" ;;
    esac
  done
  printf '%s' "$out"
}

# Absolute home paths — never legitimate in a public repo. Tilde conventions are
# per-user judgment and belong in the denylist instead (and ~/.claude etc. are
# legitimate install paths).
PRIV_PATH_ERE='/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+'

# Card and account-number fragments: a 4-5 digit group that something marks as
# the tail of a card or account. A literal denylist of known suffixes can never
# be complete, so this catches the shape instead. Four forms:
#
#   1. a keyword — ending, ending in, card, acct, account (any case, on a word
#      boundary) — then 1-6 separator chars (space # ( : * . x X - or U+2026)
#      then the digits:            "card ending in NNNN", "Atmos card (NNNN)"
#   2. a strong mask touching the digits, starting a word: an x/X run of 2+,
#      a * run of 3+, "..." or U+2026:  "XXXX-NNNN", "****NNNN", "...NNNN"
#   3. a weak mask (one x/X or one *) touching the digits, right after a
#      capitalised name:           "Visa xNNNN", "Amex *NNNN"
#   4. digits in parentheses right after a capitalised word: "Sapphire (NNNN)".
#      Years 19xx/20xx are excluded in this form only, so a citation like
#      "Smith (YYYY)" does not trip; form 1 still catches "card (YYYY)".
#
# Precision rules (each has a fixture in test/privacy.test.sh):
#   * the digit group is exactly 4-5 digits: a 6+ digit number never matches;
#   * the digits must not run on into a letter, '*', '-' or a '.'+digit, so
#     "1000ms", "1024px", "**YYYY**", "YYYY-10-23" and "1234.56" do not trip;
#   * masks and names must start a word, so "0x1234", "1080x1920", "n*1000",
#     "0...1000" and a camelCase call like "fooArg(4096)" do not trip;
#   * a lone x or * needs the capitalised name and "**" (markdown bold) is not
#     a mask, so "%q x1024", "x * 1000" and "**4096 tokens" do not trip;
#   * bare years, ticket ids (act-NNNN, #NNNN) and ports (:8080) carry no
#     keyword or mask, so they never match.
# Biased toward catching leaks: a phrase like "year ending YYYY" does trip it.
# Reword such a line. There is no per-line allow-marker; the only exemption is a
# repo declaring whole files as synthetic fixtures (see priv_fixture_globs).
_priv_d='[0-9]{4,5}'
_priv_t='([^[:alnum:]*.-]|[.][^0-9]|[.]$|$)'
_priv_kw="($(priv_ci ending)|$(priv_ci card)|$(priv_ci acct)|$(priv_ci account))"
_priv_sep='([[:space:]#(:*.xX-]|…)'
_priv_ws='(^|[^[:alnum:]_])'
PRIV_CARD_ERE="${_priv_ws}${_priv_kw}([[:space:]]+$(priv_ci in))?${_priv_sep}{1,6}${_priv_d}${_priv_t}"
PRIV_CARD_ERE="$PRIV_CARD_ERE|(^|[[:space:](])([xX]{2,}|[*]{3,}|[.][.][.]|…)-?${_priv_d}${_priv_t}"
PRIV_CARD_ERE="$PRIV_CARD_ERE|${_priv_ws}[A-Z][A-Za-z]+[[:space:]]([xX]|[*])${_priv_d}${_priv_t}"
PRIV_CARD_ERE="$PRIV_CARD_ERE|${_priv_ws}[A-Z][a-z]+[[:space:]]?[(]([03-9][0-9]{3}|1[0-8][0-9]{2}|2[1-9][0-9]{2}|[0-9]{5})[)]"
unset _priv_d _priv_t _priv_kw _priv_sep _priv_ws

# priv_resolve_denylist [<explicit file>] -> the denylist path on stdout.
# Order: explicit arg -> $PLUGIN_KIT_DENYLIST -> the per-machine default
# ${XDG_CONFIG_HOME:-~/.config}/plugin-release-kit/denylist. The path is printed
# even when no file exists there, because its <path>.d/ directory may.
priv_resolve_denylist() {
  local dl=${1:-}
  [ -n "$dl" ] || dl="${PLUGIN_KIT_DENYLIST:-}"
  [ -n "$dl" ] || dl="${XDG_CONFIG_HOME:-$HOME/.config}/plugin-release-kit/denylist"
  printf '%s' "$dl"
}

# priv_denylist_sources <denylist path> -> every source file, one per line: the
# denylist itself (if it exists) and then each regular, non-hidden file in
# <denylist>.d/ in name order. The .d/ directory is for GENERATED term lists
# (e.g. account suffixes exported from a ledger): a generator owns its own file
# there and rewrites it freely, so the hand-kept denylist stays hand-kept.
priv_denylist_sources() {
  local dl=$1 f
  [ -f "$dl" ] && printf '%s\n' "$dl"
  if [ -d "$dl.d" ]; then
    for f in "$dl.d"/*; do
      [ -f "$f" ] || continue
      case "${f##*/}" in .*|*~) continue ;; esac
      printf '%s\n' "$f"
    done
  fi
}

# priv_denylist_terms <denylist path> -> the terms from every source, one per
# line, with blank lines, '#' comments and surrounding whitespace removed.
priv_denylist_terms() {
  local src
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$src" | grep -vE '^(#|$)'
  done <<EOF
$(priv_denylist_sources "$1")
EOF
}

# priv_check_paths <tracked file list> — [8] absolute home paths.
priv_check_paths() {
  local hits
  hits=$(printf '%s\n' "$1" | while IFS= read -r f; do
    [ -f "$f" ] || continue
    [[ "$f" == LICENSE* ]] && continue
    LC_ALL=C grep -IlE -- "$PRIV_PATH_ERE" "$f" 2>/dev/null
  done)
  if [ -z "$hits" ]; then pass "no absolute personal/home paths in tracked files"
  else fail "tracked files contain personal/home paths (use repo-relative or generic placeholders):"; printf '%s\n' "$hits" | sed 's/^/         /'; fi
}

# priv_fixture_globs [<repo>] -> the glob pathspecs listed in <repo>/.privacy-fixtures
# (default: cwd), one per line, comments and blanks removed. A repo uses this
# file to declare files of SYNTHETIC data — demo mail, test fixtures — that must
# look like real card statements. Declared files skip ONLY the card-shape check;
# home paths and the denylist still apply to them, so a real, known card suffix
# in a fixture is still caught. Globs use git's pathspec glob rules ("*" stays
# inside one directory, "**" crosses them), and the same list is honoured by the
# working-tree check and by check-history, so both read one definition.
priv_fixture_globs() {
  local f="${1:-.}/.privacy-fixtures"
  [ -f "$f" ] || return 0
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f" | grep -vE '^(#|$)'
}

# priv_check_cards <tracked file list> — [8] card/account-number fragments.
# Reports file:line only, never the matched text, so the verifier's own output
# can be pasted into a ticket or log without re-leaking the digits. Run from the
# repo root (both callers cd there first).
priv_check_cards() {
  local hits exempt="" g note=""
  local -a specs=()
  while IFS= read -r g; do [ -n "$g" ] && specs+=(":(glob)$g"); done <<EOF
$(priv_fixture_globs .)
EOF
  [ "${#specs[@]}" -gt 0 ] && exempt=$(git ls-files -- "${specs[@]}" 2>/dev/null)
  hits=$(printf '%s\n' "$1" | while IFS= read -r f; do
    [ -f "$f" ] || continue
    [[ "$f" == LICENSE* ]] && continue
    [ -n "$exempt" ] && printf '%s\n' "$exempt" | grep -qxF -- "$f" && continue
    # The filename is data, never part of a sed/awk script (a tracked name with
    # '#' or ';w <file>' in it would otherwise inject sed commands).
    LC_ALL=C grep -InE -- "$PRIV_CARD_ERE" "$f" 2>/dev/null | cut -d: -f1 |
      while IFS= read -r n; do printf '%s:%s\n' "$f" "$n"; done
  done)
  [ -n "$exempt" ] && note=" ($(printf '%s\n' "$exempt" | grep -c .) file(s) declared synthetic in .privacy-fixtures skipped)"
  if [ -z "$hits" ]; then pass "no card/account-number fragments in tracked files$note"
  else fail "tracked files contain card/account-number fragments (file:line; remove the digits, or declare synthetic fixtures in .privacy-fixtures):$note"; printf '%s\n' "$hits" | sed 's/^/         /'; fi
}

# priv_check_denylist <tracked file list> <denylist path> — [9] proper nouns.
# Word-boundary match (act-5972d5): a short token like "/qcm" must not
# substring-match "launcher/qcmd". LC_ALL=C so BSD grep's negated bracket class
# behaves under a UTF-8 login locale.
priv_check_denylist() {
  local tracked=$1 dl=$2 terms t pat h dhits=""
  if [ -z "$(priv_denylist_sources "$dl")" ]; then
    warn "no denylist configured (--denylist, \$PLUGIN_KIT_DENYLIST, or ${dl}[.d/]) — proper-noun scan skipped"
    return 0
  fi
  terms=$(priv_denylist_terms "$dl")
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    pat=$(dl_word_pattern "$t")
    h=$(printf '%s\n' "$tracked" | while IFS= read -r f; do
      [ -f "$f" ] || continue
      # Files where personal names are legitimate (author attribution).
      [[ "$f" == LICENSE* ]] && continue
      [[ "$f" == *.claude-plugin/*.json || "$f" == *.codex-plugin/*.json ]] && continue
      LC_ALL=C grep -IlE -- "$pat" "$f" 2>/dev/null && break
    done)
    [ -n "$h" ] && dhits="$dhits$t -> $(printf '%s' "$h" | tr '\n' ' ')"$'\n'
  done <<< "$terms"
  if [ -z "$dhits" ]; then pass "no denylisted proper nouns in tracked files"
  else fail "tracked files leak denylisted terms:"; printf '%s' "$dhits" | sed 's/^/         /'; fi
}
