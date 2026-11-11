#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Installs the pinned security tools of the contracts workspace.
#
#   tools/bin/        Echidna, Medusa, Aderyn and hevm from their GitHub releases, each checked against the sha256
#                     pinned below before it is unpacked
#   .venv/            Slither, crytic-compile, Halmos and certora-cli (requirements.txt)
#   .venv-mythril/    Mythril (requirements-mythril.txt); its z3-solver and py-evm pins conflict with Halmos
#   node_modules/     solhint and @openzeppelin/upgrades-core (package.json, package-lock.json), installed with
#                     lifecycle scripts disabled
#   tools/semgrep-smart-contracts/  Semgrep smart-contract rules (Decurity), git checkout of a pinned commit (--rules)
#   tools/4naly3er/   4naly3er, git checkout of a pinned commit with its Node dependencies installed locally (--4naly3er)
#   tools/bin/necessist  Necessist, built by `cargo install --locked` at a pinned version (--necessist; needs cargo:
#                     the project publishes no release binaries)
#   tools/bin/gambit  Gambit, the mutant generator bundled in the certora-cli wheel that requirements.txt pins (--gambit,
#                     after --python): a link to that binary, so its version moves only with the certora-cli pin
#
# Python packages resolve with uv and --exclude-newer, so a transitive dependency published after the cutoff is never
# picked. Supported platforms: macOS arm64 and Linux x86_64.
#
# Usage, from contracts/:
#   script/install-security-tools.sh [--binaries] [--python] [--gambit] [--node] [--rules] [--4naly3er] [--necessist]
#   (no flag: --binaries --python --gambit --node --rules --4naly3er; --necessist only when asked, since it compiles
#   from source)
# BINARIES="aderyn" (space-separated) limits --binaries to some of echidna, medusa, aderyn and hevm; CI jobs use it to
# download only what they run.

set -euo pipefail

cd "$(dirname "$0")/.."

ECHIDNA_VERSION=2.3.3
MEDUSA_VERSION=1.5.1
ADERYN_VERSION=0.6.8
HEVM_VERSION=0.58.0
PYTHON_VERSION=3.11
SEMGREP_RULES_COMMIT=2e878a89ac7bba1f8435e8a68e3ecb7700096cd5
FOURNALYZER_COMMIT=8a9d1ebb7d362bc94f036fa9123d0977c6cb7436
SOLC_JS_VERSION=0.8.28
NECESSIST_VERSION=4.1.0
# Newest upload date uv may resolve for any Python package (tool pins and their transitive dependencies).
PY_EXCLUDE_NEWER=2026-10-26

BIN_DIR="$PWD/tools/bin"
BINARIES="${BINARIES:-echidna medusa aderyn hevm}"
UV="${UV:-$(command -v uv || echo "$HOME/.local/bin/uv")}"

os="$(uname -s)-$(uname -m)"
case "$os" in
  Darwin-arm64)
    ECHIDNA_ASSET="echidna-${ECHIDNA_VERSION}-aarch64-macos.tar.gz"
    ECHIDNA_SHA256=8e16a43d8c37b74365ef259ea986e074b8a717309f770c7ff3d1f9fb891a7902
    MEDUSA_ASSET=medusa-mac-arm64.tar.gz
    MEDUSA_SHA256=a8b38bbd07a60f51e1b96304db58dba441b5053d7a61d1749458f3f7eaf5d3ce
    ADERYN_ASSET=aderyn-aarch64-apple-darwin.tar.xz
    ADERYN_SHA256=624c6652bb9478b38ddc255c27819cd5c6cb0448f5deb72036cc9cf5a27d4aac
    HEVM_ASSET=hevm-arm64-macos
    HEVM_SHA256=4f6d5e0c8fc39b88c9f5edea05028b4d4ce31e399296da39d89c9cc68697b5d6
    ;;
  Linux-x86_64)
    ECHIDNA_ASSET="echidna-${ECHIDNA_VERSION}-x86_64-linux.tar.gz"
    ECHIDNA_SHA256=436d26cb5af34c6c525812b857ac53f218c7f6ad07d69495ef88bc4cdc85c764
    MEDUSA_ASSET=medusa-linux-x64.tar.gz
    MEDUSA_SHA256=ddfe1517ae9028ef9fc331b00f5a6a9d5406f3fcd11a715d60c6b6fb3e4546d3
    ADERYN_ASSET=aderyn-x86_64-unknown-linux-gnu.tar.xz
    ADERYN_SHA256=ffd6ca658962e211a3ac821c646f69c8e14bf1b1001cbfe091bcd4535a691e46
    HEVM_ASSET=hevm-x86_64-linux
    HEVM_SHA256=7d6da60cfaa5cfe326cef8e4dffc1fb66595c60a325d86921f393bbf5cea275c
    ;;
  *)
    echo "install-security-tools: unsupported platform $os (macOS arm64 and Linux x86_64 only)" >&2
    exit 2
    ;;
esac

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch <url> <sha256> <dest>: download into a fresh temporary directory and keep the file only if the hash matches.
fetch() {
  local url=$1 want=$2 dest=$3 got
  curl -sSfL --retry 3 -o "$dest" "$url"
  got=$(sha256 "$dest")
  if [ "$got" != "$want" ]; then
    echo "install-security-tools: sha256 mismatch for $url" >&2
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    rm -f "$dest"
    exit 1
  fi
}

# have <binary> <version-substring>: true when tools/bin already holds that version.
have() {
  local flag=--version
  [ "$1" = hevm ] && flag=version
  [ -x "$BIN_DIR/$1" ] && "$BIN_DIR/$1" "$flag" 2>&1 | grep -q -- "$2"
}

wanted() { case " $BINARIES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

install_binaries() {
  mkdir -p "$BIN_DIR"
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  if ! wanted echidna; then
    :
  elif have echidna "$ECHIDNA_VERSION"; then
    echo "echidna $ECHIDNA_VERSION already installed"
  else
    mkdir "$tmp/echidna"
    fetch "https://github.com/crytic/echidna/releases/download/v${ECHIDNA_VERSION}/${ECHIDNA_ASSET}" \
      "$ECHIDNA_SHA256" "$tmp/echidna.tgz"
    tar -xzf "$tmp/echidna.tgz" -C "$tmp/echidna"
    install -m 0755 "$(find "$tmp/echidna" -type f -name echidna | head -n1)" "$BIN_DIR/echidna"
    echo "echidna $ECHIDNA_VERSION installed"
  fi

  if ! wanted medusa; then
    :
  elif have medusa "$MEDUSA_VERSION"; then
    echo "medusa $MEDUSA_VERSION already installed"
  else
    mkdir "$tmp/medusa"
    fetch "https://github.com/crytic/medusa/releases/download/v${MEDUSA_VERSION}/${MEDUSA_ASSET}" \
      "$MEDUSA_SHA256" "$tmp/medusa.tgz"
    tar -xzf "$tmp/medusa.tgz" -C "$tmp/medusa"
    install -m 0755 "$(find "$tmp/medusa" -type f -name medusa | head -n1)" "$BIN_DIR/medusa"
    echo "medusa $MEDUSA_VERSION installed"
  fi

  if ! wanted aderyn; then
    :
  elif have aderyn "$ADERYN_VERSION"; then
    echo "aderyn $ADERYN_VERSION already installed"
  else
    mkdir "$tmp/aderyn"
    fetch "https://github.com/Cyfrin/aderyn/releases/download/aderyn-v${ADERYN_VERSION}/${ADERYN_ASSET}" \
      "$ADERYN_SHA256" "$tmp/aderyn.txz"
    tar -xJf "$tmp/aderyn.txz" -C "$tmp/aderyn"
    install -m 0755 "$(find "$tmp/aderyn" -type f -name aderyn | head -n1)" "$BIN_DIR/aderyn"
    echo "aderyn $ADERYN_VERSION installed"
  fi

  if ! wanted hevm; then
    :
  elif have hevm "$HEVM_VERSION"; then
    echo "hevm $HEVM_VERSION already installed"
  else
    fetch "https://github.com/argotorg/hevm/releases/download/release/${HEVM_VERSION}/${HEVM_ASSET}" \
      "$HEVM_SHA256" "$tmp/hevm"
    install -m 0755 "$tmp/hevm" "$BIN_DIR/hevm"
    echo "hevm $HEVM_VERSION installed"
  fi

  # Downloads from GitHub carry the quarantine attribute on macOS; the hashes above are the trust check.
  if [ "$(uname -s)" = Darwin ]; then
    xattr -d com.apple.quarantine "$BIN_DIR"/* 2>/dev/null || true
  fi
}

install_python() {
  if [ ! -x "$UV" ]; then
    echo "install-security-tools: uv not found (set UV=/path/to/uv)" >&2
    exit 2
  fi
  [ -x .venv/bin/python ] || "$UV" venv --python "$PYTHON_VERSION" .venv
  "$UV" pip install --python .venv/bin/python --exclude-newer "$PY_EXCLUDE_NEWER" -r requirements.txt
  [ -x .venv-mythril/bin/python ] || "$UV" venv --python "$PYTHON_VERSION" .venv-mythril
  "$UV" pip install --python .venv-mythril/bin/python --exclude-newer "$PY_EXCLUDE_NEWER" -r requirements-mythril.txt
}

install_gambit() {
  # certora-cli ships Gambit as certora_bins/gambit in its platform wheels (macOS universal, Linux x86_64).
  local bin
  bin=$(.venv/bin/python -I -c 'import pathlib, certora_bins; print(pathlib.Path(certora_bins.__file__).parent / "gambit")' \
    2>/dev/null) || { echo "install-security-tools: --gambit needs certora-cli in .venv (run --python first)" >&2; exit 2; }
  if [ ! -x "$bin" ] || ! "$bin" --help >/dev/null 2>&1; then
    echo "install-security-tools: the certora-cli wheel has no runnable Gambit at $bin" >&2
    exit 1
  fi
  mkdir -p "$BIN_DIR"
  ln -sf "$bin" "$BIN_DIR/gambit"
  echo "gambit linked from certora-cli $(.venv/bin/python -I -c 'import importlib.metadata as m; print(m.version("certora-cli"))')"
}

install_node() {
  # Lifecycle scripts stay off: solhint and upgrades-core need none to run.
  npm ci --ignore-scripts --no-audit --no-fund
}

# checkout <url> <commit> <dir>: a git checkout of exactly <commit>; an existing checkout at another commit is replaced.
checkout() {
  local url=$1 commit=$2 dir=$3
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$commit" ]; then
    echo "$dir already at $commit"
    return 1
  fi
  rm -rf "$dir"
  git init -q "$dir"
  git -C "$dir" fetch -q --depth 1 "$url" "$commit"
  git -C "$dir" checkout -q FETCH_HEAD
  [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || { echo "install-security-tools: $dir is not at $commit" >&2; exit 1; }
  echo "$dir checked out at $commit"
}

install_rules() {
  # Licensed CC BY-NC-SA 4.0 by its authors; read at run time from tools/, never copied into the repository.
  checkout https://github.com/Decurity/semgrep-smart-contracts.git "$SEMGREP_RULES_COMMIT" tools/semgrep-smart-contracts || true
}

install_4naly3er() {
  local dir=tools/4naly3er
  if checkout https://github.com/Picodes/4naly3er.git "$FOURNALYZER_COMMIT" "$dir" || [ ! -x "$dir/node_modules/.bin/ts-node" ]; then
    # 4naly3er picks its compiler from the `solc-<version>` aliases of its package.json and lists 0.6.6 to 0.8.23. Every
    # src/ file pins 0.8.28, so the list is replaced by that one alias (one solc-js build instead of forty). Its
    # eslint plugins declare conflicting peer ranges that yarn ignores; npm needs --legacy-peer-deps for the same tree.
    node -e '
      const fs = require("fs"), f = process.argv[1], p = JSON.parse(fs.readFileSync(f));
      for (const k of Object.keys(p.dependencies)) if (k.startsWith("solc-")) delete p.dependencies[k];
      p.dependencies["solc-" + process.argv[2]] = "npm:solc@" + process.argv[2];
      fs.writeFileSync(f, JSON.stringify(p, null, 2) + "\n");' "$dir/package.json" "$SOLC_JS_VERSION"
    (cd "$dir" && npm install --ignore-scripts --no-audit --no-fund --legacy-peer-deps)
  fi
}

install_necessist() {
  if [ -x "$BIN_DIR/necessist" ] && "$BIN_DIR/necessist" --version 2>&1 | grep -q "$NECESSIST_VERSION"; then
    echo "necessist $NECESSIST_VERSION already installed"
    return
  fi
  command -v cargo >/dev/null || { echo "install-security-tools: --necessist needs cargo (rustup.rs)" >&2; exit 2; }
  cargo install necessist --version "$NECESSIST_VERSION" --locked --root "$PWD/tools"
}

if [ $# -eq 0 ]; then
  set -- --binaries --python --gambit --node --rules --4naly3er
fi
for step in "$@"; do
  case "$step" in
    --binaries) install_binaries ;;
    --python) install_python ;;
    --gambit) install_gambit ;;
    --node) install_node ;;
    --rules) install_rules ;;
    --4naly3er) install_4naly3er ;;
    --necessist) install_necessist ;;
    *)
      echo "install-security-tools: unknown option $step" >&2
      exit 2
      ;;
  esac
done
