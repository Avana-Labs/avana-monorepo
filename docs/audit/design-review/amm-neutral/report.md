# AMM-neutral design review: combined report

Date: 2026-11-10 (run `AMMN-R1`). Scope: the proposed move from "Uniswap v3 full-range positions, GHO debt, one Hub on Ethereum" to a shared core, with one integration per AMM protocol, several Hubs and several chains. Uniswap v3 (Ethereum) and Aerodrome Slipstream (Base) are the first integrations.

No Solidity implementation exists yet. Every result below checks the spec, the interfaces, models, simulations, and live external sources. None of it checks contract code.

## Sources

| Review | File | Method | Findings |
|---|---|---|---|
| Red team | [red-team.md](red-team.md) | Exploit walkthroughs with numeric demos | AMMN-RT-01…16 |
| Flow walkthroughs | [flow-walkthroughs.md](flow-walkthroughs.md) | Every persona and flow, step by step | AMMN-FLOW-01…26 |
| Integration assumptions | [integration-assumptions.md](integration-assumptions.md) | 60 assumptions checked against the pinned source, the address book, Chainlink's directory and live `eth_call` | AMMN-INT-01…08 |
| Gas and DoS | [gas-dos.md](gas-dos.md) | Gas models, griefing and liveness | AMMN-GAS-01…16 |
| Architecture options | [architecture-options.md](architecture-options.md) | Alternatives compared, with counts | AMMN-ARCH-01…10 |
| State machine | [state-machine.md](state-machine.md) | Quint model of 2 Hubs and 3 Spokes (`docs/spec/05-verification/quint/topology*.qnt`), 20 tests and 40 simulator runs | AMMN-SM-01…06 |
| Topology simulation | [../topology-options.md](../topology-options.md) | 1,000-user engine, 3 topologies, 5 seeds, 125 runs (`SIM-R7`) | Recommendation |
| Pricing models | `docs/spec/05-verification/z3/amm-pricing/`, `hypothesis/test_hyp_amm_pricing.py` | Z3 and Hypothesis, 11 tests | Listing guards |
| Verification coverage | [verification-coverage.md](verification-coverage.md) | trace.py analysis | Coverage gaps |

Background research (Aave V4 flash loans, Base, Slipstream, Uniswap v4 hooks) lives in Avana's internal references, outside the repo.

## Security score: 52 / 100 for the proposed design as written

The score starts at 100 and subtracts 6 per Critical, 2 per High, 0.5 per Medium and 0 per Low, after merging duplicates. It is capped at 60 while any Critical finding is open.

| Severity | Count after merge |
|---|---|
| Critical | 6 |
| High | 13 |
| Medium | 22 |
| Low | 14 |

- **Proposed design as written: 52.**
- **Current single-market v3 spec:** a launch blocker also applies to it, AMMN-INT-01, because the stablecoin feeds have a 24 h heartbeat. Its score would be about 70.
- **Projected after the Critical and High fixes are in the spec and re-verified:** about 85.
- **Above 90:** needs the implementation, Foundry and prover runs, and external audits.

## Resolution status

Status on 2026-11-10, after the AMM-neutral spec rewrite and the alignment rulings. Every Critical and High finding is resolved in the spec text and mirrored in [5.3](../../../spec/05-verification/03-audit-findings.md) and the [findings register](../../findings-register.md) with status "Resolved in spec — re-verification pending": the named rule states the fix, and the proving check listed in the register has not yet passed in a logged run against the rewritten pages. "Spec-stage residual" is the severity left once the rule holds as written; it is not a code result.

### Critical

| ID | Resolving rule | Decision | Spec-stage residual |
|---|---|---|---|
| AMMN-RT-01 | `REQ-AMM-CORE-006` (a pledge needs the market's exact `[tickLower, tickUpper]`), `INV-005` | `Q-359` | Informational: a mismatched range reverts before any credit |
| AMMN-INT-01 | `SPEC-ORC-019` (fresh while age ≤ feed heartbeat + `heartbeatMargin`, 1,800 s), `REQ-ORACLE-054`, second source `REQ-ORACLE-100` | `Q-364` | Low: a stablecoin primary at 86,400 s is listable; borrowing waits only while the second source disagrees |
| AMMN-FLOW-01, AMMN-GAS-09 | `INV-091`, `REQ-LOCK-004` (two Lock members, AaveAdapter and LPVaultSwap) | `Q-362` | Informational: new Spokes and markets need no Lock redeploy |
| AMMN-FLOW-02, AMMN-INT-05 | `INV-095`, `REQ-FLASH-001`, `REQ-FLASH-002` (`IFlashSource` on the Aave V3 Pool, premium check `φ × 10⁴ ≤ maxFlashFeeBps × F`) | `Q-362`, `Q-365` | Low: short flash liquidity falls back to the caller-funded path |
| AMMN-SM-03 | `INV-064`, `INV-065`, `REQ-PROXY-001` (logic-free immutable proxy, no migration) | `Q-359` | Informational: exits never depend on proxy code |
| AMMN-RT-02 | `SPEC-AMM-CORE-001`, `SPEC-ORC-005`, `INV-078` (oracle ratio clamped to the range, amounts floored then −1 unit) | `Q-359`, `Q-363` | Informational: the clamp bounds a depegged market at its range edge |

### High

| ID | Resolving rule | Decision | Spec-stage residual |
|---|---|---|---|
| AMMN-INT-04, AMMN-ARCH-07 | `INV-093`, `REQ-HUB-092` (standard Spoke, 5-argument `liquidationCall` with `receiveShares = false`) | `Q-362`, `Q-281` | Informational |
| AMMN-RT-03, AMMN-SM-04, AMMN-INT-07 | `INV-093`, `REQ-RISK-078` (the three required settings, drift trips a breaker), `REQ-ADAPTER-036` and `REQ-VTOKEN-006` (token admits only proxy → Hub, Hub → proxy and Hub → LPVaultSwap) | `Q-362`, `Q-281` | Low: from an Aave change until the drift check trips `CONFIG_DRIFT` (every Avana entry point and a per-block keeper poke), a seizure outside LPVaultSwap is an accepted residual bounded by the Spoke draw caps; after that new activity stops until restored, and liquidation continues |
| AMMN-RT-04, AMMN-RT-16, AMMN-FLOW-04 | `INV-064`, `INV-065`, `REQ-PROXY-050` (CREATE2 salt over `(wallet, spoke, marketId)`, no migration) | `Q-359` | Informational |
| AMMN-RT-05 | `INV-092`, `REQ-COLL-026` (one ledger per chain; token and depositor caps keyed by Hub; the pool-share cap per pool, summed over every market of that pool on the chain) | `Q-361` | Informational |
| AMMN-SM-01, AMMN-RT-11, AMMN-FLOW-05 | `INV-094`, `SPEC-HUB-003`, `REQ-CONFIG-081` (funding Hub owns the cap, one registry sums lines) | `Q-360` | Informational: cross-Hub lines are off at launch |
| AMMN-GAS-01 | `INV-096` (a), `REQ-AMM-CORE-015` (at most 16 records per account per market, so one liquidation of the largest account fits the per-transaction gas limit: `G = 1.31M + 0.24M × 16 = 5.15M ≤ 16,777,216`) | `Q-362`, `Q-381` | Informational |
| AMMN-GAS-02 | Resolved by decision: no minimum; Avana keeper pays gas. `INV-096` (b): no minimum debt on any chain; Avana's own keepers liquidate every account and Avana pays the gas, with the permissionless fallback kept; `SPEC-CHAIN-001` states the per-chain gas model in gas units only | `Q-381` (supersedes `Q-311`, `Q-317`, `Q-362`, `Q-380` on minimum debt) | Informational: liquidation never depends on a keeper's profit; keeper gas is an Avana operating cost |
| AMMN-FLOW-03, AMMN-INT-06 | `INV-098`, `REQ-CHAIN-003`, `REQ-ORACLE-099` (sequencer feed and grace period per L2) | `Q-362`, `Q-365` | Informational |
| AMMN-INT-02 | `EXT-013`, `REQ-ROUTE-011` (no GSM as a primary route or flash dependency) | `Q-365`, `Q-341` | Informational |
| AMMN-FLOW-12 | `EMG-052`, `EMG-064` (Aave-side halt scope, playbook and keeper path); accepted risk (`ATTACK-180`, `FINDING-228`) | `Q-346` | Medium, accepted: an Aave halt of a Spoke or reserve still stops that market's repay, withdraw and liquidation; Aave owns that control and the playbook covers it |
| AMMN-FLOW-14, AMMN-RT-09 | `INV-070`, `INV-083`, `REQ-ROUTE-006` (route per token class, stressed at full one-sidedness) | `Q-339`, `Q-340` | Low |
| AMMN-RT-06, AMMN-GAS-03 | `REQ-AMM-V4-001` (hook allowlist with no remove-liquidity hooks or deltas) | `Q-302` | Informational: Uniswap v4 is not listed at launch |
| AMMN-RT-07 | `REQ-AMM-CURVE-002`, `REQ-AMM-BAL-002`, `REQ-AMM-CORE-012` (reentrancy-lock check, `getReserves`, effective supply, per-block quote-change cap `REQ-ORACLE-103`) | `Q-302` | Informational: v2, Curve and Balancer are not listed at launch |

### Spec-stage score: 79 / 100

Method: the formula of the score above, applied to the spec-stage residuals, plus 0.5 for each of the 19 Critical and High rows whose proving check has not yet passed against the rewritten pages. No Critical remains, so the cap of 60 no longer applies. The 22 Medium findings are counted at their original severity because they have not been re-scored here.

| Deduction | Points |
|---|---|
| 22 Medium findings × 0.5 | 11 |
| AMMN-FLOW-12 residual Medium × 0.5 | 0.5 |
| 19 Critical and High rows pending re-verification × 0.5 | 9.5 |
| **Spec-stage score** | **100 − 21 = 79** |

When the 19 proving checks pass, the score is 88.5 at spec stage. Above 90 still needs the implementation, Foundry and prover runs, and external audits. `FV-CUS-F-10` and `FV-CTL-F-25`…`F-29` (`FINDING-286`…`FINDING-291`), found after this review, are Low or Informational and deduct nothing. The [final re-check](final-recheck.md) re-scores every finding against the rewritten pages, and its fix pass maps each remaining WEAK item and the three attacks it found (`FINDING-293`…`FINDING-295`) to its resolving rule.

## Parameter decisions (2026-11-10)

After the final re-check, decisions `Q-391`…`Q-402` removed five mechanisms:

- **SettlementBudget** (`Q-397`), with all its parameters and every draw. It closed rounding gaps of about one debt unit per liquidation, but needed its own contract, funding in every debt asset, and windows and reserves that produced AMMN-RT-13 and AMMN-GAS-10. The caller (Avana's keeper) sizes `debtToCover` and its funding up front, including any increase from Aave V4's dust rule and the exact flash premium, and pays any rounding gap through the existing shortfall top-up.
- **In-kind settlement** (`Q-401`). It priced pool-token payouts from the oracle during route outages, and its trigger, probe and expiry added attack surface. The PayoutEscrow stays only as the escrow for refused payouts.
- **Idle-collateral mechanism** (`Q-396`). AMMN-FLOW-16, cap squatting by a debt-free LP, becomes an accepted risk, handled by caps set at listing and monitoring.
- **On-chain health floors** (`Q-398`). `minOpeningHealthFactor` and `PROXY_HEALTH_FACTOR_FLOOR` are gone. The Lens shows a recommended borrow at HF 1.10 beside the maximum at HF 1.00, and an optional per-market hard floor is off by default.
- **Alert-only breakers** (`Q-399`): price drop, seizure surge and route failures are monitoring alerts, because reverted calls cannot persist counts and the counters could be gamed. The on-chain gates are the oracle and stablecoin band checks, the 10 % pool concentration gate and the deficit freeze at 10,000 GHO.

Two removals reopen findings, both accepted: AMMN-FLOW-16, and a residual of AMMN-FLOW-09 and AMMN-GAS-08 (a market whose every route fails waits for a route instead of settling in kind). The spec-stage score moves from 99.0 to **98.0 / 100** ([re-score](final-recheck.md#re-score-after-the-owner-decisions)).

## What the tests confirmed

- **Fair-composition pricing holds for concentrated liquidity.** In Uniswap v3 and Slipstream, a spot move does not change the quote. The quote is monotone in liquidity and correct outside the range. "Floor, then −1 unit" is proven safe.
- **The other approaches fail as expected.** Spot reserves × price can be inflated ×5 for $5.4k.
- **Debt valuation is already asset-generic.** `DebtReserveDef`, `DebtOracle` and the non-GHO branches exist.
- **The vendored Aave V4 interfaces match the pinned commit exactly.** This covers the health factor, bonus, close factor, dust, deficit flow and share rounding.
- **Ledger conservation holds in every modelled topology.** Credited units always equal custodied units, and token supply always equals credited units.
- **No stable-pool depeg or liquidity-crunch scenario created bad debt or Hub supplier loss** in any topology.

## Critical, to fix before any further design work

| ID | Problem | Fix |
|---|---|---|
| AMMN-RT-01 | A narrow-range NFT is credited at the market's per-unit value. A $10k position prices at $9.79M (×979). | Each market fixes `(pool, tickLower, tickUpper)`. Pledge requires an exact tick match. The rule is stated in the core, and each integration checks it. |
| AMMN-INT-01 | Stablecoin Chainlink heartbeats are 82,800–86,400 s, not ≤ 3,600 s. Listing the launch market is impossible, and borrowing would be stopped most of the day. | The heartbeat comes from each feed's own config. Borrow freshness is derived from that heartbeat plus a deviation trigger. The SymPy and Z3 freshness models are re-checked. |
| AMMN-FLOW-01, AMMN-GAS-09 | The Lock's members are immutable, so a later Spoke's vault and ledger can never join it. Every flow on a new Spoke reverts. | Only the Adapter and LPVaultSwap are Lock members. Every vault and ledger entry point is reachable only through them (AMMN-ARCH-01). |
| AMMN-FLOW-02, AMMN-INT-05 | Base has no GHO FlashMinter, no GSM and no deep GHO, so liquidation step 1 fails for Slipstream. | One `IFlashSource`, implemented with the Aave V3 Pool `flashLoan` on every chain, which flash-borrows the debt asset. Mainnet first, Base after its settlement depth is proven. |
| AMMN-SM-03 | With pinned proxies and migration, once an Adapter drops an old version a paused borrower cannot repay or withdraw, and caps or freezes can strand migration. This breaks "exits never blocked". | Either every Adapter version supports repay and withdraw for every proxy version forever, or the proxy model changes. Decision required. |
| AMMN-RT-02 | Pricing math that does not clamp the oracle ratio to the range overvalues a depegged market ×2.97. | A clamp requirement, plus a Z3 check in `amm-pricing`. Raised to Critical because it is a direct theft path. |

## High

| ID | Problem | Fix |
|---|---|---|
| AMMN-INT-04, AMMN-ARCH-07 | The 5-argument liquidation-manager Spoke in the spec exists in no Aave source. The real one has 4 arguments, one collateral reserve per Spoke and one debt reserve per user. | Use a standard Spoke. The listing AIP sets `receiveSharesEnabled=false`, `liquidationFee=0` and no reinvestment controller, and Avana's drift check enforces them. |
| AMMN-RT-03, AMMN-SM-04, AMMN-INT-07 | On a standard Spoke, receive-shares liquidation takes vault-token shares that Avana can never settle. Liquidating and then borrowing leaves about $100k of bad debt that cannot be liquidated. | Same three settings, a check at listing, and a breaker trip if they drift. |
| AMMN-RT-04, AMMN-RT-16, AMMN-FLOW-04 | Migration lets an attacker-chosen implementation register, old versions cannot be patched, a borrower can get two proxies per (wallet, Spoke), and migrating can dodge a liquidation. | Decided together with AMMN-SM-03. |
| AMMN-RT-05 | Per-Spoke ledgers multiply the Hub-wide token, depositor and pool-share caps by the number of Spokes. | Caps live in one per-Hub (or chain-wide) counter. |
| AMMN-SM-01, AMMN-RT-11, AMMN-FLOW-05 | A cross-Hub credit line can stay open after the funding Hub sets its cap to 0. No registry sums cross-Hub lines. | The funding Hub owns the cap. One registry sums lines per (funding Hub, asset). No cross-Hub lines at launch (simulation T3). |
| AMMN-GAS-01 | An uncapped record list plus Aave's dust rule: about 125 records of $8 need about 31M gas, so the account can never be liquidated. | At most 16 records per account per market. |
| AMMN-GAS-02 | The $10 minimum pledge does not cover liquidation gas on Ethereum, so third-party keepers would leave small debts unliquidated. | Resolved by decision: no minimum; Avana keeper pays gas (`Q-381`). Avana's own keepers liquidate every account whatever its size. |
| AMMN-FLOW-03, AMMN-INT-06 | No L2 sequencer-uptime check. The Base grace period follows only Expired prices. | A sequencer feed per chain, with a grace period after restart. |
| AMMN-INT-02 | The GSM addresses in EXT-013 belong to seized GSMs with a cap of 0. | Replace them. The live USDC GSM holds about $0.03, so it cannot be the primary USDC buy route (AMMN-INT-03). |
| AMMN-FLOW-12 | An Aave halt of a Spoke or reserve blocks repay, withdraw and liquidation of that market. | Document this as an Aave-side containment, and add a playbook entry and a keeper path. |
| AMMN-FLOW-14, AMMN-RT-09 | No routes exist for non-stable tokens. One-sided unwinds of concentrated ranges understate slippage (4.76% modelled vs 9.09% actual). | Route requirements for each token class. Stress the route test at full one-sidedness. |
| AMMN-RT-06, AMMN-GAS-03 | Uniswap v4 removal hooks can block or skim liquidations. | Hooks must be on an allowlist (no remove hooks) before v4 is listed. |
| AMMN-RT-07 | v2, Curve and Balancer pricing is open to read-only reentrancy and same-transaction manipulation. | The listing guards from `amm-pricing`: reentrancy-lock check, `getReserves`, effective supply including pending fees, a cap on change per block. |

## Medium

- **Records and indexes:** built for two tokens and one `tokenId` (AMMN-FLOW-24). Pending settlement is two-token (inventory).
- **Spoke topology:** one market per Spoke costs 2.4× the governance actions and splits the credit line (AMMN-ARCH-02, topology simulation).
- **Contagion:** several markets in one account let one stale oracle liquidate healthy collateral; T2 wrongly liquidated 11.4 accounts (topology simulation).
- **Instance scope:** Adapter and LPVaultSwap per Hub gives no smaller blast radius than per chain (AMMN-ARCH-03).
- **Shared budget:** a shared settlement-budget window lets one Spoke starve another (AMMN-RT-13). The budget was later removed (`Q-397`).
- **Cross-Hub proxies:**
  - a shared ProxyManager lets one Hub squat another Hub's proxy addresses (AMMN-RT-10, AMMN-FLOW-18)
  - a Stable pause does not stop a cross-Hub borrow (AMMN-SM-06)
  - a vault token attached to a second Spoke (AMMN-RT-12)
- **Base liveness:** a TWAP buffer sized for 12 s blocks lets about $2 of swaps keep a market Drifting (AMMN-RT-08).
- **Breakers:**
  - breaker reports can be starved of gas by the 63/64 rule (AMMN-GAS-04)
  - `pokeMinGas` is not derived from that rule (AMMN-GAS-05)
  - a token pause or blocklist on a shared route token halts other markets (AMMN-GAS-08)
- **Oracle switch:** an oracle switch can stop liquidation (AMMN-FLOW-20).
- **Wind-down and listing:** wind-down never ends (AMMN-FLOW-22). Listing rules exclude Slipstream, WBTC/WETH and stocks (AMMN-FLOW-21).
- **Generic AMM interface:** it does not fit pools keyed by address (Uniswap v4, Balancer), Curve's lack of a closed form, rolled-in fees, native ETH or rate tokens (AMMN-ARCH-06).
- **Base timing:** dual-chain launch has no driver yet, and the spec has no sequencer rules (AMMN-ARCH-05).
- **Lenders:** take uncovered losses first-come (AMMN-FLOW-15). A non-borrowing LP can fill every cap (AMMN-FLOW-16).
- **Pause scope:** pause and freeze are per Hub (AMMN-FLOW-19). Repay-with-collateral is refused under Paused (AMMN-FLOW-26).
- **Invariant wording:** INV-057 must be stated as a check on new draws (AMMN-SM-02). The cross-market health invariant must allow shared token prices (AMMN-SM-05).
- **Settlement:** pending settlement always sends GHO to the GHO Coverage Spoke, whatever the debt asset (inventory).
- **Flash source:** a single source needs a liquidity check at each call, a maximum fee and a replaceable implementation (AMMN-ARCH-04).
- **Tokenized stocks:** market-hours feeds and corporate actions (AMMN-RT-14).

## Low

- **Gas costs:**
  - per-draw cold reads (AMMN-GAS-10)
  - n-token unwind cost (AMMN-GAS-13)
  - struct packing: `BackingRecord` 10 → 5 slots (AMMN-GAS-15)
  - immutables (AMMN-GAS-16)
- **Liquidation edges:**
  - a 1-wei repay front-run hitting the dust rule (AMMN-GAS-11)
  - keeper list size (AMMN-GAS-12)
  - Slipstream's unstaked-only rule must be enforced (AMMN-GAS-14)
- **Configuration and accounting:**
  - copied configuration paired with the wrong NFPM or factory (AMMN-RT-15)
  - "borrower surplus" missing from the payout order (AMMN-FLOW-23)
  - three keepers per Hub per chain (AMMN-FLOW-25)
- **Contract set:**
  - Lens out of the audited core (AMMN-ARCH-08)
  - the beacon versus pinned wording (AMMN-ARCH-09)
- **Housekeeping:**
  - rename settlement "venue" to "swap route"
  - mark EXT-001's Hub-halt scope Info (AMMN-INT-08)

## Verification coverage today

- **Defined:** about 99% of critical behaviour is written down.
- **Checked:** 37.5% has a spec-stage check that ran and passed. 57.4% is covered only through a decision that a test lists. 1.4% has no verification method at all.
- **Not yet run:** no Solidity check has run. trace.py counts prover tags that have never run as "Verified".
- **Orphans:** FINDING-197 and FINDING-198 have no verification. SIM-02H, SIM-04C and QNT-F1 have no finding.

Required rule: every critical requirement names a verification method, and every failed check produces a finding. The trace.py patch in [verification-coverage.md](verification-coverage.md) enforces this for the new AMM IDs.

## Recommended architecture (evidence-weighted)

| Question | Recommendation | Evidence |
|---|---|---|
| Spoke grouping | One Spoke per (chain, AMM protocol, risk tier), holding several markets. Each wallet gets a separate PositionProxy per market, so each market keeps its own health factor. | Isolation like T1: 0 accounts liquidated through a healthy market. Governance cost like T2: 16 actions per market, against 38–56. |
| Adapter, LPVaultSwap | One per chain, scoped by Hub inside. | AMMN-ARCH-03 |
| Vault, ledger | One vault per AMM protocol per chain, and one AMM-neutral ledger per chain. Only the Adapter and LPVaultSwap are Lock members. | AMMN-ARCH-01, AMMN-FLOW-01, AMMN-RT-05 |
| VaultToken, LPOracle | Per market, with one oracle implementation per AMM protocol. | AMMN-ARCH-04, AMMN-INT-01 |
| Spoke type | Standard Aave V4 Spoke plus 3 required settings, checked by the drift check. | AMMN-INT-04, AMMN-RT-03, AMMN-SM-04 |
| Flash | `IFlashSource` implemented with the Aave V3 Pool `flashLoan` of the debt asset. GHO is the payout and settlement asset. | flash-source research |
| Chains | Ethereum first. Base after sequencer rules, feeds and settlement depth are in place. | AMMN-ARCH-05, AMMN-FLOW-02/03 |
| Cross-Hub credit lines | None at launch. The design stays ready for them, with the cap owned by the funding Hub. | Simulation T3, AMMN-SM-01 |
