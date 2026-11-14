# Checklist: SwapRoutes

Spec pages: 12-settlement-routes.md. CVL specs: SettlementRoute.spec.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (46: 4 verified, 0 failed, 35 not run, 7 unlinked)

- [ ] `REQ-ROUTE-001` (12-settlement-routes.md:117) A market can be activated only if, for every token of the market and every debt asset approved on its CDP Spok — TEST-054, TEST-245 (only excluded checks: uses a stand-in for SwapRoutes)
- [~] `REQ-ROUTE-002` (12-settlement-routes.md:118) Route classes per token class (`Q-339`). For each (token, debt asset) pair the primary route is the deepest au — TEST-054
- [~] `REQ-ROUTE-003` (12-settlement-routes.md:119) The backup route of a slot MUST share no entry of `dependencies()` with the primary of the same (market, token — TEST-054, TEST-221
- [ ] `REQ-ROUTE-004` (12-settlement-routes.md:120) A route of a market MUST NOT call that market's own pool on any hop. The liquidation is removing liquidity fro — TEST-054 (only excluded checks: uses a stand-in for SwapRoutes)
- [~] `REQ-ROUTE-005` (12-settlement-routes.md:121) `setRoute` and `restoreRoute` MUST revert with `InvalidRoute` unless `route.tokenIn() == token`, `route.tokenO — TEST-054, TEST-221
- [~] `REQ-ROUTE-006` (12-settlement-routes.md:122) Each route slot has a published `routeDepthThreshold(marketId, token, debtAsset, kind)`, set in the listing ba — TEST-061, TEST-064
- [x] `REQ-ROUTE-007` (12-settlement-routes.md:126) `swap` MUST revert with `NotLPVaultSwap` unless `msg.sender == LP_VAULT_SWAP`, and with `NotLocked` unless the — PROP-037, TEST-046, TEST-054, TEST-060 — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_037_swapOnlyForLPVaultSwapUnderLock
- [~] `REQ-ROUTE-008` (12-settlement-routes.md:127) `swap` MUST request `amountIn` with `TOKEN_IN.transferFrom(LP_VAULT_SWAP, route, amountIn)`, measure `inRecv`  — TEST-046, TEST-054, TEST-177, TEST-221, TEST-232
- [~] `REQ-ROUTE-009` (12-settlement-routes.md:128) Every route MUST run with the minimum output LPVaultSwap passes as `minOut`, checked once after the last leg a — PROP-068, TEST-054, TEST-177, TEST-221, TEST-232
- [~] `REQ-ROUTE-010` (12-settlement-routes.md:129) Before each leg whose contract pulls its input with `transferFrom` (a Curve hop, the static aToken `deposit`,  — PROP-068, TEST-046, TEST-054
- [~] `REQ-ROUTE-011` (12-settlement-routes.md:130) A GSM leg of a `PegModule` route MUST approve the static aToken for exactly `inRecv` and `deposit(inRecv, rout — TEST-054, TEST-221, TEST-232
- [~] `REQ-ROUTE-012` (12-settlement-routes.md:131) A LitePSM leg of a `PegModule` route MUST compute `gemAmt` as the largest gem amount whose LitePSM DAI cost `c — PROP-044, PROP-068, TEST-054, TEST-177
- [x] `REQ-ROUTE-013` (12-settlement-routes.md:132) During a concentrated-liquidity hop the route MUST store the hop's pool, input token, amount and direction in  — PROP-036, TEST-046, TEST-054 — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_036_callbackAlwaysRefused
- [~] `REQ-ROUTE-014` (12-settlement-routes.md:133) `swap` MUST send all output it obtained to LPVaultSwap and return `out`, LPVaultSwap's balance rise in `TOKEN_ — PROP-068, TEST-054, TEST-080, TEST-232
- [~] `REQ-ROUTE-015` (12-settlement-routes.md:134) Any input or intermediate token left by a leg MUST be transferred to LPVaultSwap in the same call; a zero left — PROP-068, TEST-054, TEST-177, TEST-221
- [~] `REQ-ROUTE-016` (12-settlement-routes.md:135) A route MUST end every call with no change in its balance of any token and no allowance outstanding, and MUST  — PROP-068, TEST-046, TEST-054, TEST-080, TEST-221
- [~] `REQ-ROUTE-031` (12-settlement-routes.md:139) No route buys the debt asset. The liquidation caller funds the repayment with the debt asset itself, from its  — TEST-054
- [~] `REQ-ROUTE-032` (12-settlement-routes.md:140) No route takes a maximum-input limit; every route takes only `minOut`. (Source: Q-333) — TEST-054
- [~] `REQ-ROUTE-033` (12-settlement-routes.md:141) The callback rules of `REQ-ROUTE-013` apply to every pool hop of every route. (Source: Q-045, Q-148) — TEST-046, TEST-054
- [~] `REQ-ROUTE-034` (12-settlement-routes.md:142) Output delivered above `minOut` belongs to the call's recovery `R` (or, in `deleverage`, the borrower's `asset — TEST-054
- [~] `REQ-ROUTE-035` (12-settlement-routes.md:143) LPVaultSwap `forceApprove`s a route for exactly `amountIn` and resets the allowance after the call, whether it — TEST-221
- [~] `REQ-ROUTE-017` (12-settlement-routes.md:147) Adding or changing a route record MUST go through `MarketRegistry.setRoute` (normal delay) and MUST mark the r — TEST-054, TEST-063
- [~] `REQ-ROUTE-018` (12-settlement-routes.md:148) `disableRoute` (short delay) MUST set the slot Disabled until `restoreRoute` or a new `setRoute` executes. (So — TEST-054, TEST-063, TEST-168
- [~] `REQ-ROUTE-019` (12-settlement-routes.md:149) `restoreRoute` (short delay, DAO-only cancel) MUST revert with `NotPreviouslyApproved` unless `approvedBefore[ — TEST-054, TEST-063, TEST-067
- [~] `REQ-ROUTE-020` (12-settlement-routes.md:150) Route quarantine does not exist (`Q-227`); a suspect route is disabled at the short delay while guardians stop — TEST-063, TEST-168
- [ ] `REQ-ROUTE-021` (12-settlement-routes.md:151) A route is usable only if `getRoute` returns `usable = true` (status Active). (Source: Q-084, Q-151, Q-227) — TEST-054, TEST-068 (only excluded checks: uses a stand-in for SwapRoutes)
- [~] `REQ-ROUTE-022` (12-settlement-routes.md:152) When both routes of a token into the debt asset are unusable or failing, `liquidate` reverts with `NoRouteAvai — TEST-053
- [ ] `REQ-ROUTE-036` (12-settlement-routes.md:156) Enabling a debt reserve on a CDP Spoke (`enableDebtReserve`) MUST be batched with a primary and backup route,  — TEST-245 (only excluded checks: uses a stand-in for SwapRoutes)
- [~] `REQ-ROUTE-037` (12-settlement-routes.md:157) No sell-back route exists: the debt asset LPVaultSwap holds after `liquidationCall` beyond what Aave pulled, ` — TEST-048
- [ ] `REQ-ROUTE-038` (12-settlement-routes.md:158) `disableRoute` and `restoreRoute` apply to every route slot alike. (Source: Q-151, Q-228) — TEST-054, TEST-168 (only excluded checks: uses a stand-in for SwapRoutes)
- [ ] `REQ-ROUTE-039` (12-settlement-routes.md:159) A GHO debt reserve on a chain without deep GHO pools (Base, about 0.13M idle GHO in the V3 Pool) is enabled on — checked outside contracts/: a Base GHO reserve's drawCap is sized to measured off-chain route depth and Aave V3 Pool liquidity by the listing payload; that every market has both routes into GHO before enableDebtReserve is REQ-ROUTE-036, tested in MarketRegistry.MultiDebt
- [~] `REQ-ROUTE-042` (12-settlement-routes.md:163) Every route MUST implement `swap(uint256 amountIn, uint256 minOut) returns (uint256 out)` and MUST revert with — PROP-068, TEST-046, TEST-054, TEST-232
- [~] `REQ-ROUTE-043` (12-settlement-routes.md:164) A backup `DexPath` of a market MUST NOT trade through that market's own pool on any hop, and its `dependencies — TEST-054
- [~] `REQ-ROUTE-045` (12-settlement-routes.md:168) A route's constructor MUST revert with `InvalidRouteConfig` unless: `LP_VAULT_SWAP`, `LOCK`, `AAVE_ADAPTER`, ` — TEST-054, TEST-221
- [~] `REQ-ROUTE-046` (12-settlement-routes.md:169) Legacy Curve hops. A `DexPath` hop, or a hop of a `WrapperThenDex` route, MAY trade through a legacy (pre-NG)  — PROP-068, TEST-054, TEST-221, TEST-232
- [~] `REQ-ROUTE-023` (12-settlement-routes.md:184) Neither a liquidation caller, a flash liquidation helper nor a borrower can name a route, a pool, a leg or a m — TEST-227, TEST-233
- [~] `REQ-ROUTE-024` (12-settlement-routes.md:185) Every route MUST complete inside the LPVaultSwap call that uses it. (Source: Q-062, Q-022, Q-213) — TEST-232
- [x] `REQ-ROUTE-025` (12-settlement-routes.md:193) `swap` called by anyone but LPVaultSwap, or while the Lock is not held by LPVaultSwap or the AaveAdapter | rev — PROP-037, TEST-046 — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_037_swapOnlyForLPVaultSwapUnderLock
- [~] `REQ-ROUTE-026` (12-settlement-routes.md:194) GSM seized, frozen or at its cap; LitePSM halted; static aToken paused; a pool call fails; an intermediate tok — TEST-046, TEST-054
- [~] `REQ-ROUTE-027` (12-settlement-routes.md:195) Both routes of a token into the debt asset unusable or reverting | LPVaultSwap reverts with `NoRouteAvailable` — TEST-053
- [~] `REQ-ROUTE-028` (12-settlement-routes.md:196) Each route meets its `minOut`, but the total recovered is below the aggregate floor | LPVaultSwap reverts with — TEST-232
- [x] `REQ-ROUTE-029` (12-settlement-routes.md:197) Swap callback from an unexpected address or outside a hop | reverts with `InvalidCallback` (Source: Q-045, Q-0 — PROP-036, TEST-046 — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_036_callbackAlwaysRefused
- [ ] `REQ-ROUTE-030` (12-settlement-routes.md:198) `setRoute` or `restoreRoute` with a wrong token or debt asset, the market's own pool, a contract or intermedia — TEST-054 (only excluded checks: uses a stand-in for SwapRoutes)
- [~] `REQ-ROUTE-040` (12-settlement-routes.md:199) A buy-route call | Does not exist: no buy route is deployed (Source: Q-333) — TEST-054
- [~] `REQ-ROUTE-041` (12-settlement-routes.md:200) A sell-back call | Does not exist: no sell-back route is deployed (Source: Q-333) — TEST-054
- [~] `REQ-ROUTE-044` (12-settlement-routes.md:201) A route would deliver less than `minOut` | reverts with `MinOutNotMet(out, minOut)`; LPVaultSwap falls back to — TEST-177, TEST-232

## TEST rows (13: 0 verified, 0 failed, 10 not run, 3 unlinked)

- [~] `TEST-046` [access-control] Callbacks: the core flash source's `executeOperation` reverts unless `msg.sender` is the Aave V3 Pool, `initia
- [~] `TEST-054` [unit] Routes: a fixed swap route from each pool token into each debt asset the CDP Spoke can borrow (Uniswap v3, Sli
- [ ] `TEST-197` [unit] USDC-debt liquidation (6 decimals): LPVaultSwap pulls `debtToCover` USDC from the caller and measures `Kf`, ap (only excluded checks: tag on a test named for another row)
- [~] `TEST-217` [fuzz] Conservative LP value (`INV-078`): pool liquidity 10⁴ to 10¹⁵, Chainlink answers 0.01 to 2.0 per leg, pool spo
- [ ] `TEST-215` [invariant] Multi-actor invariant suite (Foundry invariant test with handlers, extending `TEST-082`). Actors: borrowers wi (only excluded checks: tag on a test named for another row)
- [~] `TEST-218` [invariant] Withdrawal and liquidation cascades: N accounts (N up to 200) opened near HF 1.10 in two markets; outside LPs 
- [~] `TEST-119` [fork] GSM on the Ethereum fork, as a backup swap route for GHO debt only: a GSM leg is used only when the GSM is not
- [ ] `TEST-120` [fork] Swap routes on both forks (Sky LitePSM, DAI/USDS converter and DEX pools on Ethereum; Slipstream and other Bas — checked outside contracts/: measures the launch listing's routes on both forks at the pinned blocks (RPC_MAINNET, RPC_BASE): which pools, thresholds and stress sizes the listing payload sets; the route rules it relies on (own pool refused, token class, primary and backup per debt asset) are TEST-054 locally
- [~] `TEST-202` [fork] Debt-asset price rally: accounts holding stable-LP collateral and WETH debt, opened at HF 1.15, see the WETH C
- [~] `TEST-221` [fork] Token edge cases. A fee-on-transfer mock pool token is rejected at listing; a fee switched on after listing on
- [~] `TEST-227` [fork] MEV: a searcher sandwiches every swap leg of `liquidate`, `settlePending` and `deleverage` at sizes up to the 
- [~] `TEST-232` [unit] Per-swap minimum: every route call from LPVaultSwap carries `minOut ≥ 1` equal to `SPEC-LIQ-018` for its leg; 
- [~] `TEST-281` [fork] One-sided unwind stress: for each concentrated-liquidity market, a seizure at and beyond each range edge retur

## PROP rows (4: 3 verified, 0 failed, 1 not run, 0 unlinked)

- [x] `PROP-036` [Certora] The core flash source's callback (`executeOperation`, checked on `FlashSource.spec`) succeeds only if `msg.sen — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_036_callbackOutsideContextRefused
- [x] `PROP-037` [Certora] Lock: any Avana function reachable only from inside the fixed set reverts unless the Lock is held and `msg.sen — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_037_swapOnlyForLPVaultSwapUnderLock
- [~] `PROP-049` [Certora] No `liquidate` seizes a market, or repays a debt reserve, whose primary and alternate routes disagree, from th
- [x] `PROP-068` [Certora] Every `ISettlementRoute.convert(amountIn, minOut)` call LPVaultSwap makes in `liquidate`, `settlePending` and  — DexPathRoute job 830e0ae334d84b7c912eb85e7bfad7fa

## INV (19: 4 verified, 0 failed, 14 not run, 1 unlinked)

- [x] `INV-058` Reconcile on exit. In `release` (withdrawal), `releasePartial` (partial removal), `releaseForDeleverage` (dele — PROP-045, PROP-051, TEST-020, TEST-150, TEST-151, TEST-153, TEST-154 — Collateralization job 8a8379652a2f4faaacd36ef1e8a3c13a
- [~] `INV-018` Blast radius of upgradeable contracts. (a) AaveAdapter implementation faulty or hostile (one per chain, servin — TEST-031, TEST-107, TEST-130, TEST-133, TEST-195
- [~] `INV-024` A borrow, a withdrawal that leaves debt, and a partial removal that leaves debt complete only if: the caller ( — TEST-019, TEST-028, TEST-095, TEST-229
- [x] `INV-073` A CDP Spoke's borrowable reserves through Avana are exactly the debt reserves the MarketRegistry approves for  — PROP-061, TEST-019, TEST-030, TEST-114 — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [~] `INV-031` The LPOracle records an outage only from successfully read source timestamps showing both routes past the Expi — PROP-074, TEST-042
- [x] `INV-034` In every routed settlement, the debt asset recovered `R` (LPVaultSwap's balance increase in the settlement ass — PROP-017, PROP-018, PROP-019, PROP-048, PROP-059, PROP-068, TEST-054, TEST-078, TEST-104, TEST-198, TEST-232, TEST-233 — DexPathRoute job 830e0ae334d84b7c912eb85e7bfad7fa
- [~] `INV-035` For every `liquidate` call, in the settlement asset `T` of the liquidation (the debt asset repaid): `Kf + R +  — PROP-015, PROP-059, TEST-051, TEST-078, TEST-092, TEST-093, TEST-104, TEST-198, TEST-216
- [~] `INV-036` The Avana fee in routed mode is `A = min(⌊G × avanaFeeShareBps / 10⁴⌋, S)` with `avanaFeeShareBps` 2,000 bps ( — PROP-015, PROP-069, TEST-051, TEST-198, TEST-240
- [~] `INV-037` No settlement budget (Q-397). No Avana contract holds funds to close a liquidation's settlement gap, and no LP — PROP-020, PROP-053, TEST-059, TEST-093, TEST-200
- [~] `INV-039` No in-kind settlement (Q-401). Every liquidation, through the one entry point `liquidate` (`INV-062`), settles — PROP-019, PROP-021
- [~] `INV-059` Persistent feed disagreement. The LPOracle (and the DebtOracle for a debt asset) stores the first time `poke() — PROP-049, TEST-044, TEST-049, TEST-157, TEST-159, TEST-219
- [~] `INV-062` One liquidation entry point (Q-404). `LPVaultSwap.liquidate` is the only liquidation entry point and admits an — PROP-022, PROP-053, TEST-174
- [~] `INV-070` Settlement in the debt asset, with no buy leg. For every debt reserve, LPVaultSwap pulls `debtToCover` of the  — PROP-059, TEST-048, TEST-092
- [~] `INV-086` Avana fee bounded and independent of routing. In every routed liquidation `A ≤ S = max(0, R_f − D)` with `R_f  — PROP-069, TEST-048, TEST-198, TEST-240
- [x] `INV-087` Stress valuation is monotone and never prices a seizure or repayment. A market's LPOracle serves (`SPEC-ORC-01 — PROP-074, TEST-037, TEST-044, TEST-105, TEST-219, TEST-230 — test/halmos/DebtOracle.halmos.t.sol:DebtOracleHalmosTest.check_PROP_074_servedDebtPriceAgainstFixedAlternate
- [~] `INV-046` An account with HF < 1 whose seized collateral market and repaid debt reserve pass `INV-030`, with no Aave pau — PROP-057, PROP-066, TEST-193, TEST-218
- [~] `INV-055` `LPOracle.latestAnswer()` never reverts and returns at least 1 (8 decimals) in every state (`SPEC-ORC-017`): t — PROP-023, PROP-027, PROP-074, TEST-036, TEST-038, TEST-105, TEST-217, TEST-219, TEST-230
- [ ] `INV-077` No zero-risk profit loop. For any sequence of calls by one actor, across any set of wallets it controls, that 
- [~] `INV-078` Conservative valuation by fair composition. For every market of every AMM protocol, the LPOracle values `units — PROP-083, TEST-217, TEST-266, TEST-279

## ATTACK (5: 0 verified, 0 failed, 1 not run, 4 unlinked)

- [ ] `ATTACK-067` Route sandwiching that pushes a settlement gap onto Avana
- [ ] `ATTACK-082` Settlement theft with a keeper key and a fast route change
- [~] `ATTACK-092` Cross-contract reentrancy during settlement — TEST-046, TEST-060, TEST-222
- [ ] `ATTACK-115` Sandwiching the routes of a caller's own liquidation
- [ ] `ATTACK-182` ETH debt and non-stable collateral routed through an intermediate stablecoin

## Cross-cutting TEST rows, every contract (17): see --uncovered

- `TEST-001` [environment] The Foundry workspace builds with solc 0.8.28 and EVM `cancun`, the same compiler as Aave V4; dependencies are
- `TEST-032` [access-control] Selector inventory: the external selectors of every deployed Avana contract are enumerated from bytecode and c
- `TEST-061` [unit] Events: every borrower and keeper action is one atomic call that emits the inventory events of its contracts, 
- `TEST-177` [unit] Zero-amount transfers skipped: with mock tokens that revert on a zero-amount `transfer` and `transferFrom`, ev
- `TEST-062` [access-control] Role map: every privileged selector of every Avana contract checks the role or the `TIMELOCK` address in the r
- `TEST-066` [access-control] Guardian powers: the Emergency Guardian (3-of-5) and the Aave Protocol Guardian hold `APPLICATION_PAUSE_GUARDI
- `TEST-080` [fuzz] Dust donations: sending 1 wei up to 10^6 wei of GHO, USDC, WETH, DAI, pool tokens or vault tokens (where the r
- `TEST-092` [invariant] Conservation: for every token (each debt asset, each pool token, each vault token), the sum of tracked balance
- `TEST-107` [invariant] Hostile suite: with the RiskModule, MarketRegistry, ParameterStore, LPOracle and LPVaultSwap replaced through 
- `TEST-108` [invariant] Structure and governance: immutables and runtime code hashes of the LPVault, Collateralization, vault tokens, 
- `TEST-212` [invariant] Timelock timing: handlers schedule normal, short and mixed batches (short-listed and normal calls in one batch
- `TEST-121` [fork] End-to-end lifecycle on one fork (Avana-deployed Aave V4 plus Ethereum Uniswap v3, Chainlink, GHO, the Aave V3
- `TEST-126` [fork] Emergency matrix: for every row of the matrix in [3.6](../03-operations/06-emergency-operations.md) (applicati
- `TEST-127` [fork] Halt deterioration and caps: with liquidation of an account stopped for the 48-hour incident window of `Q-192`
- `TEST-137` [deployment-check] Upgrade safety: every UUPS contract (AaveAdapter, MarketRegistry, ParameterStore, RiskModule, LPOracle, LPVaul
- `TEST-214` [deployment-check] Role snapshot: on every upgradeable Avana contract `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` are held only 
- `TEST-224` [deployment-check] Deployment simulation: `forge script` on the Ethereum fork and on the Base fork runs the chain's full deployme
