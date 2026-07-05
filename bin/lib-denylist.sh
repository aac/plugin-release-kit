#!/usr/bin/env bash
# lib-denylist.sh — shared denylist term-matching for verify-release [9] and
# check-history. Sourced by both, never executed, so the two matching paths stay
# in lockstep (act-5972d5: they must agree on word-boundary semantics).
#
# Denylist matching uses WORD-BOUNDARY semantics: a term matches only where its
# alphanumeric edges sit on a word boundary. So a short slash-command token like
# "/qcm" matches "run /qcm now" and "x/qcm" but NOT "/qcmd" or "launcher/qcmd"
# (the term's trailing 'm' abuts 'd', a word char — no boundary). This kills the
# substring false-positive while still catching real leaks. A term whose edge
# char is NON-alphanumeric (e.g. the leading '/' of "/qcm") gets no boundary on
# that side: the separator already delimits it, and demanding a word boundary
# there would wrongly miss "x/qcm".
#
# The construct is POSIX ERE — (^|[^[:alnum:]_]) and ([^[:alnum:]_]|$) — chosen
# for portability. GNU \b / \< word-boundary escapes are absent from BSD grep and
# from git's regex on macOS; the bracket-class form matches identically under
# `grep -E` (BSD grep 2.6 here) and `git log -G` (proven on this machine).
# NOTE: negated bracket classes misbehave under some non-GNU greps in a UTF-8
# locale, so callers of grep must run it under LC_ALL=C (git -G is unaffected).
# Terms are ERE-escaped first so regex metacharacters match literally.

# dl_esc_ere <term> -> ERE-escaped term on stdout (metacharacters matched literally).
dl_esc_ere() { printf '%s' "$1" | sed 's/[.[\*^$(){}+?|\\]/\\&/g; s/]/\\]/g'; }

# dl_word_pattern <term> -> a word-boundary-anchored ERE that matches <term>
# literally. Anchors only the term's alphanumeric edges (word char = [A-Za-z0-9_]).
dl_word_pattern() {
  local t=$1 pat
  pat=$(dl_esc_ere "$t")
  case ${t%"${t#?}"} in           # first char of $t
    [A-Za-z0-9_]) pat='(^|[^[:alnum:]_])'"$pat" ;;
  esac
  case ${t#"${t%?}"} in           # last char of $t
    [A-Za-z0-9_]) pat="$pat"'([^[:alnum:]_]|$)' ;;
  esac
  printf '%s' "$pat"
}
