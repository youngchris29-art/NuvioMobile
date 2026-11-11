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

check "next after 21"        22 "$(printf '21\n' | beta_next_n)"
check "next after 21.5"      22 "$(printf '21\n21.5\n' | beta_next_n)"
check "next after 22"        23 "$(printf '21\n21.5\n22\n' | beta_next_n)"
check "next after 9,10"      11 "$(printf '9\n10\n' | beta_next_n)"
check "next after rc suffix" 24 "$(printf '22\n23-rc1\n' | beta_next_n)"
check "empty"                 1 "$(printf '' | beta_next_n)"
check "max picks 21.5 over 21"  21.5 "$(printf '21\n21.5\n20\n' | beta_max_suffix)"
check "max picks 22 over 21.5"  22   "$(printf '21.5\n22\n21\n' | beta_max_suffix)"
check "max 21.10 over 21.9"     21.10 "$(printf '21.9\n21.10\n' | beta_max_suffix)"

exit "$FAIL"
