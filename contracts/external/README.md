# external

Third-party protocols Avana runs against on test networks (anvil, Tenderly, Sepolia), built from pinned sources with their own compiler settings, each in its own Foundry profile and output folder so none of them mixes with Avana's 0.8.28 build. Scripts deploy them from the artifacts with `vm.getCode` (`script/deploy/02_DeployWorld.s.sol`); nothing in `src/` or `test/` imports them. Every source is installed by Soldeer from `soldeer.lock` into `dependencies/` and reached through remappings scoped to its own folder (`remappings.txt`). On Ethereum and Base, Avana reads the deployed protocols themselves and none of this is built.

| Source | Repository | Pinned commit | Profile → output | Settings | Licence |
|---|---|---|---|---|---|
| Uniswap v3 core | github.com/Uniswap/v3-core | `5ea68a77cb541c6b3812df783be71ba8c081e25f` (npm 1.0.1) | `univ3` → `out-univ3/` | 0.7.6, istanbul, 800 runs, no metadata hash, built alone | BUSL-1.1 (converted to GPL-2.0-or-later) |
| Uniswap v3 periphery | github.com/Uniswap/v3-periphery | `24ccf014fe7f81d74a14c1689d6fdf123f280e45` | `univ3-periphery` → `out-univ3-periphery/` (entry `external/univ3/`) | 0.7.6, istanbul, 1,000,000 runs, NonfungiblePositionManager 2,000 | GPL-2.0-or-later |
| OpenZeppelin 3.4.2-solc-0.7 | Soldeer registry `@openzeppelin-contracts` 3.4.2-solc-0.7 | zip sha256 `81842c01…d0e9` | (periphery, Slipstream) | — | MIT |
| Aerodrome Slipstream v1.0.0 | github.com/aerodrome-finance/slipstream | `37eead2c7e5302a204dec78bfa0775bbb8ff48a2` | `slipstream-v1` → `out-slipstream-v1/` (entry `external/slipstream-v1/`) | 0.7.6, istanbul, 200 runs | BUSL-1.1, change licence GPL-2.0-or-later |
| Aerodrome Slipstream main | github.com/aerodrome-finance/slipstream | `f8717faaae6e6717db3c8e3850149c01a79c0603` (2026-04-10) | `slipstream-main` → `out-slipstream-main/` (entry `external/slipstream-main/`) | 0.7.6, istanbul, 200 runs | as above |
| ExcessivelySafeCall | github.com/nomad-xyz/ExcessivelySafeCall | `81cd99ce3e69117d665d7601c330ea03b97acce0` (Slipstream submodule) | (Slipstream) | — | MIT OR Apache-2.0 |
| Aave V3 origin v3.7.0 | github.com/aave-dao/aave-v3-origin | `cff15de6d1271b0c800fc001f4aea4c263e8a597` (tag v3.7.0) | `aave-v3` → `out-aave-v3/` | 0.8.27, shanghai, 200 runs, no metadata hash | BUSL-1.1 |
| Aave solidity-utils | github.com/aave-dao/solidity-utils | `fdc69f984036585d508889147734902dc0c64bf3` (Aave V3 origin submodule) | (Aave V3) | — | MIT |
| OpenZeppelin upgradeable 5.1.0 | github.com/OpenZeppelin/openzeppelin-contracts-upgradeable | `fa525310e45f91eb20a6d3baa2644be8e0adba31` (solidity-utils submodule); its own `openzeppelin-contracts` submodule `69c8def5` is v5.1.0, served by the vendored `@openzeppelin-contracts` 5.1.0 | (Aave V3) | — | MIT |
| Aerodrome contracts v1.0 | github.com/aerodrome-finance/contracts | `1e08fb9765ec7ccf5946cd4eb041bd25f76e872d` (tag v1.0) | `aerodrome` → `out-aerodrome/` | 0.8.19, paris, 200 runs | BUSL-1.1 |
| OpenZeppelin 4.8.0 | github.com/OpenZeppelin/openzeppelin-contracts | `7b3e7b7055d6e1226d4920ca7d7c446c0c0bfff5` (Aerodrome submodule) | (Aerodrome) | — | MIT |
| Chainlink OCR2 aggregator | github.com/smartcontractkit/libocr (`contract2/`) | `199a6f17c59863999480e990c7c0b6ba7796ec92` (no release tags; the commit Avana's `IOffchainAggregator` cites) | `chainlink-ocr2` → `out-chainlink-ocr2/` | 0.8.19, paris, 1,000 runs (1,000,000 runs puts the aggregator over EIP-170) | MIT |
| Chainlink EACAggregatorProxy | github.com/smartcontractkit/chainlink (`contracts/src/v0.6/`, copied file by file into `external/chainlink-v2.10.0/` with sha256 in its README) | tag v2.10.0 = `0fe651463fbfa323ed4c578756c5a1465e0b168d` (the last release carrying the v0.6 proxy) | `chainlink-proxy` → `out-chainlink-proxy/` | 0.6.6, istanbul, 1,000,000 runs | MIT |

Uniswap v3 core is built alone on purpose: compiled in one Foundry job with the periphery, the pool's creation code hashed to `0x664ea9b6…2c20` instead of Uniswap's canonical `POOL_INIT_CODE_HASH` `0xe34f199b…8b54`, which the position manager and Avana's `UniswapV3Integration` (`POOL_INIT_CODE_HASH`) use to derive pool addresses; built alone it matches.

Slipstream main's `CLFactory` takes the previous generation's factory as `legacyCLFactory` and lets only its owner create a pool the legacy factory already has; `02_DeployWorld` deploys generations 0–2 from v1.0.0 and generation 3 from main with generation 2 as its legacy factory.

Licences: these sources are used only to build local and test-network deployments, never Avana's production contracts ([`deployments/README.md`](../../deployments/README.md)).
