#!/usr/bin/env bash
# Tests the changelog stripping and beta-number helpers of release-beta.sh in
# isolation: only the block between the "testable helpers" markers is sourced,
# so nothing here can build, tag or publish.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../release-beta.sh"
eval "$(sed -n '/^# BEGIN testable helpers/,/^# END testable helpers/p' "$SCRIPT")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; FAIL=1; fi
}

printf -- '---\nstate: NOT SENT\ntags: [a]\n---\n\n**NOT SENT**\n\nWhat is new\n- one\n- two\n\n<!-- internal -->\nsecret\n' > "$TMP/a.md"
check "frontmatter+status+internal" $'What is new\n- one\n- two' "$(strip_changelog_note < "$TMP/a.md")"

printf 'Plain note\n\n- a\n' > "$TMP/b.md"
check "plain passes through" $'Plain note\n\n- a' "$(strip_changelog_note < "$TMP/b.md")"

printf -- '---\nstate: x\n---\nBody only\n' > "$TMP/c.md"
check "frontmatter only" "Body only" "$(strip_changelog_note < "$TMP/c.md")"

printf -- '---\nx: 1\n---\n**SENT 11-09**\n<!-- internal -->\nall internal\n' > "$TMP/d.md"
if out="$(strip_changelog_note < "$TMP/d.md" 2>"$TMP/err")"; then
  echo "FAIL everything-internal: expected failure, got [$out]"; FAIL=1
else
  check "everything-internal errors" "1" "1"
  grep -q 'no publishable text' "$TMP/err" && echo "ok   error message" || { echo "FAIL error message"; FAIL=1; }
fi

printf -- '---\r\nstate: NOT SENT\r\n---\r\n\r\n**NOT SENT**\r\n\r\nWhat is new\r\n- one\r\n\r\n<!-- internal -->\r\nsecret\r\n' > "$TMP/e.md"
out="$(strip_changelog_note < "$TMP/e.md")"
check "CRLF note" $'What is new\n- one' "$out"
case "$out" in *$'\r'*) echo "FAIL CRLF output has CR"; FAIL=1 ;; *) echo "ok   CRLF output has no CR" ;; esac

printf 'Visible text <!-- internal --> secret\nmore secret\n' > "$TMP/f.md"
check "mid-line marker only line" "Visible text" "$(strip_changelog_note < "$TMP/f.md")"

printf 'Line one\nLine two   <!-- internal --> secret\nhidden\n' > "$TMP/g.md"
check "mid-line marker after public lines" $'Line one\nLine two' "$(strip_changelog_note < "$TMP/g.md")"

printf 'Public\n<!-- internal: notes -->\nsecret\n' > "$TMP/h.md"
check "internal: form own line" "Public" "$(strip_changelog_note < "$TMP/h.md")"
printf 'Public text <!-- internal: the sections below are records, not copy -->\nsecret\n' > "$TMP/h2.md"
check "internal: form mid-line" "Public text" "$(strip_changelog_note < "$TMP/h2.md")"
printf 'Public\n<!--internal-->\nsecret\n' > "$TMP/h3.md"
check "no-space marker" "Public" "$(strip_changelog_note < "$TMP/h3.md")"
printf 'Internal testing went well\n<!-- note -->\nan internal detail\nlast\n' > "$TMP/h4.md"
check "prose and other comments do not cut" $'Internal testing went well\n<!-- note -->\nan internal detail\nlast' "$(strip_changelog_note < "$TMP/h4.md")"

printf '\357\273\277---\nstate: x\n---\nBody\n' > "$TMP/i.md"
check "BOM before frontmatter" "Body" "$(strip_changelog_note < "$TMP/i.md")"
printf '\n\n---\nstate: x\n---\nBody\n' > "$TMP/j.md"
check "blank lines before frontmatter" "Body" "$(strip_changelog_note < "$TMP/j.md")"
printf -- '---\rstate: x\r---\rBody one\r\r<!-- internal -->\rsecret\r' > "$TMP/k.md"
check "CR-only endings" $'Body one' "$(strip_changelog_note < "$TMP/k.md")"
printf -- '---\nstate: x\nno close\nBody\n' > "$TMP/l.md"
if strip_changelog_note < "$TMP/l.md" >/dev/null 2>&1; then echo "FAIL unclosed frontmatter should error"; FAIL=1; else echo "ok   unclosed frontmatter errors"; fi
printf -- '---\nx: 1\n---\nTop\n\n---\n\nBelow rule\n' > "$TMP/m.md"
check "later hr stays body" $'Top\n\n---\n\nBelow rule' "$(strip_changelog_note < "$TMP/m.md")"

check "next after 21"        22 "$(printf '21\n' | beta_next_n)"
check "next after 21.5"      22 "$(printf '21\n21.5\n' | beta_next_n)"
check "next after 22"        23 "$(printf '21\n21.5\n22\n' | beta_next_n)"
check "next after 9,10"      11 "$(printf '9\n10\n' | beta_next_n)"
check "next after rc suffix" 23 "$(printf '22\n23-rc1\n' | beta_next_n)"
check "next after two rcs"   23 "$(printf '22\n23-rc1\n23-rc2\n' | beta_next_n)"
check "next after 23 + rc1"  24 "$(printf '22\n23\n23-rc1\n' | beta_next_n)"
check "next after 21.5 + rc" 22 "$(printf '21.5\n22-rc3\n' | beta_next_n)"
check "next rc only"          1 "$(printf '1-rc1\n' | beta_next_n)"
check "max ignores rc"       22 "$(printf '22\n23-rc1\n23-rc2\n' | beta_max_suffix)"
check "max 23 over 23-rc1"   23 "$(printf '23-rc1\n23\n22\n' | beta_max_suffix)"
check "max rc only empty"    "" "$(printf '23-rc1\n' | beta_max_suffix)"
check "empty"                 1 "$(printf '' | beta_next_n)"
check "max picks 21.5 over 21"  21.5 "$(printf '21\n21.5\n20\n' | beta_max_suffix)"
check "max picks 22 over 21.5"  22   "$(printf '21.5\n22\n21\n' | beta_max_suffix)"
check "max 21.10 over 21.9"     21.10 "$(printf '21.9\n21.10\n' | beta_max_suffix)"

exit "$FAIL"
