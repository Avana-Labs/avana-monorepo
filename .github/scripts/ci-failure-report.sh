#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Builds the failure report of one workflow run and records it (see .github/workflows/ci-failure-report.yml).
# Inputs (environment): GH_TOKEN, REPO, RUN_ID, WORKFLOW, CONCLUSION, EVENT, BRANCH, SHA, RUN_URL, PR_NUMBER;
# DRY_RUN=1 prints the report instead of writing an issue or comment.
# Log text is quoted inside fenced blocks only; nothing from a log or a pull request is executed.
set -euo pipefail

LABEL=ci-failure
SHORT=${SHA:0:7}
TITLE="CI failure: ${WORKFLOW} on main @ ${SHORT}"
TITLE_PREFIX="CI failure: ${WORKFLOW} on main"
TAIL_LINES=60
GREP_LINES=40
MAX_BODY=60000

on_main() { [ "$BRANCH" = main ] && [ "$EVENT" != pull_request ]; }

if [ "$CONCLUSION" = success ]; then
  on_main || exit 0
  # Close the open failure issues of this workflow on main.
  gh issue list --repo "$REPO" --label "$LABEL" --state open --limit 100 --json number,title \
    --jq ".[] | select(.title | startswith(\"$TITLE_PREFIX\")) | .number" |
    while read -r n; do
      [ "${DRY_RUN:-0}" = 1 ] && { echo "would close #$n"; continue; }
      gh issue comment "$n" --repo "$REPO" --body "Passed on main at \`${SHORT}\`: ${RUN_URL}"
      gh issue close "$n" --repo "$REPO" --reason completed
    done
  exit 0
fi

body=$(mktemp)
{
  echo "**Workflow:** \`${WORKFLOW}\`  "
  echo "**Result:** \`${CONCLUSION}\`  "
  echo "**Event:** \`${EVENT}\` on \`${BRANCH}\` at \`${SHA}\`  "
  echo "**Run:** ${RUN_URL}  "
  echo "**Recorded:** $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo
} >"$body"

jobs=$(gh api --paginate "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" --jq '.jobs[]' | jq -s '.')
failed=$(jq -c '[.[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled")]' <<<"$jobs")

{
  echo "## Jobs"
  echo
  echo "| Job | Result | Failed steps |"
  echo "|---|---|---|"
  jq -r '.[] | "| \(.name) | \(.conclusion // .status) | \([.steps[]? | select(.conclusion == "failure" or .conclusion == "timed_out") | .name] | join(", ")) |"' <<<"$jobs"
  echo
} >>"$body"

jq -c '.[]' <<<"$failed" | while read -r job; do
  id=$(jq -r '.id' <<<"$job")
  name=$(jq -r '.name' <<<"$job")
  {
    echo "## ${name}"
    echo
    echo "Job log: $(jq -r '.html_url' <<<"$job")"
    echo
    ann=$(gh api "repos/$REPO/check-runs/$id/annotations" --jq '.[] | "- \(.annotation_level): \(.message | gsub("\n"; " "))"' 2>/dev/null | sort -u || true)
    if [ -n "$ann" ]; then
      echo "**Annotations**"
      echo
      echo "$ann"
      echo
    fi
    log=$(gh api "repos/$REPO/actions/jobs/$id/logs" 2>/dev/null | sed -E 's/^[0-9T:.-]+Z //' || true)
    # A job that never started has no log; the API then returns a storage error document instead.
    if grep -q '<Error><Code>' <<<"$log"; then log=""; fi
    if [ -n "$log" ]; then
      # Failure markers of GitHub, forge, the security scripts, Halmos, Certora and Python; not "reported" findings.
      errs=$(grep -nE '##\[error\]|\[FAIL|FAIL in|FAILED|BLOCKING|below minimum|[Cc]ounterexample|SURVIVED|survived:|^Error|Error: |Error \(|panicked|Traceback|TIMEOUT|exit code [1-9]|Process completed with exit code' <<<"$log" | tail -n "$GREP_LINES" || true)
      if [ -n "$errs" ]; then
        echo "**Error lines (last ${GREP_LINES})**"
        echo
        echo '````text'
        echo "$errs"
        echo '````'
        echo
      fi
      echo "**Log tail (last ${TAIL_LINES} lines)**"
      echo
      echo '````text'
      tail -n "$TAIL_LINES" <<<"$log"
      echo '````'
      echo
    else
      echo "No log: the job did not start or its log is not available."
      echo
    fi
  } >>"$body"
done

arts=$(gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts" --jq '.artifacts[] | "- \(.name) (\(.size_in_bytes) bytes): '"$RUN_URL"'#artifacts"' 2>/dev/null || true)
if [ -n "$arts" ]; then
  { echo "## Artifacts"; echo; echo "$arts"; echo; } >>"$body"
fi

if [ "$(wc -c <"$body")" -gt "$MAX_BODY" ]; then
  head -c "$MAX_BODY" "$body" >"$body.cut"
  printf '\n\n(Report cut at %s characters; the full logs are on the run page.)\n' "$MAX_BODY" >>"$body.cut"
  mv "$body.cut" "$body"
fi

if [ "${DRY_RUN:-0}" = 1 ]; then
  cat "$body"
elif on_main; then
  gh label create "$LABEL" --repo "$REPO" --color B60205 --description "CI failure on main, recorded by ci-failure-report" 2>/dev/null || true
  existing=$(gh issue list --repo "$REPO" --label "$LABEL" --state open --limit 100 --json number,title \
    --jq ".[] | select(.title == \"$TITLE\") | .number" | head -n 1)
  if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "$REPO" --body-file "$body"
  else
    gh issue create --repo "$REPO" --title "$TITLE" --label "$LABEL" --body-file "$body"
  fi
elif [ -n "${PR_NUMBER:-}" ]; then
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body-file "$body"
else
  echo "No pull request and not main: report written to the job summary only."
fi
cat "$body" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
