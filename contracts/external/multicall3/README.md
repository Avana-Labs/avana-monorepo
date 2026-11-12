# multicall3

Multicall3 at its canonical address `0xcA11bde05977b3631167028862bE2a173976CA11`, which the keeper and the indexer use to batch their reads. Ethereum, Base, Sepolia and Tenderly Virtual TestNets forked from them already have it there; a fresh anvil node does not, so `script/e2e/e2e-local.sh` places it with `anvil_setCode` before the first deploy step and checks its code hash.

| Item | Value |
|---|---|
| Source | github.com/mds1/multicall tag v3.1.0 = `a1fa0644fa412cd3237ef7081458ecb2ffad7dbe`, `src/Multicall3.sol` (sha256 `2054218939d3fa0f52f8ce1a33658d570a550671f63197356ee5744f7e188b1e`), installed by Soldeer as `dependencies/multicall-3.1.0/`; licence MIT |
| Compiler of the deployed contract | Solidity 0.8.12, optimizer 10,000,000 runs (the repository's `foundry.toml` at that tag; the CBOR tail of the runtime ends `64736f6c634300080c0033`, solc 0.8.12) |
| `Multicall3.runtime.hex` | The runtime bytecode, 5,561 bytes: the code that viem's `multicall3Bytecode` creation code (viem 2.57.11 in `package-lock.json`, the code viem runs for deployless multicalls) leaves when executed |
| Runtime code hash | `0x5a29a1eb2f59e45e4249b938c8192cac0d2bd32398e1afa03f302a867db692ea` (keccak-256), checked by `e2e-local.sh` after `anvil_setCode` |

Nothing builds the vendored source: rebuilding it needs solc 0.8.12, and a rebuild from another source path changes the metadata hash at the end of the runtime, so it could not stand at the canonical address with Ethereum's code hash. The source is pinned so the code at the canonical address can be read against it.
