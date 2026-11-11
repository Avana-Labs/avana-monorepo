# heimdall

[heimdall-rs](https://github.com/Jon-Becker/heimdall-rs) 0.9.3 (prebuilt `heimdall-macos-arm64` from the GitHub release), an EVM bytecode toolkit. Avana uses it to recover ABIs, storage layouts and pseudo-Solidity from deployed contracts whose source is not published, for example to confirm that a deployed Aave V4 Hub or Spoke matches the pinned build before listing a market on it.

Install (the binary is not committed):

```bash
mkdir -p tools/heimdall/bin
gh release download 0.9.3 -R Jon-Becker/heimdall-rs -p heimdall-macos-arm64 -O tools/heimdall/bin/heimdall
chmod +x tools/heimdall/bin/heimdall
```

Use:

```bash
tools/heimdall/bin/heimdall decompile <address> --rpc-url <rpc> --include-sol --output <dir>
tools/heimdall/bin/heimdall decode <calldata>
tools/heimdall/bin/heimdall dump <address> --rpc-url <rpc>
```
