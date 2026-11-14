#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Licence headers (LICENSE, LICENSING.md, THIRD_PARTY_LICENSES.md).
#
# Every Solidity file Avana owns, under contracts/{src,test,script,certora,aave-deploy} and docs/audit/, starts with exactly
#
#   // SPDX-License-Identifier: BUSL-1.1
#   pragma solidity <the file's version>;
#
#   // Copyright (c) 2026 Avana Labs
#
# Exempt from that header: src/interfaces/external/ (third-party interfaces keep their origin's SPDX identifier, which
# must be present) and the files in security/licence-allowlist.txt, each of which must carry exactly the identifier
# listed there. No Solidity file, script or package.json in those folders, in packages/ or in
# docs/spec/05-verification/ may carry UNLICENSED.
#
# Prints one line per violation and exits 1 if there is any.
#
# Usage, from contracts/:  script/check-licence.sh

set -euo pipefail

cd "$(dirname "$0")/.."

ALLOW=security/licence-allowlist.txt
[ -f "$ALLOW" ] || { echo "check-licence: missing $ALLOW" >&2; exit 2; }

roots=()
for d in src test script certora aave-deploy ../docs/audit; do
  [ -d "$d" ] && roots+=("$d")
done

status=0

# Solidity headers. Empty files have no first line and are reported by the build, not here.
find "${roots[@]}" -name '*.sol' -type f | LC_ALL=C sort | xargs awk -v allow="$ALLOW" '
  function check(f) {
    if (l1 ~ /UNLICENSED/) { printf "%s: carries UNLICENSED\n", f; bad = 1; return }
    if (f in want) {
      found[f] = 1
      if (l1 != "// SPDX-License-Identifier: " want[f]) {
        printf "%s: allowlisted as %s, first line is \"%s\"\n", f, want[f], l1; bad = 1
      }
      return
    }
    if (f ~ /^src\/interfaces\/external\//) {
      if (l1 !~ /^\/\/ SPDX-License-Identifier: [A-Za-z0-9.+-]+$/) {
        printf "%s: third-party interface without an SPDX identifier on its first line\n", f; bad = 1
      }
      return
    }
    if (l1 != "// SPDX-License-Identifier: BUSL-1.1" || l2 !~ /^pragma solidity [^;]+;$/ || l3 != "" ||
        l4 != "// Copyright (c) 2026 Avana Labs") {
      printf "%s: header is not the BUSL-1.1 SPDX line, pragma, blank line and Avana Labs copyright line\n", f
      bad = 1
    }
  }
  BEGIN {
    while ((getline line < allow) > 0) {
      if (line ~ /^#/ || line ~ /^[[:space:]]*$/) continue
      split(line, part, /[[:space:]]+/)
      want[part[1]] = part[2]
    }
  }
  FNR == 1 { if (cur != "") check(cur); cur = FILENAME; l1 = $0; l2 = l3 = l4 = "" }
  FNR == 2 { l2 = $0 }
  FNR == 3 { l3 = $0 }
  FNR == 4 { l4 = $0 }
  END {
    if (cur != "") check(cur)
    for (f in want) if (!(f in found)) { printf "%s: listed in %s but not found\n", f, allow; bad = 1 }
    exit bad
  }
' || status=1

# UNLICENSED anywhere else: scripts, harness sources and package manifests.
unlicensed=$(grep -rIlE --exclude-dir=node_modules --exclude-dir=.venv --exclude-dir=__pycache__ \
  --exclude-dir=.hypothesis --exclude-dir=.pytest_cache --exclude-dir=tools \
  'SPDX-License-Identifier: *UNLICENSED|"license": *"UNLICENSED"' \
  "${roots[@]}" package.json ../packages ../docs/spec/05-verification 2>/dev/null || true)
if [ -n "$unlicensed" ]; then
  while IFS= read -r f; do echo "$f: carries UNLICENSED"; done <<<"$unlicensed"
  status=1
fi

if [ $status -eq 0 ]; then
  echo "check-licence: every Avana-owned file carries its licence header"
fi
exit $status
