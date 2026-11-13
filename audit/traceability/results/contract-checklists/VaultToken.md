# Checklist: VaultToken

Spec pages: 04-vault-tokens.md. CVL specs: VaultToken.spec.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (56: 19 verified, 0 failed, 37 not run, 0 unlinked)

- [x] `REQ-VTOKEN-001` (04-vault-tokens.md:76) Each vault token MUST be a non-upgradeable contract with no owner, no admin, no role, no setter, no pause, no  — PROP-055, TEST-023 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_055_bindingsNeverChange
- [~] `REQ-VTOKEN-002` (04-vault-tokens.md:77) The vault token MUST implement ERC-20 with OpenZeppelin Contracts v5.1.0 `ERC20` semantics for balances, allow — TEST-023
- [x] `REQ-VTOKEN-003` (04-vault-tokens.md:78) The vault token MUST store as immutables and expose `integrationId()`, `integration()`, `marketKey()`, `hub()` — PROP-055, TEST-023 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_055_bindingsNeverChange
- [~] `REQ-VTOKEN-004` (04-vault-tokens.md:79) `decimals()` MUST return `d` per `SPEC-UNIT-001`, fixed at deployment. (Source: Q-066, Q-191) — TEST-023, TEST-024
- [~] `REQ-VTOKEN-005` (04-vault-tokens.md:80) One base unit of the vault token MUST equal one unit credited in the market (`SPEC-UNIT-002`; `10^k` liquidity — TEST-022
- [x] `REQ-VTOKEN-006` (04-vault-tokens.md:84) The token MUST allow exactly these balance changes of a market's vault token and no other (`isAllowedTransfer( — PROP-008, PROP-055, TEST-022, TEST-086, TEST-087, TEST-185, TEST-189 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_008_movementsOnlyOnAllowedPaths
- [x] `REQ-VTOKEN-007` (04-vault-tokens.md:85) The proxy registry MUST live in the token as `isValidProxy`, written only by `addValidProxy` from the Adapter  — PROP-009, TEST-130, TEST-188 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_009_registryAppendOnlyByAdapter
- [x] `REQ-VTOKEN-008` (04-vault-tokens.md:86) Every `transfer` and `transferFrom`, including transfers to `address(0)` and transfers by a spender, MUST reve — PROP-008, PROP-055, TEST-087, TEST-189 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_008_movementsOnlyOnAllowedPaths
- [~] `REQ-VTOKEN-009` (04-vault-tokens.md:87) Transfers into the Hub MUST be accepted only from a registered proxy, the only caller of `Spoke.supply` in Ava — TEST-022
- [x] `REQ-VTOKEN-010` (04-vault-tokens.md:88) On `Spoke.supply`, the Spoke calls `transferFrom(proxy, hub, amount)` as spender of the proxy's exact approval — PROP-055, TEST-022, TEST-189 — VaultToken job 6bfe727afcd349819354fa4acf36fa35
- [x] `REQ-VTOKEN-011` (04-vault-tokens.md:89) `approve` MUST follow OpenZeppelin v5.1.0 semantics; an allowance never bypasses `REQ-VTOKEN-008`, because the — PROP-055, TEST-022, TEST-189 — VaultToken job 6bfe727afcd349819354fa4acf36fa35
- [x] `REQ-VTOKEN-040` (04-vault-tokens.md:90) `isAllowedTransfer(from, to)` MUST return `(to == hub() && isValidProxy[from]) || (from == hub() && (isValidPr — PROP-055, TEST-189 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_008_movementsOnlyOnAllowedPaths
- [x] `REQ-VTOKEN-041` (04-vault-tokens.md:91) A transfer from one registered proxy to another, from LPVaultSwap to the Hub, or to or from the Adapter MUST r — PROP-055, TEST-087, TEST-189 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_055_viewsAreTheFixedFormulas
- [x] `REQ-VTOKEN-048` (04-vault-tokens.md:92) A `transfer` or `transferFrom` of 0 units MUST revert with `UnauthorizedTransfer(from, to)` on every path, the — PROP-008, PROP-055, TEST-022, TEST-189 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_008_movementsOnlyOnAllowedPaths
- [x] `REQ-VTOKEN-012` (04-vault-tokens.md:96) `mint(to, amount)` MUST revert with `OnlyAdapter` unless `msg.sender == adapter()`, with `ZeroAddress` if `to  — PROP-008, TEST-022 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_008_movementsOnlyOnAllowedPaths
- [~] `REQ-VTOKEN-013` (04-vault-tokens.md:97) The Adapter mints only inside a pledge, exactly the `credited` units Collateralization returns for the new rec — TEST-189
- [x] `REQ-VTOKEN-014` (04-vault-tokens.md:98) `burn(from, amount)` MUST revert with `OnlyAdapter` unless `msg.sender == adapter()`, with `ZeroAddress` if `f — PROP-055, TEST-022 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_055_burnNeedsNoAllowanceAndLowersExactly
- [x] `REQ-VTOKEN-015` (04-vault-tokens.md:99) Total supply MUST change only through `mint` and `burn`. (Source: Q-066, Q-224) — PROP-005, TEST-022 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_005_supplyChangesOnlyThroughAdapter
- [x] `REQ-VTOKEN-039` (04-vault-tokens.md:100) `addValidProxy(proxy)` MUST revert with `OnlyAdapter` unless `msg.sender == adapter()`, with `ZeroAddress` if  — PROP-009, TEST-188 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_009_registryAppendOnlyByAdapter
- [x] `REQ-VTOKEN-042` (04-vault-tokens.md:101) Because `burn` needs no allowance, a faulty or hostile Adapter implementation can destroy the units of any reg — PROP-009, PROP-055, TEST-022, TEST-188 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_055_burnNeedsNoAllowanceAndLowersExactly
- [~] `REQ-VTOKEN-016` (04-vault-tokens.md:105) At the end of every transaction, `totalSupply()` MUST be at most the sum of credited units of the market's ope — TEST-083, TEST-087
- [~] `REQ-VTOKEN-017` (04-vault-tokens.md:106) Between transactions vault tokens MUST rest only in the Hub, except seized units LPVaultSwap holds after a sei — TEST-022
- [~] `REQ-VTOKEN-018` (04-vault-tokens.md:107) The Hub's vault-token balance MUST equal the Hub's recorded liquidity for the asset after every Avana flow; no — TEST-022
- [~] `REQ-VTOKEN-019` (04-vault-tokens.md:111) Vault tokens MUST be deployed only by the chain's VaultTokenFactory, whose `deployVaultToken` reverts with `No — PROP-099, TEST-024, TEST-166
- [~] `REQ-VTOKEN-020` (04-vault-tokens.md:112) `deployVaultToken` MUST deploy with CREATE3 using `salt = keccak256(abi.encode(spoke, marketKey))`, where `mar — TEST-024
- [~] `REQ-VTOKEN-021` (04-vault-tokens.md:113) The factory MUST keep `tokenOf[spoke][marketKey]`, write it once in `deployVaultToken`, and revert with `Token — PROP-099, TEST-024
- [~] `REQ-VTOKEN-022` (04-vault-tokens.md:114) `deployVaultToken(integrationId, pool, poolId, shape, hub, spoke, marketId, lpOracle, decimals, name, symbol)` — PROP-099, TEST-024, TEST-138
- [~] `REQ-VTOKEN-023` (04-vault-tokens.md:115) The VaultTokenFactory MUST be non-upgradeable and hold no power over deployed tokens. Its `ADAPTER`, `LP_VAULT — PROP-099, TEST-024
- [~] `REQ-VTOKEN-024` (04-vault-tokens.md:116) The factory MUST emit `VaultTokenDeployed` for every token. (Source: Q-076) — TEST-024
- [~] `REQ-VTOKEN-038` (04-vault-tokens.md:117) The token's `marketId()` and `lpOracle()` MUST equal the `marketId` the MarketRegistry assigns to the market a — TEST-023, TEST-024
- [~] `REQ-VTOKEN-044` (04-vault-tokens.md:118) The factory's `registerIntegration(uint32 integrationId, address lpVault)` MUST revert with `NotTimelock` unle — PROP-099, TEST-024
- [~] `REQ-VTOKEN-046` (04-vault-tokens.md:120) The token's constructor MUST revert with `ZeroAddress` if any of `integration`, `hub`, `spoke`, `lpOracle`, `a — PROP-099, TEST-023, TEST-024
- [~] `REQ-VTOKEN-049` (04-vault-tokens.md:121) Market keys MUST be canonical: `registerIntegration` records the integration's `capabilities().poolKeying` and — PROP-099, TEST-024
- [~] `REQ-VTOKEN-050` (04-vault-tokens.md:122) Every vault token MUST be named so a holder and an indexer see the market without a lookup: the symbol is `avL — TEST-024
- [~] `REQ-VTOKEN-025` (04-vault-tokens.md:126) The token's transfer rule works together with the CDP Spoke and Hub configuration in [2.1](01-avana-hub-and-sp — TEST-185, TEST-189
- [~] `SPEC-UNIT-001` (04-vault-tokens.md:132) Decimals. `d` is the smallest integer in `[6, 18]` with `10^d · v ≥ $1`, where `v` is the USD value of one cre — PROP-099, TEST-023, TEST-024, TEST-264, TEST-265
- [x] `SPEC-UNIT-002` (04-vault-tokens.md:133) Unit. `1 base unit = 1 credited unit` of the market; for concentrated liquidity a credited unit is `10^k` unit — PROP-055, TEST-022 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_055_burnNeedsNoAllowanceAndLowersExactly
- [~] `SPEC-UNIT-003` (04-vault-tokens.md:134) Whole-token value. With the oracle price vector `p` (USD per whole market token, 8 decimals), one whole vault  — TEST-036
- [~] `SPEC-UNIT-004` (04-vault-tokens.md:135) Aave value of a balance. For `n` base units and `price8` (USD per whole token, 8 decimals), USD value `= n · p — TEST-071
- [~] `SPEC-UNIT-005` (04-vault-tokens.md:136) Hub cap unit. One Hub `addCap` unit is one whole token, `10^d` base units; `addCap · 10^d < 2^120` for every f — TEST-125
- [~] `SPEC-UNIT-006` (04-vault-tokens.md:137) Supply bound. `totalSupply ≤ min(units the AMM protocol can hold for the market, addCap · 10^d) < 2^120`, so n — TEST-071, TEST-125, TEST-279
- [~] `REQ-VTOKEN-026` (04-vault-tokens.md:175) A vault token MUST NOT be held by, minted to, or transferred to any address outside the Hub, LPVaultSwap and t — TEST-022, TEST-189
- [x] `REQ-VTOKEN-027` (04-vault-tokens.md:176) A vault token MUST NOT be minted or burned, and no proxy registered, by any address other than the AaveAdapter — PROP-005, TEST-022 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_005_supplyChangesOnlyThroughAdapter
- [~] `REQ-VTOKEN-028` (04-vault-tokens.md:177) A vault token MUST NOT be bound to more than one market, Hub or CDP Spoke, and no second token MUST ever be re — PROP-099, TEST-023, TEST-024
- [~] `REQ-VTOKEN-029` (04-vault-tokens.md:178) A vault token MUST NOT read from, call, or be configured by any other contract: it stores the Adapter's, LPVau — TEST-023
- [~] `REQ-VTOKEN-030` (04-vault-tokens.md:184) A transfer off the allowed paths of `REQ-VTOKEN-006`, or a zero-amount `transfer` or `transferFrom` on any pat — TEST-087, TEST-189
- [~] `REQ-VTOKEN-031` (04-vault-tokens.md:185) Transfer to the Hub from a registered proxy outside `Spoke.supply` | Accepted (the path is allowed); the units — TEST-022
- [x] `REQ-VTOKEN-032` (04-vault-tokens.md:186) `mint`, `burn` or `addValidProxy` called by anyone other than the Adapter | Reverts with `OnlyAdapter` (Source — PROP-005, TEST-022, TEST-188 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_005_supplyChangesOnlyThroughAdapter
- [~] `REQ-VTOKEN-033` (04-vault-tokens.md:187) `mint` to an address other than a registered proxy, or `burn` from an address other than a registered proxy or — TEST-022
- [~] `REQ-VTOKEN-034` (04-vault-tokens.md:188) Insufficient balance or allowance on an allowed path, including a `burn` above the holder's balance | Reverts  — TEST-022, TEST-189
- [~] `REQ-VTOKEN-035` (04-vault-tokens.md:189) `deployVaultToken` for a (Spoke, market key) pair that already has a token | Reverts with `TokenExistsForMarke — PROP-099, TEST-024
- [~] `REQ-VTOKEN-036` (04-vault-tokens.md:190) `deployVaultToken` for an unregistered integration, a zero Hub, Spoke or LPOracle, a pool key other than the o — PROP-099, TEST-024
- [~] `REQ-VTOKEN-037` (04-vault-tokens.md:191) `deployVaultToken` called by any address other than the AvanaTimelock | Reverts with `NotTimelock`; an operati — PROP-099, TEST-024, TEST-166
- [~] `REQ-VTOKEN-043` (04-vault-tokens.md:192) `mint` to, `burn` from or `addValidProxy` of `address(0)` | Reverts with `ZeroAddress` (Source: Q-224) — TEST-022, TEST-188
- [x] `REQ-VTOKEN-047` (04-vault-tokens.md:193) `addValidProxy` of `hub()`, `spoke()`, `adapter()`, `lpVaultSwap()`, `collateralization()`, `integration()`, ` — PROP-009, TEST-188 — VaultToken job 6bfe727afcd349819354fa4acf36fa35
- [~] `REQ-VTOKEN-045` (04-vault-tokens.md:194) `registerIntegration` by an address other than the timelock, for an ID or LPVault already registered, or for a — PROP-099, TEST-024

## TEST rows (19: 0 verified, 0 failed, 17 not run, 2 unlinked)

- [~] `TEST-171` [unit] Market identity from the vault token: during a pledge Collateralization takes the market ID and the LPOracle o
- [~] `TEST-186` [unit] Adapter mint equals credit: in `pledge` the AaveAdapter mints to the proxy exactly the `credited` that `Collat
- [~] `TEST-209` [unit] Withdrawal order: in `AaveAdapter.withdraw` the calls happen in this order, checked with `vm.expectCall` and a
- [~] `TEST-022` [access-control] Mint, burn and transfer authority: `mint(to, amount)` succeeds only from the AaveAdapter (`OnlyAdapter`) and o
- [~] `TEST-023` [unit] Token immutables: no owner, no setters, no pause, no upgrade, no permit, no hooks or callbacks; `marketKey()`,
- [~] `TEST-188` [unit] Proxy registry: `addValidProxy(proxy)` reverts `OnlyAdapter` for every caller other than the AaveAdapter (the 
- [~] `TEST-189` [unit] Path rule, negative cases and regression: transfers to the Adapter, the LPVault, Collateralization, the Borrow
- [~] `TEST-208` [unit] Seized-unit burn: `AaveAdapter.burnSeized(vaultToken, units)` reverts `NotLPVaultSwap` for any other caller an
- [~] `TEST-083` [invariant] Backing: for every market, vault-token `totalSupply()` is at most Collateralization's `getTotalCredited(vaultT
- [~] `TEST-086` [invariant] Hub side: the Hub's vault-token balance equals the Hub's recorded liquidity for that asset and the sum of Spok
- [~] `TEST-087` [invariant] Holders: at transaction end vault tokens sit only in the Hub and, for unsettled seizures of a hostile version,
- [~] `TEST-088` [invariant] Mint and burn authority: every mint is made by the AaveAdapter inside `pledge`, for exactly the credited units
- [~] `TEST-089` [invariant] Proxy binding and registry: only the ProxyManager deploys proxies, only on the AaveAdapter's call, each at `pr
- [~] `TEST-153` [invariant] Reconcile on exit: the handlers of `TEST-082` add hostile seize-and-keep, honest settlement of pending balance
- [ ] `TEST-109` [fork] Seizure proof (`Q-116`, `Q-144`) on the Avana-deployed Aave V4 with the full listing configuration and a stand (only excluded checks: tag on a test named for another row)
- [~] `TEST-180` [fork] Liquidation exclusivity on the standard CDP Spoke: `liquidationCall` from every address other than LPVaultSwap
- [~] `TEST-130` [hostile] Hostile AaveAdapter (blast radius): once executed, the hostile Adapter can borrow every debt reserve against e
- [ ] `TEST-133` [hostile] Hostile MarketRegistry and ParameterStore: remapping a market to an attacker pool, Spoke, vault token or debt  (only excluded checks: uses a stand-in for VaultToken)
- [~] `TEST-268` [fork] Drift checks for the standard CDP Spoke settings: for each listed Avana collateral reserve, the DAO executor s

## PROP rows (5: 5 verified, 0 failed, 0 not run, 0 unlinked)

- [x] `PROP-005` [Certora] Vault-token `totalSupply` increases only in `mint` with `msg.sender == adapter()` and decreases only in `burn` — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_005_supplyChangesOnlyThroughAdapter
- [x] `PROP-008` [Certora, Halmos] Every successful `transfer` or `transferFrom` has a non-zero amount and `isAllowedTransfer(from, to)`, that is — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_008_movementsOnlyOnAllowedPaths
- [x] `PROP-009` [Certora, Halmos] Each vault token's proxy registry changes only by `addValidProxy` with `msg.sender == adapter()`, never remove — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_009_registryAppendOnlyByAdapter
- [x] `PROP-043` [SMTChecker] The immutable contracts (every LPVault, Collateralization, vault token, VaultTokenFactory, ProxyManager, Posit — Lock job 0f0bbe338f844d87ba9968713df8b185
- [x] `PROP-055` [Certora] Vault token, any caller sequence: `totalSupply` changes only through `mint`/`burn` by `adapter()`; `burn(from, — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_055_burnNeedsNoAllowanceAndLowersExactly

## INV (15: 6 verified, 0 failed, 9 not run, 0 unlinked)

- [~] `INV-008` For every registered proxy `p` and market `m`: `Spoke.getUserSuppliedShares(reserveId_m, p) == Σ r.credited` o — PROP-045, TEST-010, TEST-085, TEST-107, TEST-150, TEST-151, TEST-153, TEST-154, TEST-185, TEST-190
- [x] `INV-009` `VaultToken.mint(to, amount)` succeeds only when called by the AaveAdapter (the token's immutable `adapter()`) — PROP-005, PROP-006, PROP-055, PROP-099, TEST-010, TEST-022, TEST-088, TEST-130, TEST-189 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_005_supplyChangesOnlyThroughAdapter
- [x] `INV-012` An address is a registered proxy of a market's vault token if and only if the AaveAdapter called `addValidProx — PROP-005, PROP-009, PROP-055, PROP-064, PROP-076, PROP-099, TEST-089, TEST-130, TEST-188, TEST-190 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_005_adapterOnlyFunctionsRefuseOtherCallers
- [~] `INV-013` A proxy's vault-token supply on the Spoke decreases only through (a) `Spoke.withdraw` called by the proxy thro — PROP-011, TEST-090, TEST-109, TEST-150, TEST-180, TEST-189, TEST-209
- [x] `INV-016` A PositionProxy is a logic-free immutable account. Its only state-changing function is `execute(target, data)` — PROP-010, PROP-033, PROP-056, TEST-025, TEST-031, TEST-032, TEST-130, TEST-172, TEST-187 — PositionProxy job 58d4d482ec8442e0ba96406d32591f0d
- [~] `INV-017` Collateralization and each LPVault obtain an AMM protocol's position manager and factory only from the LPVault — PROP-083, TEST-010, TEST-030, TEST-108, TEST-114, TEST-116, TEST-171, TEST-264, TEST-265
- [x] `INV-064` One proxy per (wallet, CDP Spoke, market). The chain's ProxyManager creates a PositionProxy only in `deployPro — PROP-064, PROP-076, TEST-025, TEST-089, TEST-190, TEST-211, TEST-271 — ProxyManager job 195a664988f54afa9c5ddd05dd0e92e0
- [~] `INV-069` Minimum pledge value. Every pledge and re-credit, for a new account and for a top-up alike, completes only if  — PROP-062, TEST-196, TEST-235
- [~] `INV-030` `LPVaultSwap.liquidate`, the only liquidation entry point (`INV-062`), admits any caller that is not a frozen  — PROP-022, PROP-066, TEST-049, TEST-055, TEST-160, TEST-174
- [x] `INV-083` Oracle minimum on every swap. Every call LPVaultSwap makes to a settlement or standby swap route passes `minOu — PROP-068, TEST-161, TEST-198, TEST-227, TEST-232 — DexPathRoute job 830e0ae334d84b7c912eb85e7bfad7fa
- [~] `INV-045` When the proxy has no debt on its Spoke (`spoke.getUserAccountData(proxy).borrowCount == 0`), the depositor's  — PROP-057, PROP-066, TEST-016, TEST-018, TEST-099, TEST-132, TEST-162, TEST-192, TEST-193, TEST-195, TEST-218, TEST-228, TEST-229
- [~] `INV-067` Pause-state effects. In every application pause state and pause reason, the liquidation entry point `liquidate — PROP-057, PROP-066, TEST-029, TEST-053, TEST-099, TEST-193, TEST-229, TEST-243
- [x] `INV-085` Address freeze bounds. `freezeAddress` never covers the protected set (the AvanaTimelock, the Aave governance  — PROP-071, TEST-229 — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [~] `INV-055` `LPOracle.latestAnswer()` never reverts and returns at least 1 (8 decimals) in every state (`SPEC-ORC-017`): t — PROP-023, PROP-027, PROP-074, TEST-036, TEST-038, TEST-105, TEST-217, TEST-219, TEST-230
- [~] `INV-099` An oracle switch never stops liquidation. For the life of a market, its LPOracle proxy stays both the Aave pri — TEST-284

## ATTACK (10: 0 verified, 0 failed, 7 not run, 3 unlinked)

- [~] `ATTACK-001` Duplicate LP Collateral Registration — TEST-010, TEST-011
- [~] `ATTACK-002` Liquidation Outside the Authorized Route — TEST-090, TEST-180, TEST-189, TEST-215
- [~] `ATTACK-018` Vault-token transfer to an unrestricted holder — TEST-189
- [~] `ATTACK-019` Detaching vault tokens from their NFT records — TEST-189
- [~] `ATTACK-023` Hostile AaveAdapter calls `liquidationCall` as an allowed holder — TEST-189
- [~] `ATTACK-124` Burning vault tokens held by the Hub or a victim proxy — TEST-130
- [ ] `ATTACK-125` Rogue proxy registration in a vault token
- [ ] `ATTACK-155` Third-party seizure through Spoke configuration on a standard Spoke
- [~] `ATTACK-181` Third-party seizure on a standard Spoke without the liquidation-manager variant — TEST-189
- [ ] `ATTACK-200` Aave turns off borrowing of a debt reserve

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
