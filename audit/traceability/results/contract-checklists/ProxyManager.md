# Checklist: ProxyManager

Spec pages: 05-position-proxy-and-proxy-manager.md. CVL specs: ProxyManager.spec, ProxyManagerIsolation.spec.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (50: 2 verified, 0 failed, 48 not run, 0 unlinked)

- [~] `REQ-PROXY-001` (05-position-proxy-and-proxy-manager.md:107) Each PositionProxy MUST be a plain immutable contract deployed by `ProxyManager.deployProxy(wallet, spoke, mar — TEST-172, TEST-190
- [~] `REQ-PROXY-002` (05-position-proxy-and-proxy-manager.md:108) Each proxy MUST hold `ADAPTER`, `WALLET`, `SPOKE` and `MARKET_ID` as constructor immutables and nothing else.  — PROP-010, TEST-025, TEST-172
- [~] `REQ-PROXY-003` (05-position-proxy-and-proxy-manager.md:109) The proxy constructor MUST revert with `ZeroAddress()` if `adapter`, `wallet` or `spoke` is `address(0)` or `m — PROP-010, TEST-025, TEST-187, TEST-190
- [~] `REQ-PROXY-004` (05-position-proxy-and-proxy-manager.md:110) The binding MUST be fixed at creation by the CREATE2 call: the salt and the constructor arguments both carry ` — PROP-010, TEST-025, TEST-190
- [~] `REQ-PROXY-005` (05-position-proxy-and-proxy-manager.md:111) `WALLET`, `SPOKE` and `MARKET_ID` MUST never change; no function transfers, renounces, recovers or rebinds the — PROP-010, TEST-025
- [~] `REQ-PROXY-006` (05-position-proxy-and-proxy-manager.md:112) Neither the proxy nor the ProxyManager MAY use `tx.origin` or check whether a caller or a wallet holds code (` — TEST-172
- [~] `REQ-PROXY-007` (05-position-proxy-and-proxy-manager.md:116) The proxy MUST expose exactly one state-changing function, `execute(target, data)`, which reverts with `OnlyAd — PROP-010, TEST-032, TEST-172, TEST-187, TEST-271
- [~] `REQ-PROXY-008` (05-position-proxy-and-proxy-manager.md:117) The Adapter MUST NOT make the proxy call `Spoke.liquidationCall`, `setUserPositionManager`, `setUserPositionMa — TEST-031, TEST-172, TEST-187
- [~] `REQ-PROXY-009` (05-position-proxy-and-proxy-manager.md:118) The Adapter MUST make the proxy borrow only a debt reserve in the MarketRegistry's enabled set for `SPOKE` ([2 — TEST-030, TEST-114
- [~] `REQ-PROXY-010` (05-position-proxy-and-proxy-manager.md:119) The Adapter MUST make the proxy call only `SPOKE`, the market's vault token and the debt asset of a reserve it — PROP-010, TEST-031, TEST-032
- [~] `REQ-PROXY-011` (05-position-proxy-and-proxy-manager.md:120) The proxy MUST NOT read any state: no pause state, price state, parameter, cap or health factor. The Adapter a — TEST-032, TEST-172, TEST-187
- [~] `REQ-PROXY-012` (05-position-proxy-and-proxy-manager.md:121) Errors from the Spoke, the Hub and the tokens MUST propagate unchanged through `execute`; the proxy's own erro — PROP-010, TEST-032, TEST-187
- [~] `REQ-PROXY-013` (05-position-proxy-and-proxy-manager.md:122) Every amount the Adapter forwards, refunds or verifies through the proxy MUST be measured as a balance delta o — TEST-027, TEST-029
- [~] `REQ-PROXY-014` (05-position-proxy-and-proxy-manager.md:123) The proxy MUST NOT call `Lock.acquire` or `Lock.release`: it is not a Lock member. `execute` is callable only  — TEST-172, TEST-187
- [~] `REQ-PROXY-078` (05-position-proxy-and-proxy-manager.md:124) The proxy MUST make no call to any LPOracle, including `poke()`. The first observation of a feed disagreement  — TEST-032
- [~] `REQ-PROXY-040` (05-position-proxy-and-proxy-manager.md:128) Only the Adapter MUST supply collateral for a proxy, in the same pledge or re-credit call that minted the unit — TEST-187
- [~] `REQ-PROXY-041` (05-position-proxy-and-proxy-manager.md:129) The Adapter MUST revert with `ZeroAmount()` before any proxy call if the units to supply are 0. It derives the — TEST-186
- [~] `REQ-PROXY-042` (05-position-proxy-and-proxy-manager.md:130) The supply step MUST, through `execute`: call `vaultToken.approve(SPOKE, units)`; call `SPOKE.supply(reserveId — TEST-010, TEST-032
- [~] `REQ-PROXY-043` (05-position-proxy-and-proxy-manager.md:131) If `SPOKE.getUserReserveStatus(reserveId, proxy)` reports collateral disabled after the supply, the Adapter MU — TEST-010, TEST-027
- [~] `REQ-PROXY-044` (05-position-proxy-and-proxy-manager.md:132) A proxy MUST hold at most one collateral reserve: its market's vault-token reserve on `SPOKE`. The Adapter sup — TEST-203
- [~] `REQ-PROXY-045` (05-position-proxy-and-proxy-manager.md:133) The supply step MUST NOT check the health factor, a price state, the pause state or Hub shares == assets; pled — TEST-032
- [~] `REQ-PROXY-046` (05-position-proxy-and-proxy-manager.md:134) Collateral cleanup: when the proxy's supplied shares of its market reserve are 0, the reserve is not paused (` — TEST-018, TEST-061
- [~] `REQ-PROXY-047` (05-position-proxy-and-proxy-manager.md:135) After a supply step the Adapter MUST emit `CollateralSupplied(proxy, marketId, units, shares)` with the suppli — TEST-010, TEST-061
- [~] `REQ-PROXY-087` (05-position-proxy-and-proxy-manager.md:139) The borrow step MUST read `asset = SPOKE.getReserve(debtReserveId).underlying`, call `SPOKE.borrow(debtReserve — TEST-027, TEST-187
- [~] `REQ-PROXY-088` (05-position-proxy-and-proxy-manager.md:140) The repay step runs only with `amount > 0` equal to the amount the Adapter measured arriving at the proxy from — TEST-029, TEST-032, TEST-177
- [~] `REQ-PROXY-089` (05-position-proxy-and-proxy-manager.md:141) The withdrawal step MUST revert with `ZeroAmount()` if `units == 0`, call `SPOKE.withdraw(reserveId, units, pr — PROP-011, TEST-018, TEST-187
- [~] `REQ-PROXY-090` (05-position-proxy-and-proxy-manager.md:142) The proxy MUST expose the views `ADAPTER()`, `WALLET()`, `SPOKE()` and `MARKET_ID()`. Debt and collateral are  — TEST-025
- [~] `REQ-PROXY-050` (05-position-proxy-and-proxy-manager.md:146) The ProxyManager MUST be an immutable contract with no upgrade proxy, owner, role, pause or setter, deployed o — TEST-089, TEST-190, TEST-191
- [~] `REQ-PROXY-051` (05-position-proxy-and-proxy-manager.md:147) `deployProxy(wallet, spoke, marketId)` MUST revert with `OnlyAdapter()` unless `msg.sender == ADAPTER`, with ` — PROP-064, TEST-089, TEST-190
- [x] `REQ-PROXY-052` (05-position-proxy-and-proxy-manager.md:148) `deployProxy` MUST create the proxy with CREATE2 from the salt `keccak256(abi.encode(wallet, spoke, marketId)) — PROP-064, PROP-076, TEST-089, TEST-190, TEST-247, TEST-271 — ProxyManagerIsolation job 8da8ab97dc3d4df797db7b55bfd7125e
- [~] `REQ-PROXY-053` (05-position-proxy-and-proxy-manager.md:149) One `(wallet, spoke, marketId)` triple MUST map to at most one proxy and one proxy to exactly one triple: the  — PROP-064, PROP-076, TEST-025, TEST-089, TEST-190, TEST-211, TEST-271
- [~] `REQ-PROXY-054` (05-position-proxy-and-proxy-manager.md:150) The ProxyManager MUST NOT write any registry of proxies. A proxy becomes a valid vault-token holder only when  — TEST-025, TEST-089, TEST-191
- [x] `REQ-PROXY-055` (05-position-proxy-and-proxy-manager.md:151) Proxy recognition MUST use the Adapter's binding (`walletOf(proxy) != address(0)`) or a vault token's `isValid — PROP-076, TEST-187, TEST-190, TEST-271 — ProxyManagerIsolation job 8da8ab97dc3d4df797db7b55bfd7125e
- [~] `REQ-PROXY-056` (05-position-proxy-and-proxy-manager.md:152) `ProxyDeployed` MUST be emitted before the Adapter's first supply through the new proxy, and the Adapter emits — TEST-025, TEST-190
- [~] `REQ-PROXY-085` (05-position-proxy-and-proxy-manager.md:153) The ProxyManager constructor MUST take `adapter` and `marketRegistry`, revert with `ZeroAddress()` if either i — TEST-025, TEST-089, TEST-190
- [~] `REQ-PROXY-086` (05-position-proxy-and-proxy-manager.md:154) There MUST be no function on any contract that replaces, upgrades or re-points the code of a deployed Position — PROP-010, TEST-025, TEST-062, TEST-130, TEST-191, TEST-195
- [~] `REQ-PROXY-099` (05-position-proxy-and-proxy-manager.md:155) `deployProxy(wallet, spoke, marketId)` MUST revert with `AddressIsFrozen(wallet)` if `MARKET_REGISTRY.isFrozen — PROP-064, TEST-089, TEST-190, TEST-229
- [~] `REQ-PROXY-100` (05-position-proxy-and-proxy-manager.md:156) Each wallet MUST have one PositionProxy per (CDP Spoke, market) and never more than one. Account isolation: ea — PROP-064, TEST-089, TEST-190, TEST-271
- [~] `REQ-PROXY-101` (05-position-proxy-and-proxy-manager.md:157) Neither the PositionProxy nor the ProxyManager MAY hold or grant any role: neither inherits `AccessControl` or — TEST-172, TEST-191
- [~] `SPEC-PROXY-005` (05-position-proxy-and-proxy-manager.md:161) **Collateral unit movement.** Supply: `balanceOf(proxy)` of the vault token falls by exactly `units` across `S — PROP-011, TEST-018, TEST-032
- [~] `REQ-PROXY-091` (05-position-proxy-and-proxy-manager.md:171) `execute` called by an address other than `ADAPTER`, including the bound wallet; or with a target that is the  — PROP-010, TEST-130, TEST-172, TEST-187, TEST-271
- [~] `REQ-PROXY-092` (05-position-proxy-and-proxy-manager.md:172) Proxy constructor with a zero `adapter`, `wallet` or `spoke`, or `marketId == 0` | The deployment reverts with — PROP-010, TEST-187
- [~] `REQ-PROXY-093` (05-position-proxy-and-proxy-manager.md:173) Zero units in a supply or withdrawal step, or `amount == 0` in a borrow step | The Adapter reverts with `ZeroA — TEST-027, TEST-186
- [~] `REQ-PROXY-094` (05-position-proxy-and-proxy-manager.md:174) The Spoke returns a withdrawn amount other than `units`, a token balance delta of the proxy differs from the e — PROP-011, TEST-010, TEST-018, TEST-029
- [~] `REQ-PROXY-095` (05-position-proxy-and-proxy-manager.md:175) Reserve not enabled as collateral after a supply step | The Adapter reverts with `CollateralNotEnabled(reserve — TEST-010
- [~] `REQ-PROXY-096` (05-position-proxy-and-proxy-manager.md:176) Aave blocks the action (reserve paused or frozen, Hub halt, `drawCap`, health factor below 1, `MaximumUserRese — TEST-019, TEST-027, TEST-158, TEST-187, TEST-203
- [~] `REQ-PROXY-097` (05-position-proxy-and-proxy-manager.md:177) `deployProxy` called by an address other than `ADAPTER`, with a zero `wallet`, `spoke` or `marketId`, for a tr — PROP-064, TEST-190
- [~] `REQ-PROXY-098` (05-position-proxy-and-proxy-manager.md:178) A callee reached through `execute` reverts with empty data | `execute` reverts with `CallFailed(target)`; a re — PROP-010, TEST-187
- [~] `REQ-PROXY-102` (05-position-proxy-and-proxy-manager.md:179) `deployProxy` for a wallet the MarketRegistry has frozen | The call reverts with `AddressIsFrozen(wallet)`; th — PROP-064, TEST-089, TEST-229
- [~] `REQ-PROXY-103` (05-position-proxy-and-proxy-manager.md:180) Any attempt to upgrade, re-point, re-initialize or take ownership of a proxy or the ProxyManager | No such fun — TEST-172, TEST-191

## TEST rows (10: 0 verified, 0 failed, 10 not run, 0 unlinked)

- [~] `TEST-010` [unit] Pledge happy path: the NFT owner approves the LPVault for one `positionKey` and calls `AaveAdapter.pledge(mark
- [~] `TEST-025` [unit] Proxy creation and binding: on the wallet's first pledge to a market the Adapter calls `ProxyManager.deployPro
- [~] `TEST-190` [unit] Proxy addresses: `ProxyManager.deployProxy(wallet, spoke, marketId)` reverts `OnlyAdapter` for any caller othe
- [~] `TEST-089` [invariant] Proxy binding and registry: only the ProxyManager deploys proxies, only on the AaveAdapter's call, each at `pr
- [~] `TEST-107` [invariant] Hostile suite: with the RiskModule, MarketRegistry, ParameterStore, LPOracle and LPVaultSwap replaced through 
- [~] `TEST-211` [invariant] Accounts and multi-asset accounting: handlers pledge, borrow, repay and liquidate on two Borrow Spokes, severa
- [~] `TEST-191` [fork] No proxy upgrade path through the real AvanaTimelock: the ProxyManager exposes no function that changes Positi
- [~] `TEST-229` [unit] Address freeze: a frozen wallet's new pledge (non-rescue), borrow (as caller or receiver), withdraw-with-debt,
- [~] `TEST-252` [unit] Small fixes: grace starts at the newest leg in use of the fresh price, never after `block.timestamp`, includin
- [~] `TEST-271` [access-control] Proxy per (wallet, Spoke, market): one wallet pledges into two markets of one CDP Spoke and one market of a CD

## PROP rows (4: 4 verified, 0 failed, 0 not run, 0 unlinked)

- [x] `PROP-043` [SMTChecker] The immutable contracts (every LPVault, Collateralization, vault token, VaultTokenFactory, ProxyManager, Posit — Lock job 0f0bbe338f844d87ba9968713df8b185
- [x] `PROP-064` [Certora] ProxyManager: `deployProxy(wallet, spoke, marketId)` succeeds only for `msg.sender == ADAPTER`, the chain's si — ProxyManager job 195a664988f54afa9c5ddd05dd0e92e0
- [x] `PROP-070` [Certora] Inductive admin invariant: for every upgradeable Avana contract (not the ProxyManager, which is immutable with — test/halmos/DebtOracle.halmos.t.sol:DebtOracleHalmosTest.check_PROP_070_adminRolesOnlyTimelock
- [x] `PROP-076` [Certora (`ProxyManagerIsolation.spec`, `PositionProxy.spec`)] One proxy per `(wallet, spoke, market)`: for any two successful `deployProxy` calls the triples differ and so  — ProxyManagerIsolation job 8da8ab97dc3d4df797db7b55bfd7125e

## INV (6: 3 verified, 0 failed, 3 not run, 0 unlinked)

- [x] `INV-009` `VaultToken.mint(to, amount)` succeeds only when called by the AaveAdapter (the token's immutable `adapter()`) — PROP-005, PROP-006, PROP-055, PROP-099, TEST-010, TEST-022, TEST-088, TEST-130, TEST-189 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_005_supplyChangesOnlyThroughAdapter
- [x] `INV-012` An address is a registered proxy of a market's vault token if and only if the AaveAdapter called `addValidProx — PROP-005, PROP-009, PROP-055, PROP-064, PROP-076, PROP-099, TEST-089, TEST-130, TEST-188, TEST-190 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_005_adapterOnlyFunctionsRefuseOtherCallers
- [~] `INV-018` Blast radius of upgradeable contracts. (a) AaveAdapter implementation faulty or hostile (one per chain, servin — TEST-031, TEST-107, TEST-130, TEST-133, TEST-195
- [~] `INV-020` In a borrow of debt reserve `r`, `r`'s asset moves from `r`'s funding Hub (the CDP Spoke's home Hub, or anothe — TEST-027, TEST-106
- [x] `INV-064` One proxy per (wallet, CDP Spoke, market). The chain's ProxyManager creates a PositionProxy only in `deployPro — PROP-064, PROP-076, TEST-025, TEST-089, TEST-190, TEST-211, TEST-271 — ProxyManager job 195a664988f54afa9c5ddd05dd0e92e0
- [~] `INV-065` Implementation changes only by timelock; proxy code never changes. A PositionProxy's code is fixed at creation — PROP-010, PROP-058, TEST-025, TEST-062, TEST-063, TEST-089, TEST-130, TEST-168, TEST-172, TEST-191

## ATTACK (8: 0 verified, 0 failed, 8 not run, 0 unlinked)

- [~] `ATTACK-010` Pledging into someone else's account — TEST-026
- [~] `ATTACK-022` A borrower's proxy acting as liquidator — TEST-031, TEST-130, TEST-172, TEST-187, TEST-189, TEST-271
- [~] `ATTACK-029` PositionProxy pre-deployment or initialization front-run — TEST-190
- [~] `ATTACK-123` Changing the code of every PositionProxy at once — TEST-025, TEST-172, TEST-191
- [~] `ATTACK-134` Pre-deploying code at a victim's proxy address — TEST-190
- [~] `ATTACK-156` Attacker-chosen proxy implementation — TEST-031, TEST-172, TEST-190, TEST-191
- [~] `ATTACK-162` Cross-Hub proxy squatting — TEST-271
- [~] `ATTACK-186` Proxy squatting through a per-chain ProxyManager — TEST-190, TEST-271

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
