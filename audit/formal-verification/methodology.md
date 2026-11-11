# Formal verification methodology

> **Status:** In review · **Owner:** Avana Labs · **Last reviewed:** 2026-11-09

This page sets out how Avana verifies its contracts formally:

- the three verification areas;
- the property families each area proves;
- the bug classes each family is designed to catch;
- the assumptions every proof states;
- the format of the internal verification reports;
- the ordered list of properties proved before external audit.

The property identifiers `PROP-001` onward live in [5.2 Formal Properties](../../spec/05-verification/02-formal-properties.md). The CVL sources live in [`contracts/certora/`](../../contracts/certora/), and one evidence file per property goes in [`audit/formal/`](../formal/). This page defines what those properties must cover and how their results are reported.

## 1. Verification areas

Avana's contracts are verified in three areas. Each area owns its contracts, its CVL configurations and its report.

| Area | Contracts | What the area protects |
|---|---|---|
| **custody** | Collateralization, VaultToken, VaultTokenFactory, LPVault, AaveAdapter mint and burn paths, PositionProxy collateral movement | Every vault-token unit is backed by a credited unit of a position its AMM protocol's LPVault holds. One position, keyed by (`integrationId`, `positionKey`), backs one record. Supply, records, proxy shares and Hub assets agree, per vault token, and the Hub-wide caps are one counter per Hub. |
| **liquidation** | LPVaultSwap, SettlementMath, settlement routes, SettlementBudget, Coverage Spoke, PayoutEscrow | A liquidation:<br>• seizes only what the Spoke sized;<br>• conserves GHO;<br>• recovers at least the floor;<br>• draws the budget only within caps;<br>• records and covers bad debt only through the allowed path. |
| **control** | AaveAdapter gates, RiskModule, PositionProxy and ProxyManager binding, MarketRegistry, ParameterStore, LPOracle with LPPriceMath, Lock (two members), Lens, AvanaTimelock, UUPS upgrade paths, standard-Spoke drift settings, IFlashSource | Only the right role reaches each selector, through the right delay. Pause and oracle states gate exactly the actions the spec names. Exits and repay stay live. Upgrades cannot corrupt storage or re-run initializers. |

Calls cross areas. For example, a liquidation's seized-unit burn is a custody fact, but it is reached through LPVaultSwap. A cross-area property belongs to the area named in its target row (section 6). The other area imports it as a proved summary, never as an unproved assumption.

## 2. How a property is proved

### 2.1 Tools

| Tool | Used for | Strength | Limit stated in the report |
|---|---|---|---|
| Certora Prover (CVL) | Parametric rules over every external function; inductive invariants; ghost sums; storage comparison between two executions | Unbounded inputs and arbitrary prior state for invariants | Loop unrolling bound, summaries, hashing bound |
| Halmos | Arithmetic and library lemmas (SettlementMath, LPPriceMath, share and charge math); short call sequences | Bit-precise on the real bytecode | Loop bound, call depth, bytes lengths |
| Solidity SMTChecker | No overflow, underflow, division by zero or failing `assert` in immutable contracts (`PROP-043`, `PROP-044`) | Whole-contract, no harness | Engine timeouts are reported as unproved, never as proved |
| Foundry invariant fuzzing (stateful handlers) | Cross-contract invariants on a mainnet fork with the real Aave V4 Hub and Spoke | Real external code, long sequences | Evidence within bounds, not proof |
| Spec-stage models (Z3, SymPy, Quint, Hypothesis in [`spec/05-verification/`](../../spec/05-verification/)) | Every formula before code exists | Exact integer and real arithmetic | Model-to-code gap, closed by the implementation-stage property |

### 2.2 Proof styles

- **Parametric rule.** `method f; env e; calldataarg args; f(e, args);` with assertions over the state before and after. Use it when the property must hold for every entry point, such as access control, non-interference or monotonicity.
- **Inductive invariant.**
  - The invariant is proved on the constructor or initializer and preserved by every function.
  - Other rules may assume it only through `requireInvariant`.
  - A shared helper `requireAllInvariants(...)` lists every invariant a rule assumes, so the assumption set is visible in one place.
- **Ghost mirror and sum.**
  - Each mapping that participates in a sum gets a ghost written by an `Sstore` hook and checked by an `Sload` hook (`require ghost == value`).
  - Sums use `usum` or a hook-maintained running total that starts at 0 (`init_state axiom`).
- **Two-execution comparison.**
  - Save `storage init = lastStorage`, run one sequence, then run another sequence `at init` and compare the results.
  - Splitting, idempotency and front-running rules use this shape.
- **Witness.**
  - Every rule whose premise is non-trivial carries a `satisfy` statement showing the success path is reachable.
  - `rule_sanity: basic` is on in every conf. A vacuous rule counts as a failed rule.
- **Mutation check.**
  - For each family, the report lists at least one injected mutant from that family's bug class, and the rule must catch it.
  - Mutants include: flip a rounding direction, drop a role check, skip a lock acquire, reorder a state write after an external call, remove a cap check.
  - A rule that catches no mutant is rewritten.

### 2.3 Summaries are proved, not trusted

Every summary used in a contract rule is either:

- proved against the real code in its own rule, as a library-equivalence rule (family F-24); or
- discharged by another conf, as the setup models in `contracts/certora/specs/setup/` already are.

Examples:

- A `mulDiv` summary that returns a free value `r` with `r × d ≤ x × y` (round down) or `r × d ≥ x × y` (round up) is proved against OpenZeppelin `Math.mulDiv` before any rule relies on it.
- The Aave model's "Hub shares equal assets for the vault-token asset" is `PROP-040` on the real Hub at `a3ef63e`.
- A summary nothing proves is listed in the report under "Unproved assumptions", together with the fork test or monitoring that covers it.

## 3. Property families

Each family has five parts:

- a definition;
- the rule shape, in CVL-style pseudocode;
- the bug classes it catches, with public examples;
- the Avana contracts it applies to;
- the target rows in section 6.

### F-01 Functional integrity

**Definition.** Each state-changing entry point changes exactly the fields its spec names, by exactly the specified amount, and nothing else.

```
rule pledge_integrity(env e, bytes32 positionKey) {
    uint128 L = unitsAfterCustody(positionKey);
    mathint supplyBefore = vaultToken.totalSupply();
    pledge(e, positionKey, ...);
    assert vaultToken.totalSupply() == supplyBefore + L;
    assert recordOf(positionKey).credited == L;
    assert vaultToken.balanceOf(hub) - hubBefore == L;   // supplied through the proxy
}
```

**Catches:** wrong formula, wrong token, wrong recipient, missing field update. Public examples:

- **Compound III (Certora 2022, Critical):** `principalValue` computed wrongly. ([report](https://certora.cdn.prismic.io/certora/e7ca6508-fad8-4a41-8588-b3312d8b750e_Compound+Report.pdf))
- **Aave V3 StataTokenV2 L-01:** `totalAssets()` queried the wrong token. ([report](https://github.com/aave-dao/aave-v3-origin/blob/main/audits/2024-09-11_Certora_StataTokenV2.pdf))

**Applies to:** every contract.

- **Highest value:** Collateralization `pledge`, `release` and `settleSeizure`; AaveAdapter `borrow` and `repay`; LPVaultSwap settlement; SettlementBudget `draw`; PayoutEscrow `deposit` and `claim`.
- **Targets:** T-07, T-08, T-20, T-37, T-49.

### F-02 Nothing for zero

**Definition.** A call that moves zero value moves nothing and returns no value. Conversely, a call cannot yield a positive amount for a zero input or a zero-value position.

```
rule nothingForZero(env e, uint256 units) {
    require units == 0;
    supplyCollateral@withrevert(e, units, ...);
    assert lastReverted;   // ZeroAmount
}
rule noValueFromNothing(env e) {
    require accountCredited(p, vt) == 0;
    borrow@withrevert(e, ...);
    assert lastReverted;
}
```

**Catches:**

- 1-wei borrows against zero-valued collateral;
- zero-share mints;
- empty settlements that still pay fees or draw budgets.

Public examples:

- **Euler EVK (Enigma Dark H-01):** liability value rounded to 0 allowed a 1-wei borrow with no collateral. ([report](https://github.com/euler-xyz/euler-vault-kit/blob/master/audits/EnigmaDark_EVK_report.pdf))
- **ERC-4626 first-depositor zero-share mint.** ([analysis](https://www.openzeppelin.com/news/a-novel-defense-against-erc4626-inflation-attacks))

**Applies to:** PositionProxy, AaveAdapter, Collateralization, LPVaultSwap (`NothingSeized` before any draw or fee), SettlementBudget, PayoutEscrow, Coverage Spoke (`NothingToCover`).

**Targets:** T-17, T-38.

### F-03 Validity and revert conditions (no unintended DoS)

**Definition.** A call reverts if and only if one of its listed revert conditions holds. The "only if" direction is the one that rules out DoS: a must-succeed path does not revert outside its listed conditions.

```
rule repay_revertsOnlyWhen(env e, address payer, uint256 x) {
    require debt(p) > 0 && x > 0 && e.block.timestamp <= deadline;
    require allowance(payer, adapter) >= x && balanceOf(payer) >= x;
    require !ghoReservePaused() && !hubHalted();
    repay@withrevert(e, ...);
    assert !lastReverted;
}
```

**Catches:**

- liquidation or repay blocked by an unrelated reserve;
- rounding that trips a cap on a full repay;
- reverts from dust left behind.

Public examples:

- **Euler EVK (Enigma Dark H-02):** repay rounding raised supply by 1 wei, tripped the supply cap and blocked a full repay. ([report](https://github.com/euler-xyz/euler-vault-kit/blob/master/audits/EnigmaDark_EVK_report.pdf))
- **Aave V4 (ChainSecurity 6.2 and 6.4):** liquidation reverted because an unrelated asset was paused. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-01-28_Aave-V4_ChainSecurity.pdf))
- **Aave v3.5 (Certora M-01):** liquidation DoS from inconsistent floor and ceil rounding of the protocol fee. ([report](https://github.com/aave-dao/aave-v3-origin/blob/main/audits/2025-07-14_Certora_AaveV3.5.pdf))

**Applies to:**

- AaveAdapter and PositionProxy: repay, debt-free withdraw, `repayAllAndWithdraw`.
- LPVault: `collectFees`.
- LPVaultSwap: `liquidate` and `liquidatePermissionless`.
- PayoutEscrow: `claim`.
- LPOracle: `latestAnswer`.

**Targets:** T-18, T-19, T-45, T-51, T-57, T-66.

### F-04 Field bounds (valid-state invariants)

**Definition.** Every stored field stays within its domain. Cross-field relations also hold, such as `perCall ≤ per24h`, `inKindUntil` lying in the future only while enabled, and an index being a bijection.

```
invariant creditedBelowBound(uint256 id)
    record(id).credited <= MAX_CREDITED_LIQUIDITY;
```

**Catches:**

- parameters pushed to values that disable a safety check;
- packed-field overflow;
- index and set desynchronisation.

Public examples:

- **Aave V4 Spoke (Certora M-01):** a collateral factor changed from non-zero to 0 made liquidations revert. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-03-09_Spoke-Fomal-Verification_Certora.pdf))
- **Aave V4 (ChainSecurity 6.8):** a config-key overflow let the collateral factor be set to 0. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-01-28_Aave-V4_ChainSecurity.pdf))
- **Compound III (Certora, Critical):** a `uint8` mask on a 16-bit `assetsIn` dropped collateral. ([report](https://certora.cdn.prismic.io/certora/e7ca6508-fad8-4a41-8588-b3312d8b750e_Compound+Report.pdf))

**Applies to:** ParameterStore (hard and liveness bounds), SettlementBudget caps, MarketRegistry market status and in-kind window, Collateralization records and seizure list, LPOracle stored state.

**Targets:** T-09, T-60, T-77, T-78, T-80.

### F-05 Aggregated-sum integrity

**Definition.** Each aggregate equals the sum of its parts after every call. Examples:

- a total supply and the sum of balances;
- a per-market total and the sum of its per-record values;
- an exposure counter and the sum of remaining charges;
- an escrow total and the sum of claimables.

```
ghost mapping(address => mathint) sumCredited { init_state axiom forall address v. sumCredited[v] == 0; }
hook Sstore records[KEY uint256 id].credited uint128 newV (uint128 oldV) {
    sumCredited[records[id].vaultToken] = sumCredited[records[id].vaultToken] + newV - oldV;
}
invariant supplyEqualsCredited(address vt)
    to_mathint(vt.totalSupply()) == sumCredited[vt] + pendingUnits(vt)
    { preserved with (env e) { requireAllInvariants(vt, e); } }
```

**Catches:**

- re-registration overwriting an entry;
- self-transfer double counting;
- a missing decrement on one exit path.

Public examples:

- **Aave V4 Hub (Certora M-03):** `addSpoke` on an existing spoke overwrote its data and broke `sumOfSpoke*`. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-03-09_Hub-Fomal-Verification_Certora.pdf))
- **Compound III (Certora, Critical):** `transferCollateral` with `src == dst` created funds. ([report](https://certora.cdn.prismic.io/certora/e7ca6508-fad8-4a41-8588-b3312d8b750e_Compound+Report.pdf))

**Applies to:**

- custody: VaultToken supply against records and pending units; proxy shares against credited units.
- Collateralization counters.
- PayoutEscrow `totalClaimable`.
- SettlementBudget rolling window.

**Targets:** T-01, T-03, T-04, T-14, T-41.

### F-06 Solvency and backing

**Definition.** Every claim is backed. This takes two forms:

- **External form:** the contract's real token or position holdings cover its internal accounting.
- **Accounting form:** obligations never exceed assets plus recorded deficit.

```
invariant liquidityCoversCredit(uint256 id)
    isOpen(id) => lpVault.unitsOf(record(id).positionKey) >= record(id).credited
               && lpVault.depositorOf(record(id).positionKey) == record(id).depositor;
rule mintOnlyAgainstBacking(method f, env e) {
    mathint s0 = vt.totalSupply(); mathint c0 = sumCredited[vt] + pendingUnits(vt);
    f(e, args);
    assert vt.totalSupply() - s0 == sumCredited[vt] + pendingUnits(vt) - c0;
}
```

**Catches:**

- functions that skip the solvency check;
- transfers whose source can be the protocol itself;
- donations used to fake backing.

Public examples:

- **Euler Finance (2023):** `donateToReserves` had no health check. ([post-mortem](https://rekt.news/euler-rekt/))
- **Aave V4 Hub (Certora L-02):** `transferFrom` from and to the Hub passed add and restore with no payment. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-03-09_Hub-Fomal-Verification_Certora.pdf))
- **Aave V3 (Certora 2022, Critical):** `repayWithATokens` skipped the health-factor check. ([report](https://github.com/aave-dao/aave-v3-origin/blob/main/audits/2022-01-24_Certora_AaveV3.pdf))

**Applies to:**

- LPVault and Collateralization: position custody covers credited units.
- VaultToken: supply equals backing.
- LPVaultSwap: balance-neutral at call end.
- SettlementBudget: draws never exceed the balance.
- Coverage Spoke: covered amount never exceeds funded balance or deficit.

**Targets:** T-02, T-11, T-31, T-41.

### F-07 Share-rate and index monotonicity

**Definition.** Conversion rates and indexes never decrease, except through the one operation the spec permits:

- operation by operation;
- over time.

Rates are compared cross-multiplied with the virtual offsets, so there is no division:

```
rule shareRateMonotone(method f, env e) {
    mathint A0 = hub.getAddedAssets(id); mathint S0 = hub.getAddedShares(id);
    f(e, args);
    mathint A1 = hub.getAddedAssets(id); mathint S1 = hub.getAddedShares(id);
    assert (A1 + 10^6) * (S0 + 10^6) >= (A0 + 10^6) * (S1 + 10^6);
}
```

For the vault-token Hub asset, Avana proves the stronger equality `addedAssets == addedShares`. That asset has `drawCap = 0` on every Spoke, a liquidity fee of 0 and no reinvestment, so no accrual can move the ratio.

**Catches:**

- rounding that lowers the share price;
- empty-market inflation;
- fee dilution;
- an index that fails to grow.

Public examples:

- **Aave V4 Hub (Certora M-01 and M-02):** the share rate decreased, and fell below 1, from split rounding of fees and deficit. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-03-09_Hub-Fomal-Verification_Certora.pdf))
- **Hundred Finance (2023)** and **Sonne Finance (2024):** empty-market exchange-rate manipulation. ([Hundred](https://rekt.news/hundred-rekt2/), [Sonne](https://rekt.news/sonne-finance-rekt/))

**Applies to:**

- Hub vault-token asset: equality.
- Coverage Spoke: `fundedBalance` uses the GHO asset's rate with virtual offsets.
- LPOracle: the timestamp only advances.

**Targets:** T-16, T-47.

### F-08 Splitting and additivity

**Definition.** Doing an action in parts never beats doing it at once, from the protocol's side. The direction of the inequality is the one that favours the protocol.

```
rule debitAdditivity(env e, uint256 a, uint256 b) {
    storage init = lastStorage;
    debit(e, p, vt, a); debit(e, p, vt, b);
    mathint split = sumCredited[vt];
    debit(e, p, vt, a + b) at init;
    mathint whole = sumCredited[vt];
    assert split == whole;   // Avana's list debit is exact
}
rule exitChargeSplitIndependent(uint256 u1, uint256 u2) {
    // remainingCharge after exits u1 then u2 equals remainingCharge after one exit of u1 + u2
}
```

**Catches:**

- multi-step liquidations that collect a larger total bonus;
- fees avoided by splitting;
- interest that depends on how often accrual is called.

Public examples:

- **Euler EVK (ChainSecurity 6.1):** multiple partial liquidations gave a larger discount. ([report](https://github.com/euler-xyz/euler-vault-kit/blob/master/audits/ChainSecurity_EVK_report.pdf))
- **Aave V4 (ChainSecurity 6.9):** profitable multi-step liquidations. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-01-28_Aave-V4_ChainSecurity.pdf))
- **Balancer v3 (Certora L-03):** split deposits paid less fee. ([report](https://github.com/balancer/balancer-v3-monorepo/blob/main/audits/certora/2024-09-04.pdf))

**Applies to:**

- Collateralization: seizure-list debit, exit charge release (`remainingCharge` is computed from fixed `originalUsdCharge` and `originalUnits`).
- LPVaultSwap: repeated small liquidations of one account.
- SettlementBudget: draws split across calls stay inside the 24-hour window.

**Targets:** T-12, T-13, T-39.

### F-09 Idempotency

**Definition.** Repeating a refresh, accrual or poke within one block changes nothing the second time, and a cached value is never refreshed by re-reading the same source round.

```
rule pokeIdempotent(env e) {
    poke(e); storage s = lastStorage;
    poke(e);
    assert lastStorage[currentContract] == s[currentContract];
}
```

**Catches:**

- state that drifts with the frequency of calls;
- double application of an update;
- a stale value re-stamped as fresh.

Public examples:

- **Aave V4 (ChainSecurity 6.5):** fees could be lowered by accruing often. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-01-28_Aave-V4_ChainSecurity.pdf))
- **Compound III (Certora, Medium):** `isLiquidatable` was evaluated before accrue. ([report](https://certora.cdn.prismic.io/certora/e7ca6508-fad8-4a41-8588-b3312d8b750e_Compound+Report.pdf))

**Applies to:** LPOracle `poke` and cached price, RiskModule pre-checks that call `poke`, Collateralization reconcile-on-exit (reconciling twice debits once).

**Targets:** T-70.

### F-10 View integrity

**Definition.** A view returns what the matching state-changing call would do:

- previews equal outcomes;
- views do not depend on whether an update has run;
- views revert under exactly the conditions the matching call reverts.

```
rule previewLiquidationMatches(env e, LiquidationParams p) {
    LiquidationPreview pv = lens.previewLiquidation(e, p.proxy, p.vaultToken, p.debtReserveId, p.debtToCover);
    LiquidationResult r = lpVaultSwap.liquidate(e, p);
    assert r.unitsSeized == pv.unitsSeized && r.debtRepaid == pv.debtRepaid;
}
```

**Catches:**

- previews that ignore accrued fees;
- an off-by-one in `max*` functions;
- a view reading the wrong token.

Public examples:

- **Aave V4 Hub (Certora L-03):** views ignored accrued fees. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-03-09_Hub-Fomal-Verification_Certora.pdf))
- **Aave V4 TokenizationSpoke (Certora I-01):** `maxRedeem` underestimated by 1 share. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-04-13_TokenizationSpoke-Fomal-Verification_Certora.pdf))

**Applies to:** Lens (`previewLiquidation`, `previewRelease`, cap and headroom views), RiskModule views, LPOracle `getPriceState` against the gates that consume it.

**Targets:** T-73, T-74.

### F-11 Rounding-direction consistency

**Definition.** Every rounding goes against the party who could exploit it:

| Quantity | Rounding |
|---|---|
| Value the protocol credits | Down |
| Value it charges | Up |
| Recovery floors | Computed conservatively |
| Each keeper share | Down |

One quantity is rounded once, not part by part.

```
rule seizedValueRoundsDown(uint256 c, uint256 Pc, uint256 Pd) {
    mathint V = seizedValue(c, Pc, Pd);                // SPEC-LIQ-004
    assert V * 10^dv * Pd <= c * Pc * 10^18;
}
```

**Catches:**

- 1–2 wei debt creation compounding into a full seizure;
- conversion rounding in the user's favour;
- inconsistent floor and ceil on the two sides of one transfer.

Public examples:

- **Aave V4 (ChainSecurity 6.1, Medium):** 2-wei premium-debt rounding let repeated liquidations create debt. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-01-28_Aave-V4_ChainSecurity.pdf))
- **Morpho-AaveV3 (Runtime Verification A01):** rounding direction in the `_account*` functions. ([report](https://github.com/runtimeverification/publications/tree/main/reports/smart-contracts))
- **Aave v3.5 (Certora M-02):** allowance reduced by less than the rounded-up debt minted. ([report](https://github.com/aave-dao/aave-v3-origin/blob/main/audits/2025-07-14_Certora_AaveV3.5.pdf))

**Applies to:**

- SettlementMath: `V`, `minGho`, `U`, costs, net bonus, in-kind split, keeper payout.
- LPPriceMath: `price8 = isqrt(4·v0·v1) − 1`.
- Collateralization: `remainingCharge` rounds up.
- RiskModule: `usdCharge` booking.
- Coverage Spoke: `fundedBalance` rounds down.

**Targets:** T-13, T-34, T-35, T-39, T-40, T-69.

### F-12 Front-running, order independence and non-interference

**Definition.**

- An action on one account changes no other account's position.
- A third party's call placed before a victim's call cannot make the victim's call revert or pay less, beyond the conditions the spec names.
- Two independent actions commute.

```
rule noChangeToOtherProxy(method f, env e, address other) {
    require other != targetProxyOf(f, e);
    mathint s0 = spoke.getUserSuppliedShares(r, other);
    f(e, args);
    assert spoke.getUserSuppliedShares(r, other) == s0;
}
rule donationCannotBlockSeizure(env e1, env e2) {
    storage init = lastStorage;
    liquidate(e2, p);                    bool ok1 = !lastReverted;
    vt.transfer(e1, hub, 1) at init;     liquidate@withrevert(e2, p);
    assert ok1 => !lastReverted;
}
```

**Catches:**

- griefing with 1-wei donations;
- permit front-run DoS;
- cross-account spill-over in shared accounting.

Public examples:

- **Aave v3.6 (Certora L-01):** a 1-wei transfer front-ran a first supply and blocked collateral auto-enable. ([report](https://github.com/aave-dao/aave-v3-origin/blob/main/audits/2025-11-18_Certora_Aave-v3.6.pdf))
- **Euler EVK (Certora M-01):** bad-debt socialisation griefed by sending 1 wei of collateral. ([report](https://github.com/euler-xyz/euler-vault-kit/blob/master/audits/Certora_EVK_report.pdf))
- **Zivoe vault (Runtime Verification A02):** permit front-run DoS. ([report](https://github.com/runtimeverification/publications/tree/main/reports/smart-contracts))

**Applies to:** VaultToken (a transfer to the Hub leaves unrecorded units that no debit uses), Collateralization (the seizure debit comes from Avana's own snapshot), LPVaultSwap, AaveAdapter `repay` (any payer), PayoutEscrow `claim`.

**Targets:** T-15, T-18, T-48, T-61.

### F-13 Re-initialisation and duplicate registration

**Definition.**

- Every initializer runs once, and implementation contracts are never initialisable.
- Every registry rejects a key it already holds: one open record per (`integrationId`, `positionKey`), one vault token per market key, one proxy per `(wallet, spoke, marketId)`, one market per `(chainId, spoke, reserveId)`.

```
rule noDoublePledge(env e, bytes32 integrationId, bytes32 positionKey) {
    require recordIdOf(integrationId, positionKey) != 0;
    pledge@withrevert(e, positionKey, ...);
    assert lastReverted;               // AlreadyPledged
}
rule initializeOnce(env e1, env e2) {
    initialize(e1, w1, s1);
    initialize@withrevert(e2, w2, s2);
    assert lastReverted;
}
```

**Catches:**

- re-registration overwriting live state;
- takeover of an uninitialised implementation;
- duplicate assets inflating collateral.

Public examples:

- **Aave V4 Hub (Certora M-03):** `addSpoke` overwrote an existing spoke. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-03-09_Hub-Fomal-Verification_Certora.pdf))
- **Wormhole:** uninitialised UUPS implementation. ([write-up](https://immunefi.com/blog/bug-fix-reviews/wormhole-uninitialized-proxy-bugfix-review/))
- **Nomad:** initialisation accepted the zero root. ([post-mortem](https://rekt.news/nomad-rekt/))
- **Veridise money-market report:** duplicate assets in a uniqueness check overstated collateral. ([report](https://veridise.com/wp-content/uploads/2025/12/VAR-Venture23-250804-MoneyMarket-V2.pdf))

**Applies to:** Collateralization records, VaultTokenFactory, ProxyManager and PositionProxy `initialize`, MarketRegistry `registerMarket` and token listing, every UUPS implementation, LPOracle `initialize`.

**Targets:** T-05, T-22, T-62.

### F-14 Access-control matrix

**Definition.** For every selector of every contract, a successful call implies the caller holds the role the role map assigns and the operation went through the delay it requires. Every privileged selector is listed: none is left unchecked by omission.

```
rule onlyRoleCanCall(method f, env e) filtered { f -> isRestricted(f.selector) } {
    f@withrevert(e, args);
    assert !lastReverted => hasRole(roleOf(f.selector), e.msg.sender);
}
rule proxyOnlyAdapter(method f, env e) filtered { f -> !f.isView } {
    f@withrevert(e, args);
    assert !lastReverted => e.msg.sender == ADAPTER;
}
```

**Catches:**

- missing modifiers;
- timelock bypass through a side path;
- a role that can reach a selector outside its intent.

Public examples:

- **GHO (Certora, Low):** the rebalance timelock was bypassed through mint, burn or stkAAVE transfer. ([report](https://github.com/aave/gho-core/blob/main/certora/reports/Aave_Gho_Formal_Verification_Report.pdf))
- **Audius:** governance takeover. ([post-mortem](https://rekt.news/audius-rekt/))

**Applies to:** every contract. Each selector's row in [1.4](../../spec/01-architecture/04-permissions-and-roles.md) and [2.15](../../spec/02-contracts/15-governance-and-timelock.md) becomes one assertion.

**Targets:** T-06, T-36, T-37, T-40, T-44, T-53, T-55, T-63, T-76.

### F-15 State-machine reachability and liveness

**Definition.** Every state machine (pause state, market status, oracle price state, timelock operation, budget window) has these properties:

- **Allowed transitions:** only the transitions the spec allows occur.
- **Reachability:** every allowed transition is reachable, shown with a `satisfy` witness.
- **Liveness:** every state that halts something has a path out that no single role can block.

```
rule pauseTransitions(method f, env e) {
    PauseState s0 = pauseState();
    f(e, args);
    PauseState s1 = pauseState();
    assert s0 != s1 => allowedTransition(s0, s1, f.selector, e.msg.sender);   // SPEC-GOV-004
}
rule canAlwaysRepayAll(env e) { /* see F-03 */ }
```

**Catches:**

- deadlock;
- a halt with no exit;
- a guardian able to lift what only governance should lift;
- a state that can never be left.

Public examples:

- **Morpho-AaveV3 (Runtime Verification A08):** deadlock when disabling a reserve as collateral. ([report](https://github.com/runtimeverification/publications/tree/main/reports/smart-contracts))
- **Aave V4 (Trail of Bits TOB-AAVE-3):** lowering `riskPremiumThreshold` blocked refresh. ([report](https://github.com/aave/aave-v4/blob/main/audits/2025-11-06_Aave-V4_TrailOfBits.pdf))
- **Lido Dual Governance (Runtime Verification):** state-machine proofs. ([report](https://strapi-rv-bucket-01.s3.us-east-2.amazonaws.com/Dual_Governance_Formal_Verification_6603b61bc5.pdf))

**Applies to:** MarketRegistry pause state and market lifecycle, LPOracle price state, AvanaTimelock operations, LPVaultSwap keeper floor, PayoutEscrow claim.

**Targets:** T-47, T-50, T-54, T-56, T-60, T-70, T-75, T-78.

### F-16 Oracle staleness and manipulation

**Definition.** A price used for a decision meets three conditions:

- it carries its original source timestamp;
- it is no older than the decision's maximum age;
- it comes from a source that agrees with its alternate and with the pool TWAP, within tolerance.

A failed or manipulated input moves the market into a degraded state. It never moves the market into a fresh price. The served answer never reverts and never reads 0.

```
rule cacheNeverRefreshesTimestamp(env e) {
    uint256 t0 = sourceTimestamp(feed);
    poke(e);
    assert sourceTimestamp(feed) != t0 => newObservationIsLiveAndNewer(feed);
}
rule borrowNeedsFreshPrice(env e) {
    borrow(e, ...);
    assert forall collateral m. priceState(m) == Live && age(m) <= borrowPriceMaxAge;
}
```

**Catches:**

- stale or floored feeds;
- spot-price manipulation;
- a cache re-stamping old data;
- out-of-gas inside `try` recorded as an outage.

Public examples:

- **Venus / Blizz:** the Chainlink LUNA price was floored at `minAnswer`. ([post-mortem](https://rekt.news/venus-blizz-rekt/))
- **Inverse Finance:** spot/TWAP manipulation. ([post-mortem](https://rekt.news/inverse-finance-rekt/))
- **Aave V4 (ChainSecurity note):** the oracle timestamp was not validated and was assumed instead. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-01-28_Aave-V4_ChainSecurity.pdf))

**Applies to:** LPOracle with LPPriceMath, RiskModule gates, LPVaultSwap price checks, Lens price views.

**Targets:** T-59, T-66, T-67, T-68.

### F-17 Liquidation correctness

**Definition.** Five properties together:

- **No healthy liquidation:** a liquidation completes only for an account below the threshold, with accepted prices and outside the grace rules.
- **No over-seizure:** collateral value seized is at most debt repaid × bonus, plus one base unit.
- **Exact debit:** the custody debit equals the Spoke's share drop.
- **Bad-debt recording:** a deficit is recorded only when the account has no collateral left on the Spoke, and covered only by the authorised path, up to the recorded amount.
- **Liveness:** an unhealthy account with accepted prices can be liquidated.

```
rule healthyCannotBeLiquidated(env e, LiquidationParams p) {
    require spoke.getHealthFactor(p.proxy) >= 10^18;
    lpVaultSwap.liquidate@withrevert(e, p);
    assert lastReverted;
}
rule noOverSeizure(env e, LiquidationParams p) {
    LiquidationResult r = lpVaultSwap.liquidate(e, p);
    assert value(r.unitsSeized) <= r.debtRepaid * LB / 10^4 + valueOfOneUnit();
}
```

**Catches:**

- liquidation of a healthy account, or an action that leaves an account immediately liquidatable;
- excess bonus;
- deficit DoS from micro-collateral;
- bad debt that is never recorded or is covered twice.

Public examples:

- **Aave V4 (Trail of Bits TOB-AAVE-7):** users became immediately liquidatable after an action. ([report](https://github.com/aave/aave-v4/blob/main/audits/2025-11-06_Aave-V4_TrailOfBits.pdf))
- **Aave V4 (Trail of Bits TOB-AAVE-1):** deficit-reporting DoS with micro-collateral. ([report](https://github.com/aave/aave-v4/blob/main/audits/2025-11-06_Aave-V4_TrailOfBits.pdf))
- **Aave v3.3 (Certora M-01):** the rate strategy ignored the new deficit. ([report](https://github.com/aave-dao/aave-v3-origin/blob/main/audits/2024-11-07_Certora_Aave-v3.3.0.pdf))
- **Compound DAI liquidations (2020):** liquidations driven by an oracle spike. ([article](https://www.theblock.co/post/85850/dai-compound-dydx-liquidations-defi))

**Applies to:** LPVaultSwap, SettlementMath, Collateralization seizure, Coverage Spoke, the Borrow Spoke configuration (`liquidationFee = 0`, `receiveSharesEnabled = false`).

**Targets:** T-15, T-32, T-33, T-45, T-46.

### F-18 Upgrade safety

**Definition.** For every UUPS contract (the PositionProxy and the ProxyManager are immutable and covered by the converse proof below):

- each new implementation keeps the storage layout of the deployed one, extended only by appending inside its ERC-7201 namespace;
- every implementation constructor calls `_disableInitializers()`;
- reinitialisation uses `reinitializer(n)` atomically inside `upgradeToAndCall`;
- only `APPLICATION_ADMIN`, the AvanaTimelock, can upgrade, and only after the normal delay;
- an implementation address must hold code.

```
rule onlyTimelockUpgrades(env e, address impl, bytes data) {
    upgradeToAndCall@withrevert(e, impl, data);
    assert !lastReverted => e.msg.sender == TIMELOCK;
}
rule implementationNotInitialisable(env e) {
    implementation.initialize@withrevert(e, ...);
    assert lastReverted;
}
```

The storage-layout comparison is a deployment check (`TEST-137`) on `forge inspect storageLayout` output. The CVL rules cover the authorisation and initializer properties.

**Catches:**

- uninitialised implementations;
- storage collision through re-run initializers;
- upgrades without delay;
- self-destructible logic.

Public examples:

- **OpenZeppelin `UUPSUpgradeable` (CVE-2021-41264).** ([post-mortem](https://forum.openzeppelin.com/t/uupsupgradeable-vulnerability-post-mortem/15680))
- **Audius:** a storage collision let `initialize` re-run. ([post-mortem](https://rekt.news/audius-rekt/))
- **Aave V4 (Trail of Bits TOB-AAVE-2):** upgradeability practices. ([report](https://github.com/aave/aave-v4/blob/main/audits/2025-11-06_Aave-V4_TrailOfBits.pdf))

**Applies to:** AaveAdapter, MarketRegistry, ParameterStore, RiskModule, LPOracle, LPVaultSwap. Non-upgradeable contracts (PositionProxy, ProxyManager, Lock, Collateralization, every LPVault, the flash source) get the converse proof: no upgrade path, no settable target and no `delegatecall`.

**Targets:** T-64, T-65.

### F-19 Reentrancy and cross-contract locks

**Definition.**

- Every external state-changing entry point of the fixed Avana set acquires the shared Lock.
- Every inner function accepts calls only while the Lock is held, and only from its named caller.
- While the Lock is held, views that a third party could read mid-operation revert.
- No function writes storage after an external call it does not control, unless the Lock is held.

```
rule lockedInnerCall(method f, env e) filtered { f -> isInner(f.selector) } {
    f@withrevert(e, args);
    assert !lastReverted => (lock.holder() == expectedHolder(f.selector) && e.msg.sender == expectedCaller(f.selector));
}
// Opcode-hook check (reentrancySafe): flag SLOAD/SSTORE → CALL → SSTORE outside the lock.
```

**Catches:**

- classic reentrancy;
- read-only reentrancy into price or position views;
- callback paths that skip checks.

Public examples:

- **Fei Rari:** reentrancy. ([post-mortem](https://rekt.news/fei-rari-rekt/))
- **Sentiment:** read-only reentrancy through a Balancer price. ([post-mortem](https://hackmd.io/@sentimentxyz/SJCySo1z2))
- **Curve LP oracle:** read-only reentrancy. ([analysis](https://www.chainsecurity.com/blog/curve-lp-oracle-manipulation-post-mortem))

**Applies to:** Lock, Collateralization, LPVault, AaveAdapter, PositionProxy, LPVaultSwap, routes, SettlementBudget, PayoutEscrow, Lens.

**Targets:** T-72, T-73.

### F-20 ERC-20 edge cases

**Definition.** Every token interaction is measured as a balance delta and checked against the expected amount. Each of these is either rejected at listing or tolerated:

- fee-on-transfer and rebasing tokens;
- false-returning and missing-return transfers;
- zero-amount transfers;
- blocklisting;
- decimals from 6 to 18.

The vault token itself also follows ERC-20:

- `transfer` and `transferFrom` update allowances correctly;
- self-transfers conserve balances;
- `approve` overwrites.

```
rule escrowDepositIsBalanceDelta(env e, address t, address b, uint256 amt) {
    mathint bal0 = t.balanceOf(escrow);
    deposit(e, t, b, amt);
    assert t.balanceOf(escrow) - bal0 == amt;        // else TransferMismatch
}
// run under ERC20Standard, ERC20NoRevert (returns false) and ERC20USDT (no return value) dispatch models
```

**Catches:**

- accounting that diverges from real balances;
- silent transfer failure;
- decimal scaling errors.

Public examples:

- **Balancer STA pools (2020):** fee-on-transfer tokens desynchronised internal balances. ([analysis](https://slowmist.medium.com/detailed-analysis-of-balancer-hack-de8bd86020de))
- **Aave V4 Liquidation library (Certora):** sizing rules are run per decimals pair, 18-18 and 16-12. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-03-09_Libraries-Fomal-Verification_Certora.pdf))

**Applies to:** VaultToken, VaultTokenFactory decimals, PositionProxy, LPVaultSwap, routes, PayoutEscrow, LPVault fee collection, LPPriceMath normalisation.

**Targets:** T-10, T-22, T-42.

### F-21 Conservation of value and balance-neutral routers

**Definition.**

- A contract that only routes value ends each call with:
  - every token balance unchanged (stray dust untouched);
  - every allowance it granted reset to 0.
- A settlement identity balances to the wei: inflows = outflows.

```
rule settlementConserves(env e, LiquidationParams p) {
    LiquidationResult r = liquidate(e, p);
    assert r.F + r.K + r.R + r.B == r.D + r.F + r.phi + r.A + r.keeperOut;   // INV-035
}
rule noResidualAllowance(env e, LiquidationParams p, address t, address spender) {
    liquidate(e, p);
    assert t.allowance(lpVaultSwap, spender) == 0;
}
```

**Catches:**

- leftover approvals that let a later call drain funds;
- surplus captured by the wrong party;
- arithmetic leaks.

Public example:

- **Balancer v3 (Certora C-01):** an unused approval in `_wrapWithBuffer` could drain the vault. ([report](https://github.com/balancer/balancer-v3-monorepo/blob/main/audits/certora/2024-09-04.pdf))

**Applies to:** LPVaultSwap, settlement routes, PositionProxy (exact approvals reset), AaveAdapter.

**Targets:** T-23, T-30, T-31, T-36, T-44.

### F-22 Health preservation

**Definition.** No user-callable function can make an account unhealthy, or lower its health factor below the opening floor, except:

- a price move;
- liquidation itself.

An action that adds collateral or reduces debt never lowers the health factor.

```
rule borrowLeavesHealthy(env e) {
    borrow(e, ...);
    assert hfExcludingRescue(proxy) >= max(WAD, hardHealthFloor(marketId), minHealthFactor); // Q-398: no other floor
}
```

**Catches:**

- a missing health check on one path;
- an unchecked cast that skips the check;
- donations that bypass solvency.

Public examples:

- **Aave V4 Spoke (Certora L-01):** an unchecked int cast skipped the health check. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-03-09_Spoke-Fomal-Verification_Certora.pdf))
- **Euler EVK (Certora):** the "accounts stay healthy" rule. ([report](https://github.com/euler-xyz/euler-vault-kit/blob/master/audits/Certora_EVK_report.pdf))
- **Euler Finance (2023):** donation without a health check. ([post-mortem](https://rekt.news/euler-rekt/))

**Applies to:** AaveAdapter, RiskModule, PositionProxy.

**Targets:** T-58.

### F-23 Callback and external-input authenticity

**Definition.**

- A callback is accepted only from its fixed caller, with the expected initiator and context.
- Any address or identifier a caller supplies is checked against Avana's own registry before use. Examples: vault token, proxy, debt reserve, route.

```
rule flashCallbackAuth(env e, address initiator, address token, uint256 amt, uint256 fee, bytes data) {
    onFlashLoan@withrevert(e, initiator, token, amt, fee, data);
    assert !lastReverted => e.msg.sender == GHO_FLASH_MINTER && initiator == lpVaultSwap && lock.holder() == lpVaultSwap;
}
```

**Catches:**

- spoofed callbacks;
- caller-supplied tokens or markets that do not match the record;
- swapped underlyings.

Public examples:

- **Veridise money-market report:** liquidation did not check the reserve asset against the token record. ([report](https://veridise.com/wp-content/uploads/2025/12/VAR-Venture23-250804-MoneyMarket-V2.pdf))
- **Balancer v3 (Certora C-02):** an ERC-4626 underlying could be swapped. ([report](https://github.com/balancer/balancer-v3-monorepo/blob/main/audits/certora/2024-09-04.pdf))

**Applies to:** LPVaultSwap `onFlashLoan`, Uniswap swap callbacks in routes, LPVault `onERC721Received` (canonical NFPM only), AaveAdapter and Lens (registered proxy and approved debt reserve).

**Targets:** T-43, T-74, T-76.

### F-24 Arithmetic safety and math-library equivalence

**Definition.**

- No reachable overflow, underflow, division by zero or unsafe cast inside the stated input bounds.
- Every math helper equals its reference definition. Avana's own `mulDiv`, `isqrt`, tick conversion and bps arithmetic are proved against a `mathint` reference, so the summaries used elsewhere are sound.

```
rule priceMathEquivalence(uint256 v0, uint256 v1) {
    require v0 >= 1 && v1 >= 1 && v0 <= MAX_ANSWER && v1 <= MAX_ANSWER;
    mathint p = lpPriceMath.price8(v0, v1);
    assert p >= 1 && p * p <= 4 * v0 * v1 && (p + 2) * (p + 2) > 4 * v0 * v1;   // isqrt − 1
}
```

**Catches:** overflow DoS, silent truncation in casts, wrong summaries.

Public examples:

- **Optimism (Runtime Verification):** `prevBoughtGas + _amount` overflow. ([report](https://github.com/runtimeverification/publications/tree/main/reports/smart-contracts))
- **Euler EVK (Certora M-02 and M-04):** overflows. ([report](https://github.com/euler-xyz/euler-vault-kit/blob/master/audits/Certora_EVK_report.pdf))

**Applies to:** LPPriceMath, SettlementMath, Collateralization charge math, every immutable contract (SMTChecker).

**Targets:** T-21, T-35, T-52, T-69.

### F-25 Governance parameter bounds and delays

**Definition.**

- **Tighten selectors:** move a parameter only in its safer direction, at the short delay.
- **Loosen selectors:** move it only at the normal delay.
- **Every value:** stays within its hard bounds and its liquidation-liveness bounds.
- **Delays:** stay within `[SHORT_DELAY, MAX_DELAY]`.
- **Role-change operations:** can be cancelled only by the DAO canceller.

```
rule tightenIsSafer(env e, uint256 m, uint256 v) {
    uint256 old = slippageAllowanceBps(m);
    tightenSlippageAllowanceBps@withrevert(e, m, v);
    assert !lastReverted => v < old && v >= slippageAllowanceMinBps(m);
}
```

**Catches:**

- emergency paths with no delay;
- parameters set to values that block liquidation;
- a governance hot path that cannot be cancelled.

Public examples:

- **Beanstalk:** `emergencyCommit` executed with no timelock. ([post-mortem](https://rekt.news/beanstalk-rekt/))
- **Aave V4 (ChainSecurity 6.8):** a config overflow set the collateral factor to 0. ([report](https://github.com/aave/aave-v4/blob/main/audits/2026-01-28_Aave-V4_ChainSecurity.pdf))

**Applies to:** ParameterStore, MarketRegistry, SettlementBudget cap setters, LPVaultSwap keeper set, AvanaTimelock.

**Targets:** T-54, T-55, T-71, T-77, T-79.

## 4. Assumptions and simplifications

Every published FV engagement narrows its model, and the soundness of a result depends on what was narrowed. Avana states each assumption in the report of every property that relies on it. Each assumption carries a justification and names the proof or test that discharges it. An assumption with no discharge is listed as unproved.

| Assumption class | What practitioners state | How Avana states and discharges it |
|---|---|---|
| Loop unrolling | Certora Aave V4: `loop_iter` 3, optimistic. Compound III: 2. Halmos defaults: `--loop 2`. Runtime Verification: loop invariants, or empty arrays then symbolic `bytes`. | Each conf states its `loop_iter` and which loop it bounds. Every loop whose length a user can grow (the seizure-list walk, multi-reserve health reads, the route list) gets two extra checks:<br>• a non-optimistic run (`optimistic_loop: false`) at the bound, so an unrolling shortfall fails the rule instead of being assumed away;<br>• a Halmos or fuzz test at larger lengths.<br>The gas ceiling on the list walk is `REQ-VAULT-108`. |
| Token behaviour | Standard ERC-20 only: no fee-on-transfer, no rebasing, no hooks, decimals 6–18 (Certora Aave V4). Morpho runs three dispatch models (`ERC20Standard`, `ERC20NoRevert`, `ERC20USDT`). | Listing admits only standard tokens (`REQ-ARCH-014`) with decimals in [6, 18] and an even sum (`REQ-VTOKEN-036`, `SPEC-UNIT-001`). The rules that move pool or debt tokens (routes, PayoutEscrow, LPVaultSwap remainders) also run under the false-returning and missing-return models, because `REQ-SWAP-082` tolerates a failing remainder transfer. Blocklisting of an Avana contract is an accepted external risk ([4.3](../../spec/04-security/03-external-dependencies.md)). |
| Price bounds | Prices non-zero (Certora Aave V4). Oracle quotes bounded and monotone (Certora EVK). Price ≤ 1e40 (Morpho fuzzing). | Feed answers lie inside each feed's pinned minimum and maximum answer. Normalised 8-decimal values satisfy `1 ≤ a ≤ 1e24` for `PROP-023`. `p, b < 2^128` for the agreement check. Out-of-bound answers are a modelled input that must lead to a failed route (`REQ-ORACLE-067`), never an assumed impossibility. |
| Amount bounds | Amounts < 2^96 and timestamps < 2^35 (Runtime Verification, Lido DG). Morpho: amounts 1e2–1e32. | Credited liquidity ≤ `MAX_CREDITED_LIQUIDITY` (`REQ-VAULT-107`). Total supply ≤ the integration's per-range liquidity bound (`SPEC-UNIT-006`, `REQ-AMM-V3-007`). `usdCharge < 2^128` (`REQ-VAULT-110`). Timestamps < 2^40 and non-decreasing across calls in one rule. |
| Summarised math | Certora's `mulDiv` in CVL. Morpho summaries pin the rounding inequality. Interest rate as an uninterpreted function. | `mulDiv`, `isqrt`, `TickMath` and `FullMath` are replaced by CVL functions that keep the rounding inequality. Each summary is proved equal to the library on the real code in a library conf (F-24). |
| External protocols | Spoke proofs use a symbolic Hub. Compound III: external calls cannot change Comet's state. Certora EVK: calls come only through the EVC. | Hub, Spoke and AaveOracle are summarised by `AaveModel`. The vault-token Hub asset's shares-equal-assets property is proved on the real Hub at `a3ef63e` (`PROP-040`). Aave's own liquidation sizing, dust rule and bonus run as fork tests (`TEST-109` to `TEST-111`, `TEST-114`). Uniswap NFPM and pool are summarised so third parties can only increase a position's liquidity. |
| Reentrancy through summaries | Certora Aave V3 (2022): summarised external calls cannot re-enter, which misses some reentrancy. | Avana does not assume reentrancy away. The Lock is proved on its own (`PROP-037`). The opcode-hook rule of F-19 summarises unresolved external calls as `HAVOC_ALL`, so a call that re-enters an Avana contract is part of the model. |
| Roles and governance | The governor and admin are trusted. `setLTV` and `initialize` are out of scope (Certora EVK). | Role checks are uninterpreted functions, so any role map is covered. The deployed role map is checked by `TEST-062`. Hostile-implementation proofs (`INV-018`, `TEST-130` to `TEST-133`) treat each upgradeable implementation as arbitrary code: the immutable custody contracts must hold their invariants against it. |
| Gas | Infinite gas, which is unsound where code reads `gasleft()` (Runtime Verification, Optimism). | Gas is unbounded in CVL and Halmos. The two gas-dependent behaviours, the `poke()` minimum gas (`REQ-ORACLE-074`) and the in-kind remainder transfer gas (`REQ-SWAP-083`), are proved in Foundry tests with explicit gas limits and listed as outside the CVL model. |
| Addresses and hashing | Arbitrary but fixed addresses. `optimistic_hashing` with a length bound. | Distinct arbitrary addresses for the caller, other accounts and the protocol contracts. Every hashed input is fixed-size (`hashing_length_bound: 224`, as in `contracts/certora/README.md`). |
| Scope cuts | Rewards disabled (Runtime Verification, Zivoe). Liquidation and configuration excluded from fuzzing (noted as a gap by Trail of Bits). | No Avana entry point is excluded from a parametric rule. A function filtered out of a rule is listed in the report with the reason, and with the rule that covers it instead. |

## 5. Report format

Each area publishes one internal report per verified commit, in `audit/formal-verification/<area>-<commit>.md`. The per-property evidence files stay in `audit/formal/`. The report follows the section order used in Certora's published lending reports (Aave V4 Hub, Spoke and Libraries; Euler EVK; Balancer v3), so internal and external results can be compared side by side.

1. **Project summary.**
   - Scope table: contract, file, commit, solc 0.8.28 / `cancun`, Certora and Halmos versions.
   - Short protocol overview of the area.
2. **Assessment methodology.**
   - Rules versus inductive invariants.
   - Over- and under-approximation used.
   - **Security context:** each threat from [4.2 Attack Scenarios](../../spec/04-security/02-attack-scenarios.md) mapped to the target IDs that address it.
   - Fix-validation process.
3. **Findings summary.** Counts by severity: discovered, confirmed, fixed.
4. **Severity matrix** (below).
5. **Detailed findings table.** ID, title, severity, status.
6. **One block per finding**, with these fields:
   - severity, impact, likelihood;
   - files;
   - status;
   - **violated property** (target ID and rule name);
   - description;
   - exploit scenario with concrete numbers;
   - recommendation;
   - fix with commit;
   - fix review: the rule re-run, and "Verified after fix".

   Every finding is also entered as a `FINDING-NNN` in [5.3](../../spec/05-verification/03-audit-findings.md).
7. **Formal verification.** Five parts:
   - **Verification notations:**
     - Verified;
     - Verified after fix;
     - Violated;
     - Accepted violation (with the decision that accepts it);
     - Holds within bounds (fuzz or bounded proof only);
     - Timeout (never counted as verified).
   - **General assumptions and simplifications:** the section 4 rows this report relies on, each with its discharge.
   - **Unproved assumptions:** summaries or bounds no proof discharges, and the test or monitor that covers each one.
   - **Properties overview:** target ID, family, contract, statement, spec IDs, status.
   - **Detailed properties:** per target, the rules with their status, a one-line description, the reproduction command, the run link, the mutation caught and the `satisfy` witness result.
8. **Spec-ID trace.** Every rule's tag line `// PROP-NNN verifies: INV-…, REQ-…` (or `// T-NN verifies: …` for targets not yet numbered in 5.2), as collected by `trace.py`.

**Severity matrix.** The matrix uses impact × likelihood, as in Certora's Aave V4 reports:

| Impact \ Likelihood | Low | Medium | High |
|---|---|---|---|
| **High** | Medium | High | Critical |
| **Medium** | Low | Medium | High |
| **Low** | Low | Low | Medium |

Impact levels:

- **High:** loss of collateral, vault tokens minted without backing, unbacked debt, or a protocol-wide halt of exits or liquidation.
- **Medium:** bounded loss, griefing, or a liveness loss in one market.
- **Low:** dust-level loss.

Likelihood levels:

- **High:** any unprivileged caller, with no precondition beyond an ordinary market state.
- **Medium:** needs a specific but plausible state, such as a price move, a paused reserve or a full cap.
- **Low:** needs a privileged role acting against its mandate, a misconfiguration outside listing checks, or inputs at the edge of the stated bounds.

A result with no security consequence is **Informational**. These levels give the same classes as the severity table in [`audit/README.md`](../README.md).

## 6. Priority targets

These are the 74 properties proved first, in priority order within each area.

- **P0:** must be Verified before an external audit starts.
- **P1:** Verified before launch.
- **P2:** Verified, or Holds within bounds, before launch, with the gap stated.

Statements describe the current architecture:

- the AaveAdapter is the only vault-token minter and burner, and the only caller of a PositionProxy;
- Collateralization keeps the records;
- each AMM protocol's LPVault holds that protocol's positions;
- the ProxyManager is the immutable CREATE2 deployer of the PositionProxies, one per wallet × CDP Spoke × market.

### 6.1 custody

| ID | Pri | Family | Contract | Property | Spec IDs |
|---|---|---|---|---|---|
| T-01 | P0 | F-05 sum | Collateralization, VaultToken | For each market, `totalSupply ≤ Σ credited` over open records + pending-settlement units for any LPVaultSwap implementation, with equality while every `burnSeized` is settled in the same call; every Adapter call keeps the gap. | `INV-001`, `PROP-001`, `SPEC-BACK-009`, `REQ-ADAPTER-075` |
| T-02 | P0 | F-06 backing | LPVault, Collateralization | Every open record's live units (`unitsOf(positionKey)`) are ≥ its credited units, and the record's LPVault holds the position. | `INV-002`, `PROP-002`, `SPEC-BACK-010` |
| T-03 | P0 | F-05 sum | VaultToken, Hub, Spoke | At the end of every transaction, these are all equal: `balanceOf(Hub)`; Hub added assets; Σ proxy supplied shares; `totalSupply − balanceOf(LPVaultSwap)`. | `INV-003` |
| T-04 | P0 | F-05 sum | Collateralization | For each proxy and market, Spoke supplied shares equal Σ credited of that proxy's records. A shortfall found at exit is reconciled as `max(0, C − S)`. | `INV-008`, `INV-058`, `PROP-045`, `SPEC-BACK-011` |
| T-05 | P0 | F-13 duplicate | Collateralization | At most one open record per (`integrationId`, `positionKey`) across all markets, Spokes and Hubs of the chain. Pledging a position that has an open record reverts `AlreadyPledged`. | `INV-005`, `PROP-003`, `REQ-VAULT-106` |
| T-06 | P0 | F-14 access | VaultToken | `totalSupply` rises only in `mint` and falls only in `burn`, and both succeed only when called by the AaveAdapter. Mint and burn to or from `address(0)` revert. | `INV-009`, `INV-010`, `PROP-005`, `REQ-VTOKEN-032`, `REQ-VTOKEN-043`, `REQ-ARCH-032` |
| T-07 | P0 | F-01 integrity | Collateralization, AaveAdapter | A pledge mints exactly the liquidity read from the NFPM after custody, once, to the pledging wallet's proxy, and supplies it so the proxy's shares rise by the same amount. | `INV-009`, `PROP-006`, `SPEC-BACK-002`, `REQ-VAULT-107`, `REQ-VAULT-111` |
| T-08 | P0 | F-01 integrity | Collateralization, AaveAdapter | The burn amount is exact in each case:<br>• withdrawal: the record's credited units;<br>• seizure: the units LPVaultSwap received in that call;<br>• pending settlement: at most the pending units, keeping `totalSupply + units ≤ totalCredited + pending`. | `INV-010`, `PROP-007`, `SPEC-BACK-012`, `REQ-COLL-012`, `REQ-VAULT-141` |
| T-09 | P0 | F-04 bounds | Collateralization | `credited` is set at pledge, falls only by debits (seizure, withdrawal, partial removal, deleverage release, reconcile on exit) and rises only in `recredit`, to exactly the live liquidity. Units added to a pledged position are credited only through `recredit`. | `INV-006`, `REQ-VAULT-107` |
| T-10 | P0 | F-20 token | VaultToken | A non-zero balance is held only by the Hub, the AaveAdapter, LPVaultSwap or a registered proxy. Every transfer and mint is along an allowed `(from, to)` pair. | `INV-011`, `PROP-008`, `REQ-VTOKEN-030`, `REQ-VTOKEN-031`, `REQ-VTOKEN-033` |
| T-11 | P0 | F-06 custody | LPVault | A position leaves only in one of two ways:<br>• to its depositor of record, closing the record in the same call;<br>• as a stray position (no custody entry), through the AvanaTimelock.<br>Each LPVault accepts positions only from its pinned position manager, and only on the market's exact shape. | `INV-007`, `PROP-038`, `REQ-VAULT-122`, `REQ-VAULT-123`, `REQ-VAULT-124` |
| T-12 | P1 | F-08 splitting | Collateralization | A debit of `u ≤ Σ credited` walks the largest-first list from the head and debits exactly `u`. Debiting `a` then `b` gives the same state as debiting `a + b`. A debit above Σ credited reverts with no state change. | `INV-015`, `PROP-012`, `PROP-013`, `PROP-014`, `SPEC-BACK-006`, `REQ-VAULT-117` |
| T-13 | P1 | F-08 / F-11 | Collateralization | `remainingCharge = ceil(originalUsdCharge × remaining / originalUnits)` does not depend on how exits are split. The released cap is ≥ 0, and the last exit releases exactly what remains. | `PROP-028`, `SPEC-BACK-005`, `SPEC-CAP-004` |
| T-14 | P1 | F-05 sum | Collateralization | For each market the regular counter plus the top-up slice counter equals Σ `remainingCharge` over the market's open records, and each token and depositor counter equals Σ `remainingCharge` over the open records in its scope (`remainingCharge` on the record's current basis, rebased at re-credit). A subtraction below 0 clamps and emits `CounterSaturated`; it never reverts. | `INV-027`, `PROP-029`, `SPEC-BACK-004`, `REQ-VAULT-127` |
| T-15 | P0 | F-12 / F-17 | Collateralization | The seizure debit equals the drop in the proxy's supplied shares between Avana's own snapshot under the Lock and the read after `liquidationCall`. No debit uses a value the caller supplies. A vault-token donation to the Hub changes no debit. | `INV-014`, `PROP-004`, `SPEC-BACK-007`, `REQ-VAULT-115`, `REQ-VAULT-116`, `REQ-VTOKEN-031` |
| T-16 | P0 | F-07 rate | Hub (vault-token asset) | With `drawCap = 0` on every Spoke, a liquidity fee of 0 and no reinvestment, every Hub function keeps `addedAssets == addedShares`. With that equality, units in = shares = units burned = liquidity removed. | `PROP-040`, `PROP-011`, `INV-004`, `SPEC-HUB-008`, `REQ-VAULT-114` |
| T-17 | P1 | F-02 zero | PositionProxy, Collateralization | Zero units or a zero amount reverts `ZeroAmount`. Zero liquidity after custody reverts `ZeroLiquidity`. A zero-credit record exits only through `releaseZeroCredit`, by its depositor. | `REQ-PROXY-093`, `REQ-PROXY-060`, `REQ-VAULT-107`, `REQ-VAULT-121`, `REQ-COLL-011` |
| T-18 | P1 | F-12 / F-03 | LPVault | `collectFees` pays only the depositor of record, never changes liquidity and never mints. A liquidation's `collect` takes at most the principal its `decreaseLiquidity` returned. | `INV-033`, `INV-044`, `SPEC-BACK-008`, `REQ-VAULT-120` |
| T-19 | P1 | F-03 liveness | AaveAdapter, Collateralization | With zero debt, a depositor's withdrawal succeeds in every price state, Avana pause state and donation state. It is blocked only by an Aave pause of the vault-token reserve or a Hub halt, and, for an account with an unsettled seizure, while Hub shares ≠ assets (`REQ-VAULT-143`). | `INV-045`, `REQ-ACCESS-074`, `REQ-PROXY-077` |
| T-20 | P1 | F-01 integrity | Collateralization | Reconcile on exit:<br>• `release`, `releasePartial`, `recredit`, `releaseForDeleverage`, `releaseZeroCredit` and `settleSeizure` (the reconciling calls of `REQ-VAULT-140`) compute the shortfall from the proxy's shares and debit it once;<br>• reconciliation is skipped while Hub shares ≠ assets. | `INV-058`, `PROP-045`, `SPEC-BACK-011`, `REQ-VAULT-143` |
| T-21 | P2 | F-24 arithmetic | Collateralization, VaultToken, LPVault, Lock, SettlementBudget, PayoutEscrow | No reachable overflow, underflow, division by zero or failing `assert` in any immutable contract. | `PROP-043`, `SPEC-UNIT-006` |
| T-22 | P1 | F-13 / F-20 | VaultTokenFactory | Only the AvanaTimelock deploys a token, and only one per market key. The pool must be canonical for its pinned factory, with a standard tick spacing for concentrated liquidity, and the range aligned by the signed tick remainder (`SPEC-BACK-001`). Decimals are the smallest `d` in [6, 18] with `10^d · v ≥ $1` for the value `v` of one credited unit (`SPEC-UNIT-001`). | `REQ-VTOKEN-035`, `REQ-VTOKEN-036`, `REQ-VTOKEN-037`, `REQ-ACCESS-061`, `SPEC-UNIT-001`, `SPEC-ORC-005` |
| T-23 | P1 | F-21 conservation | PositionProxy | The vault-token balance of the proxy falls by exactly `units` on supply and rises by exactly `units` on withdraw. Every approval it grants is back to 0 by the end of the call. | `SPEC-PROXY-005`, `INV-021`, `REQ-PROXY-094` |
| T-81 | P0 | F-13 duplicate | Collateralization | AMM-neutral key: records are keyed by (`integrationId`, `positionKey`); a position of another integration with the same key is not refused, the same pair is. | `REQ-VAULT-027`, `REQ-COLL-027` |
| T-82 | P0 | F-04 bounds | Collateralization, LPVault | Exact shape: a pledge succeeds only when the position's pool and range equal the market's exactly, and the LPVault's `marketOfPosition` equals the vault token's market. | `REQ-COLL-024`, `REQ-VAULT-009`, `REQ-AMM-CORE-006`, `SPEC-BACK-001` |
| T-83 | P0 | F-06 backing | Uniswap v3 and Slipstream integrations | The composition at the oracle price clamped to the range is at most what the units hold, valued at oracle prices, at every spot price. | `SPEC-AMM-V3-001`, `REQ-AMM-V3-005` |
| T-84 | P1 | F-21 conservation | Collateralization | Every amount array has one entry per market token (2 to 8); each token's pending payout is at most its pending amount and the final settlement pays the exact remainder. | `REQ-COLL-028`, `SPEC-BACK-012` |
| T-85 | P0 | F-13 duplicate | Collateralization, ProxyManager | One market per proxy: a proxy's records all belong to `proxyMarket[proxy]`, written once; two (wallet, spoke, marketId) triples never share a proxy address. | `REQ-COLL-031`, `REQ-PROXY-053`, `REQ-PROXY-100` |
| T-86 | P0 | F-05 sum | Collateralization, RiskModule | Hub-wide token, depositor and pool counters are one counter per Hub over every Spoke and market of the chain, so adding Spokes never multiplies a cap. | `REQ-COLL-026`, `REQ-VAULT-034` |
| T-87 | P1 | F-03 liveness | Collateralization | At most 16 records per account and market; the seizure of all of them fits the per-transaction gas cap. | `REQ-VAULT-025`, `SPEC-BACK-016` |
| T-88 | P0 | F-19 reentrancy | Collateralization, every LPVault, Lock | Every function that moves a position, token or ledger amount runs only in a call tree opened by the Lock's two members, AaveAdapter and LPVaultSwap. | `REQ-LOCK-004`, `REQ-LOCK-028`, `REQ-COLL-029` |

### 6.2 liquidation

| ID | Pri | Family | Contract | Property | Spec IDs |
|---|---|---|---|---|---|
| T-30 | P0 | F-21 conservation | LPVaultSwap, SettlementMath | `F + K + R + B == D + (F + φ) + A + keeperOut` in every call. Once Aave's pull and the budget cap pass, no checked operation reverts. | `INV-035`, `PROP-015`, `SPEC-LIQ-010`, `REQ-SWAP-062` |
| T-31 | P0 | F-21 / F-06 | LPVaultSwap | Every `liquidate`, `liquidatePermissionless` and `settlePending` ends with:<br>• each token balance equal to its balance before the call;<br>• zero allowance to the Spoke, the FlashMinter and every route. | `INV-021`, `PROP-016` |
| T-32 | P0 | F-17 over-seizure | LPVaultSwap | The oracle value of vault tokens seized is ≤ `debtRepaid × LB` + the value of one base unit, where `LB` is the Spoke's bonus at that health factor. With `liquidationFee = 0`, every seized share goes to LPVaultSwap. | `INV-032`, `SPEC-LIQ-001`, `SPEC-LIQ-004`, `SPEC-HUB-005` |
| T-33 | P0 | F-17 no healthy liquidation | LPVaultSwap | A liquidation completes only if all of these hold:<br>• the account's health factor is < 1;<br>• every price passes the liquidation price checks;<br>• the grace-window rule allows it;<br>• Hub shares equal assets. | `REQ-SWAP-050`, `REQ-SWAP-051`, `REQ-SWAP-052`, `REQ-SWAP-055`, `INV-030` |
| T-34 | P0 | F-11 rounding | SettlementMath | Rounding is conservative throughout:<br>• `V` rounds down;<br>• `minGho = max(0, ⌈V(1 − s)⌉ − U − floorRoundingAllowanceGho)` never asks for more than `V(1 − s)`;<br>• a successful routed settlement has `R ≥ minGho`. | `INV-034`, `PROP-018`, `PROP-048`, `SPEC-LIQ-004`, `SPEC-LIQ-005`, `REQ-SWAP-060` |
| T-35 | P1 | F-24 / F-11 | SettlementMath | The effective slippage `s` satisfies `bNet × (10⁴ − s) ≥ 10⁴ × (10⁴ + costsBps)` for every bonus and cost in range. The net bonus and costs round against the keeper. | `PROP-017`, `SPEC-LIQ-001`, `SPEC-LIQ-002`, `SPEC-LIQ-003` |
| T-36 | P1 | F-14 / F-21 | LPVaultSwap | The Avana fee `A` is ≤ the realised surplus `max(0, R − D − φD)`. `A = 0` whenever the budget is drawn or settlement is in kind. `A` is paid only to `feeRecipient`. | `INV-036`, `SPEC-LIQ-008`, `SPEC-LIQ-009` |
| T-37 | P0 | F-01 / F-14 | SettlementBudget | Only LPVaultSwap, while holding the Lock, can draw. Each draw is ≤ the per-call cap. Draws within any rolling 24-hour window are ≤ the 24-hour cap and ≤ `PER_24H_CAP_MAX` in total. | `INV-037`, `PROP-020`, `SPEC-SET-002`, `SPEC-SET-003`, `REQ-BUDGET-013`, `REQ-BUDGET-014`, `REQ-BUDGET-023` |
| T-38 | P0 | F-02 zero | LPVaultSwap, SettlementBudget | A budget draw happens only inside a `liquidate` that debited ≥ 1 vault-token unit. `liquidate` with zero units received reverts `NothingSeized` before any draw or fee. | `PROP-047`, `INV-038`, `REQ-SWAP-056` |
| T-39 | P1 | F-08 / F-11 | SettlementMath, SettlementBudget | Each draw is ≤ the value of one base unit + 1 wei + `U + floorRoundingAllowanceGho`. Repeated small liquidations cannot draw more in total than one liquidation of the same total size plus one such bound per call. | `INV-038`, `SPEC-SET-001` |
| T-40 | P1 | F-11 / F-14 | LPVaultSwap | In-kind settlement:<br>• runs only from the approved-keeper `liquidate`, only while in-kind is enabled and unexpired, only with keeper GHO, and with no budget draw and no Avana fee;<br>• the keeper's oracle value is ≤ `⌊D × bNet / 10⁴⌋`;<br>• `0 ≤ kᵢ ≤ aᵢ`. | `INV-039`, `PROP-019`, `PROP-021`, `SPEC-LIQ-011`, `SPEC-LIQ-012`, `SPEC-LIQ-013`, `REQ-SWAP-063` |
| T-41 | P0 | F-05 / F-06 | PayoutEscrow | For every borrower and token:<br>• amount credited = amount claimed + `claimable`;<br>• `totalClaimable == Σ claimable`;<br>• deposits come only from LPVaultSwap under the Lock, measured as a balance delta;<br>• `claim` is reentrancy-safe and leaves the credit unchanged when the transfer fails. | `INV-061`, `PROP-052`, `REQ-ESCROW-009`, `REQ-ESCROW-011`, `REQ-ESCROW-015`, `REQ-ESCROW-016` |
| T-42 | P1 | F-20 token | LPVaultSwap, PayoutEscrow | A borrower-remainder transfer that reverts, returns `false` or runs out of `PAYOUT_TRANSFER_GAS` does not revert the liquidation: the remainder goes to the PayoutEscrow. Proved under the standard, false-returning and missing-return token models. | `REQ-SWAP-082`, `REQ-SWAP-083`, `REQ-ESCROW-011` |
| T-43 | P0 | F-23 callback | LPVaultSwap, routes | `onFlashLoan` succeeds only from the GHO FlashMinter, with initiator LPVaultSwap and a matching context. A swap callback succeeds only from the route's fixed pool, inside a hop. A flash fee above `maxFlashFeeBps` reverts before `liquidationCall`. | `INV-040`, `PROP-036`, `REQ-SWAP-053`, `REQ-SWAP-054`, `REQ-ROUTE-029` |
| T-44 | P1 | F-14 / F-21 | Settlement routes | `convert` and `buyExactOut` revert unless called by LPVaultSwap holding the Lock. Recovered GHO is measured as LPVaultSwap's balance increase. A buy route never spends more than `maxGhoIn` and delivers exactly `amountOut`. | `REQ-ROUTE-025`, `REQ-ROUTE-040`, `SPEC-LIQ-006` |
| T-45 | P0 | F-03 / F-17 | LPVaultSwap | `liquidatePermissionless` admits any caller, never draws the budget, never takes the in-kind branch and uses only `PrimaryThenBackup` mode. When proceeds fall short, it reverts `InsufficientProceeds`. | `INV-062`, `PROP-053`, `REQ-SWAP-080`, `REQ-SWAP-081`, `REQ-ACCESS-139` |
| T-46 | P0 | F-17 bad debt | Coverage Spoke, Borrow Spoke | A Hub deficit for an Avana Borrow Spoke is reported only inside an LPVaultSwap `liquidationCall` that leaves the account with no collateral on that Spoke. `eliminateDeficit` runs only through `coverDeficit`, for an allowlisted Spoke, and for at most `min(maxAmount, recorded deficit, funded balance)`. | `INV-041`, `INV-042`, `PROP-039`, `SPEC-FLR-001`, `REQ-FLR-029`, `REQ-FLR-030`, `REQ-FLR-031` |
| T-47 | P1 | F-07 / F-15 | Coverage Spoke | `fundedBalance = floor(addedShares × (A + 1e6) / (S + 1e6))` rounds down. A withdrawal executes only at or after `executableAt`, and only once. | `SPEC-FLR-002`, `SPEC-FLR-003`, `REQ-FLR-033`, `REQ-FLR-034` |
| T-48 | P1 | F-12 non-interference | LPVaultSwap | A liquidation of proxy `p` changes no other proxy's supplied shares, debt or records. A donation of vault tokens or GHO to LPVaultSwap or the Hub cannot change its seized units, payout or draw. | `INV-014`, `INV-021`, `INV-053` |
| T-49 | P1 | F-01 / F-14 | LPVaultSwap | `settlePending` succeeds only for an active keeper. It hands the LPVault `min(held, pending units)` and sends every released pool-token unit only to the market's routes. `R ≥ minPending`. | `PROP-051`, `SPEC-LIQ-014`, `REQ-SWAP-068`, `REQ-SWAP-071` |
| T-50 | P1 | F-15 liveness | LPVaultSwap | An account with health factor < 1 is liquidatable by an active keeper when all of these hold:<br>• prices are accepted;<br>• no Avana liquidation halt, no Aave pause and no Hub halt;<br>• Hub shares equal assets;<br>• the account is outside the grace window.<br>Keeper removal never leaves fewer than `keeperFloor` keepers. | `INV-046`, `INV-048`, `PROP-035`, `REQ-SWAP-065` |
| T-51 | P1 | F-03 deadline | LPVaultSwap | Success implies `block.timestamp ≤ deadline` and `keeperOut ≥ minPayout`. A non-zero `minPayout` in `InKind` mode reverts. | `PROP-022`, `REQ-SWAP-078`, `REQ-SWAP-079` |
| T-52 | P2 | F-24 arithmetic | LPVaultSwap, routes | No reachable overflow or division by zero inside the listing bounds. | `PROP-044` |

### 6.3 control

| ID | Pri | Family | Contract | Property | Spec IDs |
|---|---|---|---|---|---|
| T-53 | P0 | F-14 matrix | All upgradeable contracts | Every restricted selector reverts unless the caller holds the role in the published role map. `APPLICATION_ADMIN` is held only by the AvanaTimelock. Timelock self-only selectors revert when called directly. | `PROP-034`, `REQ-ACCESS-002`, `REQ-ACCESS-003`, `REQ-ACCESS-116` |
| T-54 | P0 | F-15 / F-25 | AvanaTimelock | `schedule` needs a delay ≥ the required delay of every call in the operation. `execute` succeeds only in `[readyAt, readyAt + GRACE_PERIOD)` and with its predecessor done. `updateDelay` always reverts. `setNormalDelay` stays in `[SHORT_DELAY, MAX_DELAY]`. | `SPEC-GOV-001`, `SPEC-GOV-002`, `SPEC-GOV-003`, `SPEC-GOV-013`, `REQ-ACCESS-030`, `REQ-ACCESS-117`, `REQ-ACCESS-118`, `REQ-ACCESS-125` |
| T-55 | P0 | F-14 / F-25 | AvanaTimelock | A role-change operation can be cancelled only by a holder of both `CANCELLER_ROLE` and `DAO_CANCELLER_ROLE`. Any canceller can cancel other operations inside the cancel window. The timelock is its own only admin. | `SPEC-GOV-005`, `SPEC-GOV-007`, `REQ-ACCESS-001`, `REQ-ACCESS-119`, `REQ-ACCESS-152` |
| T-56 | P0 | F-15 state machine | MarketRegistry, AaveAdapter | Pause transitions follow `SPEC-GOV-004`. The freeze guardian can only freeze. `Frozen` blocks new-account pledges and borrowing. `Paused` blocks every pledge, borrowing and withdraw-with-debt. Neither blocks repay, debt-free withdrawal, fee collection or the seized-unit burn. | `SPEC-GOV-004`, `REQ-ACCESS-062`, `REQ-ACCESS-063`, `REQ-ACCESS-073`, `REQ-ACCESS-074`, `REQ-ACCESS-122`, `REQ-ACCESS-123`, `REQ-ACCESS-124`, `REQ-ADAPTER-072`, `REQ-ADAPTER-073` |
| T-57 | P0 | F-03 liveness | AaveAdapter, PositionProxy | When the proxy has GHO debt, a repay by any payer succeeds whenever all of these hold:<br>• the amount is positive;<br>• the deadline is unexpired;<br>• the payer has sufficient allowance and balance;<br>• the GHO reserve is not paused and the Hub is not halted.<br>Repay at zero debt returns 0 and moves no token. Repay calls neither the RiskModule nor the ParameterStore. | `INV-043`, `PROP-032`, `REQ-PROXY-068`, `REQ-PROXY-069`, `REQ-PROXY-070` |
| T-58 | P0 | F-22 health | AaveAdapter, RiskModule | After every borrow and every withdraw-with-debt, the rescue-excluded health factor read after the Spoke call is ≥ `max(1, hardHealthFloor(m), minHealthFactor)`; the optional hard floor is off (0) by default and no other opening floor exists (`Q-398`). | `INV-025`, `PROP-031`, `SPEC-PROXY-001`, `SPEC-CF-003`, `REQ-ADAPTER-059`, `REQ-PROXY-067` |
| T-59 | P0 | F-16 oracle gate | RiskModule, AaveAdapter | A borrow or withdraw-with-debt completes only if all of these hold:<br>• every collateral market of the account is Live;<br>• every collateral input and debt feed is ≤ `borrowPriceMaxAge` old and not in the future;<br>• each debt price source equals the recorded one. | `INV-023`, `INV-024`, `SPEC-PROXY-002`, `REQ-ADAPTER-055`, `REQ-PROXY-063`, `REQ-PROXY-064`, `REQ-PROXY-065` |
| T-60 | P0 | F-15 / F-04 | AaveAdapter, RiskModule | A borrow is refused if any enabled vault-token reserve of the account is paused or frozen on Aave, or the GHO reserve is paused, for the reviewed RiskModule; for any RiskModule, Aave refuses a paused or frozen borrowed reserve. | `INV-060`, `PROP-046`, `PROP-050`, `REQ-ADAPTER-056`, `REQ-ADAPTER-062`, `REQ-PROXY-080` |
| T-61 | P0 | F-12 / F-04 | AaveAdapter | `borrowNonce` rises by exactly 1 per successful borrow and is unchanged by a reverted one. At most one borrow succeeds per signed nonce. | `INV-019`, `REQ-PROXY-058`, `REQ-PROXY-059` |
| T-62 | P0 | F-13 binding | ProxyManager, PositionProxy | One proxy per `(wallet, spoke)`, at the CREATE2 address fixed by the ProxyManager. Only the AaveAdapter can request deployment. `wallet` and `spoke` are set once in the creating call and never change. A second `initialize` reverts. | `INV-012`, `PROP-009`, `PROP-010`, `REQ-PROXY-092`, `REQ-PROXY-097`, `REQ-ARCH-035` |
| T-63 | P0 | F-14 access | PositionProxy | Every state-changing proxy function reverts unless `msg.sender` is the AaveAdapter, including calls from the bound wallet. The proxy makes no `delegatecall` and no arbitrary external call. | `REQ-PROXY-091`, `REQ-ARCH-034`, `PROP-010` |
| T-64 | P0 | F-18 upgrade | AaveAdapter, ProxyManager, MarketRegistry, ParameterStore, RiskModule, LPOracle, LPVaultSwap | Only the AvanaTimelock, through `APPLICATION_ADMIN` at the normal delay, can upgrade or call `setProxyImplementation`. The new implementation must hold code. Implementations cannot be initialised. Storage layouts extend append-only inside their ERC-7201 namespaces. | `TEST-137`, `REQ-ACCESS-031`, `REQ-ACCESS-147`, `REQ-PROXY-003`, `REQ-PROXY-098`, `REQ-ADAPTER-004`, `REQ-ORACLE-080` |
| T-65 | P0 | F-18 containment | Collateralization, VaultToken, LPVault, Lock, SettlementBudget, PayoutEscrow | For any implementation of RiskModule, ParameterStore, LPOracle or LPVaultSwap, all of these hold:<br>• no vault token is minted without backing;<br>• no proxy is registered or rebound outside the ProxyManager path;<br>• no position or settlement-budget token moves outside its allowed flow.<br>The immutable contracts have no upgrade path and no settable target. | `INV-018`, `INV-052`, `INV-053`, `TEST-130`, `TEST-131`, `TEST-132`, `TEST-133` |
| T-66 | P0 | F-16 / F-03 | LPOracle, LPPriceMath | `latestAnswer()` never reverts and returns a value > 0 in every state, for every feed behaviour: revert, zero, negative, stale, out-of-bounds, out-of-gas inside `try`. While Cached or Expired, it returns the last accepted price. | `INV-055`, `PROP-027`, `SPEC-ORC-012` |
| T-67 | P0 | F-16 staleness | LPOracle | Each price keeps its original source timestamp, and re-reading or caching the same round never refreshes it. A cached price is written only from a validated, Live observation newer than the stored one. A failure moves Cached → Expired after `cachedWindow`. | `INV-056`, `SPEC-ORC-013`, `SPEC-ORC-015`, `REQ-ORACLE-067`, `REQ-ORACLE-068` |
| T-68 | P1 | F-16 manipulation | LPOracle | Each of these marks the market Drifting:<br>• route disagreement beyond tolerance;<br>• TWAP drift beyond `twapToleranceTicks`;<br>• a USD-band breach;<br>• a clamped sqrt price.<br>Liquidation pauses for at most `disagreementPauseMax` and is then blocked as Expired until the routes agree. The first-observation time is set once per episode. | `INV-059`, `PROP-049`, `SPEC-ORC-010`, `SPEC-ORC-011`, `SPEC-ORC-016`, `REQ-ORACLE-070`, `REQ-ORACLE-071`, `REQ-ORACLE-072`, `REQ-ORACLE-073` |
| T-69 | P1 | F-24 / F-11 | LPPriceMath | Price math is safe and correctly rounded:<br>• `price8 = isqrt(4·v0·v1) − 1` is ≥ 1 and ≤ the exact `2√(v0·v1)`;<br>• `4·v0·v1` cannot overflow;<br>• the stable ceiling never raises a value, is monotone and is symmetric in token order;<br>• the derived sqrt price lies in `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)`;<br>• the agreement check is exact and symmetric. | `PROP-023`, `PROP-024`, `PROP-025`, `PROP-026`, `SPEC-ORC-003`, `SPEC-ORC-004`, `SPEC-ORC-008`, `SPEC-ORC-009` |
| T-70 | P1 | F-09 / F-15 | LPOracle | `poke()` is idempotent within a block. It reverts with no state change below `pokeMinGas`. An outage is recorded only from successfully read source timestamps, never from a caught error. | `INV-031`, `REQ-ORACLE-074`, `REQ-ORACLE-075` |
| T-71 | P1 | F-25 bounds | ParameterStore, MarketRegistry | Every tighten setter moves strictly in the safer direction and stays inside its hard bounds and liquidation-liveness bounds. Loosen setters run only at the normal delay. A configuration that would fail `checkConfig` reverts. | `INV-047`, `PROP-042`, `SPEC-GOV-011`, `SPEC-GOV-012`, `REQ-CONFIG-067`, `REQ-ACCESS-120`, `REQ-PSTORE-013` |
| T-72 | P0 | F-19 lock | Lock and the fixed set | Lock rules:<br>• `acquire` succeeds only for a constructor-fixed member while the Lock is free;<br>• `release` succeeds only for the holder;<br>• no function runs through `delegatecall`;<br>• every inner entry point accepts calls only while the Lock is held by its named caller. | `INV-054`, `PROP-037`, `REQ-LOCK-019`, `REQ-LOCK-020`, `REQ-LOCK-021`, `REQ-LOCK-022`, `REQ-LOCK-023`, `REQ-LOCK-024` |
| T-73 | P1 | F-19 / F-10 | Lens, Collateralization, LPVault | Every Lens read and every custody view that a third party could call mid-operation reverts `Locked` while the Lock is held, so no price or position read observes an intermediate state. | `REQ-LENS-021`, `REQ-VAULT-125`, `REQ-VAULT-160` |
| T-74 | P1 | F-10 / F-23 | Lens | `previewLiquidation` returns the units, debt and payout that `liquidate` would produce in the same state. It reverts on the same unknown proxy or unapproved debt reserve that LPVaultSwap rejects. Paging returns empty past the end and rejects limits above `LENS_MAX_PAGE`. | `REQ-LENS-023`, `REQ-LENS-024`, `REQ-LENS-032`, `REQ-LENS-033` |
| T-75 | P1 | F-15 lifecycle | MarketRegistry | Market lifecycle:<br>• a market moves only Registered → Active → Offboarding;<br>• `activateMarket` succeeds only from Registered with every on-chain check passing;<br>• `cancelRegistration` deletes only a Registered market;<br>• the in-kind window closes at `inKindUntil` without a transaction. | `REQ-ACCESS-033`, `REQ-ACCESS-034`, `REQ-ACCESS-036`, `REQ-ACCESS-134`, `REQ-CONFIG-065`, `REQ-CONFIG-066`, `REQ-CONFIG-068`, `SPEC-GOV-010` |
| T-76 | P1 | F-14 / F-23 | MarketRegistry | `restoreRoute` and `restoreBuyRoute` accept only the previously approved address. A route can never be the market's own pool or share a dependency with the other slot. `disableRoute` clears only the enabled flag. | `REQ-ACCESS-047`, `REQ-ACCESS-048`, `REQ-ACCESS-127`, `REQ-ROUTE-030` |
| T-77 | P1 | F-04 / F-25 | RiskModule | A pledge completes only if, after it:<br>• every exposure counter is within its cap;<br>• the pool-share cap holds;<br>• the market's price state allows the pledge type;<br>• the value is ≥ `minPledgeUsd`.<br>The returned charge satisfies `0 < usdCharge < 2^128` and `sliceUsd ≤ usdCharge`. | `INV-026`, `INV-028`, `SPEC-CAP-002`, `SPEC-CAP-005`, `REQ-RISK-048`, `REQ-RISK-049`, `REQ-RISK-051`, `REQ-RISK-064`, `REQ-VAULT-110` |
| T-78 | P1 | F-15 / F-04 | AaveAdapter | No new-account pledge, borrow or withdraw-with-debt completes while any of these holds:<br>• the approved Aave configuration has drifted (Spoke implementation, debt-reserve set, and the three standard-Spoke settings `receiveSharesEnabled == false`, `liquidationFee == 0` and no reinvestment controller);<br>• Hub shares ≠ assets. | `INV-029`, `INV-004`, `REQ-ADAPTER-057`, `REQ-ADAPTER-058`, `REQ-RISK-050` |
| T-79 | P2 | F-25 bounds | SettlementBudget | Only the AvanaTimelock changes caps or withdraws. `perCall ≤ per24h ≤` the immutable maximum. A non-zero `perCall` is ≥ `floorRoundingAllowanceGho`. Tightening lowers a cap and loosening raises it. | `REQ-BUDGET-016`, `REQ-BUDGET-017`, `REQ-BUDGET-018`, `REQ-BUDGET-019`, `REQ-ACCESS-058`, `REQ-ACCESS-059` |
| T-80 | P2 | F-04 config | Hub configuration | GHO drawn by each Borrow Spoke is ≤ its `drawCap`. The Borrow Spoke `drawCap`s sum to ≤ `creditLineGho`. Every vault-token asset has `drawCap = 0` on every Spoke. | `INV-057`, `SPEC-HUB-003` |
| T-89 | P0 | F-23 callback | LPVaultSwap, IFlashSource | A flash loan is taken only within `maxFlashLoan` and `maxFlashFeeBps`; the callback is accepted only from the Pool, with the source as initiator, one asset and the active context; the lender is never the CDP Spoke's home Hub or the debt reserve's funding Hub; the source changes only through the timelock; a short source falls back to the caller-funded path. | `REQ-FLASH-001`…`REQ-FLASH-010`, `SPEC-LIQ-015` |
| T-90 | P0 | F-17 liquidation | AaveAdapter, RiskModule, VaultToken | On the standard Aave V4 Spoke only LPVaultSwap can complete a liquidation (the vault token's transfer rule), and drift in `receiveSharesEnabled`, `liquidationFee` or the reinvestment controller trips `CONFIG_DRIFT`, which stops new activity and never liquidation, repay or a debt-free exit. | `REQ-ADAPTER-029`…`REQ-ADAPTER-033`, `REQ-RISK-078`, `REQ-RISK-086` |

### 6.4 Highest-value ten

When proof capacity is limited, these ten come first. They cover the bug classes that have caused the largest losses in comparable lending and vault protocols: unbacked minting, solvency bypass, share-rate rounding, over-seizure, oracle staleness and access or upgrade takeover.

1. **T-01:** vault-token supply = Σ credited + pending (custody).
2. **T-02:** live units ≥ credited, and the record's LPVault holds the position (custody).
3. **T-06:** only the AaveAdapter mints or burns (custody).
4. **T-15:** seizure debit = Avana's own share-drop snapshot, unaffected by donations (custody).
5. **T-30:** GHO conservation identity of every liquidation (liquidation).
6. **T-32:** no over-seizure beyond `debtRepaid × LB` + one unit (liquidation).
7. **T-37:** SettlementBudget draws only from LPVaultSwap under the Lock, within per-call and 24-hour caps (liquidation).
8. **T-58:** health factor ≥ the opening floor after every borrow and withdraw-with-debt (control).
9. **T-67:** prices keep their source timestamps, and staleness gates borrowing (control).
10. **T-64:** upgrades only through the timelock, with initializers locked and layouts append-only (control).

## 7. References

These are public reports and specifications whose methods inform this methodology.

- **Certora:**
  - Aave V4 Hub, Spoke and Libraries FV reports (2026-03-09) and TokenizationSpoke FV report (2026-04-13): https://github.com/aave/aave-v4/tree/main/audits
  - Aave V4 CVL specifications: https://github.com/aave/aave-v4/tree/feat/certora-cvl-v0.5.11/certora
  - Aave V3 CVL: https://github.com/aave-dao/aave-v3-origin/tree/main/certora
  - GHO CVL and reports: https://github.com/aave/gho-core/tree/main/certora
  - Morpho Blue CVL: https://github.com/morpho-org/morpho-blue/tree/main/certora
  - Euler EVK: https://github.com/euler-xyz/euler-vault-kit/blob/master/audits/Certora_EVK_report.pdf
  - Compound III: https://certora.cdn.prismic.io/certora/e7ca6508-fad8-4a41-8588-b3312d8b750e_Compound+Report.pdf
  - Balancer v3: https://github.com/balancer/balancer-v3-monorepo/blob/main/audits/certora/2024-09-04.pdf
  - Lido Dual Governance CVL: https://github.com/lidofinance/dual-governance/tree/main/certora
- **Runtime Verification** (Kontrol and K): https://github.com/runtimeverification/publications/tree/main/reports/smart-contracts
  - Lido Dual Governance FV: https://strapi-rv-bucket-01.s3.us-east-2.amazonaws.com/Dual_Governance_Formal_Verification_6603b61bc5.pdf
- **Trail of Bits:**
  - Aave V4: https://github.com/aave/aave-v4/blob/main/audits/2025-11-06_Aave-V4_TrailOfBits.pdf
  - Property catalogs: https://github.com/crytic/properties
- **ChainSecurity:**
  - Aave V4: https://github.com/aave/aave-v4/blob/main/audits/2026-01-28_Aave-V4_ChainSecurity.pdf
  - Euler EVK: https://github.com/euler-xyz/euler-vault-kit/blob/master/audits/ChainSecurity_EVK_report.pdf
- **a16z Halmos examples:** https://github.com/a16z/halmos/tree/main/examples
- **Enigma Dark** (Euler EVK invariant campaign): https://github.com/euler-xyz/euler-vault-kit/blob/master/audits/EnigmaDark_EVK_report.pdf
- **Veridise** money-market report: https://veridise.com/wp-content/uploads/2025/12/VAR-Venture23-250804-MoneyMarket-V2.pdf
- **Invariant suites:**
  - Morpho Blue: https://github.com/morpho-org/morpho-blue/tree/main/test/invariant
  - Euler EVK: https://github.com/euler-xyz/euler-vault-kit/tree/master/test/invariants
