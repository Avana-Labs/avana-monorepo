# Third-party licences

One entry per third-party component in this repository or in its builds: what it is, the pinned version, its licence, where Avana uses it, and the licence text or where to find it. Which Avana files carry which licence is in [`LICENSING.md`](LICENSING.md); the attribution notices are collected in [`NOTICE`](NOTICE). Full texts of the copyleft and source-available licences that apply to files in this repository are in [`LICENSES/`](LICENSES/).

## Ported third-party code

Code from these projects is ported into files in this repository. Each such file carries the origin's licence in its SPDX line and names the origin in its header.

### Uniswap v3-core and v3-periphery

- Version: v3-core `5ea68a77cb541c6b3812df783be71ba8c081e25f`, v3-periphery `24ccf014fe7f81d74a14c1689d6fdf123f280e45`.
- Copyright: (c) 2021 Uniswap Labs.
- Licence: GPL-2.0-or-later. `TickMath.sol`, `LiquidityAmounts.sol` and `OracleLibrary.sol` are GPL-2.0-or-later at these commits; `Tick.sol` and `SqrtPriceMath.sol` were BUSL-1.1 until the v3-core change date of 2023-04-01 and are GPL-2.0-or-later since.
- Used in: `contracts/src/amm/concentrated-liquidity/ClPriceMath.sol` (tick and square-root price conversion, the per-tick liquidity bound, amounts for liquidity, mean tick and harmonic-mean liquidity; compiled into the Uniswap v3 and Slipstream LPVaults); the Python ports in `contracts/test/differential/reference/avana_reference.py`, `spec/05-verification/z3/units-oracle/_common.py` and `spec/05-verification/hypothesis/model/uniswap.py`.
- Licence text: [`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt).

### Aave V4

- Version: `a3ef63ea6415d25237a9775bf66e76e9993561c2` (`aave/aave-v4`).
- Copyright: (c) Aave Labs.
- Licence: the Aave V4 licence (SPDX `LicenseRef-BUSL`): use in a test environment only, no production use of the work or a derivative, a representation that the user has not contributed to a competing lending product in the prior four years, the licence to be reproduced in each copy or derivative; Change License MIT.
- Used in: the Python reference models `spec/05-verification/hypothesis/model/aave.py`, `spec/05-verification/hypothesis/model/mathlib.py`, `spec/05-verification/z3/aave-risk/_v4ref.py` and `audit/formal-verification/liquidation/aave_ref.py`, which reproduce the Hub, Spoke, liquidation and math-library arithmetic to check Avana's specification and tests. None of them is deployed.
- Licence text: [`LICENSES/LicenseRef-BUSL-AaveV4.md`](LICENSES/LicenseRef-BUSL-AaveV4.md) (a copy of `LICENSE` at the pinned commit).

## Third-party interfaces

Subsets of deployed contracts' interfaces, copied from the origin source with identical selectors into `contracts/src/interfaces/external/`; each file names its source file and commit.

| Component | Version | Licence (SPDX of the Avana copy) | Files | Licence text |
|---|---|---|---|---|
| Uniswap v3-core | `5ea68a7` | GPL-2.0-or-later | `uniswap/IUniswapV3Factory.sol`, `uniswap/IUniswapV3Pool.sol`, `uniswap/IUniswapV3SwapCallback.sol` | [`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt) |
| Uniswap v3-periphery | `24ccf01` | GPL-2.0-or-later | `uniswap/INonfungiblePositionManager.sol` | [`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt) |
| Aerodrome Slipstream, (c) 2023 Perpetual Cyclist Services LLC | `main`, read 2026-11-10 | GPL-2.0-or-later | `aerodrome/ICLFactory.sol`, `aerodrome/ICLPool.sol`, `aerodrome/INonfungiblePositionManager.sol` (GPL-2.0-or-later); `aerodrome/ICLGauge.sol` (MIT, the upstream gauge interface's licence) | [`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt) |
| Aave V3 core | `a00f28e3ad7c0e4a369d8e06e0ac9fd0acabcab7` | AGPL-3.0 | `aave/IAaveV3ACLManager.sol` | [`LICENSES/AGPL-3.0.txt`](LICENSES/AGPL-3.0.txt) |
| Aave V3 origin | v3.4 | MIT | `aave/IAaveV3Pool.sol`, `aave/IAaveV3PoolAddressesProvider.sol`, `aave/IAaveV3FlashLoanReceiver.sol` | [MIT](#mit-license) |
| Sky `usds`, (C) 2023 Dai Foundation | `d65551dbc11cfe1afcc4718ab790663b99d766af` | AGPL-3.0-or-later | `sky/IDaiUsds.sol` | [`LICENSES/AGPL-3.0.txt`](LICENSES/AGPL-3.0.txt) |
| Sky `dss-lite-psm`, (C) 2023 Dai Foundation | `dbf0022225f645f5697e5517d0cf00810471bccf` | AGPL-3.0-or-later | `sky/ILitePsm.sol` | [`LICENSES/AGPL-3.0.txt`](LICENSES/AGPL-3.0.txt) |
| Chainlink `chainlink-evm`, (c) 2018 SmartContract ChainLink Limited SEZC | `4d83db28afc6d54761ce324e633d89244a97907e` | MIT | `chainlink/IAggregatorV3.sol`, `chainlink/IAggregatorProxy.sol`, `chainlink/ISequencerUptimeFeed.sol` | [MIT](#mit-license) |
| Chainlink `libocr` | `199a6f17c59863999480e990c7c0b6ba7796ec92` | MIT | `chainlink/IOffchainAggregator.sol` | [MIT](#mit-license) |
| GHO `gho-core`, (c) 2023 Aave | `c6335a0bb9cba099960c5378b1ff0db190b8da8f` | MIT | `gho/IGsm.sol` | [MIT](#mit-license) |

## Solidity dependencies

Installed by Soldeer into `contracts/dependencies/` (not committed), declared in `contracts/foundry.toml` `[dependencies]` and locked in `contracts/soldeer.lock`.

| Component | Version | Licence | Use | Licence text |
|---|---|---|---|---|
| OpenZeppelin Contracts, (c) 2016-2024 Zeppelin Group Ltd | 5.1.0 | MIT | compiled into Avana's contracts (`ERC20`, `SafeERC20`, `Math`, `SafeCast`, `TimelockController`, `ERC1967Proxy`, ERC-3156 and ERC-4626 interfaces) | [MIT](#mit-license) |
| OpenZeppelin Contracts Upgradeable, (c) 2016-2024 Zeppelin Group Ltd | 5.1.0 | MIT | compiled into the upgradeable contracts (`Initializable`, `UUPSUpgradeable`, `AccessControlUpgradeable`) | [MIT](#mit-license) |
| Solady, (c) 2022-2025 Solady. | 0.1.26 | MIT | `CREATE3`, compiled into the VaultTokenFactory | [MIT](#mit-license) |
| Forge Standard Library, (c) Contributors to Forge Standard Library | 1.17.0 | MIT OR Apache-2.0 | tests and scripts | [MIT](#mit-license); Apache-2.0 at [apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0) |
| Aave V4, (c) Aave Labs | `a3ef63ea6415d25237a9775bf66e76e9993561c2` | Aave V4 licence (`LicenseRef-BUSL`, test environments only) | compiled with Aave's own settings into `out-aave/` for the local, Sepolia and fork test deployments; imported by `contracts/aave-deploy/AvanaAaveV4Roles.sol`; reference for the ABI of Avana's Aave V4 interfaces | [`LICENSES/LicenseRef-BUSL-AaveV4.md`](LICENSES/LicenseRef-BUSL-AaveV4.md) |
| Uniswap v3-core, (c) 2021 Uniswap Labs | `5ea68a77cb541c6b3812df783be71ba8c081e25f` | BUSL-1.1 repository licence with a 2023-04-01 change date to GPL-2.0-or-later; files GPL-2.0-or-later or BUSL-1.1 | reference source of the ported math and the interfaces; not compiled | [`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt) |
| Uniswap v3-periphery, (c) 2021 Uniswap Labs | `24ccf014fe7f81d74a14c1689d6fdf123f280e45` | GPL-2.0-or-later | reference source; not compiled | [`LICENSES/GPL-2.0.txt`](LICENSES/GPL-2.0.txt) |
| GHO `gho-core`, (c) 2023 Aave | `c6335a0bb9cba099960c5378b1ff0db190b8da8f` | MIT | reference source of the GHO interfaces; not compiled | [MIT](#mit-license) |
| halmos-cheatcodes (a16z) | `6da4e692c357ba6d641a2e677a28298cac9f76ab` | AGPL-3.0 | remapped for symbolic tests and Certora confs; not imported | [`LICENSES/AGPL-3.0.txt`](LICENSES/AGPL-3.0.txt) |

## Packages

Installed from the lock files, not committed. TypeScript packages are bundled into the builds of `services/` and of the web app (`web/`); Python and Node packages under `contracts/` and `spec/05-verification/` run the checks only.

| Package | Version | Licence | Where |
|---|---|---|---|
| viem | 2.57.11 | MIT | `services/common`, `services/indexer`, `services/keeper`, `services/convex`, `packages/protocol`, `web/` |
| ponder | 0.18.2 | MIT | `services/indexer` |
| hono | 4.13.13 | MIT | `services/indexer` |
| typescript | 6.0.3 | Apache-2.0 | `services/`, `web/` (build) |
| @types/node | 22.20.5 | MIT | `services/`, `web/` (build) |
| vitest | 5.1.0 | MIT | `services/common`, `services/indexer`, `services/keeper`, `services/convex`, `packages/protocol`, `web/` (tests) |
| @aws-sdk/client-kms | 3.1156.0 | Apache-2.0 | `services/keeper` (signer keys held in AWS KMS) |
| tsx | 4.23.15 | MIT | `services/keeper` (runs the TypeScript entry point) |
| solhint | 6.2.5 | MIT | `contracts/package.json` |
| @openzeppelin/upgrades-core | 1.47.0 | MIT | `contracts/package.json` (storage-layout check) |
| @informalsystems/quint | 0.22.4 | Apache-2.0 | `spec/05-verification/package.json` |
| z3-solver | 4.13.0.0 | MIT | `spec/05-verification/requirements.txt` |
| sympy | 1.13.3 | BSD-3-Clause | `spec/05-verification/requirements.txt` |
| mpmath | 1.3.0 | BSD-3-Clause | dependency of sympy |
| hypothesis | 6.112.5 | MPL-2.0 | `spec/05-verification/requirements.txt` |
| pytest | 8.3.3 | MIT | `spec/05-verification/requirements.txt` |
| convex | 1.50.0 | Apache-2.0 | `services/convex`, `web/` |
| @assistant-ui/react | 0.15.15 | MIT | `web/` |
| @convex-dev/agent | 0.7.0 | Apache-2.0 | `web/`, `services/convex` (Ask AI) |
| @emotion/is-prop-valid | 1.4.0 | MIT | `web/` |
| @hugeicons/core-free-icons | 4.2.3 | MIT | `web/` |
| @hugeicons/react | 1.1.9 | MIT | `web/` |
| @radix-ui/react-accordion | 1.2.20 | MIT | `web/` |
| @radix-ui/react-dialog | 1.1.23 | MIT | `web/` |
| @radix-ui/react-dropdown-menu | 2.1.24 | MIT | `web/` |
| @radix-ui/react-select | 2.3.7 | MIT | `web/` |
| @radix-ui/react-slot | 1.3.3 | MIT | `web/` |
| @radix-ui/react-switch | 1.3.7 | MIT | `web/` |
| @sentry/nextjs | 10.78.0 | MIT | `web/` |
| @tanstack/react-query | 5.101.4 | MIT | `web/` |
| @vercel/analytics | 2.0.1 | MIT | `web/` |
| @vercel/speed-insights | 2.0.0 | Apache-2.0 | `web/` |
| class-variance-authority | 0.7.1 | Apache-2.0 | `web/` |
| clsx | 2.1.1 | MIT | `web/` |
| connectkit | 1.9.2 | BSD-2-Clause | `web/` |
| framer-motion | 12.43.0 | MIT | `web/` |
| lucide-react | 1.33.0 | ISC | `web/` |
| next | 16.4.5 | MIT | `web/` |
| radix-ui | 1.6.7 | MIT | `web/` |
| react | 18.3.1 | MIT | `web/` |
| react-dom | 18.3.1 | MIT | `web/` |
| react-markdown | 10.1.0 | MIT | `web/` |
| remark-gfm | 4.0.1 | MIT | `web/` |
| tailwind-merge | 2.6.1 | MIT | `web/` |
| tailwindcss-animate | 1.0.7 | MIT | `web/` |
| wagmi | 2.19.5 | MIT | `web/` |
| web-vitals | 4.2.4 | Apache-2.0 | `web/` |
| zod | 4.6.7 | MIT | `web/`, `services/convex` (Ask AI) |
| @eslint/js | 10.0.1 | MIT | `web/` (build, tests) |
| @next/bundle-analyzer | 16.4.5 | MIT | `web/` (build, tests) |
| @next/eslint-plugin-next | 16.4.5 | MIT | `web/` (build, tests) |
| @playwright/test | 1.62.1 | Apache-2.0 | `web/` (build, tests) |
| @testing-library/dom | 10.4.1 | MIT | `web/` (build, tests) |
| @testing-library/jest-dom | 6.9.1 | MIT | `web/` (build, tests) |
| @testing-library/react | 16.3.2 | MIT | `web/` (build, tests) |
| @testing-library/user-event | 14.6.1 | MIT | `web/` (build, tests) |
| @types/react | 18.3.31 | MIT | `web/` (build, tests) |
| @types/react-dom | 18.3.7 | MIT | `web/` (build, tests) |
| @vitejs/plugin-react | 6.0.5 | MIT | `web/` (build, tests) |
| eslint | 10.8.0 | MIT | `web/` (build, tests) |
| eslint-config-prettier | 10.1.8 | MIT | `web/` (build, tests) |
| globals | 17.8.0 | MIT | `web/` (build, tests) |
| jsdom | 29.1.1 | MIT | `web/` (build, tests) |
| lighthouse | 13.4.1 | Apache-2.0 | `web/` (build, tests) |
| postcss | 8.5.32 | MIT | `web/` (build, tests) |
| prettier | 3.9.6 | MIT | `web/` (build, tests) |
| tailwindcss | 3.4.19 | MIT | `web/` (build, tests) |
| typescript-eslint | 8.65.0 | MIT | `web/` (build, tests) |
| @rolldown/binding-linux-x64-gnu | 1.2.1 | MIT | `web/` (Linux build binding) |
| @ai-sdk/openai | 4.0.44 | Apache-2.0 | `services/convex` (Ask AI) |
| @convex-dev/rag | 0.7.6 | Apache-2.0 | `services/convex` (Ask AI) |
| @convex-dev/rate-limiter | 0.3.2 | Apache-2.0 | `services/convex` (Ask AI) |
| ai | 7.0.0 | Apache-2.0 | `services/convex` (Ask AI) |
| convex-test | 0.0.54 | Apache-2.0 | `services/convex` (tests) |
| @edge-runtime/vm | 5.0.0 | MIT | `services/convex` (tests) |

## Tools installed at run time

Downloaded by [`contracts/script/install-security-tools.sh`](contracts/script/install-security-tools.sh) (or, for heimdall, by the command in [`tools/heimdall/README.md`](tools/heimdall/README.md)) into ignored folders. None is copied into the repository or into a build output; each runs under its own licence.

| Tool | Version | Licence | Where |
|---|---|---|---|
| Semgrep smart-contract rules (Decurity) | commit `2e878a89ac7bba1f8435e8a68e3ecb7700096cd5` | CC BY-NC-SA 4.0 ([text](https://creativecommons.org/licenses/by-nc-sa/4.0/legalcode)) | `contracts/tools/semgrep-smart-contracts/`, read by Semgrep in the fast tier |
| Semgrep | 1.182.1 | LGPL-2.1-or-later | `contracts/.venv` |
| Slither, crytic-compile | 0.11.6, 0.4.2 | AGPL-3.0 | `contracts/.venv` |
| Halmos | 0.3.3 | AGPL-3.0 | `contracts/.venv` |
| certora-cli | 8.20.3 | GPL-3.0-only | `contracts/.venv` |
| Gambit (Certora) | the binary in the certora-cli 8.20.3 wheel | MIT | `contracts/tools/bin/gambit`, linked by `--gambit` |
| Mythril | 0.24.8 | MIT | `contracts/.venv-mythril` |
| Echidna | 2.3.3 | AGPL-3.0 | `contracts/tools/bin/` |
| Medusa | 1.5.1 | AGPL-3.0 | `contracts/tools/bin/` |
| hevm | 0.58.0 | AGPL-3.0 | `contracts/tools/bin/` |
| Aderyn | 0.6.8 | GPL-3.0 | `contracts/tools/bin/` |
| Necessist | 4.1.0 | AGPL-3.0 | `contracts/tools/bin/` |
| 4naly3er | commit `8a9d1ebb7d362bc94f036fa9123d0977c6cb7436` | GPL-3.0 | `contracts/tools/4naly3er/` |
| heimdall-rs | 0.9.3 | MIT | `tools/heimdall/bin/` |
| Eclipse Temurin JDK (for the Certora Prover) | 21.0.13 | GPL-2.0 with the Classpath Exception | installed separately; not part of the repository |
| Foundry | 1.9.0 | MIT OR Apache-2.0 | installed with `foundryup` |
| Solidity compiler | 0.8.28 | GPL-3.0 | installed by Foundry |

## MIT License

The components marked MIT above are distributed under this licence, each with its own copyright line as given in its entry and in [`NOTICE`](NOTICE):

```text
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
