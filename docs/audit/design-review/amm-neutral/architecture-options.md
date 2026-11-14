# AMM-neutral architecture: options review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Scope | The proposed AMM-neutral design (instance scope, liquidation, pricing, launch chains) tested against `docs/spec/01-architecture/*`, `docs/spec/02-contracts/*`, [4.4 Design Decisions](../../../spec/04-security/04-design-decisions.md) (`Q-001`…`Q-278`), [8 Market lifecycle](../../../spec/03-operations/08-market-lifecycle.md) `MKT-018`…`MKT-026` and the interface tree in `contracts/src` |
| Method | Each assumption is compared with at least two alternatives. Counts come from the spec and the interfaces; where a fact could not be checked on-chain or in source it is marked **[UNVERIFIED]** with the check that settles it. |
| Findings | `AMMN-ARCH-01`…`AMMN-ARCH-10`: 1 High, 5 Medium, 2 Low, 2 Informational |
| Inputs added during the review | Decision on flash liquidity (one Aave flash source on every chain); [integration-assumptions.md](integration-assumptions.md) `AMMN-INT-01`, `AMMN-INT-04`, `AMMN-INT-05`, `AMMN-INT-06`, `AMMN-INT-07` |

## 0. Baseline measurements

### What the spec builds today

On the review date the spec did not yet follow the proposal. It had one Hub, **one** Borrow Spoke holding one vault-token reserve per market (`REQ-ARCH-027`, `Q-239`), **one** LPVault and **one** Collateralization for every market (`REQ-ARCH-031`, `REQ-ARCH-171`), one AaveAdapter, one LPVaultSwap, one Lock with four fixed members (`REQ-LOCK-001`), and one VaultToken plus one LPOracle UUPS proxy per market (`REQ-ARCH-032`, `REQ-ARCH-039`). Everything below compares against that baseline as well as against the proposal.

### Avana-authored contract types and interface size

`find contracts/src -name '*.sol' | xargs wc -l` gives 11,796 lines: 1,388 in vendored external interfaces and **10,408** in Avana interfaces and types. No implementation exists yet. "Code" counts non-blank, non-comment lines.

| Contract | Form (`Q-226`) | Interface lines | Interface code lines | Spec page lines |
|---|---|---|---|---|
| ParameterStore | U | 1,566 | 544 | 247 |
| MarketRegistry | U | 1,560 | 499 | 328 |
| LPVaultSwap | U | 960 | 281 | 432 |
| Lens | I | 888 | 401 | 177 |
| Collateralization | I | 830 | 246 | 388 |
| AaveAdapter | U | 756 | 249 | 315 |
| RiskModule | U | 580 | 167 | 297 |
| LPOracle (per market) | U | 382 | 81 | 496 (shared with DebtOracle) |
| DebtOracle (per non-GHO debt asset) | U | 380 | 106 | — |
| SettlementBudget | I | 358 | 103 | 149 |
| LPVault | I | 317 | 76 | 187 |
| AvanaTimelock (+ roles) | I | 324 | 84 | 545 |
| Settlement and debt-buy routes | I | 244 | 46 | 212 |
| PositionProxy + ProxyManager | U (beacon) | 356 | 96 | 197 |
| PayoutEscrow | I | 142 | 32 | 105 |
| Coverage Spoke (First-Loss Reserve) | DAO | 140 | — | 185 |
| VaultToken + VaultTokenFactory | I | 275 | 73 | 181 |
| Lock | I | 110 | 20 | 128 |

That is 19 contract types Avana writes and audits, plus one route contract per route version.

### Aave DAO and Avana operations per new market (current spec)

Counted from `MKT-018`…`MKT-026` for a market listed on an existing Borrow Spoke with GHO as the only debt reserve:

| Party | Operations |
|---|---|
| Avana operators | 3 transactions: deploy and initialize the LPOracle proxy, `increaseObservationCardinalityNext`, `poke` |
| Avana timelock, normal delay | 1 batch of about 8–12 calls (`setFeed`/`listToken` per new token, `deployVaultToken`, `registerMarket`, `setInitialMarketParams`, `setInitialMarketCaps`, `setInitialTokenCap`, `setRoute` × 2 per non-GHO token, `setInKindAutoTrigger`) |
| Avana timelock, short delay | 1 call: `activateMarket` |
| Aave DAO | 1 AIP with 4 calls: `addAssetWithDecimals`, fee-receiver caps, `addSpoke` (vault asset → Borrow Spoke), `addReserve` (price source and dynamic config) |
| New contracts | 2: VaultToken, LPOracle proxy |

The first market on a **new** Borrow Spoke adds, on the Aave side, an Aave-deployed liquidation-manager Spoke implementation, Spoke proxy and AaveOracle (`ORACLE` and `LIQUIDATION_MANAGER` are implementation immutables, [2.1](../../../spec/02-contracts/01-avana-hub-and-spokes.md) table rows 42–43), Spoke registration, `updateLiquidationConfig`, `riskPremiumThreshold`, two Guardian role grants (`freezeReserve`, `pauseReserve`), `addSpoke` on each funding Hub's debt asset with a `drawCap`, the debt reserve with its price source, and the Coverage Spoke allowlist entry: about **8 more DAO calls and 3 Aave deployments per debt asset**. On the Avana side it adds `approveSpoke`, `setLiquidationExpectations` and one `approveDebtReserve` per debt reserve (3 timelock calls).

---

## 1. Markets per CDP Spoke

**Assumption:** one market per CDP Spoke, for isolation.

| Measure | A. One market per Spoke (the proposal's preference) | B. One Spoke per (Hub, AMM protocol), several markets (the proposal's diagram) | C. One Spoke per Hub, all markets (current spec) |
|---|---|---|---|
| Spokes for M markets, P AMM protocols, H Hubs | M | H × P | H |
| Aave DAO calls per new market of a known AMM protocol | ≈ 12 + 3 Aave deployments | 4 | 4 |
| Avana timelock calls per new market | ≈ 11–15 | ≈ 8–12 | ≈ 8–12 |
| New Avana contracts per market | 4 (VaultToken, LPOracle, LPVault, Collateralization) under the proposal | 2 | 2 |
| Liquidation-manager implementations the DAO must approve | M | H × P | H |
| Hard borrow limit isolating a mispriced market | That market's `drawCap` | `drawCap` shared by one AMM protocol's markets in one Hub | `drawCap` shared by every market in the Hub |
| Health factors per wallet | One per market; no cross-margin; one PositionProxy per market | One per AMM protocol per Hub | One per Hub |
| Spoke-wide `targetHealthFactor`, `liquidationBonusFactor` | Per market | Per AMM protocol | Shared by all markets |
| GHO credit line | Split into M `drawCap`s; unused headroom of one market cannot serve another | Split into H × P | One per Hub |
| Per-market borrow cap | Possible (it is the Spoke `drawCap`) | Not possible: debt in a multi-reserve account is not attributable to one market | Not possible |
| Adding a new AMM protocol | Per market, as always | One new Spoke; the new, least-tested code sits behind its own `drawCap` | Listed into the shared Spoke; new code shares the `drawCap` with proven markets |
| Liquidation path | Unchanged; `collateralReserveId` is fixed per Spoke | Unchanged | Unchanged; keeper picks the reserve |
| Blast radius of an LPOracle that overprices market m | `drawCap(m)` | `drawCap` of m's (Hub, AMM protocol) Spoke | Whole Hub Spoke `drawCap` |

Notes on the measurements:

- An inflated LP price is bounded only by the Spoke `drawCap`. Avana's `marketUsdCap` is checked at pledge with the price of that moment; collateral already pledged is revalued without a cap, and the Hub `addCap` bounds units, not USD.
- Markets of one AMM protocol share all their code. Option A isolates only market-specific failures (one token's depeg, one feed's configuration). Those are already handled by per-market caps, breakers and the `Q-247` fix for cross-market liquidation gating (`DR-02`).
- The proposal says both "one market per Spoke" and "a vault can hold multiple approved markets". Under option B the second statement holds and the first is dropped.

**Recommendation:** B. Use one Spoke per (Hub, AMM protocol), with markets as reserves on it. A new AMM integration is the most likely place for a bug. B gives it its own `drawCap` at the DAO cost of one Spoke, not one Spoke per market. Use A only for a market the risk service providers want capped on its own; it remains possible case by case.

**Risk of A:** about 3× the DAO work per listing; M Aave-deployed Spoke implementations to bytecode-check (`REQ-HUB-005`); the GHO line split into many small `drawCap`s that are each easier to exhaust in a liquidation wave; one PositionProxy and health factor per market per wallet, which users will see as worse capital efficiency; and the Lock conflict in `AMMN-ARCH-01`.

**Dependency on §5:** the only liquidation-manager Spoke that exists in Aave's code allows one collateral reserve per Spoke (`AMMN-INT-04`). Choosing it forces option A. Option B needs the standard Spoke (§5 option C) or a variant Aave Labs has not written.

**Open question at review time:** whether Aave's risk service providers require a separate borrow cap for each LP market, or accept a cap per (Hub, AMM protocol) plus Avana's per-market USD caps. Decision: several markets per CDP Spoke with per-market USD caps (`Q-280`), caps set with the risk service providers (`Q-197`).

### `AMMN-ARCH-02` — Medium — One market per Spoke multiplies DAO work without isolating shared code

One Spoke per market raises the per-listing Aave DAO work from 4 calls to about 12 plus 3 Aave deployments. Every market would also need its own liquidation-manager implementation, because `ORACLE` and `LIQUIDATION_MANAGER` are implementation immutables. The GHO credit line would be split into M caps. Markets of one AMM protocol share code, so a code bug reaches all of them anyway. A Spoke per (Hub, AMM protocol) bounds new integration code behind its own `drawCap` at a fraction of the cost. The proposal's two statements on vault scope also contradict each other.

---

## 2. Scope of AaveAdapter and LPVaultSwap

**Assumption:** one AaveAdapter and one LPVaultSwap per Hub. In the proposal the same per-Hub scope applies to MarketRegistry, ParameterStore, RiskModule, SettlementBudget, PayoutEscrow and Lock.

Long-run reference: 1 chain, 3 Hubs, 5 AMM protocols, so S = 15 Spokes under option B of §1.

| Measure | A. Per chain | B. Per Hub (proposal) | C. Per Spoke |
|---|---|---|---|
| Adapter + LPVaultSwap instances | 2 | 6 | 30 |
| Policy contracts (Registry, Store, RiskModule) | 3 | 9 | 45 |
| Upgrade calls per Adapter or LPVaultSwap bug fix | 1 each | 3 each | 15 each |
| Lock | 1, fixed members | 3 Locks, or 1 Lock with members multiplied by Hub | 15 |
| Spoke implementations | One per Spoke in every option (`ORACLE` immutable). Only if a liquidation-manager variant is used (§5), `LIQUIDATION_MANAGER` = that scope's LPVaultSwap | same | same |
| Blast radius of a code bug | Every Spoke on the chain | Same in practice: every instance runs the same implementation, upgraded by the same timelock | Same |
| Blast radius of a compromised timelock or Guardian | Every Spoke on the chain | Every Spoke on the chain (one timelock, one Guardian per chain) | Same |
| Blast radius of a configuration error | Keyed per market or per `(spoke, debtReserveId)` already (`REQ-ARCH-042`) | Same | Same |
| Funds at risk, faulty Adapter (`REQ-ARCH-178`) | Sum of `drawCap`s it serves | Sum per Hub, but all Hubs share the implementation and the upgrade key | Sum per Spoke, same caveat |
| "Stuck Lock" | Not possible across transactions: transient storage clears each transaction (`REQ-LOCK-012`, `REQ-LOCK-013`); a leaked lock fails only the rest of its own transaction (`REQ-LOCK-014`) | Same | Same |
| Liquidation-blocking LPVaultSwap bug | Blocks Avana liquidations on every Spoke until a normal-delay upgrade (≥ 4 days) | Blocks one Hub, if the bug depends on Hub data; a code bug blocks all | Same |
| Adding an AMM protocol | No new instance | No new instance | New Spoke, so new instances |

**Recommendation:** A, one instance per chain for the Adapter, LPVaultSwap, RiskModule, MarketRegistry, ParameterStore, SettlementBudget, PayoutEscrow, Lock and Lens. Keep the Hub and Spoke boundaries as data, keyed by Spoke and debt reserve, as the spec already does. Per-Hub instances add contracts, Lock members and upgrade calls but do not shrink the blast radius, because the implementation, the timelock and the Guardian are shared.

**Risk of B:** three times the deployments and upgrade calls, three Locks or a larger Lock membership, and a false sense of isolation in the threat model. The real single point of failure is the same in every option: LPVaultSwap is the only `LIQUIDATION_MANAGER`, and its fix waits the normal delay.

**Open question at review time:** the fix path for a bug that blocks liquidation in LPVaultSwap: the normal-delay upgrade only, or a pre-approved immutable fallback liquidator. The second option depends on whether the Aave variant can hold two managers. Current rule: LPVaultSwap is upgraded through the timelock at the normal delay (`Q-226`, `Q-228`); no fallback liquidator is recorded.

### `AMMN-ARCH-03` — Low — Per-Hub copies of shared contracts add work without reducing blast radius

Every per-Hub instance runs the same implementation under the same timelock and Guardian. A code bug or a role compromise therefore reaches every Hub in either layout. Per-Hub scoping triples deployments, upgrade calls and Lock membership, and it implies an isolation that does not exist. A stuck Lock is not a failure mode that crosses transactions (`REQ-LOCK-012`…`014`).

---

## 3. Custody and ledger scope

**Assumption:** a separate immutable LPVault and a separate immutable Collateralization ledger per CDP Spoke.

| Measure | A. LPVault + ledger per Spoke (proposal) | B. One LPVault + one ledger per chain (current spec, v3 only) | C. One LPVault per AMM protocol per chain + one AMM-neutral ledger per chain | D. Merged vault + ledger per AMM protocol |
|---|---|---|---|---|
| Contracts to audit | 2 types; 2 deploys per Spoke | 2 | 1 ledger + 1 vault per AMM protocol | 1 per AMM protocol; the ledger code is copied into each |
| Fits the 500-line limit (`Q-240`) | Yes | Yes | Yes | Unlikely: the Collateralization interface alone is 830 lines (246 code) |
| Deploy operations per new market | +2 under one-market-per-Spoke | 0 | 0 | 0 |
| Deploy operations per new AMM protocol | +2 per Spoke | Impossible: NFPM is a constructor immutable (`REQ-ARCH-049`), so a new vault is required anyway | +1 vault | +1 |
| Lock | Members are fixed constructor immutables (`REQ-LOCK-001`, `REQ-LOCK-004`). Each new vault and ledger needs a new Lock, and every immutable that stores `LOCK` (LPVault, Collateralization, SettlementBudget, PayoutEscrow) must be redeployed | Unchanged | Unchanged if vaults never call `acquire()` (route `collectFees` and `returnStrayNft` through the Adapter) | Members grow with each AMM protocol, unless handled the same way |
| Blast radius of a ledger bug | One Spoke's markets, but the bug exists in every copy | All markets on the chain; immutable, so the only fix is to redeploy and migrate | All markets on the chain | One AMM protocol's markets |
| Blast radius of a vault bug | One Spoke | All positions | One AMM protocol's positions | One AMM protocol's positions |
| Liquidation path | LPVaultSwap must look up the vault and ledger per Spoke | One ledger | One ledger; the vault is read from the VaultToken immutable, like the market ID and LPOracle today (`REQ-ARCH-048`) | One contract per AMM protocol |
| Risk of an AMM-neutral ledger being wrong | Low: redeploy per Spoke | High: ledger is v3-shaped (per-NFT records, `liquidityOf`) | Medium: it must take `bytes32` position keys and n-token arrays from day one | Low |

**Recommendation:** C. Use one AMM-neutral, immutable ledger per chain and one immutable vault per AMM protocol per chain. Each VaultToken names its vault as an immutable. Vaults never acquire the Lock: every outer entry point goes through the Adapter or LPVaultSwap, so the Lock's members are only those two fixed proxy addresses and never change. A ledger bug then has the same reach as in B, but the ledger contains no AMM-specific code, which is what changes when an integration is added.

**Risk of A:** the immutable Lock cannot admit contracts deployed later. Every new Spoke would require either redeploying the Lock and every immutable that binds `LOCK`, or replacing the fixed member list with a list governance can extend, which weakens `REQ-LOCK-001`.

**Open question at review time:** whether every outer entry point of the vault, including fee collection and stray-NFT return, can move behind the AaveAdapter, so that the Lock's members shrink to {AaveAdapter, LPVaultSwap}. Decision: yes; the Lock has exactly those two members (`Q-318`), and stray-position return is a timelock-only LPVault call (`Q-296`).

### `AMMN-ARCH-01` — Medium — A vault and ledger per Spoke conflicts with the immutable Lock

`REQ-LOCK-001` and `REQ-LOCK-004` fix the Lock's members (`AAVE_ADAPTER`, `COLLATERALIZATION`, `LP_VAULT`, `LP_VAULT_SWAP`) in its constructor. Adding a vault and ledger with each Spoke means redeploying the Lock, and with it every immutable contract that stores `LOCK`, or making the member list extendable by governance. Option C avoids this: one ledger per chain, one vault per AMM protocol, and outer entry points only in the Adapter and LPVaultSwap.

---

## 4. VaultToken and LPOracle per market

**Assumption:** a separate VaultToken plus an LPOracle instance per market.

**VaultToken per market is required.** Each market is a separate Aave Hub asset (an ERC-20), and units of different pools are not interchangeable. The token cannot also serve as the Aave price source: AaveOracle requires `decimals() == 8` (`MKT-023`), while the token's ERC-20 `decimals()` is the market's `d` (6–18, `Q-066`).

**LPOracle address per market is also required.** `IAaveV4PriceFeed.latestAnswer()` takes no argument, so each reserve needs its own source address. Replacing that address is a DAO action (`REQ-ORACLE-078`). The open choice is where the logic and state live.

| Measure | A. UUPS proxy per market, one implementation per AMM protocol | B. One oracle per AMM protocol keyed by `marketId` + immutable per-market shim | C. One oracle per chain keyed by `marketId`, pricing from the AMM integration + shim |
|---|---|---|---|
| Contracts to audit | Base oracle + one pricing library per AMM protocol | Same + shim (≈ 40 lines) | Same + shim; pricing call crosses into the vault |
| Deploy operations per market | 1 proxy + `initialize` | 1 shim clone + 1 timelock config call | Same as B |
| Upgrade calls per oracle fix | One per market (one batch) | One per AMM protocol | One |
| Staged rollout (canary market) | Yes | Per AMM protocol only | No |
| Blast radius of a bad upgrade | Markets that were upgraded (usually all) | All markets of one AMM protocol | All markets on the chain |
| Interface change from today | Small: `pool()`, `token0()`, `token1()` become `marketKey()` and `tokens()` | Rewrite `ILPOracle` (382 lines) to keyed functions | Same as B, plus a cross-contract pricing dependency |
| Extra gas per Aave price read | 0 | ≈ 2.6k (one extra call) | ≈ 2.6k + integration call |
| Liquidation path | Unchanged | Unchanged | Liquidation depends on integration views |

**Recommendation:** A, the proposed plan, with one LPOracle implementation per AMM protocol. The AMM-neutral price-state logic goes in a shared base contract, and the AMM-specific composition math goes in an internal library that the vault also uses for minimum-recovery checks. B saves deploy operations but costs an interface rewrite and loses staged upgrades. Not a finding.

**Risk of A:** low. It needs N upgrade calls per fix, which one batch handles. Separately, `AMMN-INT-01` (23–24 h stablecoin heartbeats) means the shared price-state base must read each feed's heartbeat and deviation threshold from configuration. A fixed ≤ 1 h freshness rule makes no stablecoin market listable.

**Open question at review time:** whether staged oracle upgrades (one market first) are needed; without them, B is acceptable and lowers per-market deploy work. Decision: one LPOracle instance per market (`Q-279`).

---

## 5. Liquidation-manager Spoke compared with a standard Spoke

**Assumption under review:** replace the liquidation-manager Spoke (`Q-222`) with a standard Spoke whose `liquidationCall` is public, relying on a transfer-restricted VaultToken.

**New evidence** ([integration-assumptions.md](integration-assumptions.md), `AMMN-INT-04`, `AMMN-INT-07`). The Spoke that `Q-222` and `IAaveV4Spoke` describe exists in no Aave source. The only liquidation-manager Spoke in `aave/aave-v4` (`455a406`) differs from it:

- Its 5-argument `liquidationCall` always reverts. It exposes a 4-argument call plus `maxCollateralToRemove` instead.
- It hard-codes one collateral reserve per Spoke and `USER_RESERVES_LIMIT = 1`.
- It has no target-health-factor sizing, no dust rule and no liquidation fee.
- It emits its own liquidation event.

On a standard Spoke, `receiveShares = true` and the liquidation fee both move Spoke shares without any token transfer. The transfer restriction therefore gives exclusivity only while every vault reserve key has `receiveSharesEnabled = false` and `liquidationFee = 0` (or a fee paid to an Avana address), and the vault asset has no reinvestment controller.

The question is therefore no longer "variant or standard" but a choice among three Spokes:

| Measure | A. Existing variant (`455a406`) | B. The variant the spec describes (`Q-222`) | C. Standard Spoke + required config |
|---|---|---|---|
| Exists in Aave source | Yes | **No**: needs new Aave Labs code, audit and DAO approval before launch | Yes, canonical and most audited |
| Markets per Spoke | 1 (forces §1 option A) | Many | Many (§1 option B possible) |
| Reserves per account | 1 collateral + 1 debt: one debt asset per account per Spoke | Many | Many, up to the DAO-set limit |
| Liquidation sizing | None in Aave: LPVaultSwap must size each seizure with `maxCollateralToRemove` (new Avana code and proofs) | Canonical target health factor and dust rule | Canonical |
| Who can liquidate | LPVaultSwap only, in code | LPVaultSwap only, in code | Anyone may call. A call succeeds only through LPVaultSwap while the three config settings hold; otherwise it fails at the vault-token transfer |
| A DAO payload turns on `receiveSharesEnabled` or a fee | No effect | No effect | A third party can take vault-token shares with no ledger debit (`INV-014` breaks). It can enable them as collateral and borrow against them; that debt can never be liquidated (any seizure needs a token transfer), so it becomes bad debt |
| A DAO upgrade of the Spoke proxy | Can change anything | Can change anything | Can change anything |
| Avana code changes from the spec | Large: 4-argument call, new event, Avana-side sizing, one debt asset per account, one market per Spoke | None in the spec; launch blocked on Aave | Small: drop `LIQUIDATION_MANAGER` checks, add the three config settings to the AIP's required settings and to the drift check, accept failed third-party calls |
| DAO approvals per new market | ≈ 12 calls + 3 Aave deployments (a new Spoke per market) | 4 | 4 |
| Liquidation path | LPVaultSwap calls the 4-argument function with its own cap | As specified | As specified; `receiveShares = false` |
| Residual risk | Avana's sizing code replaces Aave's | Schedule risk | A config error is caught by the drift check only after the block it lands in |

Two points apply to every option:

- The Aave DAO can upgrade the Spoke proxy, so "enforced in code" protects against a mistaken configuration payload, not against the DAO.
- `AMMN-INT-01`: live USDC, USDT and GHO Chainlink feeds have 23–24 h heartbeats. Under the spec's "stale collateral counts as 0" rule with `borrowPriceMaxAge` ≤ 4,200 s, collateral would read as stale for most of each day. In options B and C, Aave's health factor would then call for liquidation of every account. In option A, with no dust rule and Avana-side sizing, a wrong price leads straight into seizures. The freshness rule must be rebuilt around deviation-triggered feeds before any Spoke choice is safe.

**Recommendation:** C, the standard Spoke, for launch. It is the only option that exists, keeps Aave's audited sizing and deficit reporting, and allows several markets per Spoke (§1 option B). Exclusivity rests on three settings: `receiveSharesEnabled = false` and `liquidationFee = 0` on every vault reserve key, and no reinvestment controller on the vault asset. The recommendation makes them required AIP settings, checks them in the RiskModule drift check (which freezes new borrowing), and asks the Aave DAO to restrict who can change them on Avana reserves (for example, the Risk Steward cannot touch them). Option B fits as a later upgrade of the same Spoke, not as a launch dependency. A fits only with one market per Spoke, one debt asset per account and Avana-written liquidation sizing.

**Risk of B (the spec at review time):** launch waits on Aave Labs code that did not exist on the review date. **Risk of A:** the work in §1 option A, plus Avana owns liquidation sizing that Aave's audited code does today. **Risk of C:** one DAO configuration payload can expose Avana collateral to third parties until the drift check freezes the market. This is the `Q-221` accepted risk, now with bad debt as a stated consequence.

**Open question at review time:** accept C's residual risk (one DAO configuration error, detected after the fact), or wait for a multi-reserve variant (B) from Aave Labs. Decision: C, the standard Spoke with three required settings and the drift check (`Q-281`, `Q-352`), with the exposure window of `Q-382`.

### `AMMN-ARCH-07` — Medium — The decided Borrow Spoke does not exist; the safest option that exists is the standard Spoke with three required settings

`Q-222` depends on a Spoke that no Aave commit contains (`AMMN-INT-04`). The only variant that exists forces one market per Spoke, one debt asset per account and Avana-side liquidation sizing. The standard Spoke keeps canonical sizing and multi-market accounts. Its exclusivity needs `receiveSharesEnabled = false`, `liquidationFee = 0` and no reinvestment controller (`AMMN-INT-07`), enforced as required AIP settings and by the drift check. Supersede `Q-222` with that choice, state the residual risk (third-party share seizure followed by debt that cannot be liquidated), and keep the multi-reserve variant as a later request to Aave Labs.

---

## 6. Flash liquidity and the settlement asset

**Decision of 2026-11-10 (`Q-334`):** Base has no GhoFlashMinter and no GSM; GHO there is CCIP-bridged only. Liquidations on every chain use **one** flash-loan source, and it must be an Aave flash loan. This section therefore does not compare settlement assets. It records the risks of a single Aave flash source and answers whether GHO stays the settlement asset on Base.

Sources: the internal liquidation research (mainnet GhoFlashMinter capacity 2,000,000 GHO and fee 0, GSM capacity, GHO DEX depth of about $1.3M on Curve, $93k on Balancer and $47k on Uniswap v3, all on mainnet). The separate verification of Aave V3 and V4 flash facts (`~/Documents/avana-internal-references/research/flash-source.md`) did not exist when this review was written. Every Aave flash fact below is therefore **[UNVERIFIED]** until that file confirms it.

### Risks of a single Aave flash source

| Risk | What happens | Effect on liquidation | Control to specify |
|---|---|---|---|
| Liquidity ceiling | An Aave V3 `flashLoanSimple` can lend at most the reserve's unborrowed balance held by its aToken. **[UNVERIFIED]** On mainnet the V3 GHO reserve uses a GhoAToken that holds no GHO, so the V3 Pool may not be able to flash-lend GHO at all; that is why the GhoFlashMinter exists. On Base, flash-lendable GHO is only what suppliers left unborrowed in the V3 Base GHO reserve. | A liquidation larger than the available balance cannot be funded. In a depeg wave, borrowers draw the same reserve down while liquidations need it. | Read `available` on-chain before each liquidation (as the spec does for FlashMinter capacity). Cap each chain's GHO `drawCap` and each account's size so the largest liquidation fits under a stated fraction of the flash ceiling at its 30-day low. Add a breaker that stops new borrowing when the ceiling falls below that bound. |
| Fee | The V3 premium (`FLASHLOAN_PREMIUM_TOTAL`) is set by Aave governance and is waived only for addresses with the V3 ACLManager `FLASH_BORROWER` role. **[UNVERIFIED]** Whether each chain's ACLManager grants the role to LPVaultSwap. | Without the role, every liquidation pays the premium; a later fee increase raises the shortfall on every liquidation. | Make `FLASH_BORROWER` on each chain a listing requirement. Keep an on-chain maximum fee (as for the FlashMinter today), above which LPVaultSwap falls back to caller-funded GHO. |
| Reserve paused, inactive or flash-disabled | V3 flash loans need the reserve active, not paused and `flashLoanEnabled`. A frozen reserve still lends flash loans **[UNVERIFIED]**. The Aave Guardian pauses reserves during incidents, which is when Avana liquidations are likely. | With one source, a paused GHO reserve or a paused Pool stops every Avana liquidation on that chain. | Check the reserve flags in the drift check and the Lens. Keep caller-funded GHO (`REQ-ARCH-040`) as the only fallback, and size keeper GHO inventory for the pause-loss bound (`MKT-013`). |
| Aave V3 deprecation | As liquidity migrates to V4, V3 reserves shrink, then get frozen or have flash loans disabled. | The ceiling falls over time with no Avana action, and a deprecation AIP can end flash funding outright. | Specify the flash source as a replaceable route (one immutable adapter contract per source version, chosen by timelock), not a constructor immutable of LPVaultSwap. Track the V3 ceiling against Avana's caps on a schedule. |
| Aave V4 as the source | **[UNVERIFIED]** Whether the V4 Hub or a V4 Spoke offers flash loans at the pinned commit. If it does not, "one Aave source on every chain" means V3 everywhere, with the deprecation risk above. | — | Settle this from `flash-source.md` before the spec names a source. |
| Reentrancy with the V4 Spoke | Inside the flash callback, LPVaultSwap calls `liquidationCall` on the V4 Borrow Spoke, which pulls the debt asset and calls the Hub. If the flash loan comes from the **same V4 Hub**, the Hub is mid-call: a Hub reentrancy guard makes the liquidation fail, or, without one, the Hub's liquidity accounting is read while the loan is outstanding. From a separate V3 Pool there is no shared lock, but the callback is an external entry that must be authenticated. | Every liquidation fails (guard), or liquidity-dependent values (Hub liquidity, interest index) are read in an inconsistent state. | Never flash-borrow from a Hub that the Borrow Spoke draws from. In the callback require `msg.sender == source`, `initiator == LPVaultSwap`, the expected asset and amount, and a transient "callback expected" flag set under the Lock, as the spec requires for the FlashMinter. |
| Single source, no fallback | All four risks above are correlated with stress. | One Aave action (pause, fee, deprecation) stops all Avana liquidations on a chain. | Caller-funded GHO stays as the fallback; permissionless liquidators need it to work without the flash source. |

### Does GHO stay the settlement asset on Base?

Only as the asset that repays GHO debt, and only up to what Base can absorb. Two limits bind on Base, and the smaller sets the cap:

1. **Flash ceiling:** unborrowed GHO in the Aave V3 Base reserve (or the V4 source, if one exists).
2. **Conversion depth:** converting recovered pool tokens back into GHO on Base, with no GSM, goes through DEX pools whose GHO depth is thin. Every liquidation must buy back at least the flashed GHO plus the fee in one transaction.

The GHO `drawCap` of each Base Borrow Spoke must therefore be no more than the smaller of those two limits, measured at a stressed level, times the share of debt that can need liquidation in one block. If that number is too small to be useful, GHO should not be the debt asset on Base at launch. That is a listing decision, not a settlement redesign.

**Recommendation:** accept the single Aave source only with the controls in the table: on-chain ceiling check, `FLASH_BORROWER` on every chain, a maximum fee, a replaceable source adapter, never the same V4 Hub, an authenticated callback, and caller-funded GHO as the fallback. Before writing the spec, confirm the mainnet case: if the V3 Pool cannot flash-lend GHO there, "one Aave source" either requires V4 flash loans or gives up the GhoFlashMinter that works today.

**Risk without the controls:** one Aave pause, fee change or V3 wind-down stops every Avana liquidation on a chain, and on Base the GHO cap has no measured link to flash or conversion depth.

**Open question at review time:** on mainnet, if the Aave V3 Pool cannot flash-lend GHO, keep the GhoFlashMinter there (two sources) or require V4 flash loans. Decision: GHO's flash minter is not used on any chain; the source is the chain's Aave V3 Pool (`Q-334`), and a liquidation is funded by its caller (`Q-404`).

### `AMMN-ARCH-04` — High — A single Aave flash source makes liquidation depend on one external reserve

With one Aave flash source per chain, liquidation stops whenever that reserve is paused, flash-disabled, drained, repriced by a fee change or deprecated, all of which happen most often under stress. On Base the flash ceiling and GHO conversion depth are both thin. On mainnet the V3 Pool may not be able to flash-lend GHO at all **[UNVERIFIED]**. Specify an on-chain ceiling check, `FLASH_BORROWER` on every chain, a maximum fee, a replaceable source adapter, a rule against flash-borrowing from the Borrow Spoke's own Hub, an authenticated callback and caller-funded GHO as the fallback. Size each Base GHO `drawCap` to the smaller of the flash ceiling and the conversion depth.

---

## 7. Pricing library per market compared with an AMM plug-in interface

**Assumption:** a per-market pricing math library, with "each AMM type has its own model".

| Measure | A. Pricing library per AMM protocol, compiled into that protocol's vault and LPOracle implementation | B. External `IAmmIntegration` plug-in contracts called by a shared vault, ledger and LPVaultSwap |
|---|---|---|
| Trust boundary | None new: the vault owns its positions and calls its AMM directly | New: the shared vault must let the plug-in act on positions it owns (delegatecall, per-token approval, or calldata the vault executes) |
| Custody of NFTs | Vault is the owner and caller | The plug-in is not the owner. Delegatecall puts plug-in code in the custody context |
| Adding an AMM protocol | New vault + library + LPOracle implementation; ledger, Adapter and LPVaultSwap unchanged | New plug-in + registry entry; a wrong registration is a custody risk |
| Audit per new AMM protocol | Vault + library | Plug-in + its interaction with the shared vault |
| Liquidation path | LPVaultSwap → ledger → vault named by the VaultToken | LPVaultSwap → ledger → shared vault → plug-in |

**Recommendation:** A, but with a fixed interface. `IAmmIntegration` below is the interface every per-AMM-protocol vault implements. The ledger, LPVaultSwap and the oracle base contract depend only on it. That keeps plug-in-style neutrality without adding a delegatecall or approval trust boundary.

### Minimal AMM-neutral interface set

```solidity
// Implemented by each per-AMM-protocol LPVault. Called only by the ledger while
// the Adapter or LPVaultSwap holds the Lock, except the views.
interface IAmmCustody {
    // Take custody of a position and return its credited units for the market.
    // NFT: positionKey = bytes32(tokenId). Fungible LP: positionKey = keccak(market, depositor, nonce).
    function receivePosition(bytes32 marketKey, address from, bytes calldata position)
        external returns (bytes32 positionKey, uint256 units);
    function returnPosition(bytes32 positionKey, address to) external;
    function unitsOf(bytes32 positionKey) external view returns (uint256 units);
}

interface IAmmUnwind {
    // Remove exactly `units` from one position and send the n tokens to `to`.
    // Fees must not be mixed into `amounts` (collect them first or return them separately).
    function unwind(bytes32 positionKey, uint256 units, uint256[] calldata minOut, address to)
        external returns (uint256[] memory amounts);
}

interface IAmmFees {
    // Accrued-fee collection where the AMM separates fees from principal.
    // Returns an empty array when fees compound into the position.
    function collectFees(bytes32 positionKey, address to) external returns (uint256[] memory amounts);
    function feesSeparable() external pure returns (bool);
}

interface IAmmPricing {
    function tokens(bytes32 marketKey) external view returns (address[] memory);
    // Token amounts per 10**d units at the given USD prices (8 decimals), over the market's fixed range.
    // `exact` is false when the AMM has no closed form and the result is a conservative lower bound.
    function compositionAt(bytes32 marketKey, uint256[] calldata pricesUsd)
        external view returns (uint256[] memory amountsPerWholeUnit, bool exact);
    // Spot or TWAP view used only as a consistency check; `available` is false when the AMM has none.
    function consistencyPrice(bytes32 marketKey, uint32 window)
        external view returns (uint256[] memory pricesRelative, bool available);
}

interface IAmmRisk {
    struct RiskMeta {
        bytes32 ammProtocol;
        bool hasRemovalHooks;      // code that runs on liquidity removal
        bool hasAdminParams;       // e.g. amplification ramp, fee setter, pause
        bool feesCompound;
        bool usesRateProviders;    // ERC-4626 or rate-oracle tokens
        bool nativeToken;          // address(0) in tokens()
    }
    function riskMeta(bytes32 marketKey) external view returns (RiskMeta memory);
    // True while the pool is mid-operation (read-only reentrancy guard).
    function isPoolLocked(bytes32 marketKey) external view returns (bool);
}
```

### Paper test

| Check | Uniswap v3 | Slipstream (CL) | Uniswap v2 | Curve StableSwap-NG | Balancer weighted (v2) | Uniswap v4 |
|---|---|---|---|---|---|---|
| `marketKey` | Pool address | Pool address (`CLFactory.getPool(t0, t1, tickSpacing)`) | Pair address | Pool address | `poolId` (bytes32), tokens in the Vault | `PoolId` (bytes32), no pool address |
| `positionKey`, units | tokenId, liquidity | tokenId, liquidity | Synthetic key, LP amount | Synthetic key, LP amount | Synthetic key, BPT amount | tokenId (PositionManager), liquidity |
| `compositionAt` exact | Yes, closed form over the range | Yes, same math | Yes: `r0 = √(k·p1/p0)`, `r1 = √(k·p0/p1)`, per effective supply incl. pending `_mintFee` | **No** closed form; needs an n-dimensional Newton solve. Lower bound `min(pᵢ)·D/supply` is valid because Σxᵢ ≥ D | Yes: `bᵢ = wᵢ·V/pᵢ`, `V = k·Π(pᵢ/wᵢ)^wᵢ`, supply = `getActualSupply()` | Yes, v3 math |
| `unwind` of x units | `decreaseLiquidity` + `collect`; fees in `tokensOwed` must be separated | Same | `transfer` + `burn`, pro rata | `remove_liquidity`, pro rata | `exitPool` exact BPT in, pro rata | `modifyLiquidities` inside `unlock`; **hooks can block it or take a share of the proceeds** |
| `collectFees` | Yes | Yes (unstaked only; unstaked positions pay a fee share to the gauge) | **No**: fees compound | **No**: fees compound | **No**: fees compound | Yes, but any liquidity change also pays out fees |
| `consistencyPrice` | `observe` TWAP | `observe` TWAP | Cumulative prices | `price_oracle()` EMA | **None** (weighted pools have no oracle) | **None** without an oracle hook |
| `isPoolLocked` | `slot0.unlocked` | `slot0.unlocked`, different slot0 layout (no `feeProtocol`) | Private lock; reserves cannot be read mid-swap | No public flag on most pools; read-only reentrancy on remove with native ETH | `ensureNotInVaultContext` | PoolManager unlock state via `exttload` |
| Admin risk | Factory owner fee switch | Factory and fee modules | `feeTo` | Amplification ramp, fees | Pool owner swap fee, pause window | Hook code, dynamic fee |
| Fits as written | Yes | Yes | Yes, with `feesSeparable = false` | Partly: inexact pricing | Partly: no consistency check | Only hookless pools, or hooks on an allowlist with no removal permissions |

**Cases that do not fit:**

1. Markets keyed by pool address. `VaultTokenFactory.tokenOfPool(address)`, `deployVaultToken` (CREATE3 salt = pool), `ILPOracle.pool()` and the pool derivation in `REQ-ARCH-049` all assume an address. Uniswap v4 (`PoolId`) and Balancer (`poolId`) have no pool contract per market. Key everything by `bytes32 marketKey`.
2. Curve StableSwap-NG (and Aerodrome v2 stable pools, x³y + y³x) cannot compute a composition at an oracle price in closed form. Use the `min(pᵢ)·D/supply` lower bound (`exact = false`), or a bounded on-chain solver with its own verification.
3. Balancer weighted and Uniswap v4 have no built-in TWAP. "TWAP is a consistency check only" needs a per-AMM fallback, either a feed-only check or an oracle hook.
4. Uniswap v2, Curve and Balancer compound fees into the position. `Q-009` and `Q-011` (fees belong to the borrower and can be collected at any time) cannot hold; fees raise collateral value instead.
5. Uniswap v4 hooks with `beforeRemoveLiquidity`, `afterRemoveLiquidity` or `afterRemoveLiquidityReturnDelta` can block liquidation or take part of the proceeds. Custom-curve hooks that keep liquidity outside the PoolManager break the composition math entirely.
6. Fungible LP has no per-position identity. The ledger's per-NFT records and largest-first seizure lists (`REQ-ARCH-171`) reduce to one synthetic record per account per market. `Q-001` ("no ERC-20 LP custody") must be superseded.
7. Native ETH (Uniswap v4, Curve ETH pools) needs an `address(0)` sentinel in `tokens()` and in every route.
8. ERC-4626 and rate-oracle tokens (Curve NG, Balancer v3 boosted pools) need USD price = underlying price × rate, which adds a rate-provider dependency to the oracle routes.
9. Staked positions (Slipstream gauges, Curve and Balancer gauges) and their reward tokens are outside the interface. They are out of scope, as the proposal already states for Slipstream.

### `AMMN-ARCH-06` — Medium — Interfaces that would be immutable are still shaped for Uniswap v3

The VaultTokenFactory, VaultToken and ledger are immutable, and they key markets by pool address and positions by NFT. Uniswap v4 and Balancer have no pool address. Curve has no closed-form composition at an oracle price. Balancer weighted and Uniswap v4 have no TWAP. Three of the six AMM protocols compound fees. If these contracts ship with the current shapes, adding a later AMM protocol needs a second VaultTokenFactory and a second ledger. Fix the keys (`bytes32 marketKey`, `bytes32 positionKey`), n-token arrays, an `exact` flag on composition and an optional consistency check before the immutable contracts are written.

---

## 8. Launch chains

**Assumption:** launch on Ethereum mainnet and Base at the same time.

| Measure | A. Mainnet and Base together | B. Mainnet first, Base after |
|---|---|---|
| AMM integrations to audit before launch | 2 (Uniswap v3, Slipstream) | 1 |
| Flash source | Aave flash loan on both chains (`Q-334`); Base ceiling and GHO conversion depth unmeasured (`AMMN-ARCH-04`) | One chain to measure |
| Avana governance | Two timelocks, two Guardian and governance Safe sets, two deployment manifests | One |
| Aave DAO | Two listing AIPs. The Base AIP executes cross-chain, adding bridge delay to every Base payload, including an emergency one **[UNVERIFIED]** for V4 on Base | One |
| Aave V4 | Mainnet live. A Base address-book file exists; which Hubs and Spokes exist on Base, and whether the liquidation-manager variant is deployable there, is **[UNVERIFIED]** | Mainnet live |
| Oracles | Base needs an L2 sequencer-uptime check and a grace period after restart; **the spec has none** (no "sequencer" in `docs/spec/`). Chainlink coverage on Base for USDT and other pool tokens needs checking | Not needed |
| GHO | Base: CCIP-bridged only, no FlashMinter or GSM (confirmed 2026-11-10), thin depth | GSM for conversion |
| Funds at risk at launch | Two sets of caps | One |
| Work | About 2× audit and operations | About 1× now, then a smaller increment |

**Recommendation:** B. Launch on mainnet with Uniswap v3 first. Add Base when Slipstream, a Base settlement path, a sequencer check and the Aave V4 Base deployment are verified, and the Base flash ceiling and GHO depth are measured. The AMM-neutral refactor (§3, §7) is what makes the second chain cheap, and it does not need Base live to be tested.

**Risk of A:** the launch depends on four unverified Base facts. The protocol would also launch without sequencer handling, so after a Base sequencer outage Aave liquidations could run on prices that are stale or just restored, and borrowers would have no time to repay.

**Open question at review time:** which Base need is a launch requirement rather than a preference, and whether listing Slipstream as the second integration on mainnet's schedule would meet it. Decision: Ethereum and Base launch together (`Q-279`).

### `AMMN-ARCH-05` — Medium — A Base launch has no sequencer-uptime handling and depends on unverified Base facts

The spec has no L2 sequencer-uptime check or post-restart grace period. The Base flash and conversion limits are unmeasured (`AMMN-ARCH-04`). Aave V4's deployment and the liquidation-manager variant on Base are unverified. `Q-005` already lists Ethereum mainnet as the launch chain, and each further chain needs its own Aave approval. Launch on mainnet first.

---

## 9. Contracts to remove or merge

| Contract | Interface lines (code) | Purpose | Options compared | Recommendation | Risk of removal |
|---|---|---|---|---|---|
| SettlementBudget | 358 (103) | Closes the rounding gap between recovery and flash repayment (`REQ-ARCH-042`) | Keep / remove and rely on the caller top-up and in-kind settlement already specified / move into LPVaultSwap | Keep it for launch but ask: the caller top-up already exists. Do not move it into LPVaultSwap, because funds would then sit in an upgradeable contract | Dust shortfalls that permissionless liquidators will not top up; in-kind runs more often |
| PayoutEscrow | 142 (32) | Holds in-kind remainders a blocked borrower cannot receive | Keep / merge into the ledger's pending balance / drop in-kind | Keep. It is small, immutable and closes a liveness hole (a USDC/USDT-blocklisted borrower could otherwise block their own liquidation) | Liquidation of blocklisted borrowers fails exactly when routes have failed |
| Lock | 110 (20) | Cross-contract reentrancy | Keep / per-contract transient guards | Keep, with members {Adapter, LPVaultSwap} (§3). Per-contract guards would let a token callback during settlement reenter the Adapter | Cross-contract reentrancy |
| Lens | 888 (401) | Read-only views and previews; "not part of the protocol's security" (2.17) | Keep in the audited core / move to the periphery or an off-chain SDK | Move out of the audited, immutable core. It is the fourth-largest interface and the third-largest by code, and no core contract calls it | Permissionless liquidators lose an on-chain preview; publish it as a periphery contract instead |
| First-Loss Reserve (Coverage Spoke) | 140 | Covers Aave deficits per (Hub, asset) | Keep / fund an Aave-side deficit mechanism with no Avana code **[UNVERIFIED** whether V4 has one for a third party to fund] | Keep if the DAO requires an Avana-controlled first loss; otherwise ask Aave whether a standard funded position can call `eliminateDeficit` | The DAO will likely require first-loss capital in some form |
| ParameterStore + MarketRegistry | 1,566 + 1,560 (544 + 499) | Parameters and bounds; listings and routes | Keep split / merge | Keep split: they share one trust level and blast radius (`REQ-ARCH-178`), so merging adds no safety, and the merged contract would break `Q-240`. The size is the problem: cut parameters, not contracts | — |
| RiskModule | 580 (167) | Stateless checks | Keep / merge into the Adapter | Keep: it is split out for size and so the Adapter stays the small contract that moves funds (`Q-229`) | — |
| Adapter and RiskModule drift checks | Part of the above | Compare Aave configuration with expectations | Check every field / check only the implementation and manager | Depends on §5. With the standard Spoke, keep and strengthen them: `receiveSharesEnabled`, `liquidationFee`, reinvestment controller and implementation. With a liquidation-manager variant, drop the field checks it enforces in code | With the standard Spoke, removal is not safe |
| ProxyManager beacon | 130 (30) | Every PositionProxy follows one implementation | Beacon (spec) / pinned implementation per proxy (proposal) | Resolve the conflict. Pinned proxies remove a chain-wide upgrade of every account's custody, but each fix needs an opt-in migration | Under the beacon, one bad upgrade reaches every proxy |

### `AMMN-ARCH-08` — Low — The Lens is in the audited immutable core but carries no security role

Spec 2.17 states that no core contract calls the Lens and nothing it returns authorizes an action. Its interface is 888 lines (401 code). Move it to an unaudited or separately reviewed periphery that can be redeployed. Keep `previewLiquidation` there, since LPVaultSwap re-checks everything on execution.

### `AMMN-ARCH-09` — Informational — The proposal and the spec disagree on the PositionProxy upgrade model

The proposal records "pinned implementation per proxy, no beacon", while 2.5 specifies the ProxyManager as the beacon of every PositionProxy (`REQ-ARCH-035`). The custody trust statement (`REQ-ARCH-047`) and the blast radius in `REQ-ARCH-178` differ between the two. Record one choice in 4.4.

### `AMMN-ARCH-10` — Informational — Drift checks duplicate rules the liquidation-manager Spoke enforces in code

Under `Q-222` the Spoke rejects a non-zero liquidation fee and a borrowable vault reserve in code. The RiskModule's drift check also tests these fields on every pledge and borrow. With the implementation and `LIQUIDATION_MANAGER` checks in place, the field checks add code, gas and test cases but no protection. Remove them. This applies only if a liquidation-manager Spoke is used. Under the standard Spoke recommended in §5, these field checks become the main control and must stay.

---

## Summary of recommendations

| # | Assumption | Recommendation | Finding |
|---|---|---|---|
| 1 | One market per Spoke | One Spoke per (Hub, AMM protocol); markets as reserves. This requires the standard Spoke (§5) | `AMMN-ARCH-02` Medium |
| 2 | Adapter and LPVaultSwap per Hub | One per chain; Hub and Spoke scope as data | `AMMN-ARCH-03` Low |
| 3 | Vault + ledger per Spoke | One AMM-neutral ledger per chain; one vault per AMM protocol per chain; Lock members {Adapter, LPVaultSwap} | `AMMN-ARCH-01` Medium |
| 4 | VaultToken + LPOracle per market | Keep both per market; one LPOracle implementation per AMM protocol | — |
| 5 | Standard Spoke | Standard Spoke for launch, with `receiveSharesEnabled = false`, `liquidationFee = 0` and no reinvestment controller as required settings plus the drift check; the `Q-222` Spoke does not exist | `AMMN-ARCH-07` Medium |
| 6 | Flash liquidity (decided: one Aave flash source, `Q-334`) | Accept with controls: ceiling check, `FLASH_BORROWER`, maximum fee, replaceable source, never the same V4 Hub, authenticated callback, caller-GHO fallback; Base GHO `drawCap` ≤ min(flash ceiling, conversion depth) | `AMMN-ARCH-04` High |
| 7 | Pricing library per market | Library per AMM protocol behind a fixed `IAmmIntegration`-style interface the vault implements; `bytes32` keys, n-token arrays | `AMMN-ARCH-06` Medium |
| 8 | Two chains at once | Mainnet first | `AMMN-ARCH-05` Medium |
| 9 | Contract set | Move the Lens out of the core; resolve the beacon conflict; keep the drift checks (standard Spoke); keep the rest | `AMMN-ARCH-08` Low, `AMMN-ARCH-09` Info, `AMMN-ARCH-10` Info |

## Questions open at review time and their decisions

1. Borrow caps: one CDP Spoke per (chain, Hub, AMM protocol, risk tier) lists several markets, each with Avana's per-market USD caps (`Q-280`); the caps and risk factors are set with the Aave V4 risk service providers in each listing payload (`Q-197`).
2. Fix path for a liquidation-blocking LPVaultSwap bug: LPVaultSwap is a UUPS proxy upgraded through the timelock at the normal delay (`Q-226`, `Q-228`); 4.4 records no second liquidation manager.
3. Lock members: exactly the AaveAdapter and LPVaultSwap; fee collection and zero-credit release are AaveAdapter entry points, and stray-position return is a timelock-only LPVault call (`Q-318`, `Q-296`).
4. Oracle upgrades: one LPOracle instance per market (`Q-279`), so an upgrade can reach one market first.
5. Standard Spoke: every CDP Spoke is a standard Aave V4 Spoke with three required settings and Avana's drift check; the residual risk of a DAO configuration change is accepted with the exposure window of `Q-382` (`Q-281`, `Q-352`).
6. Flash liquidity: GHO's flash minter is not used on any chain; the flash source is the chain's Aave V3 Pool (`Q-334`), and a liquidation is funded by its caller (`Q-404`).
7. Launch chains: Ethereum and Base launch together, each with its own Hub, timelock and Guardian (`Q-279`).
8. SettlementBudget and in-kind settlement: both removed; the caller shortfall top-up stays (`Q-397`, `Q-401`).
9. PositionProxy: a logic-free immutable account with no beacon or implementation slot (`Q-306`).
