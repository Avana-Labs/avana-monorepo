#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# No AI credit in commit messages or pull request text (decision of 2026-11-16). Fails on a line that holds:
#
#   - a co-author trailer naming an AI tool: "Co-Authored-By:" followed on the same line by Claude, Anthropic, ChatGPT,
#     OpenAI, Codex or Copilot;
#   - the address noreply@anthropic.com;
#   - "Generated with" as words of their own (not "regenerated with") followed by one of those names, or after the
#     robot emoji.
#
# Matching ignores case. Ordinary prose ("generated with forge", "regenerated with the new rows") passes.
#
# Usage, from the repository root or contracts/ (each option may repeat; every input is checked):
#
#   check-ai-credit.sh --message <file>           one commit message (the commit-msg hook in lefthook.yml)
#   check-ai-credit.sh --range <base>..<head>     every commit in the range, merge commits included
#   check-ai-credit.sh --text <file> <label>      any text, such as a pull request's title and body
#
# CI (.github/workflows/commit-messages.yml) checks a pull request's own commits (base..head) and its title and body;
# commits already on main are not checked. script/check-ai-credit.test.sh covers the patterns.

set -euo pipefail

TOOLS='(claude|anthropic|chatgpt|openai|codex|copilot)'
PATTERNS=(
  -e "^[[:space:]]*co-authored-by:.*${TOOLS}"
  -e 'noreply@anthropic\.com'
  -e "(^|[^[:alnum:]])generated with[[:space:]]+\[?${TOOLS}"
  -e '🤖[[:space:]]*generated with'
)

found=0
check() { # <label> <file>
  local hits
  # Comment lines of a commit message template are not part of the message.
  if hits=$(grep -v '^#' "$2" | grep -n -i -E "${PATTERNS[@]}"); then
    while IFS= read -r line; do echo "$1: $line"; done <<<"$hits"
    found=1
  fi
}

[ $# -gt 0 ] || { sed -n '4,20p' "$0" >&2; exit 2; }
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
while [ $# -gt 0 ]; do
  case $1 in
    --message)
      check "commit message" "$2"
      shift 2
      ;;
    --range)
      # One git call for the whole range: each commit is its short hash, a newline and its message, NUL-separated.
      while IFS= read -r -d '' rec; do
        printf '%s\n' "${rec#*$'\n'}" >"$tmp"
        check "commit ${rec%%$'\n'*}" "$tmp"
      done < <(git log -z --format='%h%n%B' "$2")
      shift 2
      ;;
    --text)
      check "$3" "$2"
      shift 3
      ;;
    *)
      echo "check-ai-credit: unknown option $1" >&2
      exit 2
      ;;
  esac
done

if [ $found -ne 0 ]; then
  echo "check-ai-credit: AI credit found; remove it from the commit message or the pull request text" >&2
  exit 1
fi
