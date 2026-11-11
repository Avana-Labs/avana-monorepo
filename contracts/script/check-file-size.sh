#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# File size limits of contracts/src (Q-240).
#
#   implementation file  at most 500 lines of code: lines that are neither blank nor comment-only
#   interface file       at most 300 lines in total, NatSpec and blank lines included
#
# An implementation file declares a contract (abstract or not) or a library with functions. Every other file
# (interfaces, events and errors, structs and enums, constant-only libraries, external mirrors) is an interface file.
# Prints one line per file over its limit and exits 1 if there is any; prints the largest file of each class.
#
# Usage, from contracts/:  script/check-file-size.sh [src-dir]

set -euo pipefail

SRC_DIR="${1:-src}"
MAX_IMPL_CODE=500
MAX_INTERFACE_LINES=300

if [ ! -d "$SRC_DIR" ]; then
  echo "check-file-size: no such directory: $SRC_DIR" >&2
  exit 2
fi

status=0
largest_impl=0
largest_impl_file="none"
largest_iface=0
largest_iface_file="none"

while IFS= read -r -d '' file; do
  if grep -Eq '^[[:space:]]*(abstract[[:space:]]+)?contract[[:space:]]' "$file" ||
    { grep -Eq '^[[:space:]]*library[[:space:]]' "$file" && grep -Eq '^[[:space:]]*function[[:space:]]' "$file"; }; then
    # Lines of code: strip block comments, line comments and blank lines.
    code=$(awk '
      {
        line = $0
        out = ""
        while (length(line) > 0) {
          if (in_block) {
            end = index(line, "*/")
            if (end == 0) { line = ""; break }
            line = substr(line, end + 2)
            in_block = 0
          } else {
            start = index(line, "/*")
            slash = index(line, "//")
            if (slash > 0 && (start == 0 || slash < start)) { out = out substr(line, 1, slash - 1); line = ""; break }
            if (start == 0) { out = out line; line = ""; break }
            out = out substr(line, 1, start - 1)
            line = substr(line, start + 2)
            in_block = 1
          }
        }
        if (out ~ /[^[:space:]]/) n++
      }
      END { print n + 0 }
    ' "$file")
    if [ "$code" -gt "$largest_impl" ]; then
      largest_impl=$code
      largest_impl_file=$file
    fi
    if [ "$code" -gt "$MAX_IMPL_CODE" ]; then
      echo "FAIL implementation $file: $code lines of code (limit $MAX_IMPL_CODE)"
      status=1
    fi
  else
    lines=$(awk 'END { print NR }' "$file")
    if [ "$lines" -gt "$largest_iface" ]; then
      largest_iface=$lines
      largest_iface_file=$file
    fi
    if [ "$lines" -gt "$MAX_INTERFACE_LINES" ]; then
      echo "FAIL interface $file: $lines lines (limit $MAX_INTERFACE_LINES)"
      status=1
    fi
  fi
done < <(find "$SRC_DIR" -type f -name '*.sol' -print0)

echo "largest implementation file: $largest_impl_file ($largest_impl lines of code, limit $MAX_IMPL_CODE)"
echo "largest interface file: $largest_iface_file ($largest_iface lines, limit $MAX_INTERFACE_LINES)"
if [ "$status" -eq 0 ]; then
  echo "check-file-size: every file is within its limit"
fi
exit "$status"
