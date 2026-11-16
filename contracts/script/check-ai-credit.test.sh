#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Regression test of script/check-ai-credit.sh:
#
#   1. --message: each form of AI credit fails; ordinary prose that shares words with the patterns passes.
#   2. --text: a pull request body with a credit fails, without one passes.
#   3. --range: in a scratch repository, a range whose merge commit carries a credit fails, a range of clean commits
#      passes, and a credited commit before the range's base is not checked.
#
# Usage, from contracts/:  script/check-ai-credit.test.sh

set -euo pipefail

CHECK="$PWD/script/check-ai-credit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
expect() { # <description> <expected: pass|fail> <args...>
  local d=$1 want=$2 got=pass
  shift 2
  "$CHECK" "$@" >"$TMP/log" 2>&1 || got=fail
  if [ "$got" = "$want" ]; then
    echo "ok   $d"
  else
    echo "FAIL $d (expected $want, got $got)"
    sed 's/^/     /' "$TMP/log"
    fail=1
  fi
}

message() { # <name> <text>: a commit message file with a subject line and the text as its body
  printf 'Fix the gate\n\n%s\n' "$2" >"$TMP/$1"
}

message trailer-claude 'Co-Authored-By: Claude Opus <someone@example.com>'
message trailer-lower 'co-authored-by: chatgpt <bot@example.com>'
message trailer-copilot 'Co-authored-by: Copilot <copilot@example.com>'
message trailer-codex 'Co-Authored-By: OpenAI Codex <codex@example.com>'
message address 'Reviewed-by: someone <noreply@anthropic.com>'
message generated '🤖 Generated with [Claude Code](https://example.com)'
message generated-plain 'Generated with ChatGPT.'
for m in trailer-claude trailer-lower trailer-copilot trailer-codex address generated generated-plain; do
  expect "message: $m fails" fail --message "$TMP/$m"
done

message human-trailer 'Co-Authored-By: Josue Mpia <someone@users.noreply.github.com>'
message regenerated 'findings-register.md: regenerated with the new rows and counts.'
message generated-tool 'Gas snapshots generated with forge snapshot.'
message prose 'The Codex review and the Claude-style prompt notes are out of scope here.'
message comment '# Co-Authored-By: Claude (a template comment, stripped by git)'
for m in human-trailer regenerated generated-tool prose comment; do
  expect "message: $m passes" pass --message "$TMP/$m"
done

printf 'Tooling fixes\n\n## Summary\n\nWhole records.\n' >"$TMP/body-clean"
printf 'Tooling fixes\n\n## Summary\n\nWhole records.\n\n🤖 Generated with [Claude Code](https://example.com)\n' >"$TMP/body-credit"
expect "text: PR body without a credit passes" pass --text "$TMP/body-clean" "pull request"
expect "text: PR body with a credit fails" fail --text "$TMP/body-credit" "pull request"

# A scratch repository: main has an old credited commit; the branch has clean commits and a merge whose message
# carries a credit.
R="$TMP/repo"
git init -q -b main "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
g commit -q --allow-empty -m "Old commit" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
g commit -q --allow-empty -m "Main moves on"
base=$(g rev-parse HEAD)
g checkout -q -b topic HEAD~1
g commit -q --allow-empty -m "Topic work"
clean=$(g rev-parse HEAD)
g merge -q --no-ff main -m "Merge main" -m "Co-authored-by: Copilot <copilot@example.com>"
merged=$(g rev-parse HEAD)
(cd "$R" && expect "range: clean commits pass, the credited commit on main is not checked" pass --range "$base..$clean")
(cd "$R" && expect "range: a credited merge commit fails" fail --range "$base..$merged")

exit $fail
