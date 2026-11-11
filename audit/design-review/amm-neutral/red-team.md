# AMM-neutral architecture: red-team review

> **Status:** Design review · **Scope:** the proposed AMM-neutral layout (shared per-Hub AaveAdapter and LPVaultSwap, per-Spoke immutable LPVault and Collateralization, cross-Hub credit lines, pinned PositionProxy with opt-in migration, Uniswap v3 and Slipstream at launch, v2/Curve/Balancer/v4 later, standard Spoke with a transfer-restricted VaultToken as the alternative to the liquidation-manager Spoke) against `spec/02-contracts`, `spec/03-operations`, `spec/04-security/01-global-invariants.md` and `spec/04-security/02-attack-scenarios.md`.

Attacker set: borrower, keeper, LP, trader, MEV searcher, malicious token or pool, compromised role. Numbers marked *(script)* come from a Python run with `spec/05-verification/.venv`; the script is reproduced in [Appendix A](#appendix-a-numeric-checks).

## Summary

| ID | Severity | Attack | Spec today |
|---|---|---|---|
| AMMN-RT-01 | Critical | Narrow-range NFT credited at the market range's value per unit of liquidity (×979) | `INV-005(b)` is full-range only; no fixed-range rule |
| AMMN-RT-02 | High | LPPriceMath without clamping the oracle ratio to the range overvalues a depegged market (×2.97) | No requirement; full range has no edges |
| AMMN-RT-03 | High | Standard Spoke turns five code-level liquidation guarantees into Aave-side configuration | `ATTACK-002/014/021/120` rely on the liquidation-manager Spoke |
| AMMN-RT-04 | High | Pinned proxy migration: attacker implementation, unpatchable versions, two proxies per (wallet, Spoke) | `INV-063/064`, `REQ-PROXY-001` assume one beacon |
| AMMN-RT-05 | High | Per-Spoke ledgers multiply Hub-wide token, depositor and pool-share caps by the number of Spokes | `INV-027/028` scoped to one ledger |
| AMMN-RT-06 | High (later AMM protocols) | Uniswap v4 removal hooks keep the removed tokens or block removal | `INV-078` assumes removal returns the curve amounts |
| AMMN-RT-07 | High (later AMM protocols) | Read-only reentrancy and in-transaction pool-state manipulation in v2/Curve/Balancer fair-reserve models | `ATTACK-093` relies on "LPOracle reads no pool state" |
| AMMN-RT-08 | Medium | TWAP buffer sized for 12 s blocks; on Base a dust-swap griefer forces `OLD` and keeps the market Drifting for about $2 | `REQ-ORACLE-055` hard-codes 12 s |
| AMMN-RT-09 | Medium | Concentrated ranges unwind one-sided; route stress measured on two half legs doubles real slippage | `INV-078` listing stress assumes both legs |
| AMMN-RT-10 | Medium | Per-chain ProxyManager serving several per-Hub Adapters: cross-Hub proxy squatting and widened blast radius | `REQ-PROXY-051…053` single `ADAPTER` |
| AMMN-RT-11 | Medium | Cross-Hub credit lines: no registry sees every Spoke drawing a funding Hub asset; coverage cannot see foreign-Hub Spokes | `SPEC-HUB-003`, `INV-042`, `INV-057` |
| AMMN-RT-12 | Medium | A vault-token Hub asset attached to a second Spoke on a shared Hub drains or strands vault-token liquidity | `INV-003` assumes one Spoke per asset |
| AMMN-RT-13 | Medium | Shared per-Hub SettlementBudget window lets one Spoke's liquidations starve another's | `INV-037` global window vs `INV-075` no contagion |
| AMMN-RT-14 | Medium (Volatile Hub) | Tokenized stocks: market-hours feeds, corporate actions, holder allowlists | Partly `ATTACK-058/059` |
| AMMN-RT-15 | Low | v3/Slipstream configuration copy pairs the wrong NFPM, factory or pool implementation | `INV-005(b)`, `INV-017` name one canonical factory |
| AMMN-RT-16 | Low | Migration used to dodge an in-flight liquidation | No requirement |

---

## Findings

### AMMN-RT-01 — Narrow-range NFT credited at the market range's value (Critical)

**Preconditions.** A market with a fixed, non-full range (the proposal prices "over the market's fixed range"); the v3 intake path checks that the NFT's ticks lie *within* the market range, or checks only the pool, after "the v3 full-range check … move[s] out of Collateralization".

**Exploit.**
1. Market: stable pool, fixed range `[0.90, 1.10]`. Value per unit of liquidity at price 1: 0.097854 USD *(script)*.
2. Attacker mints a position one tick each side of the spot (`tickSpacing` 1) with $10,000 of tokens. Its liquidity is `L = 100,007,500` *(script)*.
3. Pledges it. Collateralization credits `L` units; LPOracle prices each unit at the market range: $9,786,145, ×979 *(script)*.
4. Borrows up to the caps (`marketUsdCap`, `depositorUsdCap`) and walks away. Liquidation recovers about $10,000.

**Why the spec does not stop it.** `INV-005(b)` and `ATTACK-004` require "the pool's minimum and maximum usable ticks". With fixed ranges that rule must become exact equality with the market's ticks; no requirement says so, and a unit of liquidity is worth a different amount in every range.

**Fix.** Each AMM intake contract states its exact identity predicate. For v3 and Slipstream: `tickLower == market.tickLower ∧ tickUpper == market.tickUpper`, both multiples of the pool's `tickSpacing`, pool derived through the market's factory equals `vaultToken.pool()`. A vault token binds one range; the range is a constructor immutable of the vault token and the LPOracle.

**Verification.** Foundry fork test: pledging any NFT whose ticks differ from the market's by one `tickSpacing` reverts (`RangeMismatch`); Hypothesis property over random `(tickLower, tickUpper)` that the intake predicate accepts exactly one pair; prover rule `pledge succeeds ⇒ ticks(r.tokenId) == market.ticks`.

### AMMN-RT-02 — Oracle ratio outside the range priced without clamping (High)

**Preconditions.** LPPriceMath computes `x = L(1/√P − 1/√pb)`, `y = L(√P − √pa)` at the oracle ratio `P` without first clamping `√P` to `[√pa, √pb]`, and floors a negative amount at 0 (or uses signed math).

**Exploit.**
1. Market range `[0.99, 1.01]`; token1 depegs to $0.952, so the oracle ratio is 1.05, above the range.
2. A position of `L = 1,000,000` holds 10,000 token1, worth $9,524. Unclamped math gives `y = 29,708`, `x = −19,137 → 0`: value $28,293, ×2.97 *(script)*.
3. Attacker buys depegged token1, mints positions in the range (they are all token1), pledges and borrows against 2.97× their value exactly while the depeg runs and liquidation routes are thin.

The same class covers decimals and token order: forgetting `10^(d1−d0)` for DAI/USDC (18/6 decimals) mis-scales the ratio by 10¹², and the value by up to 10⁶.

**Why the spec does not stop it.** `SPEC-ORC-*` and `INV-078` are written for full range, where no edge exists.

**Fix.** Add a `SPEC-ORC` rule: `√P_oracle = √(v0 · 10^d1 / (v1 · 10^d0))` in Q64.96, rounded down, then clamped to `[sqrtRatio(tickLower), sqrtRatio(tickUpper)]`; amounts by Uniswap `getAmountsForLiquidity` rounding down. State the general property: the served value is `min` over reachable holdings of `x·v0 + y·v1`. That minimum is monotone in each price, so the stable ceiling `SPEC-ORC-004` stays conservative.

**Verification.** Hypothesis property (random ranges, decimals 0–24, both token orders, prices on and off range): LPPriceMath value ≤ removal value at every pool price. The script's 20,000-sample run of the clamped formula passes *(script)*. Add a Z3 model of the clamp branch and a SymPy proof that `dV/dP = L(1 − p*/P)/(2√P)` has its minimum at the clamped oracle ratio.

### AMMN-RT-03 — Standard Spoke reopens attacks the liquidation-manager Spoke closes in code (High)

**Preconditions.** CDP Spokes are standard Aave V4 Spokes whose configuration roles (reserve config, liquidation config, dynamic config, upgrades) sit with the Aave DAO or its stewards rather than the Avana timelock.

**What changes.** The liquidation-manager Spoke reverts in code for: any caller other than LPVaultSwap (`ATTACK-002`), `receiveShares = true` (`ATTACK-021`), a borrowable vault-token reserve (`REQ-PROXY-009`), and any debt reserve outside `APPROVED_DEBT_RESERVES` (`INV-073`). Its only-LPVaultSwap rule also gates deficit reports (`INV-041`). On a standard Spoke, the VaultToken recipient rule (`INV-011`) is the only code barrier, and it sees only token transfers.

**Exploit (shares path, one configuration change away).**
1. `receiveSharesEnabled` is set true on a vault-token reserve (steward mistake, governance proposal or compromised role).
2. In the same block, attacker calls `Spoke.liquidationCall(vaultReserve, ghoReserve, victimProxy, 100,000, true)`. No vault token moves, so `INV-011` never runs. Attacker's own Spoke position gets shares worth 105,000 (LB 1.05).
3. Attacker borrows GHO directly on the Spoke against those shares: 100,800 at CF 0.96 (+800 net), or 102,300 at LB 1.10 and CF 0.93 *(script)*. Even at LB × CF < 1 (−5,500 at CF 0.90) the loan is bad debt: LPVaultSwap refuses the attacker's account (`UnknownProxy`), and no other liquidator can receive vault tokens.
4. The victim's records still show the seized units; they reach pending settlement only at the victim's exit (`INV-058`).

The same holds for a non-zero `liquidationFee` (`ATTACK-014`: fee shares with no record) and for a vault-token reserve made borrowable. The RiskModule drift check (`INV-029`) stops new risk only after the change; it cannot stop the attack in the change's block.

**Fix.** Keep the liquidation-manager Spoke (preferred). If a standard Spoke is used, every Spoke configuration and upgrade role must be held only by the Avana timelock, verified on-chain by the drift check (`AccessManager` role holders) and at `deployCdpSpoke`. Also require on every V4 Spoke version that `collateralFactor × maxLiquidationBonus < 1`.

**Verification.** Foundry fork test on the pinned V4 standard Spoke: flip each flag, attempt the attack, and assert either a revert or that the flag change cannot execute outside the Avana timelock. Add a Quint model of role holders × config flags with the property "no vault-token shares are held by a non-proxy".

### AMMN-RT-04 — Pinned proxies with opt-in migration (High)

**Preconditions.** "Pinned implementation per proxy (CREATE2) … A new version needs opt-in migration", with the mechanism unspecified.

**Exploits.**
- **(a) Attacker-chosen implementation.** If migration accepts an implementation address from the wallet, the attacker's own code becomes a registered proxy (`INV-012` is append-only). It can then:
  - borrow directly on the Spoke, skipping freshness, `minOpeningHealthFactor`, rescue units (`INV-082`) and pause checks;
  - withdraw vault tokens to itself and pass them to any other registered proxy;
  - on a standard Spoke, call `liquidationCall` and legally receive seized vault tokens (`ATTACK-022`, now reopened).

  A phishing "upgrade your account" page is enough.
- **(b) Unpatchable bug.** A missing `OnlyAdapter` in version *n* can no longer be fixed by one `setProxyImplementation`. Every proxy that does not migrate stays exploitable, because the Adapter is not on the path of a direct call.
- **(c) Two accounts per (wallet, Spoke).** A CREATE2 address over init code that embeds the implementation changes with each version. `predictProxy(w, s)` then names a new address, which breaks `INV-064` and the `r.proxy == proxyOf(depositor, spoke)` check of `INV-005(c)`.
- **(d) Records must change proxy.** Aave V4 has no position transfer, so migration must burn from the old proxy, mint to the new one, and rewrite `r.proxy`. `INV-005(d)` forbids that in the immutable ledger.

**Fix.**
- Implementations come only from a timelock allowlist keyed by code hash, and the latest version is installed at creation.
- The proxy init code is constant (implementation read from the ProxyManager at construction), so the address depends only on `(wallet, spoke)`.
- Migration is an Adapter-mediated atomic operation, sketched in [Appendix B](#appendix-b-migration-sketch), that checks same wallet, Spoke and ledger, equal debt and units before and after, HF not lower, and an allowlisted target version. It runs only when HF ≥ `minOpeningHealthFactor` and only to a higher version.
- Add an Adapter-side per-version block on new risk, and treat each pinned version as permanent: it gets the full selector inventory, formal verification and the `REQ-PROXY-007/008` checks.

**Verification.** Certora rule `isValidProxy(p) ⇒ codehash(p) ∈ allowlist ∧ p == predictProxy(wallet(p), spoke(p))`; Foundry invariant test across a v1→v2 migration (supply shares, debt, records, registry); Quint model of migration interleaved with liquidation.

### AMMN-RT-05 — Hub-wide caps fragment across per-Spoke ledgers (High)

**Preconditions.** One market per CDP Spoke, with an immutable Collateralization ledger per Spoke holding the counters of `INV-027` and checking `INV-028`.

**Exploit.** `tokenUsdCap[USDT]` = $10M, intended to bound USDT tail exposure on the Stable Hub. USDC/USDT, USDT/DAI and USDT/GHO are three Spokes, so three ledgers each admit $10M. Through ordinary pledges (or one whale through `depositorUsdCap`), USDT exposure reaches $30M. Two markets on one pool with different ranges likewise double the pool-share cap. On a USDT depeg, routes sized for $10M must absorb $30M at once; the shortfall becomes Stable Hub bad debt (`INV-074` holds only while realizable value tracks the caps).

**Why the spec does not stop it.** The counters are per ledger. No requirement aggregates token, depositor or pool exposure across Spokes of a Hub.

**Fix.** A per-Hub exposure accumulator, immutable, written only by ledgers registered for that Hub at `deployCdpSpoke`. Every pledge, top-up, re-credit and debit updates the Hub-wide token, depositor and pool counters, and `INV-028` checks against them. Alternatively, partition each Hub-wide cap into per-Spoke caps whose sum is checked at listing.

**Verification.** Quint model with N ledgers and one accumulator: Hub-wide counter == Σ over ledgers, always ≤ cap. Hypothesis stateful test across two ledgers sharing a token. Z3 check that per-Spoke partitions sum ≤ Hub cap at every `listCollateralMarket`.

### AMMN-RT-06 — Uniswap v4 hooks on liquidity removal (High, later AMM protocols)

**Exploit.**
- A pool whose hook has `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA` keeps part or all of every removal. At 1%, realizable 9,876 vs oracle 9,975; at 100%, 0 vs 9,975 *(script)*. Pledge, borrow at full oracle value, and liquidation returns nothing.
- A `beforeRemoveLiquidity` hook that reverts (or turns on a revert later, if upgradeable) makes every position in the pool unliquidatable.
- Dynamic-fee hooks reprice routes that use the pool. Native-ETH currencies add payout reentrancy (`ATTACK-094`).

**Why the spec does not stop it.** `INV-078` assumes removal returns the curve amounts.

**Fix.** List only pools with `hooks == address(0)`, or hooks whose address permission bits clear every remove-liquidity flag (`BEFORE_/AFTER_REMOVE_LIQUIDITY`, `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA`), with no upgrade path and a pinned code hash. Make the v4 intake check the `PoolKey` hook bits on-chain.

**Verification.** Foundry fork test with a hostile hook: listing and pledge revert. Prover rule: `market listed ⇒ hookFlags & REMOVE_MASK == 0`.

### AMMN-RT-07 — Pool-state reads in v2/Curve/Balancer fair-reserve models (High, later AMM protocols)

**Exploit.** Fair reserves read the invariant and supply from live pool state. The protection of `ATTACK-093` ("LPOracle reads no pool state") then no longer applies.
- **Curve read-only reentrancy.** In a pool that sends native ETH inside `remove_liquidity` before balances settle, the attacker's `receive` calls `AaveAdapter.borrow`. The LPOracle reads D and supply mid-update (the 2023 virtual-price class) and values every unit of the market high. Avana's Lock does not see the pool's own lock.
- **Balancer v2.** The same pattern inside a join or exit callback. Also, `totalSupply` vs `getActualSupply` on composable pools (pre-minted BPT, unminted protocol-fee BPT) misstates effective supply.
- **Rate providers and ERC-4626 tokens** (Curve-NG, Balancer). Donating to the 4626 vault raises the stored rate, so D and the LP value jump inside one transaction.
- **Uniswap v2 with `feeOn`.** The protocol-fee mint pending since `kLast` is missing from `totalSupply`, so LP value is overstated until the next mint or burn.

**Fix.** A per-AMM reentrancy probe before every read:
- Curve: a cheap non-reentrant call per pool type, for example `remove_liquidity(0, [0, 0])` or `claim_admin_fees`, chosen and fork-tested at listing;
- Balancer v2: `VaultReentrancyLib.ensureNotInVaultContext`;
- v4: PoolManager must be locked (`exttload`).

Also: use effective supply including pending protocol-fee mints; list no rate-provider or 4626 tokens unless the rate itself comes from an approved, capped feed.

**Verification.** Foundry fork tests replaying each reentrancy against a listed pool type. SymPy derivation of v2 effective supply with `kLast`. A Hypothesis property that the fair-reserve value is unchanged by any single in-transaction donation that the model excludes.

### AMMN-RT-08 — TWAP buffer sized for 12-second blocks; cheap Drifting on Base (Medium)

**Exploit.** `REQ-ORACLE-055` sets observation cardinality `n ≥ ⌈twapWindow/12⌉ + 1`. With `W = 1,800 s`, `n = 151`, which covers only 302 s on 2-second Slipstream blocks; the requirement there is 901 *(script)*. The attacker makes one dust swap per block for 151 blocks (about $2 of Base gas). `observe([W, 0])` then reverts `OLD`, and the market is Drifting (`REQ-ORACLE-014`). That blocks new-account pledges and new borrowing, and the served price drops to `min(fresh, A)` for every account in the market. Repeating keeps the market Drifting indefinitely. Slipstream's `slot0` has a different field count from v3, so v3-ABI decoding there also reverts into Drifting.

**Fix.** `n ≥ ⌈W / chainBlockTime⌉ + 1`, with `chainBlockTime` an immutable per chain (Base 2 s); per-AMM pool readers with their own `slot0` ABI.

**Verification.** Foundry Base fork test: grief for `n` blocks, then `observe(W)` succeeds. A Z3 check of the cardinality inequality for each chain's block time.

### AMMN-RT-09 — One-sided unwind at range edges vs two-leg route stress (Medium)

**Exploit.** A concentrated position at or beyond its range edge is 100% one token. The listing stress assumes two legs of about V/2. In a constant-product route of depth 10V, two V/2 legs lose 4.76% each, but one V leg loses 9.09% *(script)*. Even with `s = 5%`, the per-leg `minOut` of `INV-083` fails.

An attacker pushes spot past the edge just before a liquidation (cheap for a narrow range: only the in-range liquidity must be crossed). Every keeper attempt then reverts or needs a shortfall top-up or budget. Positions that keep slipping toward bad debt during a depeg are exactly the ones that are one-sided.

**Why the spec does not stop it.** `ATTACK-065` covers spot moves for full range, which never go one-sided.

**Fix.** At listing and in the route-depth monitor, stress each token's route with the full position value V (the single-token composition at each edge), not V/2.

**Verification.** Simulation (`spec/05-verification/simulation`) over pool price paths crossing both edges: recovery ≥ floor. Foundry fork test of the edge unwind at listing stress size.

### AMMN-RT-10 — Per-chain ProxyManager serving per-Hub Adapters (Medium)

**Exploit.** Today `deployProxy` accepts one immutable `ADAPTER` (`REQ-PROXY-051…053`). With a per-chain ProxyManager and an Adapter per Hub, a naive "any registered Adapter" check lets Hub A's Adapter (buggy or hostile after an upgrade) deploy `(wallet, spokeOfHubB)` first, with its own Adapter baked into the pinned implementation. Hub B's Adapter then finds that address taken by a proxy that rejects it. That is a permanent denial of service for the wallet on Spoke B, or control of the account by the wrong Adapter. `INV-018`'s blast radius per Adapter spreads across Hubs.

**Fix.** The ProxyManager stores `adapterOf[spoke]`, set only by the timelock at `deployCdpSpoke`. `deployProxy` requires `msg.sender == adapterOf[spoke]`; the salt binds `(wallet, spoke)`, and the Spoke binds the Hub.

**Verification.** Certora rule: `deployProxy(w, s)` succeeds only from `adapterOf[s]`, and `ADAPTER(proxy) == adapterOf[spoke(proxy)]`. Foundry test of cross-Adapter deployment.

### AMMN-RT-11 — Cross-Hub credit lines and coverage (Medium)

**Exploit.**
- `SPEC-HUB-003`/`INV-057` require `Σ_s drawCap ≤ creditLine` over "every Avana Borrow Spoke", but the MarketRegistry is per Hub. Suppose the Stable Hub registry approves its Spokes up to the USDC line, and the Volatile Hub registry approves a Volatile Spoke drawing Stable Hub USDC. Neither registry sums the other's Spokes, so Stable Hub suppliers carry more than the approved line, including volatile-collateral shortfall risk.
- Deficits from the Volatile Spoke land on the Stable Hub. The Stable Hub's Coverage Spoke (`INV-042`) recognises only Spokes in its own registry, so the deficit stays uncovered. Or, if coverage trusts any Spoke the caller names, it can be spent outside Avana (`ATTACK-090`).

**Fix.** The credit-line check reads the funding Hub's own Spoke list on-chain (Spoke count, each Spoke's `drawCap` on the asset). It runs in `enableDebtReserve` and in the drift check. The funding Hub's registry records every foreign CDP Spoke that draws from it, written by the same timelock operation that enables the debt reserve.

**Verification.** Z3 model: Σ over the Hub's Spoke list ≤ `creditLine` after every `enableDebtReserve` and cap change. Foundry fork test with two Hubs and one shared asset.

### AMMN-RT-12 — Vault-token Hub asset attached to a second Spoke (Medium)

**Exploit.** On a shared Hub that also hosts the Lend Spoke, Coverage Spokes and other CDP Spokes, the Hub admin attaches vault-token asset `m` to a second Spoke with a non-zero `drawCap`. That Spoke draws vault tokens out of the Hub to an allowed recipient: a registered proxy or LPVaultSwap. Then:
- the Hub holds fewer tokens than the proxies' supplied shares, so proxy withdrawals and LPVaultSwap's seizure (`Hub.remove`) revert, and the market is unliquidatable;
- tokens sent to LPVaultSwap look like pending balance (`INV-003`: `totalSupply − balanceOf(LPVaultSwap)`).

**Why the spec does not stop it.** `INV-003` silently assumes one Spoke per vault-token asset.

**Fix.** Drift check and listing check: the Hub's Spoke count for `assetId_m` is 1 and that Spoke is `vaultToken.spoke()`. The Adapter and LPVaultSwap take the Spoke only from `vaultToken.spoke()`.

**Verification.** Foundry fork test: attach a second Spoke, then the drift check blocks new risk and the alarm fires. Prover rule on the drift-check predicate.

### AMMN-RT-13 — Shared settlement-budget window across Spokes (Medium)

**Exploit.** `INV-037` caps all draws at `PER_24H_CAP_MAX` = 20,000 GHO per rolling day, and the budget is now shared by every CDP Spoke on the Hub. A busy liquidation day in one low-quality market (or a keeper farming small draws within per-pair caps) uses the whole window. Liquidations in other Spokes that need a draw then revert or fall to permissionless mode, which cannot draw (`INV-062`). That is contagion, which `INV-075` says cannot happen.

**Fix.** A per-Spoke share of the global window (`perSpoke24hCap`, Σ ≤ `PER_24H_CAP_MAX`), or one SettlementBudget per CDP Spoke.

**Verification.** Z3 check of the partition sum. Quint model of two Spokes draining the window concurrently.

### AMMN-RT-14 — Tokenized stocks in the Volatile Hub (Medium)

**Attack surface.**
- Chainlink equity feeds pause outside market hours. `feedMaxAge` must exceed a long weekend, so a feed can be stale yet valid while the 24/7 DEX price moves.
- Stock splits and dividends may be implemented as rebases, mints or price adjustments that the feed and the pool see differently.
- Issuers often restrict holders, so LPVaultSwap or a route may be refused (`ATTACK-058`).

**What blocks it today.** The TWAP consistency check (`REQ-ORACLE-014`) blocks borrowing when the DEX pool diverges by more than `τ`, but only if the pool is liquid enough to track the true price.

**Fix.** Market-hours-aware feeds: block new risk when the reference market is closed. Require each token's issuer to allowlist LPVaultSwap, the routes and the vault before listing, with a fork test. Add a corporate-action runbook that offboards the market ahead of the event.

**Verification.** Foundry fork test with a closed-market feed. Simulation of weekend gaps of 10–40% against LTV.

### AMMN-RT-15 — NFPM, factory and pool-implementation mismatch in copied configuration (Low)

**Exploit.** "A new market of an existing AMM type reuses the contract code and copies the deployment config." On Base both Uniswap v3 and Slipstream exist, Slipstream has several factory versions, and v3 forks share the interfaces. A copied config can pair a Slipstream NFPM with a v3 factory, or the reverse. `getPool(t0, t1, 100)` resolves to different pools in each (fee 100 vs `tickSpacing` 100). In the worst case, the market binds a thin attacker-seeded fork pool.

**Fix.** At deployment, check:
- `NFPM.factory() == factory` and `pool.factory() == factory`;
- `factory.getPool(t0, t1, param) == pool`;
- the pool code hash (v3: `POOL_INIT_CODE_HASH` derivation; Slipstream: a clone of `factory.poolImplementation()`);
- the per-AMM decoders of `positions()` and `slot0`.

**Verification.** Foundry fork tests per chain that load the manifest and assert each equality.

### AMMN-RT-16 — Migration as a liquidation dodge (Low)

**Exploit.** A borrower with HF < 1 front-runs the keeper by migrating to a new proxy version, so the keeper's `liquidate(oldProxy, …)` reverts. This works once per version.

**Fix.** Migration requires HF ≥ `minOpeningHealthFactor` (part of AMMN-RT-04's fix).

**Verification.** Foundry test: migration at HF < threshold reverts.

---

## Attacks tried that the design already blocks

| Attempt | Blocked by |
|---|---|
| Settle a Spoke-A vault token against a Spoke-B proxy through the shared LPVaultSwap | `INV-030` (`UnknownProxy`: proxy must be registered in that token) and `INV-017` (ledger accepts a token only if `collateralization() == this`) |
| Pledge into Spoke B with Spoke A's vault token through the shared Adapter | `REQ-ADAPTER-065` (`vaultToken.spoke() == spoke`) |
| Pledge one NFT into two Spokes' vaults | Custody: `ownerOf` is unique; `INV-005(a)` |
| Third-party `liquidationCall` on a standard Spoke with `receiveShares = false` | `INV-011` recipient rule (the share path is AMMN-RT-03) |
| Flash-loan spot move to inflate the fair-composition quote, including fixed ranges | `INV-078` and `ATTACK-040`; the minimum at the oracle ratio also holds for clamped fixed ranges (20,000 random samples, Appendix A) |
| Stable $1 ceiling distorting a concentrated quote | `SPEC-ORC-004`: the value is a minimum of linear functions with non-negative amounts, so monotone in each price |
| Donated liquidity to break debits or inflate caps | `INV-002`, `INV-006`, `ATTACK-016/017` |
| `onERC721Received` reentrancy on NFT return | `INV-007` (`transferFrom`, no callback); the proxy has no `onERC721Received` (`REQ-PROXY-007`) |
| Proxy as position manager or ERC-1271 signer to bypass the Adapter | `REQ-PROXY-007/008`; must be re-checked for every pinned version (AMMN-RT-04) |
| Spoofed flash-mint or swap callback | `INV-040` |
| Sandwiching the unwind's conversion swaps | `INV-083` per-leg oracle `minOut`, `INV-034`, `ATTACK-067/115` |
| Borrower front-running the keeper by repaying | `ATTACK-060` |
| Taking the depositor's uncollected fees in a liquidation | `INV-033` |
| Malicious-token callback re-entering Avana mid-liquidation | `INV-054` Lock; Collateralization views revert under the Lock. Cross-Hub re-entry finds no shared mutable state, because Locks, ledgers and budgets are per Hub or per Spoke |
| Permissionless liquidator draining the SettlementBudget | `INV-062` (no draw in permissionless mode) |

## Appendix A — numeric checks

Run with `spec/05-verification/.venv/bin/python -I rt_demo.py`. Output:

```
== 1. Clamp: oracle ratio outside the market range ==
clamped  x=0.0 y=10000.1 value=9523.9
unclamped x=-19137.1 (negative) y=29707.6; value with x floored at 0 = 28293.0
min realizable value over all pool prices = 9523.9; overvaluation x2.97
== 2. Range mismatch: narrow position priced with the market's range ==
value/L market range=0.097854, narrow=0.00009999; $10,000 narrow position has L=100,007,500
priced as market range: $9,786,145 -> x979
== 3. INV-078 generalised to a fixed range (random check) ==
min(removal value - oracle-ratio value) over 20k samples: OK (>=0)
== 4. Route stress: 50/50 legs vs one-sided at a range edge ==
two legs of V/2: slippage 4.76% each; one leg of V: 9.09%
== 5. TWAP observation buffer on a 2 s chain ==
n = ceil(W/12)+1 = 151; covers 302 s on 2 s blocks (needs 1800); required n >= 901
== 6. receiveShares path: liquidator borrowing directly against seized shares ==
LB=1.05 CF=0.9: pays 100,000, borrows 94,500 unliquidatable -> net -5,500; bad debt 94,500
LB=1.05 CF=0.96: pays 100,000, borrows 100,800 unliquidatable -> net +800; bad debt 100,800
LB=1.1 CF=0.93: pays 100,000, borrows 102,300 unliquidatable -> net +2,300; bad debt 102,300
== 7. v4 removal hook taking a delta ==
hook keeps 1% of removed amounts: realizable 9,876 vs oracle value 9,975
hook keeps 100% of removed amounts: realizable 0 vs oracle value 9,975
```

```python
import math, random
def amounts(L, P, pa, pb, clamp=True):
    s, sa, sb = math.sqrt(P), math.sqrt(pa), math.sqrt(pb)
    if clamp:
        s = min(max(s, sa), sb)
    return L*(1/s - 1/sb), L*(s - sa)
def value(x, y, p0, p1): return x*p0 + y*p1
# 1. clamp: range [0.99, 1.01], p0 = 1, p1 = 1/1.05; compare clamped, unclamped (x floored at 0), and the
#    minimum of value(amounts(L, P)) over pool prices P.
# 2. range mismatch: value per L at P = 1 for [0.90, 1.10] vs [1.0001^-1, 1.0001]; L of a $10,000 narrow position.
# 3. 20,000 random (pa, pb, p0, p1, P): value(amounts(1, P)) >= value(amounts(1, p0/p1)).
# 4. constant-product loss S/(X+S) with X = 10V for S = V/2 and S = V.
# 5. n = ceil(1800/12)+1 observations x 2 s.
# 6. D = 100,000; seized = D*LB; loan = seized*CF.
# 7. hook keeps 1% and 100% of the removed amounts.
```

## Appendix B — migration sketch

```
migrate(spoke, targetVersion):
    require targetVersion ∈ timelockAllowlist ∧ targetVersion > version(oldProxy)
    require HF(oldProxy) ≥ minOpeningHealthFactor
    flash debt D_r for each debt reserve r → repay oldProxy
    oldProxy.withdrawCollateral(all) → Adapter burns from oldProxy, mints to newProxy, newProxy.supplyCollateral
    ledger.migrateProxy(oldProxy, newProxy)   # Adapter-only; wallet, spoke, ledger unchanged
    newProxy.borrow(D_r) for each r → repay flash
    assert units, debts equal; HF(newProxy) ≥ HF(oldProxy)
```
