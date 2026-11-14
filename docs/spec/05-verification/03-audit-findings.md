# 5.3 Audit Findings

> **Status:** In review · **Owner:** Avana Labs · **Last reviewed:** 2026-11-10

The findings register. Every counterexample found by the spec-stage models and every attack found in design review that the design did not fully block is recorded here, with the decision that resolved it and the test or property that confirms the fix. Implementation-stage findings from developers, formal verification and external auditors are added with the same fields; raw reports and evidence go in [`docs/audit/`](../../audit/).

- **Source**: who found it. Model evidence paths are relative to this folder. *Design review (attacker round)* findings came from an adversarial pass over the whole design; *Design review (decision check)* findings came from checking each decision against the others. Neither set are entries of [4.2](../04-security/02-attack-scenarios.md); 4.2 holds the attack scenarios that the final design must block. *Formal verification* findings came from machine-checked proofs over the drafted contract rules (custody, governance and control, liquidation); *Design review (risk round)* findings from a system-level solvency and risk review; *User simulation* findings from a simulated population of borrowers, liquidity providers and keepers run through market stress paths. In these sections the Resolution ends with the rules the fix changed. *Design review (AMM-neutral)* findings came from the review of the move to several AMM protocols, Hubs and chains (run `AMMN-R1`: red team, flow walkthroughs, gas and DoS, integration assumptions, architecture options, state machine); their severity is the combined report's where merging duplicates raised it.
- **Severity**: Critical (loss of collateral or unbacked debt, no precondition beyond an upgrade or a public call), High (loss or protocol-wide halt under a plausible condition), Medium (bounded loss, griefing or liveness loss in one market), Low (dust-level loss or a narrow condition), Informational (confirms a decision; no loss).
- **Status**: *Resolved in design* (a decision removes it; the verification proves the fix on code), *Resolved in spec* (a later decision changes the spec rules named in the Resolution; the verification proves the fix on code), *Accepted risk* (residual risk accepted by a decision; the Resolution names the owner and the bound, and the verification monitors or bounds it), *Resolved in spec — re-verification pending* (the decision named in the Reference changes the spec rules named in the Resolution; the verification has not yet run against the changed rules, and the status moves to Resolved in spec when it passes), *Launch condition* (resolved only once a value, configuration or agreement is in place before launch; the Resolution names the condition and who meets it, and the verification checks it).
- **Verification**: `TEST-…` in [5.1](01-test-requirements.md) and `PROP-…` in [5.2](02-formal-properties.md). Retest results come from running those tests and properties on the code.

**295 findings:** 75 resolved in design, 100 resolved in spec, 85 resolved in spec with re-verification pending, 28 accepted risks, 7 launch conditions.

## Index

| ID | Title | Severity | Component | Reference | Status |
|---|---|---|---|---|---|
| `FINDING-001` | Odd decimal sum misprices the vault token | Medium | LPOracle, vault token, listing | `MATH-UO-01` (01b), `SYM-30d`, `Q-066` | Resolved in design |
| `FINDING-002` | Deep depeg takes a whole vault token below the $1 target | Informational | Vault token decimals | `MATH-UO-02` (02c), `Q-066` | Accepted risk |
| `FINDING-003` | Non-standard tick spacing allows liquidity that overflows Aave value math | Low | Listing, LPOracle | `MATH-UO-04` (04b), `MATH-UO-05` (05c), `Q-191` | Resolved in design |
| `FINDING-004` | Sqrt price from feeds reverts before the clamp | Medium | LPOracle | `MATH-UO-10` (10b), `MATH-UO-11`, `Q-056`, `Q-191` | Resolved in design |
| `FINDING-005` | TWAP orientation taken from the listing name | Medium | LPOracle | `MATH-UO-13`, `SYM-33`, `Q-119` | Resolved in design |
| `FINDING-006` | High-decimal feed normalises to zero | High | LPOracle | `MATH-UO-15` (15b), `Q-056`, `Q-191` | Resolved in design |
| `FINDING-007` | Perfect-square answers overvalue the actual holdings | Low | LPOracle | `MATH-UO-16` (16a), `MATH-UO-17`, `Q-191` | Resolved in design |
| `FINDING-008` | Stable ceiling applied before the TWAP and agreement checks | Medium | LPOracle | `MATH-UO-20`, `HYP-51`, `Q-057`, `Q-177`, `Q-200` | Resolved in design |
| `FINDING-009` | Uncapped stable premium raises collateral value | Low | LPOracle | `MATH-UO-21`, `Q-057`, `Q-177` | Resolved in design |
| `FINDING-010` | Common-mode feed errors pass every price check | High | LPOracle, listing | `MATH-UO-22`, `MATH-UO-23` (23c), `SIM-03A`, `Q-079`, `Q-112`, `Q-130`, `Q-176`, `Q-195` | Accepted risk |
| `FINDING-011` | Floor division in the agreement tolerance admits one extra basis point | Low | LPOracle | `MATH-UO-24` (24a), `Q-184` | Resolved in design |
| `FINDING-012` | Pro-rata cap counter readings allow cap bypass or creep | High | Collateralization cap counters | `MATH-UO-25`, `MATH-UO-26`, `Q-109`, `Q-174` | Resolved in design |
| `FINDING-013` | Pledge-time cap charge floors to zero for dust | Low | RiskModule pledge charge, Collateralization cap counters | `MATH-UO-27` (27a), `Q-174`, `Q-175`, `Q-230` | Resolved in design |
| `FINDING-014` | Hub addCap sized at today's price removes the top-up slice in stress | High | Hub cap sizing, RiskModule | `MATH-UO-28`, `Q-150`, `Q-175` | Resolved in design |
| `FINDING-015` | Burn, debit and removal equalities are load-bearing | Informational | AaveAdapter, Collateralization, vault token | `MATH-UO-31`, `Q-069`, `Q-160`, `Q-165`, `Q-224`, `Q-240` | Resolved in design |
| `FINDING-016` | Exact debit check fails when Hub shares differ from assets | Medium | Collateralization liquidation debit | `MATH-UO-32`, `MATH-ST-38`, `MATH-ST-39`, `MATH-ST-40`, `MATH-ST-45`, `Q-103`, `Q-125`, `Q-160`, `Q-189`, `Q-206` | Resolved in design |
| `FINDING-017` | A faulty RiskModule could approve withdraw-with-debt down to HF 1 | Medium | RiskModule, AaveAdapter | `MATH-AR-06`, `Q-126`, `Q-161`, `Q-229`, `Q-398` | Resolved in design |
| `FINDING-018` | Interest moves accounts across the opening gate | Informational | RiskModule, Borrow Spoke | `MATH-AR-08` (08b), `Q-018`, `Q-234`, `Q-398` | Accepted risk |
| `FINDING-019` | Minimum liquidation bonus is set by the bonus factor, not the maximum bonus | Medium | Borrow Spoke configuration, LPVaultSwap | `MATH-AR-09` (09c), `SYM-15e`, `Q-098`, `Q-179` | Launch condition |
| `FINDING-020` | Below HF = bonus × CF a liquidation lowers HF and takes the whole reserve | Informational | LPVaultSwap, keeper | `MATH-AR-11` (11b), `SYM-13a`…`SYM-13c`, `Q-060`, `Q-166`, `Q-194`, `Q-234`, `Q-235` | Resolved in design |
| `FINDING-021` | Repay floor blocks partial repay and strands sub-dust debt | High | AaveAdapter repay | `MATH-AR-15` (15b), `MATH-AR-19`, `Q-146`, `Q-153`, `Q-169`, `Q-223` | Resolved in design |
| `FINDING-022` | Repay-all signed as an exact amount fails after interest | Medium | AaveAdapter repay | `MATH-AR-17`, `Q-075`, `Q-180`, `Q-209`, `Q-234` | Resolved in design |
| `FINDING-023` | Risk-premium threshold equal to the top collateral risk reverts premium updates | High | Borrow Spoke configuration | `MATH-AR-22`, `MATH-AR-23`, `Q-111`, `Q-141` | Resolved in design |
| `FINDING-024` | Many one-share dust users can exceed the one-basis-point margin | Low | Borrow Spoke configuration | `MATH-AR-24` (24a), `Q-141`, `Q-169` | Accepted risk |
| `FINDING-025` | Raising collateral risk above the threshold blocks liquidation | High | Borrow Spoke configuration, RiskModule drift check | `MATH-AR-25`, `Q-111`, `Q-141`, `Q-178` | Resolved in design |
| `FINDING-026` | Vault-token asset drawn through another Spoke breaks shares == assets | Medium | Hub configuration, RiskModule drift checks | `MATH-AR-27`, `MATH-ST-41`, `Q-080`, `Q-172`, `Q-181` | Resolved in design |
| `FINDING-027` | Pause losses depend on the worst LP drop, not the pause length | Informational | Caps, First-Loss Reserve | `MATH-AR-30` (30c), `MATH-AR-31`, `Q-079`, `Q-192`, `Q-227`, `Q-234` | Launch condition |
| `FINDING-028` | Recovery measured on the wrong balance | Informational | LPVaultSwap | `MATH-ST-02`, `MATH-ST-03`, `Q-085` | Resolved in design |
| `FINDING-029` | Additive slippage bound does not cover flash repayment | High | LPVaultSwap | `MATH-ST-05`, `MATH-ST-08`, `MATH-ST-22`, `SYM-41`, `SYM-42`, `Q-127`, `Q-159`, `Q-235` | Resolved in design |
| `FINDING-030` | Effective slippage rounded to nearest misses repayment | Low | LPVaultSwap | `MATH-ST-11`, `Q-159`, `Q-190`, `Q-235` | Resolved in design |
| `FINDING-031` | Aave liquidation-fee drift breaks the slippage bound | Medium | LPVaultSwap, Borrow Spoke, RiskModule drift checks | `MATH-ST-12`, `Q-068`, `Q-080`, `Q-190`, `Q-222`, `Q-237` | Resolved in design |
| `FINDING-032` | Waterfall wording lets Avana take keeper principal or the budget refund the keeper | High | LPVaultSwap | `MATH-ST-19`, `MATH-ST-20`, `Q-097`, `Q-127`, `Q-190`, `Q-235`, `Q-397` | Resolved in design |
| `FINDING-033` | Oversized flash loan turns the flash fee into a budget draw | Low | LPVaultSwap | `MATH-ST-23`, `SYM-45`, `Q-135`, `Q-190`, `Q-235`, `Q-397` | Resolved in design |
| `FINDING-034` | Calendar-day budget bucket allows twice the daily cap | Medium | SettlementBudget (removed, `Q-397`) | `MATH-ST-25`, `Q-167`, `Q-190`, `Q-236`, `Q-397` | Resolved in design |
| `FINDING-035` | In-kind value rounded down lets the keeper exceed the cap | Low | LPVaultSwap in-kind (removed, `Q-401`) | `MATH-ST-28`, `Q-133`, `Q-190`, `Q-401` | Resolved in design |
| `FINDING-036` | In-kind valued at pool spot price | Informational | LPVaultSwap in-kind (removed, `Q-401`) | `MATH-ST-31`, `Q-133`, `Q-401` | Resolved in design |
| `FINDING-037` | Position-manager uint128 wrap in collect | Informational | LPVault | `MATH-ST-36`, `Q-061` | Accepted risk |
| `FINDING-038` | Coverage role can spend the reserve on any Spoke's deficit | High | First-Loss Reserve, First-Loss Reserve | `MATH-ST-50`, `Q-101`, `Q-142`, `Q-190`, `Q-236` | Resolved in design |
| `FINDING-039` | Avana fee in in-kind mode unspecified | Low | LPVaultSwap in-kind (removed, `Q-401`) | `MATH-ST` findings item 10, `Q-097`, `Q-133`, `Q-163`, `Q-190`, `Q-401` | Resolved in design |
| `FINDING-040` | Rate and premium wording in the ARFC differs from Aave V4 | Low | Borrower disclosures | `SYM-51b`, `SYM-53d`, `Q-096`, `Q-231`, `Q-233` | Resolved in design |
| `FINDING-041` | Hostile LPVaultSwap can strand a borrower's NFTs | High | LPVaultSwap (upgradeable), Collateralization, AaveAdapter | `QNT-07`, `QNT-15`, `QNT-22`, `QNT-T09`, `Q-090`, `Q-125`, `Q-160`, `Q-165`, `Q-201`, `Q-211`, `Q-224`, `Q-228`, `Q-236` | Resolved in design |
| `FINDING-042` | Guardian's Aave pauseReserve blocks liquidation without expiry | High | Aave Spoke configuration, governance | `QNT-33`, `QNT-T13`, `Q-050`, `Q-083`, `Q-138`, `Q-192`, `Q-202`, `Q-209`, `Q-227`, `Q-229` | Accepted risk |
| `FINDING-043` | A faulty RiskModule approves borrowing against frozen or Drifting markets | Medium | RiskModule (upgradeable), AaveAdapter | `QNT-19`, `QNT-T04`, `Q-052`, `Q-081`, `Q-203`, `Q-227`, `Q-228`, `Q-229` | Accepted risk |
| `FINDING-044` | Zero-seizure liquidations draw the settlement budget | Medium | LPVaultSwap, SettlementBudget (removed, `Q-397`) | `QNT-29`, `QNT-T07`, `MATH-ST-06`, `Q-127`, `Q-167`, `Q-190`, `Q-198`, `Q-236`, `Q-397` | Resolved in design |
| `FINDING-045` | Guardian can keep liquidation halted half the time through repeated incidents | Low | Application pause state (MarketRegistry), governance | Quint note on `QNT-32`, `Q-083`, `Q-137`, `Q-196`, `Q-227` | Resolved in design |
| `FINDING-046` | Ledger-total debit check bricks later liquidations | Medium | Collateralization liquidation debit | `QNT-36`, `QNT-T11`, `Q-125`, `Q-160` | Resolved in design |
| `FINDING-047` | Uncapped liquidation collect takes the depositor's fees | Informational | LPVault liquidation | `QNT-T17`, `Q-061` | Resolved in design |
| `FINDING-048` | Dust accounts cannot be liquidated through routes | Medium | LPVaultSwap recovery floor | `HYP-53`, `Q-085`, `Q-098`, `Q-159`, `Q-163`, `Q-169`, `Q-198`, `Q-230`, `Q-236`, `Q-397` | Resolved in design |
| `FINDING-049` | Backup route carries every USDC and DAI leg in a USDC depeg | Medium | Settlement routes, debt buy and sell-back routes, listing | `SIM-01C`, `Q-058`, `Q-062`, `Q-084`, `Q-187`, `Q-233`, `Q-235` | Launch condition |
| `FINDING-050` | A GHO discount liquidates accounts solvent in GHO terms | Low | LPOracle, borrower disclosures | `SIM-01D`, `Q-057`, `Q-100`, `Q-177`, `Q-200`, `Q-238` | Accepted risk |
| `FINDING-051` | Disagreement tolerance below the alternate route's deviation pauses liquidations | Medium | LPOracle, listing | `SIM-01E`, `Q-112`, `Q-162`, `Q-183`, `Q-184`, `Q-199`, `Q-208` | Resolved in design |
| `FINDING-052` | Tail collapse during an outage exceeds the First-Loss Reserve at high pool risk factors | High | Caps, pool risk factor, First-Loss Reserve | `SIM-02B`, `Q-079`, `Q-101`, `Q-186`, `Q-192` | Launch condition |
| `FINDING-053` | A silent feed stall keeps markets Live on a stale price | High | LPOracle, RiskModule, LPVaultSwap | `SIM-02C`, `SIM-03C`, `Q-079`, `Q-130`, `Q-182`, `Q-229`, `Q-238` | Launch condition |
| `FINDING-054` | Cached window measured from the source timestamp is skipped | Medium | LPOracle | `SIM-02D`, `Q-079`, `Q-128`, `Q-154`, `Q-183` | Resolved in design |
| `FINDING-055` | Stale-price borrowing in a deep crash is profitable | Medium | RiskModule, caps | `SIM-03D`, `Q-079`, `Q-182`, `Q-186`, `Q-229` | Resolved in design |
| `FINDING-056` | No bonus floor makes small liquidations profitable in a gas spike | Medium | Keeper economics | `SIM-05A`, `Q-098`, `Q-169`, `Q-185` | Accepted risk |
| `FINDING-057` | Keepers that skip loss-making calls leave dust bad debt | Medium | Avana keepers, keeper gas | `SIM-05C`, `Q-098`, `Q-101`, `Q-169`, `Q-185` | Launch condition |
| `FINDING-058` | Interest-driven liquidations lose money at moderate gas | Low | Keeper economics | `SIM-07C`, `Q-098`, `Q-169`, `Q-185` | Accepted risk |
| `FINDING-059` | Zero GHO collateral factor on the Core Hub would zero every GHO pool's CF | Medium | Listing, Borrow Spoke configuration | Simulation assumption review, `Q-020`, `Q-188` | Resolved in design |
| `FINDING-060` | Aave DAO can enable receiveShares on a vault-token reserve | Medium | Borrow Spoke configuration | `Q-068`, `Q-080`, `Q-116`, `Q-172`, `Q-222` | Resolved in design |
| `FINDING-061` | Adapter as an allowed holder can seize collateral | High | Vault token, AaveAdapter, Borrow Spoke | `Q-068`, `Q-092`, `Q-120`, `Q-222`, `Q-223`, `Q-224` | Resolved in design |
| `FINDING-062` | Hostile Adapter injects an attacker contract into the proxy registry | Critical | Vault token registry, AaveAdapter | `QNT-T08` (`q068RogueRegistryTest`), `Q-068`, `Q-120`, `Q-224`, `Q-225` | Accepted risk |
| `FINDING-063` | Zero-collateral third-party liquidation succeeds | Low | Borrow Spoke, indexer | `Q-059`, `Q-116`, `Q-144` | Resolved in design |
| `FINDING-064` | Hostile LPVaultSwap debits a healthy account's records | Critical | Collateralization, LPVaultSwap | `QNT-T10`, `Q-092`, `Q-125`, `Q-160`, `Q-165`, `Q-224`, `Q-240` | Resolved in design |
| `FINDING-065` | Faulty RiskModule approves risky borrows | High | RiskModule, AaveAdapter | `Q-093`, `Q-126`, `Q-161`, `Q-228`, `Q-229`, `Q-398` | Resolved in design |
| `FINDING-066` | Upgradeable config redirects a proxy's Spoke or debt-asset target | Critical | AaveAdapter, PositionProxy, Collateralization | `Q-126`, `Q-223`, `Q-225` | Resolved in design |
| `FINDING-067` | Upgradeable checks veto repay or debt-free withdrawal | High | AaveAdapter, RiskModule, MarketRegistry | `Q-051`, `Q-093`, `Q-122`, `Q-223`, `Q-227` | Resolved in design |
| `FINDING-068` | Compromised Convex rewrites a stored borrow intent | High | Convex, web app | `Q-073`, `Q-106`, `Q-149` | Resolved in design |
| `FINDING-069` | Standing approvals to the upgradeable Adapter | High | Web app, AaveAdapter | `Q-093`, `Q-123`, `Q-144`, `Q-223` | Accepted risk |
| `FINDING-070` | Fake backing through an upgradeable pool-to-token map | Critical | Collateralization, AaveAdapter | `Q-092`, `Q-126`, `Q-224`, `Q-240` | Resolved in design |
| `FINDING-071` | Zero-credit record treated as stray | Medium | LPVault, Collateralization | `Q-104`, `Q-134`, `Q-228` | Resolved in design |
| `FINDING-072` | Settlement budget drained by route sandwiching | High | LPVaultSwap, SettlementBudget (removed, `Q-397`) | `Q-117`, `Q-127`, `Q-159`, `Q-167`, `Q-190`, `Q-235`, `Q-236`, `Q-397` | Resolved in design |
| `FINDING-073` | Keeper forces the in-kind fallback | High | LPVaultSwap in-kind (removed, `Q-401`), MarketRegistry | `Q-084`, `Q-133`, `Q-163`, `Q-227`, `Q-228`, `Q-401` | Resolved in design |
| `FINDING-074` | Per-leg unwind minimums re-create a spot-price veto | Medium | LPVault liquidation | `Q-085`, `Q-131` | Resolved in design |
| `FINDING-075` | One-wei donation bricks repay or liquidation | High | PositionProxy, LPVaultSwap | `Q-097`, `Q-124` | Resolved in design |
| `FINDING-076` | Liquidation shield through a top-up into a degraded market | High | RiskModule pledge gates, LPVaultSwap | `Q-087`, `Q-118`, `Q-121`, `Q-128`, `Q-132` | Resolved in design |
| `FINDING-077` | Grace latch re-triggered by a caught feed failure | High | LPOracle grace latch | `QNT-T12` (`graceReadLatchMissTest`), `Q-088`, `Q-129`, `Q-154` | Resolved in design |
| `FINDING-078` | Cap filling blocks rescue top-ups | High | RiskModule caps, ParameterStore, Collateralization | `Q-150`, `Q-157`, `Q-227`, `Q-230`, `Q-396` | Resolved in design |
| `FINDING-079` | Recovery multisig used as an instant loosen key | High | Pause state, governance | `Q-083`, `Q-137`, `Q-138`, `Q-156`, `Q-206`, `Q-227`, `Q-228` | Resolved in design |
| `FINDING-080` | Exploit waits out the Guardian incident deadline | Medium | Pause state | `Q-083`, `Q-138`, `Q-206`, `Q-164`, `Q-227` | Resolved in design |
| `FINDING-081` | Short-delay tightening halts liquidations | High | ParameterStore, AvanaTimelock | `Q-114`, `Q-139`, `Q-209`, `Q-210`, `Q-228` | Resolved in design |
| `FINDING-082` | Keeper wipe including the standby | High | LPVaultSwap keeper list | `Q-082`, `Q-139`, `Q-155`, `Q-213`, `Q-228`, `Q-400` | Resolved in design |
| `FINDING-083` | Malicious route installed on the short delay | High | Settlement routes, debt buy routes, MarketRegistry | `Q-062`, `Q-151`, `Q-228`, `Q-235` | Resolved in design |
| `FINDING-084` | Keeper reimbursement farming | Low | Keeper agreement | `Q-098`, `Q-115` | Accepted risk |
| `FINDING-085` | Web bundle or manifest swapped in the supply chain | Medium | Web app, release manifest | `Q-073`, `Q-115`, `Q-223` | Accepted risk |
| `FINDING-086` | Keeper grants through grantDelay cannot be cancelled | High | AvanaTimelock, LPVaultSwap keeper list | `Q-136`, `Q-155`, `Q-228` | Resolved in design |
| `FINDING-087` | Recovery alone can quarantine every keeper | High | LPVaultSwap keeper list, governance | `Q-137`, `Q-138`, `Q-139`, `Q-156`, `Q-206`, `Q-213`, `Q-227` | Resolved in design |
| `FINDING-088` | Exits still call the upgradeable RiskModule | High | Collateralization, RiskModule | `Q-055`, `Q-109`, `Q-122`, `Q-158`, `Q-209`, `Q-240` | Resolved in design |
| `FINDING-089` | Served price undefined while feeds disagree | Medium | LPOracle, LPVaultSwap | `Q-112`, `Q-128`, `Q-162`, `Q-183`, `Q-199`, `Q-208` | Resolved in design |
| `FINDING-090` | In-kind enable authority and speed unstated | Medium | LPVaultSwap in-kind (removed, `Q-401`), MarketRegistry | `Q-133`, `Q-163`, `Q-206`, `Q-227`, `Q-228`, `Q-401` | Resolved in design |
| `FINDING-091` | Paused state blocks rescue top-ups | Medium | MarketRegistry pause state | `Q-136`, `Q-138`, `Q-164`, `Q-206`, `Q-227`, `Q-228`, `Q-252` | Resolved in spec |
| `FINDING-092` | Recipient-only transfer rule lets a hostile LPVaultSwap supply seized tokens | Medium | Vault token, LPVaultSwap | `Q-120`, `Q-165`, `Q-222`, `Q-224`, `ATTACK-137` | Accepted risk |
| `FINDING-093` | Reserve ID cannot be a vault-token immutable | Informational | Vault token, AaveAdapter, PositionProxy | `Q-126` | Resolved in design |
| `FINDING-094` | Minimum NFT in a stale-prone market shields the whole account | Medium | LPVaultSwap price gates, listing | `Q-128`, `Q-182`, `Q-230`, `Q-234`, `Q-247` | Resolved in spec |
| `FINDING-095` | Compromised keeper at the floor cannot be revoked at once | Low | LPVaultSwap keeper list | `Q-139`, `Q-155`, `Q-156`, `Q-228`, `Q-400` | Accepted risk |
| `FINDING-096` | Callbacks arrive from non-Avana addresses while the lock is held | Medium | Lock contract, LPVaultSwap | `Q-045`, `Q-148`, `Q-223`, `Q-235` | Resolved in design |
| `FINDING-097` | Recovery can restore a route disabled for cause | Low | Settlement routes, debt buy routes, governance | `Q-151`, `Q-156`, `Q-206`, `Q-227`, `Q-228` | Resolved in design |
| `FINDING-098` | Debt below one seized unit cannot be liquidated through LPVaultSwap | Informational | LPVaultSwap, Borrow Spoke | `HYP-53`, `Q-127`, `Q-169`, `Q-198`, `Q-212`, `Q-215`, `Q-222`, `Q-237` | Accepted risk |
| `FINDING-099` | Adapter implementation holds custody power over every proxy position | High | AaveAdapter, PositionProxy, vault token | `Q-223`, `Q-224`, `Q-226`, `Q-228`, `ATTACK-122`, `ATTACK-124`, `ATTACK-125` | Accepted risk |
| `FINDING-100` | One beacon upgrade changes every PositionProxy at once | High | ProxyManager (beacon), PositionProxy | `Q-225`, `Q-226`, `Q-228`, `ATTACK-123` | Accepted risk |
| `FINDING-101` | A stale debt-asset feed blocks liquidation of every account holding that debt | Medium | LPVaultSwap price gates, RiskModule, debt-reserve listing | `Q-128`, `Q-234`, `Q-238`, `Q-247`, `Q-248`, `ATTACK-129` | Accepted risk |
| `FINDING-102` | A debt-asset price rally makes stable-LP accounts liquidatable together | Medium | Debt-reserve listing, caps, LPVaultSwap buy leg | `Q-192`, `Q-233`, `Q-234`, `Q-235`, `ATTACK-128` | Launch condition |
| `FINDING-103` | Buy-leg cost could be billed to the settlement budget | Medium | LPVaultSwap, SettlementBudget (removed, `Q-397`), debt buy routes | `Q-127`, `Q-235`, `Q-236`, `ATTACK-126`, `ATTACK-127`, `Q-397` | Resolved in design |
| `FINDING-104` | An unsettled seized-unit burn blocks every pledge and withdrawal of a market | Medium | AaveAdapter backing check, Collateralization, vault token | `Q-224`, `Q-257` | Resolved in spec |
| `FINDING-105` | A stray NFT could be pledged with the LPVault as depositor | Low | LPVault custody, Collateralization pledge | `Q-223`, `Q-258` | Resolved in spec |
| `FINDING-106` | Per-bucket exposure counters do not equal the slice and regular parts of open records | Informational | Collateralization exposure counters | `Q-157` | Resolved in spec |
| `FINDING-107` | Credited value can exceed the immediate removal value by one raw unit per leg | Informational | Vault-token units, LPOracle, LPVault removal | `Q-066`, `Q-124` | Resolved in spec |
| `FINDING-108` | The pending-settlement invariant named the wrong custodian | Informational | Collateralization pending settlement, LPVault | `Q-201`, `Q-211` | Resolved in spec |
| `FINDING-109` | The debt-free withdrawal check omitted the reconcile wait | Informational | Debt-free withdrawal, reconcile on exit | `Q-201` | Resolved in spec |
| `FINDING-110` | A role grant could hand out admin power that then acts without delay | Medium | AvanaTimelock, every upgradeable Avana contract | `Q-228`, `Q-259`, `ATTACK-152` | Resolved in spec |
| `FINDING-111` | Exits and the health floor depended on the upgradeable MarketRegistry | Medium | PositionProxy, AaveAdapter repay and withdraw | `Q-227`, `Q-260` | Resolved in spec |
| `FINDING-112` | The buy-leg allowance could halt or over-draw non-GHO liquidations | Medium | ParameterStore, MarketRegistry listing, LPVaultSwap two-leg settlement | `Q-235`, `Q-261`, `Q-397` | Resolved in spec |
| `FINDING-113` | An address freeze could block exits and liquidation or target Avana itself | Medium | MarketRegistry address freeze, AaveAdapter, LPVaultSwap, ProxyManager | `Q-242`, `ATTACK-139` | Resolved in spec |
| `FINDING-114` | The short-delay list could admit risk-raising selectors | Low | AvanaTimelock short-delay list | `Q-228`, `Q-262` | Resolved in spec |
| `FINDING-115` | The normal delay could be cut below the borrower exit window | Medium | AvanaTimelock delays | `Q-228`, `Q-262` | Resolved in spec |
| `FINDING-116` | The grace-window fallback started grace before the recovery | Low | LPOracle grace latch | `Q-129`, `Q-264` | Resolved in spec |
| `FINDING-117` | A cancelled registration made its pool unlistable | Low | MarketRegistry listing, VaultTokenFactory | `Q-265` | Resolved in spec |
| `FINDING-118` | A reinitializer in a PositionProxy implementation was callable by anyone | Low | PositionProxy, ProxyManager beacon | `Q-225`, `Q-266` | Resolved in spec |
| `FINDING-119` | Pages disagreed on the delay class of the USD band and grace parameters | Informational | ParameterStore, parameter registry, market lifecycle | `Q-246` | Resolved in spec |
| `FINDING-120` | A zero per-call budget cap blocked every rounding-allowance change | Low | ParameterStore, SettlementBudget caps (removed, `Q-397`) | `Q-267`, `Q-397` | Resolved in spec |
| `FINDING-121` | An unobserved recovery left the Cached start stale | Informational | LPOracle price states | `Q-183` | Resolved in spec |
| `FINDING-122` | Record paging reverted on overflow instead of returning an empty page | Informational | Lens | `Q-268` | Resolved in spec |
| `FINDING-123` | Predicted proxy addresses could diverge from stored proxies after a ProxyManager upgrade | Informational | Lens, ProxyManager, RiskModule previews | `Q-266`, `Q-268` | Resolved in spec |
| `FINDING-124` | Two verification targets claimed more scope than the design gives | Informational | Verification procedure, RiskModule, AaveAdapter | `Q-223`, `Q-229` | Resolved in spec |
| `FINDING-125` | Circuit breakers needed triggers, counting and reset that cannot block exits or liquidation | Informational | MarketRegistry breakers, RiskModule, LPVaultSwap | `Q-241`, `ATTACK-138`, `Q-399` | Resolved in spec |
| `FINDING-126` | The per-draw budget bound omitted Aave's debt rounding | Low | SettlementBudget (removed, `Q-397`), LPVaultSwap | `Q-236`, `Q-267`, `Q-397` | Resolved in spec |
| `FINDING-127` | The flash-fee allowance in a draw could exceed the fee charged | Low | LPVaultSwap waterfall, SettlementBudget (removed, `Q-397`) | `Q-267`, `Q-397` | Resolved in spec |
| `FINDING-128` | The previewed seizure could differ from Aave's by one unit | Informational | Lens liquidation preview | `Q-232`, `Q-268` | Resolved in spec |
| `FINDING-129` | A 1-wei repay at Aave's dust boundary reverted a previewed liquidation | Low | Lens liquidation preview, LPVaultSwap | `Q-268` | Resolved in spec |
| `FINDING-130` | A caller could divert Avana's fee through its own routing | Medium | LPVaultSwap fee and sell-back | `Q-231`, `Q-256`, `ATTACK-151` | Resolved in spec |
| `FINDING-131` | Buy-route over-delivery could strand the extra debt asset | Informational | LPVaultSwap buy leg and sell-back | `Q-235` | Resolved in spec |
| `FINDING-132` | A dust example seized more than Aave's sizing allows | Informational | Liquidation flow example | `Q-124` | Resolved in spec |
| `FINDING-133` | Reserve sizing did not cover the default of one pool token | High | Caps, First-Loss Reserve, Lens | `Q-186`, `Q-192`, `Q-249` | Resolved in spec |
| `FINDING-134` | An account-wide liquidation gate let one stale market shield a whole account | High | LPVaultSwap price gates, LPOracle, DebtOracle | `Q-234`, `Q-247`, `ATTACK-145` | Resolved in spec |
| `FINDING-135` | A persistent disagreement or outage halted liquidation beyond the sizing window | High | LPOracle, MarketRegistry price routes, DebtOracle | `Q-192`, `Q-208`, `Q-248`, `ATTACK-140` | Resolved in spec |
| `FINDING-136` | Automatic breakers and the address freeze were missing | High | RiskModule, MarketRegistry, First-Loss Reserve | `Q-102`, `Q-241`, `Q-242`, `Q-399` | Resolved in spec |
| `FINDING-137` | Aave's collateral factor, bonus curve and target HF were not drift-checked | Medium | RiskModule drift check | `Q-110`, `Q-270` | Resolved in spec |
| `FINDING-138` | Every swap leg ran with a zero minimum output | Medium | LPVaultSwap, settlement and sell-back routes | `Q-250`, `ATTACK-144` | Resolved in spec |
| `FINDING-139` | Any single canceller could cancel every liquidation repair | Medium | AvanaTimelock cancel rules | `Q-228`, `Q-263`, `ATTACK-097`, `ATTACK-139`, `Q-401` | Resolved in spec |
| `FINDING-140` | A raised minimum pledge could block rescue top-ups, and loosening had no step limit | Medium | RiskModule pledge checks, ParameterStore | `Q-246`, `Q-252` | Resolved in spec |
| `FINDING-141` | Token issuer actions could halt liquidation of every affected market | Medium | LPVault, settlement routes, PositionProxy repay, breakers | `Q-241`, `Q-271`, `ATTACK-058`, `ATTACK-059`, `ATTACK-148`, `ATTACK-149` | Resolved in spec |
| `FINDING-142` | A price-feed phase change disabled the grace latch | Medium | LPOracle grace latch | `Q-129`, `Q-272`, `ATTACK-150` | Resolved in spec |
| `FINDING-143` | Pool share was tested only at pledge | Medium | RiskModule pool-share check, backup routes | `Q-187`, `Q-241`, `Q-273`, `Q-399` | Resolved in spec |
| `FINDING-144` | Keeper reimbursement was sized as if keepers did every liquidation | Low | Keeper reimbursement budget | `Q-185`, `Q-249` | Resolved in spec |
| `FINDING-145` | Small accounts are guaranteed keeper losses | Low | Minimum pledge value, keeper gas | `Q-215`, `Q-230`, `Q-277`, `ATTACK-147` | Accepted risk |
| `FINDING-146` | Liquidation below debt × bonus pays the bonus from the reserve | Medium | Liquidation sizing, First-Loss Reserve | `Q-249`, `Q-278` | Resolved in spec |
| `FINDING-147` | The governance Safe's own pause path took the normal delay | Low | AvanaTimelock short-delay list | `Q-262` | Resolved in spec |
| `FINDING-148` | The governance Safe was the only proposer | Medium | AvanaTimelock proposers, governance Safe | `Q-245` | Resolved in spec |
| `FINDING-149` | One market's dust wave could use every market's budget window | Low | SettlementBudget caps (removed, `Q-397`) | `Q-236`, `Q-267`, `Q-397` | Resolved in spec |
| `FINDING-150` | Wording inconsistencies across tests and role rules | Informational | Test requirements, role rules, emergency rules | `Q-227` | Resolved in spec |
| `FINDING-151` | The borrow price-age limit equalled the feed heartbeat | High | LPOracle feed cadence, borrow and withdraw gates, listing | `Q-182`, `Q-274` | Resolved in spec |
| `FINDING-152` | A fixed floor allowance turned stressed liquidations into gas burn | High | LPVaultSwap recovery floor, keeper operations | `Q-133`, `Q-251`, `ATTACK-141`, `ATTACK-142`, `Q-395`, `Q-401` | Resolved in spec |
| `FINDING-153` | The pool-share cap refused rescue top-ups during depegs | High | RiskModule pool-share check | `Q-157`, `Q-252` | Resolved in spec |
| `FINDING-154` | Repay-all sized to the quoted debt always failed | Medium | AaveAdapter repay, Lens, app | `Q-269` | Resolved in spec |
| `FINDING-155` | A joint stall of both routes was seen only after the slow route's heartbeat | Medium | LPOracle route failover | `Q-274` | Resolved in spec |
| `FINDING-156` | Debt prices had a single source and no failover | Medium | Debt-asset pricing | `Q-238`, `Q-248` | Resolved in spec |
| `FINDING-157` | The USD band's upper bound blocked GHO markets at a GHO premium | Medium | LPOracle USD band | `Q-176`, `Q-275` | Resolved in spec |
| `FINDING-158` | A slice top-up followed by a borrow turned the rescue budget into growth | Medium | Collateralization rescue units, RiskModule health check | `Q-157`, `Q-253`, `ATTACK-146`, `Q-398` | Resolved in spec |
| `FINDING-159` | Paused refused top-ups while liquidation ran | Medium | MarketRegistry pause state, AaveAdapter pledge | `Q-227`, `Q-252` | Resolved in spec |
| `FINDING-160` | $10 dust accounts are cheap to open and costly to liquidate | Low | Minimum pledge value, keeper gas | `Q-169`, `Q-230`, `Q-277`, `ATTACK-147` | Accepted risk |
| `FINDING-161` | Liquidity added to a pledged NFT was never credited | Low | AaveAdapter, Collateralization, LPVault | `Q-134`, `Q-254`, `ATTACK-143` | Resolved in spec |
| `FINDING-162` | A maximum borrow at exactly HF 1.10 always failed | Low | Lens, app borrow sizing | `Q-268`, `Q-398` | Resolved in spec |
| `FINDING-163` | One account per wallet spreads one market's state to every market | Low | PositionProxy accounts | `Q-234`, `Q-276` | Accepted risk |
| `FINDING-164` | The largest single-market USDC borrow in the borrow examples was rounded up | Low | AaveAdapter and borrow worked examples | `MATH-AR-37` | Resolved in spec |
| `FINDING-165` | The risk-premium example cited a minimum debt that does not exist | Low | Borrow Spoke configuration | `MATH-AR-24d`, `Q-169` | Resolved in spec |
| `FINDING-166` | The restore-amount rounding bound held only while the price was at or above the stress floor | Low | RiskModule restore amount | `MATH-AR-47c`, `MATH-AR-47d` | Resolved in spec |
| `FINDING-167` | The cap-sizing tail term divided by the opening health factor | Low | Caps, First-Loss Reserve sizing guidance, Lens | `MATH-AR-44b`, `MATH-ST-77`, `Q-249` | Resolved in spec |
| `FINDING-168` | The Hub addCap rule did not cover counters above a tightened cap | Low | Hub cap sizing, RiskModule | `MATH-AR-50c`, `REQ-RISK-042` | Resolved in spec |
| `FINDING-169` | A withdraw reconcile figure could not occur at any pool price | Low | Withdraw worked example, Collateralization reconcile | `SYM-138d`, `SYM-138e` | Resolved in spec |
| `FINDING-170` | The grace window could start before a recovery on a two-leg route or through a standby switch | Medium | LPOracle and DebtOracle grace latch | `Q-248`, `Q-264` | Resolved in spec |
| `FINDING-171` | A view could miss a disagreement no poke had seen when the pause window was 0 | Low | LPOracle disagreement windows | `Q-199`, `Q-208` | Resolved in spec |
| `FINDING-172` | The 1.4 pause table named the wrong error for a new pledge under Paused(General) | Informational | Permissions and roles pause table | `Q-252` | Resolved in spec |
| `FINDING-173` | Two rules named different errors for one pledge below minPledgeUsd | Informational | RiskModule minimum pledge | `Q-252`, `Q-277` | Resolved in spec |
| `FINDING-174` | The REQ-PSTORE-006 example overstated the spend bound | Informational | ParameterStore buy slippage allowance | `Q-261` | Resolved in spec |
| `FINDING-175` | A removed debt reserve could keep budget caps below the per-call bound | Informational | MarketRegistry debt reserves, SettlementBudget caps (removed, `Q-397`) | `Q-267`, `Q-397` | Resolved in spec |
| `FINDING-176` | The Lens paging rules gave two outcomes for one call | Informational | Lens | `Q-194`, `Q-268` | Resolved in spec |
| `FINDING-177` | The pool-share breaker blocked borrowing in GHO markets at a GHO premium | Medium | RiskModule pool-share breaker | `Q-241`, `Q-273`, `Q-275` | Resolved in spec |
| `FINDING-178` | PROP-065 said nothing lowers the backing gap, but an unburned pending settlement does | Informational | Collateralization backing, LPVaultSwap pending settlement | `Q-257` | Resolved in spec |
| `FINDING-179` | Several rules listed only the exits that existed before partial removal, re-credit and deleverage release | Informational | Collateralization reconcile on exit, ledgers | `Q-201`, `Q-254`, `Q-255` | Resolved in spec |
| `FINDING-180` | Two rules described call orders the specified flows do not follow | Informational | Collateralization checks-effects-interactions, RiskModule health check | `Q-148`, `Q-253` | Resolved in spec |
| `FINDING-181` | The minimum-pledge property priced the pledge at the served price and had no rescue minimum | Medium | RiskModule minimum pledge | `Q-230`, `Q-252`, `Q-277` | Resolved in spec |
| `FINDING-182` | The address-freeze property claimed no protected address is ever frozen | Low | MarketRegistry address freeze | `Q-242` | Resolved in spec |
| `FINDING-183` | The timelock property omitted the cancel of an expired operation | Low | AvanaTimelock | `Q-228`, `Q-263` | Resolved in spec |
| `FINDING-184` | The frozen-collateral borrow property covered reserves with no supplied shares | Informational | RiskModule borrow gate | `Q-203`, `Q-229` | Resolved in spec |
| `FINDING-185` | The repay-with-collateral property omitted the buy route as a GHO recipient | Low | LPVaultSwap repay with collateral | `Q-255` | Resolved in spec |
| `FINDING-186` | Three external calls had no interface the rules could bind | Medium | LPVaultSwap, settlement and buy routes | `Q-209`, `Q-255`, `Q-259` | Resolved in spec |
| `FINDING-187` | The reconcile property listed only three reconciling calls | Informational | Collateralization reconcile on exit | `Q-201`, `Q-254`, `Q-255` | Resolved in spec |
| `FINDING-188` | A rescue top-up restored only part of the gap after a price fall | Low | RiskModule restore amount | `Q-157`, `Q-252` | Resolved in spec |
| `FINDING-189` | An oversized debtToCover sold back at the sell-back floor still lowered Avana's fee | Low | LPVaultSwap Avana fee | `Q-256` | Resolved in spec |
| `FINDING-190` | The deleverage health-factor threshold missed the unit allowance and rounding | Informational | LPVaultSwap repay with collateral | `Q-255`, `MATH-ST-75` | Resolved in spec |
| `FINDING-191` | The per-leg minimums could exceed the aggregate floor by more than rounding when a leg was dust | Informational | LPVaultSwap per-leg minimum output | `Q-250` | Resolved in spec |
| `FINDING-192` | A whole-debt Lens quote reverted once interest accrued before inclusion | Medium | Lens liquidation preview | `Q-268` | Resolved in spec |
| `FINDING-193` | A collateral-limited non-GHO Lens quote reverted after a pledge | Low | Lens liquidation preview | `Q-268` | Resolved in spec |
| `FINDING-194` | The tail-coverage view overflowed for an unlimited draw cap | Informational | Lens tail coverage, First-Loss Reserve sizing | `Q-249` | Resolved in spec |
| `FINDING-195` | The per-call cap example used parameters at which no draw happens | Informational | SettlementBudget per-call cap (removed, `Q-397`) | `Q-267`, `MATH-ST-58`, `Q-397` | Resolved in spec |
| `FINDING-196` | The LIQ-069 account did not give the stated repayment and seizure | Informational | Liquidation and Lens worked examples | `Q-268` | Resolved in spec |
| `FINDING-197` | The deficit-coverage example wrote the share burn without the virtual offset | Informational | Deficit coverage worked example | `Q-236` | Resolved in spec |
| `FINDING-198` | A liquidation example floored the health factor to the wrong digit | Informational | Liquidation worked example | `Q-268` | Resolved in spec |
| `FINDING-199` | The pending-settlement floor example omitted the USDT price from U | Low | LPVaultSwap pending-settlement floor | `MATH-ST-84`, `Q-236` | Resolved in spec |
| `FINDING-200` | The per-leg minimums could exceed the aggregate floor by the LP price's rounding | Informational | LPVaultSwap per-leg minimum output | `HYP-85`, `Q-250` | Resolved in spec |
| `FINDING-201` | A narrow-range position was credited at the market range's value per unit of liquidity (×979) | Critical | Collateralization pledge, LPVault intake, LPOracle | `AMMN-RT-01`, `Q-359`, `ATTACK-004`, `ATTACK-153` | Resolved in spec — re-verification pending |
| `FINDING-202` | Pricing without a clamp of the oracle ratio to the range overvalued a depegged market (×2.97) | Critical | LPOracle pricing math | `AMMN-RT-02`, `Q-359`, `ATTACK-154` | Resolved in spec — re-verification pending |
| `FINDING-203` | A standard Spoke turns code-level liquidation guarantees into Aave-side configuration | High | Aave V4 CDP Spoke configuration, vault token, RiskModule drift check | `AMMN-RT-03`, `Q-362`, `ATTACK-021`, `ATTACK-155` | Resolved in spec — re-verification pending |
| `FINDING-204` | Pinned proxy migration admitted attacker implementations, unpatchable versions and two proxies per (wallet, Spoke) | High | PositionProxy, ProxyManager, AaveAdapter | `AMMN-RT-04`, `Q-359`, `ATTACK-156` | Resolved in spec — re-verification pending |
| `FINDING-205` | Per-Spoke ledgers multiplied the Hub-wide token, depositor and pool-share caps by the number of Spokes | High | Collateralization cap counters, RiskModule caps | `AMMN-RT-05`, `Q-359`, `Q-361`, `ATTACK-157` | Resolved in spec — re-verification pending |
| `FINDING-206` | Uniswap v4 removal hooks keep the removed tokens or block removal | High | Uniswap v4 integration readiness, LPVault unwind | `AMMN-RT-06`, `Q-363`, `ATTACK-158` | Resolved in spec — re-verification pending |
| `FINDING-207` | Read-only reentrancy and in-transaction pool-state manipulation in v2, Curve and Balancer fair-reserve pricing | High | Pricing readiness for Uniswap v2, Curve and Balancer | `AMMN-RT-07`, `Q-363`, `ATTACK-093`, `ATTACK-159` | Resolved in spec — re-verification pending |
| `FINDING-208` | TWAP buffer sized for 12-second blocks lets a dust-swap griefer keep a Base market Drifting | Medium | LPOracle TWAP consistency check | `AMMN-RT-08`, `Q-365`, `ATTACK-041`, `ATTACK-160` | Resolved in spec — re-verification pending |
| `FINDING-209` | Concentrated ranges unwind one-sided; route stress on two half legs understated slippage | High | Settlement routes, listing stress | `AMMN-RT-09`, `Q-363`, `ATTACK-161` | Resolved in spec — re-verification pending |
| `FINDING-210` | A per-chain ProxyManager serving several Adapters allowed cross-Hub proxy squatting | Medium | ProxyManager, AaveAdapter | `AMMN-RT-10`, `Q-359`, `ATTACK-162` | Resolved in spec — re-verification pending |
| `FINDING-211` | Cross-Hub credit lines had no registry summing every Spoke that draws a funding Hub's asset | High | MarketRegistry credit lines, First-Loss Reserves | `AMMN-RT-11`, `Q-360`, `ATTACK-163` | Resolved in spec — re-verification pending |
| `FINDING-212` | A vault-token Hub asset attached to a second Spoke drains or strands vault-token liquidity | Medium | Vault-token Hub asset, drift check | `AMMN-RT-12`, `Q-359`, `Q-362`, `ATTACK-164` | Resolved in spec — re-verification pending |
| `FINDING-213` | A shared SettlementBudget window let one Spoke's liquidations starve another's | Medium | SettlementBudget (removed, `Q-397`) | `AMMN-RT-13`, `Q-362`, `ATTACK-165`, `Q-397` | Resolved in spec — re-verification pending |
| `FINDING-214` | Tokenized stocks bring market-hours feeds, corporate actions and holder allowlists | Medium | Volatile LP Hub listing, feeds | `AMMN-RT-14`, `Q-363`, `Q-365`, `REQ-READY-001`, `ATTACK-058`, `ATTACK-059`, `ATTACK-166` | Resolved in spec — re-verification pending |
| `FINDING-215` | Copied configuration paired the wrong NFPM, factory or pool implementation | Low | MarketRegistry listing, Uniswap v3 and Slipstream integrations | `AMMN-RT-15`, `Q-359`, `ATTACK-167` | Resolved in spec — re-verification pending |
| `FINDING-216` | Migration could dodge an in-flight liquidation | High | PositionProxy migration | `AMMN-RT-16`, `Q-359`, `ATTACK-168` | Resolved in spec — re-verification pending |
| `FINDING-217` | The Lock could not admit per-Spoke vaults and ledgers | Critical | Lock | `AMMN-FLOW-01`, `Q-362`, `ATTACK-169` | Resolved in spec — re-verification pending |
| `FINDING-218` | Liquidation and deleverage on Base assumed a GHO FlashMinter, GSM routes and a $1 GHO | Critical | LPVaultSwap flash and settlement | `AMMN-FLOW-02`, `Q-362`, `Q-365`, `ATTACK-170` | Resolved in spec — re-verification pending |
| `FINDING-219` | No L2 sequencer gate, and Base feed heartbeats failed the listing rule | High | LPOracle, DebtOracle, listing | `AMMN-FLOW-03`, `Q-362`, `Q-364`, `ATTACK-171` | Resolved in spec — re-verification pending |
| `FINDING-220` | Pinned proxies had no migration flow, and the spec still used a beacon | High | PositionProxy, ProxyManager | `AMMN-FLOW-04`, `Q-359`, `ATTACK-172` | Resolved in spec — re-verification pending |
| `FINDING-221` | Cross-Hub debt reserves split risk ownership between Hubs | High | Debt reserves, First-Loss Reserves, pending settlement | `AMMN-FLOW-05`, `Q-360`, `ATTACK-173` | Resolved in spec — re-verification pending |
| `FINDING-222` | Credit lines across Hubs were enforced off-chain only | Medium | MarketRegistry credit lines | `AMMN-FLOW-06`, `Q-360`, `ATTACK-174` | Resolved in spec — re-verification pending |
| `FINDING-223` | One market per Spoke contradicted the multi-market spec | High | CDP Spoke topology, PositionProxy | `AMMN-FLOW-07`, `Q-359`, `ATTACK-175` | Resolved in spec — re-verification pending |
| `FINDING-224` | Full-range math was used for markets with a fixed bounded range | High | LPOracle, caps, collateral factor | `AMMN-FLOW-08`, `Q-359`, `ATTACK-176` | Resolved in spec — re-verification pending |
| `FINDING-225` | Pool spot moves turned liquidation into a revert in drained or thin pools | High | LPVaultSwap unwind and recovery floor | `AMMN-FLOW-09`, `Q-363`, `ATTACK-177`, `Q-401` | Resolved in spec — re-verification pending |
| `FINDING-226` | Slipstream differs from Uniswap v3 in the calls the flows rely on | High | Aerodrome Slipstream integration | `AMMN-FLOW-10`, `Q-365`, `ATTACK-178` | Resolved in spec — re-verification pending |
| `FINDING-227` | One vault token per pool blocked relisting, tiers and ranges | Medium | VaultTokenFactory, market identity | `AMMN-FLOW-11`, `Q-359`, `ATTACK-179` | Resolved in spec — re-verification pending |
| `FINDING-228` | Aave-side halts and pauses stop repay, debt-free withdraw and liquidation | High | Aave Hub and Spoke halts | `AMMN-FLOW-12`, `Q-365`, `ATTACK-180` | Accepted risk |
| `FINDING-229` | Liquidation access depended on an undecided Spoke variant | High | Aave V4 CDP Spoke, vault token | `AMMN-FLOW-13`, `Q-362`, `ATTACK-181` | Resolved in spec — re-verification pending |
| `FINDING-230` | Non-GHO debt and non-stable collateral were routed through GHO | High | LPVaultSwap settlement, swap routes | `AMMN-FLOW-14`, `Q-362`, `Q-363`, `ATTACK-182` | Resolved in spec — re-verification pending |
| `FINDING-231` | Lend Spoke lenders bore uncovered deficits first-come | Medium | Lend Spoke, First-Loss Reserves | `AMMN-FLOW-15`, `Q-360`, `Q-365`, `ATTACK-183` | Resolved in spec — re-verification pending |
| `FINDING-232` | A debt-free LP could fill every cap at no cost | Medium | Collateralization cap counters | `AMMN-FLOW-16`, `Q-361`, `ATTACK-184`, `Q-396` | Accepted risk |
| `FINDING-233` | Instance scope left components unassigned or singular | Medium | Deployment topology | `AMMN-FLOW-17`, `Q-359`, `ATTACK-185` | Resolved in spec — re-verification pending |
| `FINDING-234` | A per-chain ProxyManager with several Adapters allowed proxy squatting | Medium | ProxyManager | `AMMN-FLOW-18`, `Q-359`, `ATTACK-186` | Resolved in spec — re-verification pending |
| `FINDING-235` | Pause, freeze and Guardian were per Hub and per chain while shared code was not | Medium | Pause states, Guardian, address freeze | `AMMN-FLOW-19`, `Q-361`, `ATTACK-187` | Resolved in spec — re-verification pending |
| `FINDING-236` | An oracle switch could halt liquidation | Medium | AaveOracle source, drift check | `AMMN-FLOW-20`, `Q-362`, `ATTACK-188` | Resolved in spec — re-verification pending |
| `FINDING-237` | Listing rules excluded the launch and planned markets | Medium | Market listing | `AMMN-FLOW-21`, `Q-359`, `ATTACK-189` | Resolved in spec — re-verification pending |
| `FINDING-238` | Wind-down never ended, and immutable vaults had no exit | Medium | Market offboarding | `AMMN-FLOW-22`, `Q-363`, `ATTACK-190` | Resolved in spec — re-verification pending |
| `FINDING-239` | The proposal's "borrower surplus" did not exist in the waterfall | Low | LPVaultSwap waterfall | `AMMN-FLOW-23`, `Q-363`, `ATTACK-191` | Resolved in spec — re-verification pending |
| `FINDING-240` | Two-token and tokenId keys were built into shared code | Low | Collateralization records, pending settlement, indexing | `AMMN-FLOW-24`, `Q-359`, `ATTACK-192` | Resolved in spec — re-verification pending |
| `FINDING-241` | Keeper floors multiplied per Hub and chain | Low | LPVaultSwap keepers | `AMMN-FLOW-25`, `Q-359`, `ATTACK-193` | Resolved in spec — re-verification pending |
| `FINDING-242` | Repay with collateral was refused under Paused | Medium | LPVaultSwap repay with collateral | `AMMN-FLOW-26`, `Q-363`, `ATTACK-194` | Resolved in spec — re-verification pending |
| `FINDING-243` | Seizure walked an unbounded record list, so some accounts could not be liquidated in one transaction | High | Collateralization records, LPVaultSwap seizure | `AMMN-GAS-01`, `Q-362` | Resolved in spec — re-verification pending |
| `FINDING-244` | The $10 minimum pledge did not cover liquidation gas on Ethereum | High | RiskModule minimums | `AMMN-GAS-02`, `Q-362`, `Q-381` | Resolved in design |
| `FINDING-245` | Uniswap v4 hooks and position subscribers can block or gas-grief removal | High | Uniswap v4 integration readiness | `AMMN-GAS-03`, `Q-363`, `ATTACK-158` | Resolved in spec — re-verification pending |
| `FINDING-246` | Breaker reports could be starved of gas through the 63/64 rule | Medium | Circuit breakers | `AMMN-GAS-04`, `Q-367`, `ATTACK-042`, `Q-399` | Resolved in spec — re-verification pending |
| `FINDING-247` | The `pokeMinGas` floor was not derived from the 63/64 rule | Medium | LPOracle poke | `AMMN-GAS-05`, `Q-367`, `ATTACK-042` | Resolved in spec — re-verification pending |
| `FINDING-248` | The liquidation flow assumed GHO flash minting and GSMs that do not exist on Base | Medium | LPVaultSwap flash | `AMMN-GAS-06`, `Q-362`, `Q-365` | Resolved in spec — re-verification pending |
| `FINDING-249` | Crash throughput is capped by route depth and the per-transaction cap, not by the Lock | Medium | Liquidation liveness | `AMMN-GAS-07`, `Q-367` | Resolved in spec — re-verification pending |
| `FINDING-250` | Pausable or blocklisting tokens on shared contracts and route intermediates halted other markets | Medium | Swap routes, LPVaultSwap | `AMMN-GAS-08`, `Q-367`, `Q-401` | Resolved in spec — re-verification pending |
| `FINDING-251` | The Lock's immutable allowlist could not name per-Spoke LPVaults and ledgers | Critical | Lock | `AMMN-GAS-09`, `Q-362` | Resolved in spec — re-verification pending |
| `FINDING-252` | SettlementBudget read 75 cold buckets per draw, and markets shared one window | Low | SettlementBudget (removed, `Q-397`) | `AMMN-GAS-10`, `Q-362`, `Q-397` | Resolved in spec — re-verification pending |
| `FINDING-253` | Small repay front-runs pushed a keeper's partial liquidation into Aave's dust rule | Low | Keeper sizing | `AMMN-GAS-11`, `Q-367`, `ATTACK-057` | Resolved in spec — re-verification pending |
| `FINDING-254` | `activeKeeperCount` had no keeper bound and was read on the borrow path | Low | LPVaultSwap keepers | `AMMN-GAS-12`, `Q-367` | Resolved in spec — re-verification pending |
| `FINDING-255` | n-token unwinds scale settlement legs and oracle reads with n | Low | LPVaultSwap unwind | `AMMN-GAS-13`, `Q-367` | Resolved in spec — re-verification pending |
| `FINDING-256` | Slipstream's unstaked-only rule had to be enforced | Low | Aerodrome Slipstream integration | `AMMN-GAS-14`, `Q-365`, `ATTACK-178` | Resolved in spec — re-verification pending |
| `FINDING-257` | Hot structs could be packed into fewer storage slots | Informational | Collateralization, MarketRegistry, ParameterStore | `AMMN-GAS-15`, `Q-367` | Resolved in spec — re-verification pending |
| `FINDING-258` | Per-market values could be immutables and cached reads | Informational | VaultToken, LPOracle, LPVaultSwap | `AMMN-GAS-16`, `Q-367` | Resolved in spec — re-verification pending |
| `FINDING-259` | Stablecoin Chainlink heartbeats are 23–24 hours, not at most 1 hour | Critical | LPOracle, DebtOracle freshness | `AMMN-INT-01`, `Q-364` | Resolved in spec — re-verification pending |
| `FINDING-260` | The GSM addresses in EXT-013 belong to seized GSMs | High | External dependencies, conversion routes | `AMMN-INT-02`, `Q-365`, `ATTACK-170` | Resolved in spec — re-verification pending |
| `FINDING-261` | The live USDC GSM has no buy-side liquidity | Medium | Debt buy route | `AMMN-INT-03`, `Q-362`, `Q-365` | Resolved in spec — re-verification pending |
| `FINDING-262` | The liquidation-manager Spoke in Aave's repository is not the one Avana's interface called | High | Aave V4 CDP Spoke | `AMMN-INT-04`, `Q-362`, `ATTACK-181` | Resolved in spec — re-verification pending |
| `FINDING-263` | Base has no GHO FlashMinter or GSM | Critical | LPVaultSwap flash | `AMMN-INT-05`, `Q-362`, `Q-365`, `ATTACK-170` | Resolved in spec — re-verification pending |
| `FINDING-264` | No L2 sequencer uptime check | High | LPOracle, DebtOracle | `AMMN-INT-06`, `Q-362`, `Q-365`, `ATTACK-171` | Resolved in spec — re-verification pending |
| `FINDING-265` | A transfer restriction alone does not make LPVaultSwap the only settler | High | Vault token, Aave V4 CDP Spoke | `AMMN-INT-07`, `Q-362`, `ATTACK-155` | Resolved in spec — re-verification pending |
| `FINDING-266` | EXT-001 understated the scope of a Hub halt | Informational | External dependencies | `AMMN-INT-08`, `Q-365`, `ATTACK-180` | Resolved in spec — re-verification pending |
| `FINDING-267` | A vault and ledger per Spoke conflicted with the immutable Lock | Medium | Lock, LPVault, Collateralization | `AMMN-ARCH-01`, `Q-362` | Resolved in spec — re-verification pending |
| `FINDING-268` | One market per Spoke multiplied DAO work without isolating shared code | Medium | CDP Spoke topology | `AMMN-ARCH-02`, `Q-359` | Resolved in spec — re-verification pending |
| `FINDING-269` | Per-Hub copies of shared contracts added work without reducing blast radius | Low | AaveAdapter, LPVaultSwap scope | `AMMN-ARCH-03`, `Q-359` | Resolved in spec — re-verification pending |
| `FINDING-270` | A single Aave flash source makes liquidation depend on one external reserve | High | IFlashSource | `AMMN-ARCH-04`, `Q-362` | Resolved in spec — re-verification pending |
| `FINDING-271` | A Base launch had no sequencer handling and depended on unverified Base facts | Medium | Chains | `AMMN-ARCH-05`, `Q-365` | Resolved in spec — re-verification pending |
| `FINDING-272` | Interfaces that would be immutable were still shaped for Uniswap v3 | Medium | AMM integration interface, VaultTokenFactory, ledger | `AMMN-ARCH-06`, `Q-359` | Resolved in spec — re-verification pending |
| `FINDING-273` | The decided Borrow Spoke did not exist; the safest existing option is the standard Spoke with three required settings | High | Aave V4 CDP Spoke | `AMMN-ARCH-07`, `Q-362`, `ATTACK-181` | Resolved in spec — re-verification pending |
| `FINDING-274` | The Lens was in the audited immutable core but carries no security role | Low | Lens | `AMMN-ARCH-08`, `Q-359` | Resolved in spec — re-verification pending |
| `FINDING-275` | The proposal and the spec disagreed on the PositionProxy upgrade model | Informational | PositionProxy | `AMMN-ARCH-09`, `Q-359` | Resolved in spec — re-verification pending |
| `FINDING-276` | Drift checks duplicated rules the liquidation-manager Spoke enforces in code | Informational | RiskModule drift check | `AMMN-ARCH-10`, `Q-362` | Resolved in spec — re-verification pending |
| `FINDING-277` | Cross-Hub draw caps were checked by the wrong Hub, so a funding Hub's line and cross-Hub cap did not bind | High | MarketRegistry credit lines | `AMMN-SM-01`, `Q-360` | Resolved in spec — re-verification pending |
| `FINDING-278` | "drawn ≤ drawCap" is a gate on new draws, not a state invariant | Low | Hub draw caps | `AMMN-SM-02`, `Q-360` | Resolved in spec — re-verification pending |
| `FINDING-279` | Pinned proxies could be stranded: an Adapter upgrade stops serving old versions, and migration is a gated re-borrow | Critical | PositionProxy, AaveAdapter | `AMMN-SM-03`, `Q-359` | Resolved in spec — re-verification pending |
| `FINDING-280` | On a standard Spoke, `receiveShares` liquidation bypassed LPVaultSwap and the ledger | High | Aave V4 CDP Spoke, Collateralization | `AMMN-SM-04`, `Q-362` | Resolved in spec — re-verification pending |
| `FINDING-281` | One market per Spoke did not isolate token price risk, and per-Hub token caps missed cross-Hub exposure | Medium | Isolation invariant, token caps | `AMMN-SM-05`, `Q-361` | Resolved in spec — re-verification pending |
| `FINDING-282` | A funding Hub's pause did not stop other Hubs' Spokes drawing its liquidity | Medium | Pause scope | `AMMN-SM-06`, `Q-361` | Resolved in spec — re-verification pending |
| `FINDING-283` | A 24-hour failure of both USDC routes with no standby switch liquidated accounts healthy at market prices | Low | LPOracle stress valuation, standby routes | `Q-247`, `Q-248`, `SIM-02H`, `SIM-02I`, `Q-368` | Accepted risk |
| `FINDING-284` | With no approved keeper for 48 hours, the permissionless fallback left tail bad debt | Medium | LPVaultSwap permissionless liquidation, keepers | `Q-082`, `Q-213`, `SIM-04C`, `Q-368` | Accepted risk |
| `FINDING-285` | A hostile LPVaultSwap could seize an Expired market in full for one unit of debt | Medium | LPVaultSwap, stress valuation | `Q-128`, `Q-227`, `Q-247`, `QNT-T24`, `INV-018`, `Q-368` | Accepted risk |
| `FINDING-286` | The stray-position return had no Lock member in its call tree, against the Lock entry rule | Informational | Lock, LPVault | `FV-CUS-F-10`, `REQ-LOCK-028`, `REQ-VAULT-165`, `Q-362` | Resolved (`FV-CUS-42-surface` Verified, run `FV-CUS-R6`) |
| `FINDING-287` | Short-delay lists named a tolerance and a setter that do not exist and marked three parameters Short with no tighten setter | Informational | Timelock short-delay list, ParameterStore, market lifecycle | `FV-CTL-F-25`, `MKT-027`, `REQ-ACCESS-141`, `REQ-ACCESS-155`, `REQ-ROLE-027`, `Q-362` | Resolved |
| `FINDING-288` | Four tighten-only setters were missing from the immutable short-delay set | Low | Timelock `SHORT_ELIGIBLE`, ParameterStore, SettlementBudget (removed, `Q-397`) | `FV-CTL-F-26`, `REQ-ACCESS-141`, `REQ-ACCESS-155`, `REQ-PSTORE-024`, `Q-362`, `Q-397` | Resolved |
| `FINDING-289` | The Lens and the ParameterStore bounded the flash premium with a rounded-up ceiling that LPVaultSwap refuses | Low | Lens, ParameterStore, LPVaultSwap | `FV-CTL-F-27`, `REQ-LENS-029`, `REQ-PSTORE-024`, `REQ-FLASH-002`, `REQ-SWAP-013`, `SPEC-LIQ-015`, `Q-317` | Resolved |
| `FINDING-290` | The roles page kept the two-argument proxy salt, four Lock members and an old LPVault caller list | Informational | Roles page, ProxyManager, Lock, LPVault | `FV-CTL-F-28`, `REQ-ROLE-020`, `REQ-ROLE-021`, `REQ-ROLE-038`, `REQ-PROXY-051`, `REQ-ACCESS-147`, `REQ-ADAPTER-050`, `REQ-LOCK-004`, `Q-362` | Resolved in spec — re-verification pending |
| `FINDING-291` | The exclusivity rule named a Hub-to-Adapter transfer that the vault token refuses | Informational | RiskModule exclusivity rule, vault token, PositionProxy | `FV-CTL-F-29`, `REQ-ADAPTER-036`, `REQ-VTOKEN-006`, `REQ-VTOKEN-041`, `REQ-PROXY-008`, `Q-362` | Resolved in spec — re-verification pending |
| `FINDING-292` | A released token worth less than one raw unit of the debt asset made every liquidation of the account revert with `NoRouteAvailable` | Medium | LPVaultSwap per-leg minimum output, routed settlement | `HYP-36`, `SPEC-LIQ-018`, `REQ-SWAP-022`, `REQ-SWAP-100`, `REQ-SWAP-102`, `LIQ-075`, `Q-250`, `Q-251` | Resolved in spec — re-verification pending |
| `FINDING-293` | A flash source whose own address is a Spoke could still borrow from a Hub of the chain | Low | LPVaultSwap flash path, `IFlashSource` implementation | `ATTACK-195`, `INV-095`, `REQ-FLASH-005`, `REQ-FLASH-006`, Q-386 | Resolved in spec |
| `FINDING-294` | A blocklisted fee recipient made every routed liquidation in that asset revert | Low | LPVaultSwap payouts, PayoutEscrow | `ATTACK-196`, `INV-036`, `REQ-SWAP-028`, `REQ-SWAP-064`, `REQ-SWAP-076`, Q-389 | Resolved in spec |
| `FINDING-295` | A transfer fee on a debt asset made every flash-funded liquidation of that reserve revert | Medium | LPVaultSwap flash path and payouts, `IFlashSource` implementation, debt breaker | `ATTACK-197`, `INV-095`, `REQ-FLASH-003`, `REQ-SWAP-026`, `REQ-SWAP-108`, Q-390 | Resolved in spec |

## Findings

### A. Formal-model counterexamples (Z3, SymPy)

#### FINDING-001: Odd decimal sum misprices the vault token

| Field | Value |
|---|---|
| Source | Formal verification (Z3); Formal verification (SymPy) |
| Severity | Medium |
| Component | LPOracle, vault token, listing |
| Reference | `MATH-UO-01` (01b), `SYM-30d`, `Q-066` |
| Description | `d = (d0 + d1) / 2` has no integer solution when `d0 + d1` is odd. Flooring `d` while keeping the price `2·√(a0·a1)` overvalues one whole vault token by a factor of √10 (3.16×). |
| Impact | Collateral overvalued 3.16× in any market listed with an odd decimal sum; no launch pair is affected. |
| Evidence | `z3/units-oracle/uo01_units_caps.py`, `sympy/sym04_units_decimals_oracle.py` |
| Resolution | `Q-191`: listing requires `d0 + d1` even. |
| Status | Resolved in design |
| Verification | `TEST-139` (listing guard), `TEST-023` |

#### FINDING-002: Deep depeg takes a whole vault token below the $1 target

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Informational |
| Component | Vault token decimals |
| Reference | `MATH-UO-02` (02c), `Q-066` |
| Description | With one leg at a deep discount (for example $0.0625) a whole vault token is worth less than the $1–$10 design target. |
| Impact | None: price precision stays within 1e-6 per step while a whole token is worth at least $0.01 (`MATH-UO-02d`). |
| Evidence | `z3/units-oracle/uo01_units_caps.py` |
| Resolution | Accepted risk. Owner: Avana Labs (market listing). Decimals are fixed at market creation (`Q-066`) and chosen so one whole token is worth about $1–10 at listing. Bound: price precision stays within 1e-6 per step while a whole token is worth at least $0.01 (`MATH-UO-02d`). |
| Status | Accepted risk |
| Verification | `TEST-037` |

#### FINDING-003: Non-standard tick spacing allows liquidity that overflows Aave value math

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | Listing, LPOracle |
| Reference | `MATH-UO-04` (04b), `MATH-UO-05` (05c), `Q-191` |
| Description | From tick spacing 6932 upward, full-range liquidity can reach 2^120; with an unlimited Hub cap and a large price the `toValue` chain overflows and HF computation reverts. |
| Impact | A market with a non-standard spacing could halt every account holding its reserve. |
| Evidence | `z3/units-oracle/uo01_units_caps.py` |
| Resolution | `Q-191`: listing requires a standard tick spacing; Hub caps are finite (`Q-175`). |
| Status | Resolved in design |
| Verification | `TEST-139`, `TEST-071`, `PROP-044` |

#### FINDING-004: Sqrt price from feeds reverts before the clamp

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Medium |
| Component | LPOracle |
| Reference | `MATH-UO-10` (10b), `MATH-UO-11`, `Q-056`, `Q-191` |
| Description | `mulDiv(num, 2^192, den)` reverts whenever the raw price ratio is at least 2^64, which is a valid Uniswap price; the revert happens before the clamp and cannot be caught. |
| Impact | `latestAnswer()` would revert and halt every account holding the reserve; launch pairs are 16 orders of magnitude away. |
| Evidence | `z3/units-oracle/uo03_sqrtprice_from_feeds.py` |
| Resolution | `Q-191`: listing requires a raw price below 2^64 under a 100× shock and the code clamps; the pre-check of `MATH-UO-11` makes the path revert-free. |
| Status | Resolved in design |
| Verification | `TEST-038`, `TEST-079`, `PROP-025` |

#### FINDING-005: TWAP orientation taken from the listing name

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Medium |
| Component | LPOracle |
| Reference | `MATH-UO-13`, `SYM-33`, `Q-119` |
| Description | If the reference tick is built from the listing name ("USDC/GHO") instead of the pool's `token0()`, the reference tick is +276324 against a pool tick of −276325. |
| Impact | The market sits in Drifting permanently: no new accounts, borrowing or withdraw-with-debt. |
| Evidence | `z3/units-oracle/uo03_sqrtprice_from_feeds.py` |
| Resolution | Orientation and decimals are read from the pool at listing: the reference tick uses the pool's own `token0()` and `token1()` and their `decimals()`, never the listing name, so the reference tick and the pool tick share one orientation (`Q-119`). |
| Status | Resolved in design |
| Verification | `TEST-041`, `TEST-138` |

#### FINDING-006: High-decimal feed normalises to zero

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | High |
| Component | LPOracle |
| Reference | `MATH-UO-15` (15b), `Q-056`, `Q-191` |
| Description | A feed with more than 8 decimals and a small positive answer normalises by floor to 0; `price8` becomes 0 and AaveOracle reverts with `InvalidPrice`. The raw-answer `> 0` check runs too early to catch it. |
| Impact | Every account holding the reserve halts (no repay, withdrawal or liquidation through Aave's HF path). |
| Evidence | `z3/units-oracle/uo04_lporacle_price.py` |
| Resolution | `Q-191`: listing requires normalised `minAnswer ≥ 1`; a normalised 0 is treated as a feed failure. |
| Status | Resolved in design |
| Verification | `TEST-038`, `TEST-117`, `TEST-139`, `PROP-027` |

#### FINDING-007: Perfect-square answers overvalue the actual holdings

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | LPOracle |
| Reference | `MATH-UO-16` (16a), `MATH-UO-17`, `Q-191` |
| Description | When `4·a0·a1` is a perfect square, `isqrt` is exact and the price exceeds the value of the real holdings by the finite-tick shortfall. |
| Impact | About $2.7e-5 per $1B of collateral; breaks only the strict round-against-the-borrower rule. |
| Evidence | `z3/units-oracle/uo04_lporacle_price.py` |
| Resolution | `Q-191`: `price8 = isqrt(4·a0·a1) − 1`. |
| Status | Resolved in design |
| Verification | `TEST-036`, `TEST-037`, `PROP-023` |

#### FINDING-008: Stable ceiling applied before the TWAP and agreement checks

| Field | Value |
|---|---|
| Source | Formal verification (Z3); Developer (Hypothesis model) |
| Severity | Medium |
| Component | LPOracle |
| Reference | `MATH-UO-20`, `HYP-51`, `Q-057`, `Q-177`, `Q-200` |
| Description | If the $1 cap on GHO is applied to the price fed to the TWAP guard or to one side of the route-agreement check, GHO trading above $1 by more than the TWAP tolerance makes every GHO market Drifting although feeds and pool agree. |
| Impact | New accounts, borrowing and withdraw-with-debt stop in all GHO markets for as long as GHO stays above peg. |
| Evidence | `z3/units-oracle/uo05_stable_ceiling_band.py`, `hypothesis/test_hyp_scenarios.py` (`test_hyp51_gho_above_peg_keeps_gho_markets_live`) |
| Resolution | `Q-177`: the ceiling applies only in the valuation; freshness, agreement and TWAP checks use uncapped quotes. `Q-200` confirms it for GHO: the TWAP guard and agreement checks use the uncapped GHO/USD price, so GHO markets stay Live above peg. |
| Status | Resolved in design |
| Verification | `TEST-039`, `PROP-024` |

#### FINDING-009: Uncapped stable premium raises collateral value

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | LPOracle |
| Reference | `MATH-UO-21`, `Q-057`, `Q-177` |
| Description | Only GHO was capped; a reported premium `x` on another stable leg raises the vault-token value by `√(1+x)`. |
| Impact | Borrowing capacity rises with a temporary stablecoin premium (+0.995 % for a 2 % premium). |
| Evidence | `z3/units-oracle/uo05_stable_ceiling_band.py` |
| Resolution | `Q-177`: every approved USD-pegged stable leg is valued at `min(validated price, stableCeilingUsd)`. |
| Status | Resolved in design |
| Verification | `TEST-036`, `PROP-024` |

#### FINDING-010: Common-mode feed errors pass every price check

| Field | Value |
|---|---|
| Source | Formal verification (Z3); Economic simulation |
| Severity | High |
| Component | LPOracle, listing |
| Reference | `MATH-UO-22`, `MATH-UO-23` (23c), `SIM-03A`, `Q-079`, `Q-112`, `Q-130`, `Q-176`, `Q-195` |
| Description | An error that moves both tokens' USD prices in the same direction (a provider-wide error, or backups sharing an intermediate feed such as ETH/USD) passes the route-agreement check and leaves the pool ratio unchanged, so the TWAP guard cannot see it; a real correlated drop is equally invisible. |
| Impact | Collateral overvalued by the common factor; once it exceeds 1/CF each borrowed GHO is under-backed and becomes bad debt. |
| Evidence | `z3/units-oracle/uo06_agreement_twap.py`, `simulation/sim03_correlated_drop.py` |
| Resolution | Accepted risk. Owner: Avana Labs and the Aave V4 risk service providers (listing and caps, `Q-197`). `Q-176`: the two tokens' backup routes share no intermediate feed, and an LP USD level outside [`usdBandLow`, `usdBandHigh`] = [0.90, 1.02] moves the market to Drifting; `Q-195`: a band breach blocks borrowing and withdraw-with-debt while liquidation continues when both routes are fresh and agree. Bound: a common-mode error smaller than the band (at most 10 % below or 2 % above $1 per unit) on exposure limited by the market, token and depositor caps; the shared-provider dependency of Chainlink-only pricing (`Q-079`) remains. |
| Status | Accepted risk |
| Verification | `TEST-043`, `TEST-117`, `TEST-139` |

#### FINDING-011: Floor division in the agreement tolerance admits one extra basis point

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | LPOracle |
| Reference | `MATH-UO-24` (24a), `Q-184` |
| Description | `floor(\|p − b\| × 1e4 / b) ≤ T` passes deviations up to T + 1 bps and depends on which answer is the denominator. |
| Impact | The tolerance is looser than configured and asymmetric. |
| Evidence | `z3/units-oracle/uo06_agreement_twap.py` |
| Resolution | `Q-184`: `\|p − b\| × 1e4 ≤ T × min(p, b)`, cross-multiplied. |
| Status | Resolved in design |
| Verification | `TEST-039`, `PROP-026` |

#### FINDING-012: Pro-rata cap counter readings allow cap bypass or creep

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | High |
| Component | Collateralization cap counters |
| Reference | `MATH-UO-25`, `MATH-UO-26`, `Q-109`, `Q-174` |
| Description | Dividing the original pledge value by the current units on each exit decrements a record's value many times over (2.93× over ten partial exits); keeping the original basis with floor division leaves residues in the counter. |
| Impact | Repeated partial liquidations of one large record erase other records from the counter, so new pledges exceed the caps; the other reading creeps upward. |
| Evidence | `z3/units-oracle/uo07_cap_counters.py` |
| Resolution | `Q-174`: fixed-basis remaining charge `ceil(originalUsdCharge × remainingUnits ÷ originalUnits)`, released as the difference, updated with the aggregate in the same transaction. |
| Status | Resolved in design |
| Verification | `TEST-014`, `TEST-097`, `PROP-028`, `PROP-029` |

#### FINDING-013: Pledge-time cap charge floors to zero for dust

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | RiskModule pledge charge, Collateralization cap counters |
| Reference | `MATH-UO-27` (27a), `Q-174`, `Q-175`, `Q-230` |
| Description | Rounding the pledge-time USD charge down gives 0 for a one-unit pledge at 18 decimals. |
| Impact | Dust pledges consume no cap; caps are no longer strictly conservative. |
| Evidence | `z3/units-oracle/uo07_cap_counters.py` |
| Resolution | Charges round up, as `Q-174` does for the remaining charge, and are booked at no less than `stressFloorUsd` per whole token (`Q-175`); `RiskModule.checkPledge` computes the charge and Collateralization books it in the same call (`Q-240`). Separately, every pledge must be worth at least `minPledgeUsd` ($10, `10e8`, valued at the served LPOracle price rounded down) or it reverts `BelowMinPledge` (`Q-230`), so a one-unit pledge no longer reaches the counters at all; the round-up rule still governs every charge above that minimum. |
| Status | Resolved in design |
| Verification | `TEST-013`, `TEST-070`, `TEST-196`, `PROP-062` |

#### FINDING-014: Hub addCap sized at today's price removes the top-up slice in stress

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | High |
| Component | Hub cap sizing, RiskModule |
| Reference | `MATH-UO-28`, `Q-150`, `Q-175` |
| Description | Avana caps count USD at pledge-time prices while the Hub caps units; pledges made after a small price fall fill the Hub cap and leave no room for the reserved top-up slice. |
| Impact | Rescue top-ups fail exactly when prices fall, which is when they are needed. |
| Evidence | `z3/units-oracle/uo07_cap_counters.py` |
| Resolution | `Q-175`: `addCap ≥ ceil((regular budget + rescue budget) / stressFloorUsd)` with every pledge booked at ≥ `stressFloorUsd`. |
| Status | Resolved in design |
| Verification | `TEST-125`, `TEST-135`, `PROP-030` |

#### FINDING-015: Burn, debit and removal equalities are load-bearing

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Informational |
| Component | AaveAdapter, Collateralization, vault token |
| Reference | `MATH-UO-31`, `Q-069`, `Q-160`, `Q-165`, `Q-224`, `Q-240` |
| Description | Expected counterexample: if burn ≠ debit the supply invariant breaks; if liquidity removed > debit, live ≥ credited breaks. |
| Impact | Shows which equalities the design must enforce; no flaw in the adopted design. |
| Evidence | `z3/units-oracle/uo08_backing_invariant.py` |
| Resolution | `Q-224` and `Q-240` enforce each equality in the call that changes the record. Pledge: Collateralization returns `credited`, the AaveAdapter mints exactly that to the proxy and requires `totalSupply ≤ totalCredited + pending.units` with the backing gap unchanged by the call before the call ends (`BackingMismatch`; one-sided since `Q-257`, `FINDING-104`). Withdrawal: the proxy withdraws to itself, the Adapter burns exactly the released units from it and Collateralization debits the record and the LPVault returns the NFT to its depositor. Seizure: Collateralization snapshots the proxy's shares and the token supply at `beginSeizure`; after the Adapter burns the seized units from LPVaultSwap (`burnSeized`), `settleSeizure` requires share drop == units == supply drop (`DebitMismatch`, `SupplyDropMismatch`), debits exactly those units and has the LPVault remove exactly that liquidity. Pending settlement requires `totalSupply + units ≤ totalCredited + pending.units` before it debits. All of it runs under the Lock. |
| Status | Resolved in design |
| Verification | `TEST-056`, `TEST-083`, `TEST-186`, `TEST-208`, `TEST-209`, `PROP-001`, `PROP-007`, `PROP-054` |

#### FINDING-016: Exact debit check fails when Hub shares differ from assets

| Field | Value |
|---|---|
| Source | Formal verification (Z3); Design review (decision check) |
| Severity | Medium |
| Component | Collateralization liquidation debit |
| Reference | `MATH-UO-32`, `MATH-ST-38`, `MATH-ST-39`, `MATH-ST-40`, `MATH-ST-45`, `Q-103`, `Q-125`, `Q-160`, `Q-189`, `Q-206` |
| Description | With Hub shares ≠ assets the drop in the proxy's supplied assets can exceed the tokens received by one unit, and seizing all of a proxy's shares can yield more units than its credited backing; a snapshot passed in by LPVaultSwap could also be faked. |
| Impact | Every liquidation would revert in the shares ≠ assets state, contradicting the rule that liquidation continues; or the debit underflows. |
| Evidence | `z3/units-oracle/uo08_backing_invariant.py`, `z3/settlement/st07_burn_debit.py`, `z3/settlement/st08_seizure_order.py` |
| Resolution | `Q-160`: Collateralization takes the share snapshot itself at `beginSeizure` under the lock and compares share drops (`Q-240`); `Q-189`: compare with Aave's shares-to-liquidate and require shares == assets for liquidation, which the Hub drift checks (`Q-181`) keep true; if it ever breaks, liquidation and withdraw-with-debt stop with an alarm (`Q-206`). |
| Status | Resolved in design |
| Verification | `TEST-056`, `TEST-114`, `PROP-004`, `PROP-011`, `PROP-013`, `PROP-040` |

#### FINDING-017: A faulty RiskModule could approve withdraw-with-debt down to HF 1

| Field | Value |
|---|---|
| Source | Formal verification (Z3); Design review (decision check) |
| Severity | Medium |
| Component | RiskModule, AaveAdapter |
| Reference | `MATH-AR-06`, `Q-126`, `Q-161`, `Q-229`, `Q-398` |
| Description | The health-factor floor of `Q-126` covered borrows only, so a check module that skipped it could approve a withdrawal that leaves debt down to Aave's own HF 1. |
| Impact | Same extraction as an unsafe borrow when the served price overstates collateral. |
| Evidence | `z3/aave-risk/ar02_opening_gate.py` |
| Resolution | `Q-161` and `Q-229`: the AaveAdapter calls `RiskModule.postHealthCheck` after every borrow, every withdraw-with-debt and every removal with debt, so a withdrawal is never checked more loosely than a borrow. `Q-398` removed `minOpeningHealthFactor` and `PROXY_HEALTH_FACTOR_FLOOR` as on-chain requirements: the check reverts unless the account's health factor is at least `max(1, hardHealthFloor, minHealthFactor)` (`HealthFactorTooLow`), where `hardHealthFloor` is an optional per-market floor, off (0) by default and set only if stress tests justify it, and `minHealthFactor` the caller's own bound. Aave's HF 1 is therefore the protocol limit for both borrows and withdrawals; the Lens recommends borrowing to HF 1.10. A faulty or hostile RiskModule upgrade could skip the check; that residual is bounded by Aave's own HF ≥ 1 check on every withdrawal and borrow, the drawCap per debt reserve and the 5-day timelock with cancellers on every RiskModule upgrade (`Q-228`), and is tracked in `FINDING-043`. |
| Status | Resolved in design |
| Verification | `TEST-019`, `TEST-077`, `TEST-132`, `PROP-031` |

#### FINDING-018: Interest moves accounts across the opening gate

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Informational |
| Component | RiskModule, Borrow Spoke |
| Reference | `MATH-AR-08` (08b), `Q-018`, `Q-234`, `Q-398` |
| Description | Expected counterexample: an account opened at a health-factor gate (then `minOpeningHealthFactor`; since `Q-398` a set `hardHealthFloor` or the caller's `minHealthFactor`) falls below it after interest accrues at unchanged prices. With several debt reserves, a rise in a debt asset's price lowers the health factor the same way (`Q-234`). |
| Impact | None; the gate is a point-in-time postcondition, not an invariant. |
| Evidence | `z3/aave-risk/ar02_opening_gate.py` |
| Resolution | Accepted risk (expected behaviour). Owner: Avana Labs (borrower disclosures). Since `Q-398` no gate applies by default: the check is `max(1, hardHealthFloor, minHealthFactor)` with `hardHealthFloor` off, and the Lens recommends HF 1.10. Any such gate is a postcondition of the borrow and withdraw-with-debt call only (`RiskModule.postHealthCheck`), not an invariant, so the invariant suite does not assert it after interest accrues or a debt-asset price moves (`Q-018`). Bound: at unchanged prices the HF falls only by the accrued interest on each debt reserve; a debt-asset price rise is bounded by the listing's stress validation and cap sizing (`FINDING-102`); below HF 1 the account is liquidated as any other. |
| Status | Accepted risk |
| Verification | `TEST-028`, `TEST-095`, `TEST-202` |

#### FINDING-019: Minimum liquidation bonus is set by the bonus factor, not the maximum bonus

| Field | Value |
|---|---|
| Source | Formal verification (Z3); Formal verification (SymPy) |
| Severity | Medium |
| Component | Borrow Spoke configuration, LPVaultSwap |
| Reference | `MATH-AR-09` (09c), `SYM-15e`, `Q-098`, `Q-179` |
| Description | Just below HF 1 Aave pays `minLB = 1 + (maxLB − 1) × liquidationBonusFactor`, which can be under 1 % even with a 5 % maximum bonus. |
| Impact | Keepers earn too little to cover gas, swap cost and Avana's share at the moment accounts become liquidatable. |
| Evidence | `z3/aave-risk/ar03_liquidation.py`, `sympy/sym02_liquidation_sizing.py` |
| Resolution | Launch condition. Condition: the bonus just below HF 1, `(maxLB − 1) × bonusFactor`, is at least `minLiquidationBonus` (2 %) on every vault-token reserve. Who: the Aave V4 risk service providers set the curve in each listing payload; Avana Labs runs the fork check that asserts it before launch (`Q-179`, `Q-196`). |
| Status | Launch condition |
| Verification | `TEST-113`, `TEST-135` |

#### FINDING-020: Below HF = bonus × CF a liquidation lowers HF and takes the whole reserve

| Field | Value |
|---|---|
| Source | Formal verification (Z3); Formal verification (SymPy) |
| Severity | Informational |
| Component | LPVaultSwap, keeper |
| Reference | `MATH-AR-11` (11b), `SYM-13a`…`SYM-13c`, `Q-060`, `Q-166`, `Q-194`, `Q-234`, `Q-235` |
| Description | When HF < bonus × CF the account is short of covering debt plus bonus; a partial liquidation lowers HF, and Aave seizes all of that collateral reserve instead of a partial amount. |
| Impact | The final deficit is fixed; a full seizure must still fit in gas and the deficit must be reported. |
| Evidence | `z3/aave-risk/ar03_liquidation.py`, `sympy/sym02_liquidation_sizing.py` |
| Resolution | Keepers continue sequential liquidations until a deficit is recorded (`Q-166`); each call liquidates one collateral reserve against one debt reserve, as Aave's `liquidationCall` does (`Q-235`). `Q-194` keeps records sorted so a seizure touches only the records it debits and keepers size each call to fit gas. Once no collateral is left, Aave reports the deficit of every debt reserve in its own asset (`Q-234`), and the First-Loss Reserve of that asset covers it (`Q-236`). |
| Status | Resolved in design |
| Verification | `TEST-122`, `TEST-123`, `TEST-142`, `TEST-199` |

#### FINDING-021: Repay floor blocks partial repay and strands sub-dust debt

| Field | Value |
|---|---|
| Source | Formal verification (Z3); Design review (decision check) |
| Severity | High |
| Component | AaveAdapter repay |
| Reference | `MATH-AR-15` (15b), `MATH-AR-19`, `Q-146`, `Q-153`, `Q-169`, `Q-223` |
| Description | A 1,000 GHO floor on partial repay blocks risk-reducing repays near the floor; debt below 1,000 GHO is reachable through Aave's collateral-dust branch and such an account cannot reduce debt gradually. The floor would sit on every repay path. |
| Impact | Borrowers near HF 1 cannot rescue themselves with a partial repay; contradicts the rule that no Avana rule blocks repay. |
| Evidence | `z3/aave-risk/ar03_liquidation.py`, `z3/aave-risk/ar04_repay.py` |
| Resolution | `Q-153` drops the repay floor (any partial repay allowed); `Q-169` removes the minimum debt. `AaveAdapter.repay` takes any amount up to `maxRepaySpend` on any debt reserve, accepts any payer and never reads the pause state (`Q-223`, `Q-227`). |
| Status | Resolved in design |
| Verification | `TEST-029`, `TEST-099`, `TEST-175` |

#### FINDING-022: Repay-all signed as an exact amount fails after interest

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Medium |
| Component | AaveAdapter repay |
| Reference | `MATH-AR-17`, `Q-075`, `Q-180`, `Q-209`, `Q-234` |
| Description | A signed exact repay amount equal to the debt becomes a partial repay once one wei of interest accrues. |
| Impact | Users cannot reliably close their debt. |
| Evidence | `z3/aave-risk/ar04_repay.py` |
| Resolution | `Q-180`: `repayAll` flag with `maxRepaySpend`; the AaveAdapter reads the proxy's live total debt on the named debt reserve (drawn plus premium) at execution, reverts `RepayExceedsMax` if it exceeds `maxRepaySpend`, and requires zero remaining debt on that reserve after the repay (`DebtRemaining`). At zero debt, a repay (partial or repay-all) returns 0 with no token movement (`Q-209`). `repayAllAndWithdraw` repays every debt reserve it names the same way and requires every debt reserve of the account at zero before it withdraws (`Q-234`). |
| Status | Resolved in design |
| Verification | `TEST-029`, `TEST-075`, `TEST-203` |

#### FINDING-023: Risk-premium threshold equal to the top collateral risk reverts premium updates

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | High |
| Component | Borrow Spoke configuration |
| Reference | `MATH-AR-22`, `MATH-AR-23`, `Q-111`, `Q-141` |
| Description | With `riskPremiumThreshold` equal to the highest collateral risk, per-user `percentMulUp` rounding makes the Hub check fail for two users. |
| Impact | The Hub reverts the next premium change: repay, liquidation and refresh payloads revert. |
| Evidence | `z3/aave-risk/ar05_risk_premium.py` |
| Resolution | `Q-141`: threshold = highest collateral risk + at least one basis point, never lowered while debt exists; a fork test with many users proves repay and liquidation pass. |
| Status | Resolved in design |
| Verification | `TEST-111` |

#### FINDING-024: Many one-share dust users can exceed the one-basis-point margin

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | Borrow Spoke configuration |
| Reference | `MATH-AR-24` (24a), `Q-141`, `Q-169` |
| Description | Three users holding one drawn share each at the top risk exceed the margin's slack. |
| Impact | Premium updates would revert; with one ordinary account present more than 1e16 dust accounts are needed (`MATH-AR-24c`). |
| Evidence | `z3/aave-risk/ar05_risk_premium.py` |
| Resolution | Accepted risk under `Q-169`. Owner: Aave V4 risk service providers (Borrow Spoke threshold, `Q-141`). Bound: with one ordinary account present, more than 1e16 one-share dust accounts are needed (`MATH-AR-24c`), which no realistic gas budget allows. |
| Status | Accepted risk |
| Verification | `TEST-111` |

#### FINDING-025: Raising collateral risk above the threshold blocks liquidation

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | High |
| Component | Borrow Spoke configuration, RiskModule drift check |
| Reference | `MATH-AR-25`, `Q-111`, `Q-141`, `Q-178` |
| Description | If a vault reserve's `collateralRisk` is raised above the threshold before the threshold is raised, `_notifyRiskPremiumUpdate` at the end of `liquidationCall` reverts, as do borrow, withdraw and refresh payloads. |
| Impact | Liquidations of affected accounts stop. |
| Evidence | `z3/aave-risk/ar05_risk_premium.py` |
| Resolution | `Q-178`: any collateral-risk increase follows a threshold increase; the drift check asserts collateral risk ≤ threshold minus the margin and blocks new borrows if violated. |
| Status | Resolved in design |
| Verification | `TEST-033`, `TEST-112` |

#### FINDING-026: Vault-token asset drawn through another Spoke breaks shares == assets

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Medium |
| Component | Hub configuration, RiskModule drift checks |
| Reference | `MATH-AR-27`, `MATH-ST-41`, `Q-080`, `Q-172`, `Q-181` |
| Description | One wei of interest on the vault-token asset, possible if any Spoke registered for it has `drawCap > 0`, makes added shares differ from assets; the original drift list checked only the Borrow Spoke's `borrowable` flag. |
| Impact | Triggers the shares ≠ assets stop for pledges and borrows and, under `Q-189`, for liquidation. |
| Evidence | `z3/aave-risk/ar06_vault_shares.py` |
| Resolution | `Q-172` and `Q-181`: drift and deployment checks assert `drawCap == 0` for every Spoke on the asset, zero drawn shares, a single Spoke and no reinvestment controller. |
| Status | Resolved in design |
| Verification | `TEST-033`, `TEST-114`, `TEST-135`, `PROP-040` |

#### FINDING-027: Pause losses depend on the worst LP drop, not the pause length

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Informational |
| Component | Caps, First-Loss Reserve |
| Reference | `MATH-AR-30` (30c), `MATH-AR-31`, `Q-079`, `Q-192`, `Q-227`, `Q-234` |
| Description | Witness: with CF 35 % and bonus 1.05, a 64 % LP drop during a paused period already creates a deficit; interest over the pause adds little. |
| Impact | Caps sized by pause duration alone understate losses. |
| Evidence | `z3/aave-risk/ar07_pause_bad_debt.py` |
| Resolution | Launch condition. Condition: every market's caps are sized with the proved bound `debt × max(0, (1+g) − h0(1−dLP)/(CF × LB))` using the pool's worst historic LP drop over the 48-hour incident window plus margin, and caps ≤ reserve ÷ loss factor (`Q-192`). Avana's application pause state never stops liquidation (`Q-227`), so the window covers the liquidation stops that remain: Aave-side reserve pauses and LPOracle price-state pauses. For an account with a non-GHO debt reserve the sizing adds a debt-asset price rise over the same window (`Q-234`). Who: the Aave V4 risk service providers in each listing payload (`Q-197`). |
| Status | Launch condition |
| Verification | `TEST-127`, `TEST-202` |

#### FINDING-028: Recovery measured on the wrong balance

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Informational |
| Component | LPVaultSwap |
| Reference | `MATH-ST-02`, `MATH-ST-03`, `Q-085` |
| Description | Expected counterexamples: checking the floor on the whole balance, or on the balance net of flash principal, lets prefunded GHO hide a poor recovery. |
| Impact | Confirms why recovery is measured separately. |
| Evidence | `z3/settlement/st01_recovery_floor.py` |
| Resolution | `Q-085`: recovery is measured over the unwind-and-convert window; flash repayment is checked separately. |
| Status | Resolved in design |
| Verification | `TEST-050` |

#### FINDING-029: Additive slippage bound does not cover flash repayment

| Field | Value |
|---|---|
| Source | Formal verification (Z3); Formal verification (SymPy); Design review (decision check) |
| Severity | High |
| Component | LPVaultSwap |
| Reference | `MATH-ST-05`, `MATH-ST-08`, `MATH-ST-22`, `SYM-41`, `SYM-42`, `Q-127`, `Q-159`, `Q-235` |
| Description | Aave's bonus is multiplicative; with `s = bonus − costs` the floor `D × (1 + b) × (1 − s)` misses `D × (1 + f)` by `b × (b − f) × D` (625 GHO per 1M at a 2.5 % bonus). The bonus is set per user key by Aave, so a listing-time bound goes stale. |
| Impact | Before the fix, a keeper or a route sandwich could force that gap as a settlement-budget draw on every liquidation until the cap; with the budget removed (`Q-397`) the gap would fall on the caller. |
| Evidence | `z3/settlement/st02_floor_covers_flash.py`, `z3/settlement/st04_settlement_budget.py`, `sympy/sym05_settlement.py` |
| Resolution | `Q-159`: each liquidation reads Aave's actual bonus and uses `s = min(allowance, 1 − (1 + costs)/(1 + bonus))`; the gap is then at most one vault unit plus rounding, which the caller pays through its shortfall top-up (`Q-397`). For a non-GHO debt reserve the costs include the buy leg, so the bound satisfies `(1 + bNet)(1 − s) ≥ (1 + flash fee)(1 + buySlippageAllowanceBps)` and the floor covers the covered debt cost `Gcov` (`Gnet` capped at the oracle bound of the debt Aave took) plus the flash fee on it, `φD` (`Q-235`). |
| Status | Resolved in design |
| Verification | `TEST-050`, `TEST-078`, `TEST-198`, `PROP-017`, `PROP-018`, `PROP-059` |

#### FINDING-030: Effective slippage rounded to nearest misses repayment

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | LPVaultSwap |
| Reference | `MATH-ST-11`, `Q-159`, `Q-190`, `Q-235` |
| Description | Rounding `s` to the nearest basis point can round up (3 instead of 2 at a 100.47 % bonus and 44 bps costs). |
| Impact | The floor misses repayment by about 1.4 GHO per 1M GHO. |
| Evidence | `z3/settlement/st02_floor_covers_flash.py` |
| Resolution | `Q-190`: `s = floor(10000 × (bonus − 10000 − costs) / bonus)`. The same downward rounding applies when the costs include the buy-leg allowance of a non-GHO debt reserve (`Q-235`). |
| Status | Resolved in design |
| Verification | `TEST-050`, `TEST-070`, `TEST-198`, `PROP-017` |

#### FINDING-031: Aave liquidation-fee drift breaks the slippage bound

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Medium |
| Component | LPVaultSwap, Borrow Spoke, RiskModule drift checks |
| Reference | `MATH-ST-12`, `Q-068`, `Q-080`, `Q-190`, `Q-222`, `Q-237` |
| Description | If the vault reserve's liquidation fee drifts from 0, LPVaultSwap receives less than the full bonus, and the `Q-159` bound computed on the gross bonus no longer covers the debt (4,742 GHO per 1M at a 10 % fee and 5 % bonus). |
| Impact | Liquidations revert, or need a caller shortfall top-up the slippage bound was meant to make unnecessary. |
| Evidence | `z3/settlement/st02_floor_covers_flash.py` |
| Resolution | `Q-190`: the live slippage bound uses Aave's bonus net of any liquidation fee. The liquidation-manager Borrow Spoke rejects a non-zero liquidation fee on every key in code (`UnsupportedLiquidationFee()`, `Q-222`, `Q-237`), and the drift and live-config checks assert the fee is 0. |
| Status | Resolved in design |
| Verification | `TEST-050`, `TEST-114`, `TEST-135`, `TEST-204` |

#### FINDING-032: Waterfall wording lets Avana take keeper principal or the budget refund the keeper

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | High |
| Component | LPVaultSwap |
| Reference | `MATH-ST-19`, `MATH-ST-20`, `Q-097`, `Q-127`, `Q-190`, `Q-235`, `Q-397` |
| Description | Reading "realized surplus" as the balance after flash repayment makes Avana's share include keeper principal; computing the shortfall as `D + fee − R` ignores keeper GHO so the budget refunds keeper losses. |
| Impact | Up to 200,000 GHO of a 1M keeper principal taken as fee at a 20 % share; before `Q-397`, the budget drained by keeper losses. |
| Evidence | `z3/settlement/st03_waterfall.py` |
| Resolution | `Q-190` and `Q-235`: the realized surplus is `max(0, R − D − φD)` in the debt asset, and Avana's 20 % share applies only to that surplus, never to keeper principal (`INV-036`). `Q-397` removed the SettlementBudget, so no Avana fund ever refunds a keeper: the caller sizes `debtToCover` and its funding (flash principal, exact premium and `callerFunds`) for the repayment Aave V4's dust rule may require, and pays any rounding gap at final settlement through its shortfall top-up, bounded by `maxShortfall` (`INV-034`). |
| Status | Resolved in design |
| Verification | `TEST-048`, `TEST-051`, `TEST-197`, `PROP-015` |

#### FINDING-033: Oversized flash loan turns the flash fee into a budget draw

| Field | Value |
|---|---|
| Source | Formal verification (Z3); Formal verification (SymPy) |
| Severity | Low |
| Component | LPVaultSwap |
| Reference | `MATH-ST-23`, `SYM-45`, `Q-135`, `Q-190`, `Q-235`, `Q-397` |
| Description | With a non-zero flash fee, flash-minting more than the debt makes the fee on the unused part a shortfall. |
| Impact | Before `Q-397`, budget draws up to the per-call cap; now a cost to the caller alone; zero while `maxFlashFeeBps` stays at its launch value. |
| Evidence | `z3/settlement/st04_settlement_budget.py`, `sympy/sym05_settlement.py` |
| Resolution | `Q-190`, `Q-235` and `Q-267`: settlement counts only the premium on the debt the liquidation needed, `φD` on `min(F, D)`, so the premium on a flash amount above it costs only the caller. `Q-397` removed the SettlementBudget, so no draw exists to absorb it. `Q-135` bounds the fee. |
| Status | Resolved in design |
| Verification | `TEST-052`, `TEST-118`, `TEST-197`, `PROP-015` |

#### FINDING-034: Calendar-day budget bucket allows twice the daily cap

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Medium |
| Component | SettlementBudget (removed, `Q-397`) |
| Reference | `MATH-ST-25`, `Q-167`, `Q-190`, `Q-236`, `Q-397` |
| Description | With buckets `floor(t / 86400)`, draws just before and just after midnight each get a full daily cap. |
| Impact | Twice the intended daily loss within seconds. |
| Evidence | `z3/settlement/st04_settlement_budget.py` |
| Resolution | Resolved by removal (`Q-397`): the SettlementBudget and its windows no longer exist, so there is no daily cap to double; the caller sizes `debtToCover` and its funding (flash principal, exact premium and `callerFunds`) for the repayment Aave V4's dust rule may require, and pays any rounding gap at final settlement through its shortfall top-up, bounded by `maxShortfall` (`INV-034`). Earlier fix, superseded: a rolling 24-hour window (`Q-190`) per Spoke and debt reserve under a total cap (`Q-236`). |
| Status | Resolved in design |
| Verification | `TEST-059`, `TEST-093`, `TEST-200`, `PROP-020`, `PROP-063` |

#### FINDING-035: In-kind value rounded down lets the keeper exceed the cap

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | LPVaultSwap in-kind (removed, `Q-401`) |
| Reference | `MATH-ST-28`, `Q-133`, `Q-190`, `Q-401` |
| Description | If the unwound tokens' oracle value rounds down, the keeper's pro-rata share can exceed `debt × (1 + bonus)` by under 2 wei. |
| Impact | Dust over-payment to the keeper; breaks the strict cap. |
| Evidence | `z3/settlement/st05_in_kind.py` |
| Resolution | Resolved by removal (`Q-401`): in-kind settlement no longer exists, so no keeper receives pool tokens and no in-kind cap applies. Earlier fix, superseded: in-kind oracle value rounded up, the keeper share rounded down, the borrower got the remainder (`Q-190`). |
| Status | Resolved in design |
| Verification | `TEST-053`, `PROP-019` |

#### FINDING-036: In-kind valued at pool spot price

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Informational |
| Component | LPVaultSwap in-kind (removed, `Q-401`) |
| Reference | `MATH-ST-31`, `Q-133`, `Q-401` |
| Description | Expected counterexample: valuing unwound tokens at pool spot lets a keeper who moves the spot take tokens worth 25 % more than the cap at oracle prices. |
| Impact | Confirms the oracle valuation of `Q-133`. |
| Evidence | `z3/settlement/st05_in_kind.py` |
| Resolution | Resolved by removal (`Q-401`): in-kind settlement no longer exists. The routed settlement still values the seizure at oracle prices (`V`, `INV-034`), never at pool spot; the earlier in-kind rule did the same (`Q-133`). |
| Status | Resolved in design |
| Verification | `TEST-053`, `PROP-019` |

#### FINDING-037: Position-manager uint128 wrap in collect

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Informational |
| Component | LPVault |
| Reference | `MATH-ST-36`, `Q-061` |
| Description | Without the uint128 bound the position manager's unchecked add wraps and `collect` returns less than the principal. |
| Impact | Needs about 3.4e20 whole 18-decimal tokens owed on one NFT; unreachable. |
| Evidence | `z3/settlement/st06_principal_collect.py` |
| Resolution | Accepted risk. Owner: Avana Labs (listing bounds). Bound: unreachable below about 3.4e20 whole 18-decimal tokens owed on one NFT, far above every per-market cap and the listing bounds on liquidity (`Q-061`, `Q-191`). |
| Status | Accepted risk |
| Verification | `TEST-058`, `TEST-116` |

#### FINDING-038: Coverage role can spend the reserve on any Spoke's deficit

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | High |
| Component | First-Loss Reserve, First-Loss Reserve |
| Reference | `MATH-ST-50`, `Q-101`, `Q-142`, `Q-190`, `Q-236` |
| Description | `Hub.eliminateDeficit` accepts any `spoke` argument, and role checks restrict callers, not arguments. |
| Impact | First-Loss Reserve shares could be burned to cover deficits of non-Avana Spokes on the same Hub, or of another asset. |
| Evidence | `z3/settlement/st09_deficit_coverage.py` |
| Resolution | `Q-190`: the First-Loss Reserve calls `eliminateDeficit` only for Borrow Spokes on a DAO-set allowlist (`SpokeNotAllowlisted`). `Q-236`: each covered (Hub, debt asset) has its own First-Loss Reserve, which covers deficits only in its own asset on its own Hub; a deficit in one asset is never covered with another asset's reserve. |
| Status | Resolved in design |
| Verification | `TEST-128`, `TEST-094`, `TEST-199`, `PROP-039`, `PROP-060` |

#### FINDING-039: Avana fee in in-kind mode unspecified

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | LPVaultSwap in-kind (removed, `Q-401`) |
| Reference | `MATH-ST` findings item 10, `Q-097`, `Q-133`, `Q-163`, `Q-190`, `Q-401` |
| Description | The in-kind decisions did not say whether Avana takes a share when no GHO surplus is realized. |
| Impact | Ambiguous payout code; an in-kind path could be preferred to skip the fee. |
| Evidence | `z3/settlement/README.md` |
| Resolution | Resolved by removal (`Q-401`): there is no in-kind mode. Every liquidation settles in the debt asset through the swap routes, and Avana's fee follows `INV-036`. Earlier rule, superseded: no Avana fee in in-kind mode (`Q-190`). |
| Status | Resolved in design |
| Verification | `TEST-053`, `PROP-021` |

#### FINDING-040: Rate and premium wording in the ARFC differs from Aave V4

| Field | Value |
|---|---|
| Source | Formal verification (SymPy) |
| Severity | Low |
| Component | Borrower disclosures |
| Reference | `SYM-51b`, `SYM-53d`, `Q-096`, `Q-231`, `Q-233` |
| Description | "Weighted average of all collateral" and "rate on total debt = base × (1 + URP) at all times" do not match V4: collateral is taken lowest risk first up to the debt value, values are not CF-weighted, and the premium accrues on drawn debt without compounding on itself. |
| Impact | Borrower-facing rates and premium estimates would be wrong. |
| Evidence | `sympy/sym06_risk_premium.py` |
| Resolution | Avana's borrower disclosures and rate estimates use Aave V4's own user-risk-premium walk (collateral taken lowest risk first up to the debt value, values not CF-weighted) and its accrual on drawn debt without compounding on itself (`Q-096`), shown per debt reserve the account holds (`Q-233`). Avana adds no fee on borrow interest (`Q-231`), so the rate shown is Aave's rate. |
| Status | Resolved in design |
| Verification | `TEST-111`, `TEST-206` |

### B. State-machine and property-test counterexamples (Quint, Hypothesis)

#### FINDING-041: Hostile LPVaultSwap can strand a borrower's NFTs

| Field | Value |
|---|---|
| Source | Formal verification (Quint simulator) |
| Severity | High |
| Component | LPVaultSwap (upgradeable), Collateralization, AaveAdapter |
| Reference | `QNT-07`, `QNT-15`, `QNT-22`, `QNT-T09`, `Q-090`, `Q-125`, `Q-160`, `Q-165`, `Q-201`, `Q-211`, `Q-224`, `Q-228`, `Q-236` |
| Description | A hostile or buggy LPVaultSwap version calls `liquidationCall`, keeps the seized vault tokens and never settles them with Collateralization. The proxy's Spoke supply in that market falls below the credited units of its records. Without a reconciliation path in the immutable Collateralization, the borrower could not withdraw the remaining NFT after repaying, because the withdrawal releases exactly the credited units and the proxy no longer holds them. The version can also liquidate on stale prices. |
| Impact | Before `Q-201`: permanent lock-up of the remaining NFTs of every liquidatable account the version touches. With reconcile on exit: the hostile version can seize from accounts with HF < 1 during its lifetime (at most until a canceller stops the upgrade within the 5-day normal timelock delay, or a later upgrade replaces it), but it cannot strand any NFT; the seized vault tokens stay backed by the pending-settlement balance. |
| Evidence | `quint/avana.qnt`, `quint/avana_tests.qnt` (`reconcileOnExitTest`, `reconcileOnSettlementTest`) |
| Resolution | `Q-201` reconcile on exit: when a proxy's Spoke supply in a market is below its credited units, Collateralization treats the missing units as seized on the borrower's next withdrawal (`release`, or `releaseZeroCredit` for a record left with no credit) or on the next liquidation settlement of that account-market (`settleSeizure`, after the current seizure's units are burned and before they are debited). Reconcile runs only while the vault-token Hub asset's shares equal its assets. It debits the shortfall from the records largest-first (the same order as a liquidation debit, `Q-194`), has the LPVault remove the matching liquidity into a per-market pending-settlement balance that keeps the outstanding vault tokens backed, and releases the rest of the NFT. A later honest LPVaultSwap, on anyone's `settlePending(marketId)` call, has the AaveAdapter burn the held vault tokens (`burnSeized`, at most the pending units, `Q-224`); Collateralization checks `totalSupply + units ≤ totalCredited + pending.units` (`Q-257`), debits the pending balance and has the LPVault release the pro-rata pool tokens to LPVaultSwap (`PendingSettled`); LPVaultSwap converts them to GHO, reverts unless the GHO meets the `minPending` floor, and funds the GHO First-Loss Reserve with all of it in the same call (`PendingSettlementForwarded`, `Q-211`, `Q-236`). The reserve absorbs the losses the incident causes, and since no keeper, borrower or Avana treasury receives the proceeds, nobody profits from triggering one. Example: credited 1,000,000 units, Spoke supply 600,000 after an unsettled seizure of 400,000; on withdrawal Collateralization debits 400,000 units from the largest record, the LPVault holds the tokens from removing 400,000 liquidity as pending settlement, the Adapter burns the proxy's 600,000 withdrawn units and the NFT returns with its remaining liquidity. Backing becomes `totalSupply == Σ credited + pending` (`INV-001`, `INV-008`, `INV-058`). Every LPVaultSwap upgrade waits the 5-day normal timelock delay, cancellable by the governance multisig, the Emergency Guardian, the Aave Protocol Guardian and the Aave governance executor (`Q-228`), and Collateralization still rejects wrong-record debits (`Q-160`, `Q-165`). |
| Status | Resolved in design |
| Verification | `TEST-150`, `TEST-151`, `TEST-152`, `TEST-153`, `TEST-154`, `TEST-170`, `TEST-131`, `TEST-085`, `TEST-110`, `TEST-208`, `PROP-045`, `PROP-051`, `PROP-054` |

#### FINDING-042: Guardian's Aave pauseReserve blocks liquidation without expiry

| Field | Value |
|---|---|
| Source | Formal verification (Quint simulator) |
| Severity | High |
| Component | Aave Spoke configuration, governance |
| Reference | `QNT-33`, `QNT-T13`, `Q-050`, `Q-083`, `Q-138`, `Q-192`, `Q-202`, `Q-209`, `Q-227`, `Q-229` |
| Description | The Aave Protocol Guardian holds the one-way `SpokeConfigurator.pauseReserve` on Avana's Borrow Spoke, an Aave governance power that Avana does not grant or control. Pausing a vault-token reserve or a debt reserve blocks liquidation of the accounts holding it until an Aave DAO vote unpauses it, with no expiry on the Avana side. |
| Impact | Liquidations can stay halted for a DAO voting period while bad debt grows. |
| Evidence | `quint/avana_tests.qnt` (`guardianAavePauseTest`) |
| Resolution | Accepted risk with AIP commitment (`Q-202`). Owner: Aave DAO, which governs the Aave Protocol Guardian's pause power. The deployment AIP asks the DAO to pause Avana vault-token and debt reserves only for exploits and to unpause within the 48-hour incident window of `Q-192`. Avana's own application pause state never stops liquidation (`Q-227`), so Aave-side reserve pauses and LPOracle price-state pauses are the only liquidation stops the caps must absorb. Bound: per-market caps are sized with the pause-loss bound `debt × max(0, (1+g) − h0(1−dLP)/(CF × LB))` over that window (`Q-192`), so a pause of that length stays within the First-Loss Reserve of the affected asset. While a reserve is paused, `RiskModule.preBorrowCheck` and `preWithdrawCheck` revert `AaveReservePaused(reserveId)` for a paused vault-token reserve of the account and `DebtReservePaused(debtReserveId)` for a paused debt reserve of the account (`Q-209`, `Q-229`, `INV-060`), so no new risk opens during the pause. |
| Status | Accepted risk |
| Verification | `TEST-158`, `TEST-169`, `TEST-129`, `TEST-127`, `TEST-126`, `PROP-050` |

#### FINDING-043: A faulty RiskModule approves borrowing against frozen or Drifting markets

| Field | Value |
|---|---|
| Source | Formal verification (Quint simulator); Design review (attacker round) |
| Severity | Medium |
| Component | RiskModule (upgradeable), AaveAdapter |
| Reference | `QNT-19`, `QNT-T04`, `Q-052`, `Q-081`, `Q-203`, `Q-227`, `Q-228`, `Q-229` |
| Description | The AaveAdapter enforces every borrow-side gate by calling the RiskModule (`preBorrowCheck`, `preWithdrawCheck`, `postHealthCheck`). After a faulty or hostile RiskModule upgrade, borrowing and withdraw-with-debt could pass in Drifting markets, against vault-token reserves frozen on Aave, during a liquidation halt, with a stale debt price or below the 1.10 and 1.05 health-factor floors. |
| Impact | New debt opens on collateral the reviewed gates would reject, up to the drawCap of each debt reserve; Aave still refuses any borrow or withdrawal below HF 1. |
| Evidence | `quint/avana_tests.qnt` (`hostilePolicyBorrowTest`) |
| Resolution | Accepted risk. Owner: the timelock cancellers (governance multisig, Emergency Guardian, Aave Protocol Guardian, Aave governance executor), who can cancel a RiskModule upgrade during the 5-day normal delay (`Q-228`). Bound: the gates hold for the reviewed RiskModule implementation (`Q-229`); for any implementation, the AaveAdapter reads the application pause state itself, so Frozen and Paused still stop borrowing (`Q-227`); Aave enforces HF ≥ 1, the debt reserve's own frozen and paused flags and the Borrow Spoke drawCap per debt reserve set by the Aave DAO; the Adapter keeps the deadline, the per-proxy nonce and the receiver rules on every borrow. |
| Status | Accepted risk |
| Verification | `TEST-155`, `TEST-156`, `TEST-132`, `TEST-095`, `TEST-192`, `PROP-046`, `PROP-031` |

#### FINDING-044: Zero-seizure liquidations draw the settlement budget

| Field | Value |
|---|---|
| Source | Formal verification (Quint simulator) |
| Severity | Medium |
| Component | LPVaultSwap, SettlementBudget (removed, `Q-397`) |
| Reference | `QNT-29`, `QNT-T07`, `MATH-ST-06`, `Q-127`, `Q-167`, `Q-190`, `Q-198`, `Q-236`, `Q-397` |
| Description | An approved keeper liquidates through LPVaultSwap with a `debtToCover` small enough that Aave seizes 0 units; the floor of 0 passed and the flash principal became a budget draw. |
| Impact | Before the fix: repeated calls let the budget repay borrowers' debt with no collateral seized, up to the rolling 24-hour cap of the debt reserve (500 GHO for the GHO reserve). With the zero-seizure revert and the budget removed: none. |
| Evidence | `quint/avana_tests.qnt` (`zeroSeizeRejectedTest`) |
| Resolution | LPVaultSwap reverts with `NothingSeized` when Aave seizes 0 vault-token units, so no debt is repaid without a seizure (`INV-030`). `Q-397` removed the SettlementBudget: no Avana contract funds any part of a settlement, and the caller sizes `debtToCover` and its funding (flash principal, exact premium and `callerFunds`) for the repayment Aave V4's dust rule may require, and pays any rounding gap at final settlement through its shortfall top-up, bounded by `maxShortfall` (`INV-034`), so a zero-seizure call could spend only the caller's own funds. |
| Status | Resolved in design |
| Verification | `TEST-160`, `TEST-059`, `TEST-093`, `TEST-200`, `PROP-047`, `PROP-020`, `PROP-063` |

#### FINDING-045: Guardian can keep liquidation halted half the time through repeated incidents

| Field | Value |
|---|---|
| Source | Formal verification (Quint simulator) |
| Severity | Low |
| Component | Application pause state (MarketRegistry), governance |
| Reference | Quint note on `QNT-32`, `Q-083`, `Q-137`, `Q-196`, `Q-227` |
| Description | Under the earlier incident model, each continuous liquidation halt was bounded by one incident, but a new incident after the cooldown restarted it, so the duty cycle was set by `incidentDuration` and `newIncidentCooldown`. |
| Impact | A rogue guardian could have paused liquidation for a fraction of all time equal to incident ÷ (incident + cooldown). |
| Evidence | `quint/README.md` |
| Resolution | Superseded by `Q-227`. Incidents, the incident clock, the new-incident cooldown, GuardianRestrictions and the Recovery multisig no longer exist. The application pause state (None, Frozen, Paused) never stops liquidation: both liquidation entry points, pending settlement, repay, fee collection, debt-free withdrawal and zero-credit release run in every state, and Paused blocks only pledges and non-rescue top-ups (every pledge under `MintPathSuspect`, `Q-252`), borrowing, withdraw-with-debt, removal with debt and repay with collateral. A rogue pause guardian can therefore stop new risk, which costs no collateral, but cannot halt liquidation for any fraction of time; it can be removed by a normal-delay role-change operation, which only the Aave governance executor can cancel (`Q-228`). The liquidation stops that remain (Aave-side reserve pauses, LPOracle price states) are bounded by `FINDING-042` and the 48-hour incident window of `Q-192`. |
| Status | Resolved in design |
| Verification | `TEST-065`, `TEST-101`, `TEST-192`, `TEST-193`, `PROP-057` |

#### FINDING-046: Ledger-total debit check bricks later liquidations

| Field | Value |
|---|---|
| Source | Formal verification (Quint simulator) |
| Severity | Medium |
| Component | Collateralization liquidation debit |
| Reference | `QNT-36`, `QNT-T11`, `Q-125`, `Q-160` |
| Description | A debit check of the form "Σ credited − units = supply" fails forever for an account once any seizure went unsettled. |
| Impact | Turns a stranded seizure into unliquidatable debt. |
| Evidence | `quint/avana_tests.qnt` (`ledgerCheckBricksTest`, `deltaCheckSurvivesTest`) |
| Resolution | `Q-160`: Collateralization compares its own snapshot of the proxy's supplied shares, taken at `beginSeizure`, with the read after `liquidationCall` (`Q-240`). |
| Status | Resolved in design |
| Verification | `TEST-056`, `TEST-100`, `PROP-004` |

#### FINDING-047: Uncapped liquidation collect takes the depositor's fees

| Field | Value |
|---|---|
| Source | Formal verification (Quint simulator) |
| Severity | Informational |
| Component | LPVault liquidation |
| Reference | `QNT-T17`, `Q-061` |
| Description | Expected counterexample: collecting the full owed amount during liquidation sweeps the depositor's accrued fees. |
| Impact | Confirms the principal cap. |
| Evidence | `quint/avana_tests.qnt` (`uncappedCollectTest`) |
| Resolution | `Q-061`: liquidation collects at most the principal the removal returned. |
| Status | Resolved in design |
| Verification | `TEST-058`, `TEST-091` |

#### FINDING-048: Dust accounts cannot be liquidated through routes

| Field | Value |
|---|---|
| Source | Developer (Hypothesis model) |
| Severity | Medium |
| Component | LPVaultSwap recovery floor |
| Reference | `HYP-53`, `Q-085`, `Q-098`, `Q-159`, `Q-163`, `Q-169`, `Q-198`, `Q-230`, `Q-236`, `Q-397` |
| Description | With no minimum debt, a position worth about $0.000002 can fall below HF 1; the unwind loses up to one raw token unit per leg and the PSM leg truncates, which exceeds the percentage slippage allowance, so every routed liquidation reverts at the floor. |
| Impact | Before `Q-198`: such accounts stayed HF < 1 and keepers could not meet the duty to liquidate every HF < 1 account. With `Q-198` and `Q-397`: none; the caller pays the dust gap through its shortfall top-up. |
| Evidence | `hypothesis/test_hyp_scenarios.py` (`test_hyp53_dust_accounts_settle`, `test_hyp53_every_account_size_is_liquidatable`) |
| Resolution | `Q-198`: recovery floor `minGho = max(0, ⌈V × (10⁴ − s_eff) / 10⁴⌉ − U − floorRoundingAllowanceGho)`, where `V` is the oracle GHO value of the seized backing, `s_eff` the effective slippage in bps, `U` one raw token unit of each unwound leg valued in GHO, and `floorRoundingAllowanceGho` = 1 GHO. The caller covers any gap between proceeds and the repayment through its shortfall top-up (`Q-251`, `Q-397`; the SettlementBudget that covered it earlier is removed), so dust liquidations settle and any deficit is recorded. `minPledgeUsd` ($10, `Q-230`) keeps every new pledge above dust, but partial seizures and price falls still leave dust accounts, so the floor rule stays. Example (amounts in GHO wei, 18 decimals): the HYP-53 account has `V` = 0.000002 GHO = 2 × 10¹² wei; for any `s_eff`, `⌈V × (10⁴ − s_eff) / 10⁴⌉` ≤ 2 × 10¹² wei, which is below `floorRoundingAllowanceGho` = 10¹⁸ wei, so `minGho` = 0 and the routed liquidation settles; the caller's shortfall top-up covers the remaining gap of a few millionths of a GHO. In-kind settlement no longer exists (`Q-401`). The one remaining case, a debt too small for Aave to seize even one unit, is `FINDING-098`. |
| Status | Resolved in design |
| Verification | `TEST-161`, `TEST-081`, `TEST-053`, `TEST-200`, `PROP-048` |

#### FINDING-098: Debt below one seized unit cannot be liquidated through LPVaultSwap

| Field | Value |
|---|---|
| Source | Developer (Hypothesis model) |
| Severity | Informational |
| Component | LPVaultSwap, Borrow Spoke |
| Reference | `HYP-53`, `Q-127`, `Q-169`, `Q-198`, `Q-212`, `Q-215`, `Q-222`, `Q-237` |
| Description | With no minimum debt, an account can hold a whole debt worth less than one vault-token base unit times the liquidation bonus. When it falls below HF 1, Aave sizes the seizure at 0 units, and LPVaultSwap reverts with `NothingSeized` because it never repays debt without a seizure (`INV-030`). The liquidation-manager Borrow Spoke accepts `liquidationCall` only from LPVaultSwap (`Unauthorized()` for any other caller, `Q-222`), on any debt reserve of its approved set (`Q-237`), so no other liquidation path exists. |
| Impact | The account stays below HF 1. No value is at risk: one unit of the 6-decimal USDC/USDT vault token is worth about $0.000002, so the whole debt is below about 0.000002 GHO (or the same value in another debt asset). |
| Evidence | `hypothesis/test_hyp_scenarios.py` (`test_hyp53_bound_zero_unit_seizure`: 1 unit pledged, 0.0000016 GHO borrowed, depeg to $0.70, Aave previews 0 seized shares and `liquidate` reverts) |
| Resolution | Accepted risk. Owner: Avana Labs (keeper operations). Why: a zero-unit seizure repays debt with nothing to settle it from, and before `Q-397` it drew the settlement budget (`FINDING-044`); the debt at stake is smaller than the gas of any call. Bound: the debt is below one unit × bonus of the market, at most about 0.000002 GHO of value per account in the 6-decimal market; the borrower can repay it at any time and anyone may repay it for the borrower through `AaveAdapter.repay`, which never reads the pause state (`Q-212`, `INV-043`). Keepers skip accounts whose preview seizes 0 units, so the alert does not repeat. Example: one USDC/USDT unit pledged, 0.0000016 GHO borrowed and USDT depegged to $0.70; Aave's integer sizing of the seizure for the whole debt rounds to 0 units, so `liquidate` reverts with `NothingSeized` and nothing moves; the debt at stake is 0.0000016 GHO. |
| Status | Accepted risk |
| Verification | `TEST-160`, `TEST-109`, `TEST-175` |


### C. Economic-simulation counterexamples

#### FINDING-049: Backup route carries every USDC and DAI leg in a USDC depeg

| Field | Value |
|---|---|
| Source | Economic simulation |
| Severity | Medium |
| Component | Settlement routes, debt buy and sell-back routes, listing |
| Reference | `SIM-01C`, `Q-058`, `Q-062`, `Q-084`, `Q-187`, `Q-233`, `Q-235` |
| Description | In the March 2023 USDC path the USDC GSM freezes, so every USDC leg and every DAI leg (LitePSM → USDC → GSM) goes to the DEX backup. With USDC listed as a debt reserve, the buy leg of a USDC-debt liquidation (GSM `buyAsset`) fails over to its DEX backup at the same moment. |
| Impact | The backup route is the real route in the stress that matters; a thin backup blocks liquidations, on the sell side and, for USDC debt, on the buy side as well. |
| Evidence | `simulation/sim01_depeg.py` |
| Resolution | Launch condition. Condition: each listed token has a backup conversion route to GHO that avoids the GSM or PSM of a pool token and meets its published depth threshold (`Q-187`); each non-GHO debt reserve has a primary and a backup buy route and a sell-back route, each meeting its `buyRouteDepthThresholdGho` and validated under the same stress before the reserve's `drawCap` rises above 0 (`Q-233`, `Q-235`). Who: Avana Labs checks it at listing, with the Aave V4 risk service providers sizing the market cap and the debt reserve's line to that depth. |
| Status | Launch condition |
| Verification | `TEST-119`, `TEST-120`, `TEST-139`, `TEST-197`, `TEST-202` |

#### FINDING-050: A GHO discount liquidates accounts solvent in GHO terms

| Field | Value |
|---|---|
| Source | Economic simulation |
| Severity | Low |
| Component | LPOracle, borrower disclosures |
| Reference | `SIM-01D`, `Q-057`, `Q-100`, `Q-177`, `Q-200`, `Q-238` |
| Description | With GHO at 0.90 the GHO leg of the collateral follows Chainlink down while GHO debt stays at $1 (Aave's fixed GHO price source), so drifted accounts with GHO debt are liquidated although they are solvent in GHO terms. Debt in another asset is priced by its own Chainlink feed (`Q-238`) and is not affected by a GHO discount. |
| Impact | A transfer of bonus from GHO-pool borrowers to keepers ($351 total at pool risk factor 0.75 in the model). |
| Evidence | `simulation/sim01_depeg.py` |
| Resolution | Accepted risk, a design consequence of `Q-100` (GHO debt priced by Aave's fixed GHO price source, kept by `Q-238`) and `Q-177` (below-peg leg prices pass through). Owner: Avana Labs (borrower documentation states it). Bound: the liquidation bonus on the seized part of drifted GHO-pool accounts holding GHO debt only ($351 in total at pool risk factor 0.75 in the model); GHO above peg cannot trigger it, because the TWAP guard and agreement checks use the uncapped GHO/USD price (`Q-200`). |
| Status | Accepted risk |
| Verification | `TEST-036`, `TEST-126` |

#### FINDING-051: Disagreement tolerance below the alternate route's deviation pauses liquidations

| Field | Value |
|---|---|
| Source | Economic simulation |
| Severity | Medium |
| Component | LPOracle, listing |
| Reference | `SIM-01E`, `Q-112`, `Q-162`, `Q-183`, `Q-184`, `Q-199`, `Q-208` |
| Description | With the primary-vs-alternate tolerance below the alternate route's own deviation threshold, `Q-162` pauses liquidation during fast moves (11–15 accounts blocked at 0.25–0.5 %). |
| Impact | Liquidations delayed during the depeg; a long Cached window lengthens the pause. |
| Evidence | `simulation/sim01_depeg.py` |
| Resolution | `Q-184`: tolerance ≥ primary deviation + alternate deviation + margin, enforced at listing as a hard lower bound (launch margin 50 bps, `Q-196`). `Q-199`: `poke()` and every successful Avana call store the first time they observe a disagreement, and the pause ends `disagreementPauseMax` (1 hour) after that stored time. `Q-208`: if the routes still disagree then, the market is treated as Expired for liquidation until the routes agree or governance approves a fix; repay and debt-free withdrawal stay open and borrowing stays blocked. |
| Status | Resolved in design |
| Verification | `TEST-044`, `TEST-139`, `TEST-157`, `TEST-159`, `PROP-049` |

#### FINDING-052: Tail collapse during an outage exceeds the First-Loss Reserve at high pool risk factors

| Field | Value |
|---|---|
| Source | Economic simulation |
| Severity | High |
| Component | Caps, pool risk factor, First-Loss Reserve |
| Reference | `SIM-02B`, `Q-079`, `Q-101`, `Q-186`, `Q-192` |
| Description | USDT falling to 0.10 during a 72-hour outage creates bad debt from pool risk factor 0.50 upward (105k–395k GHO on 1.29M of USDT-pool debt). |
| Impact | Losses beyond a First-Loss Reserve at its launch minimum of 100,000 GHO (`Q-196`). |
| Evidence | `simulation/sim02_oracle_outage.py`, `simulation/sim08_recommendations.py` |
| Resolution | Launch condition. Condition: each pool's `poolRiskFactor` is at most the 0.40 ceiling, per-token losses are summed across pools and tested against the remaining First-Loss Reserve (`Q-186`), and caps ≤ reserve ÷ loss factor (`Q-192`). Who: the Aave V4 risk service providers set the values in each listing payload (`Q-197`). |
| Status | Launch condition |
| Verification | `TEST-127`, `TEST-135` |

#### FINDING-053: A silent feed stall keeps markets Live on a stale price

| Field | Value |
|---|---|
| Source | Economic simulation |
| Severity | High |
| Component | LPOracle, RiskModule, LPVaultSwap |
| Reference | `SIM-02C`, `SIM-03C`, `Q-079`, `Q-130`, `Q-182`, `Q-229`, `Q-238` |
| Description | A stall that keeps returning the last round looks fresh until heartbeat plus buffer (about 25 hours for 24-hour feeds); liquidations stop silently and borrowing stays open (9.4 hours at a price 10 % above market in the model). |
| Impact | Borrowing against stale, overstated collateral; delayed liquidations. |
| Evidence | `simulation/sim02_oracle_outage.py`, `simulation/sim03_correlated_drop.py` |
| Resolution | Launch condition. Condition: every listed market has feeds that meet the required update cadence, or the market is not listed, and every non-GHO debt reserve's Chainlink feed meets the same cadence; the RiskModule's `preBorrowCheck` and `preWithdrawCheck` check each collateral and debt price's original timestamp against `borrowPriceMaxAge` (1 hour) and LPVaultSwap uses `liquidationPriceMaxAge` (feed heartbeat + 10 minutes) for both (`Q-182`, `Q-196`, `Q-229`, `Q-238`). Who: Avana Labs at listing. |
| Status | Launch condition |
| Verification | `TEST-028`, `TEST-040`, `TEST-117`, `TEST-139`, `TEST-201` |

#### FINDING-054: Cached window measured from the source timestamp is skipped

| Field | Value |
|---|---|
| Source | Economic simulation |
| Severity | Medium |
| Component | LPOracle |
| Reference | `SIM-02D`, `Q-079`, `Q-128`, `Q-154`, `Q-183` |
| Description | With 24-hour heartbeats the last round is usually hours old, so a failure skips Cached entirely (100 % of failures for a 1-hour window). |
| Impact | The Cached state never occurs; the grace latch and the disagreement bound lose their reference. |
| Evidence | `simulation/sim02_oracle_outage.py` |
| Resolution | `Q-183`: Cached is measured from the first failed read and lasts `cachedWindow`. |
| Status | Resolved in design |
| Verification | `TEST-039`, `TEST-042` |

#### FINDING-055: Stale-price borrowing in a deep crash is profitable

| Field | Value |
|---|---|
| Source | Economic simulation |
| Severity | Medium |
| Component | RiskModule, caps |
| Reference | `SIM-03D`, `Q-079`, `Q-182`, `Q-186`, `Q-229` |
| Description | During a stall in a crash to 0.45, borrowing at the opening HF on the stale price exceeds the LP's market value at pool risk factor 0.75 (11.9k profit on 800k headroom). |
| Impact | Deliberate default for profit when market/served price < CF ÷ opening HF. |
| Evidence | `simulation/sim03_correlated_drop.py` |
| Resolution | `Q-182` and `Q-229`: the RiskModule's `preBorrowCheck`, which the AaveAdapter runs before every borrow, reverts on any collateral or debt price older than `borrowPriceMaxAge`; `Q-186` caps `poolRiskFactor` at its launch ceiling, below the profitable range. |
| Status | Resolved in design |
| Verification | `TEST-028`, `TEST-117`, `TEST-201` |

#### FINDING-056: No bonus floor makes small liquidations profitable in a gas spike

| Field | Value |
|---|---|
| Source | Economic simulation |
| Severity | Medium |
| Component | Keeper economics |
| Reference | `SIM-05A`, `Q-098`, `Q-169`, `Q-185` |
| Description | The break-even bonus floor for a 1,000 GHO full liquidation is 8.7 % at 20 gwei and 43 % at 100 gwei. |
| Impact | Small liquidations are loss-making for keepers whenever gas is high. |
| Evidence | `simulation/sim05_gas_dust.py` |
| Resolution | Accepted risk, superseded in part by `Q-381`. Avana's own approved keepers liquidate every account whatever its size, and Avana pays their gas as its own operating cost (`Q-381`); no external keeper is reimbursed, and liquidation never depends on a keeper's profit. Owner: Avana Labs (keeper gas). Bound: at most `G(16)` = 5.15M gas per account liquidation, an operating cost with no effect on solvency. |
| Status | Accepted risk |
| Verification | `TEST-142` |

#### FINDING-057: Keepers that skip loss-making calls leave dust bad debt

| Field | Value |
|---|---|
| Source | Economic simulation |
| Severity | Medium |
| Component | Keeper agreement, reimbursement |
| Reference | `SIM-05C`, `Q-098`, `Q-101`, `Q-169`, `Q-185` |
| Description | If reimbursement is capped, late or disputed and keepers act rationally, a dust-heavy book in the tail path at 100 gwei leaves 322 accounts unliquidated and 5.1k GHO of bad debt. |
| Impact | Bad debt from dust loans when reimbursement is not credible. |
| Evidence | `simulation/sim05_gas_dust.py` |
| Resolution | Launch condition. Avana's own approved keepers liquidate every account whatever its size, and Avana pays their gas as its own operating cost (`Q-381`); no external keeper is reimbursed, and liquidation never depends on a keeper's profit. Condition: Avana's keepers run with a funded gas budget, sized from `SPEC-CHAIN-001`'s gas-units model and the number of accounts in the listing stress case, with the gas price as a budget input. Who: Avana Labs funds and operates them; the permissionless fallback stays. |
| Status | Launch condition |
| Verification | `TEST-142` |

#### FINDING-058: Interest-driven liquidations lose money at moderate gas

| Field | Value |
|---|---|
| Source | Economic simulation |
| Severity | Low |
| Component | Keeper economics |
| Reference | `SIM-07C`, `Q-098`, `Q-169`, `Q-185` |
| Description | Interest pushes dormant accounts just below HF 1 where the bonus is minimal; at 20 gwei every such liquidation loses money (worst −$74). |
| Impact | A steady reimbursement cost ($6.6k over two years at 12 % APR in the model). |
| Evidence | `simulation/sim07_interest_accrual.py` |
| Resolution | Accepted risk. Avana's own approved keepers liquidate every account whatever its size, and Avana pays their gas as its own operating cost (`Q-381`); no external keeper is reimbursed, and liquidation never depends on a keeper's profit. Owner: Avana Labs (keeper gas). Bound: the gas of interest-driven liquidations, an operating cost; `aaveTargetHealthFactor` 1.10 reduces repeat liquidations. |
| Status | Accepted risk |
| Verification | `TEST-142` |

#### FINDING-059: Zero GHO collateral factor on the Core Hub would zero every GHO pool's CF

| Field | Value |
|---|---|
| Source | Economic simulation |
| Severity | Medium |
| Component | Listing, Borrow Spoke configuration |
| Reference | Simulation assumption review, `Q-020`, `Q-188` |
| Description | The simulations assume every pool token has a Core Hub CF of 0.78; if GHO's Core Hub CF is 0, `min(CF0, CF1)` makes every GHO pool's CF 0, which Aave forbids for collateral. |
| Impact | GHO pools could not be listed, or would be listed with a meaningless CF. |
| Evidence | `simulation/README.md` |
| Resolution | `Q-188`: listing defines an explicit GHO-leg CF instead of the Core Hub value. |
| Status | Resolved in design |
| Verification | `TEST-135`, `TEST-139` |

### D. Design review: attacker round

#### FINDING-060: Aave DAO can enable receiveShares on a vault-token reserve

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | Medium |
| Component | Borrow Spoke configuration |
| Reference | `Q-068`, `Q-080`, `Q-116`, `Q-172`, `Q-222` |
| Description | On a canonical Spoke, with `receiveShares = true` a third-party liquidator gets the seized shares credited to its own Spoke position with no vault-token transfer, then borrows against them; LPVaultSwap can never liquidate that account. There, it is blocked only by the reserve flag, which the Aave DAO controls outside Avana's timelock. |
| Impact | Unliquidatable collateral and stranded victim NFTs if the flag were ever enabled on a canonical Spoke. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-222`: the Borrow Spoke is the liquidation-manager Spoke written by Aave Labs. Its `liquidationCall` reverts with `Unauthorized()` for every caller except LPVaultSwap and with `UnsupportedLiquidationCall()` whenever `receiveShares` is true, so no code path credits vault-token shares to a liquidator and the flag has no effect; the flag is still set off at listing and checked by the drift check. A DAO upgrade of the Spoke implementation that removed this code is caught by the on-chain implementation check, which blocks new pledges and borrows (`ATTACK-120`). |
| Status | Resolved in design |
| Verification | `TEST-109`, `TEST-110`, `TEST-114`, `TEST-136`, `TEST-180`, `TEST-182` |

#### FINDING-061: Adapter as an allowed holder can seize collateral

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | Vault token, AaveAdapter, Borrow Spoke |
| Reference | `Q-068`, `Q-092`, `Q-120`, `Q-222`, `Q-223`, `Q-224` |
| Description | Under `Q-068` the upgradeable Adapter was an allowed holder; a hostile Adapter could call `liquidationCall` and receive vault tokens while the victim's backing records stay unchanged. Under `Q-224` the Adapter is again an allowed recipient (it mints, burns and passes tokens through to proxies). |
| Impact | Victims' NFTs stranded; per-proxy backing broken; repeatable griefing. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-222`: the liquidation-manager Borrow Spoke rejects every `liquidationCall` whose caller is not `LIQUIDATION_MANAGER` (LPVaultSwap) with `Unauthorized()`, so being an allowed recipient gives the Adapter no seizure path. The Adapter's remaining custody power (mint, burn, proxy withdrawals) is the trusted-custody scope of `Q-223`, bounded by the 5-day timelock delay with cancellers and recorded as `FINDING-099`. |
| Status | Resolved in design |
| Verification | `TEST-109`, `TEST-180`, `TEST-189`, `TEST-130` |

#### FINDING-062: Hostile Adapter injects an attacker contract into the proxy registry

| Field | Value |
|---|---|
| Source | Design review (attacker round); Formal verification (Quint simulator) |
| Severity | Critical |
| Component | Vault token registry, AaveAdapter |
| Reference | `QNT-T08` (`q068RogueRegistryTest`), `Q-068`, `Q-120`, `Q-224`, `Q-225` |
| Description | Under `Q-068` the Adapter could append to the proxy registry; a registered attacker contract can receive seized tokens, supply them as its own collateral and borrow, and LPVaultSwap can never settle it against backing records. Under `Q-224` the Adapter is again the only registry writer (`addValidProxy`), so the path returns with a hostile Adapter implementation. |
| Impact | Unbacked vault tokens supplied as collateral and borrowed against, with no Collateralization record behind them. |
| Evidence | `quint/avana_tests.qnt` |
| Resolution | Accepted risk. Owner: Avana Labs (AaveAdapter code review and the timelock that upgrades it, `Q-223`, `Q-228`). The reviewed Adapter registers only the ProxyManager's CREATE2 address for `(wallet, spoke)`, at that proxy's first pledge into a market, after `isValidProxy` is false (`Q-225`). Bound: a hostile implementation must pass the 5-day normal delay, during which any canceller (governance multisig, Emergency Guardian, Aave Protocol Guardian, Aave governance executor) can cancel it and every borrower can repay and withdraw; once installed, the units it can mint are bounded by the Hub `addCap` of each vault-token asset and the debt it can draw by each debt reserve's `drawCap` (`FINDING-099`, `ATTACK-125`). |
| Status | Accepted risk |
| Verification | `TEST-188`, `TEST-190`, `TEST-130`, `PROP-055`, `PROP-064` |

#### FINDING-063: Zero-collateral third-party liquidation succeeds

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | Low |
| Component | Borrow Spoke, indexer |
| Reference | `Q-059`, `Q-116`, `Q-144` |
| Description | A `liquidationCall` whose collateral rounds to 0 restores a few wei of debt with no vault-token transfer and succeeds from any caller; the earlier wording "no unauthorized caller can change liquidation state" fails and indexers assuming `liquidator == LPVaultSwap` mis-index. |
| Impact | No value at stake; wrong invariant wording and indexing. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-144`: the proof is stated as "no vault-token movement and no deficit report except via LPVaultSwap". `Q-222`: the liquidation-manager Borrow Spoke rejects every `liquidationCall` not made by LPVaultSwap with `Unauthorized()`, so a zero-collateral third-party liquidation now reverts and every `LiquidationCall` event names LPVaultSwap; Ponder still does not rely on the liquidator field for attribution. |
| Status | Resolved in design |
| Verification | `TEST-109`, `TEST-090`, `TEST-144`, `TEST-180` |

#### FINDING-064: Hostile LPVaultSwap debits a healthy account's records

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | Critical |
| Component | Collateralization, LPVaultSwap |
| Reference | `QNT-T10`, `Q-092`, `Q-125`, `Q-160`, `Q-165`, `Q-224`, `Q-240` |
| Description | A hostile LPVaultSwap liquidates a small account, then asks the custody contracts to release liquidity from a healthy account's records; nothing defined how the immutable contracts verify which proxy was liquidated. |
| Impact | A healthy account's liquidity paid out; its Aave collateral left with no backing. |
| Evidence | `quint/avana_tests.qnt` (`hostileSwapWrongRecordTest`) |
| Resolution | `Q-125`, `Q-160`, `Q-224`, `Q-240`: the immutable Collateralization snapshots the named proxy's supplied shares and the vault token's total supply in `beginSeizure` under the lock; in `settleSeizure` it requires the proxy's share drop, the units the Adapter burned from LPVaultSwap through `burnSeized` and the supply drop to be equal (`DebitMismatch`, `SupplyDropMismatch`) before debiting that proxy's records and having the LPVault remove exactly that liquidity. |
| Status | Resolved in design |
| Verification | `TEST-056`, `TEST-131`, `TEST-208`, `PROP-004`, `PROP-054` |

#### FINDING-065: Faulty RiskModule approves risky borrows

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | RiskModule, AaveAdapter |
| Reference | `Q-093`, `Q-126`, `Q-161`, `Q-228`, `Q-229`, `Q-398` |
| Description | Every borrow-side check (price state, freshness, reserve pauses, drift, health-factor floors) lives in the upgradeable RiskModule (`Q-229`), so an upgrade can turn them off; `Q-093`'s "a hostile policy can only veto" was wrong. |
| Impact | Borrowing against stale or overstated collateral up to the drawCap. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-228`, `Q-229`: a RiskModule implementation changes only through a timelock operation at the 5-day normal delay that any canceller can cancel; since `Q-398` the post-borrow check is `max(1, hardHealthFloor, minHealthFactor)`, with no fixed opening floor; Aave enforces HF ≥ 1 and each `drawCap` on every borrow whatever the RiskModule answers. The residual of a faulty RiskModule implementation is carried as an accepted risk in `FINDING-043`. |
| Status | Resolved in design |
| Verification | `TEST-132`, `TEST-156`, `PROP-031` |

#### FINDING-066: Upgradeable config redirects a proxy's Spoke or debt-asset target

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | Critical |
| Component | AaveAdapter, PositionProxy, Collateralization |
| Reference | `Q-126`, `Q-223`, `Q-225` |
| Description | If the proxy or the Adapter reads its Spoke, reserve ID or debt-asset address from the upgradeable MarketRegistry, a faulty registry points a market or a debt reserve at an attacker contract that takes the repay amount pulled from the payer. |
| Impact | Theft of every repay in flight. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-126`, `Q-225`: each proxy's Spoke is fixed when the ProxyManager initializes it and never rebinds; reserve IDs and debt assets come from the Spoke and Hub at call time; Collateralization takes the market ID, pool and LPOracle from the vault token's immutables, never from the registry. The MarketRegistry only answers approval questions (approved Spoke, approved debt reserve, active market), so a faulty one can refuse or wrongly approve an action but not redirect funds. Repay pulls exactly the repaid amount from the payer to the proxy, the proxy approves the Spoke for that exact amount and refunds anything unconsumed (`Q-223`). |
| Status | Resolved in design |
| Verification | `TEST-030`, `TEST-133`, `TEST-171` |

#### FINDING-067: Upgradeable checks veto repay or debt-free withdrawal

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | AaveAdapter, RiskModule, MarketRegistry |
| Reference | `Q-051`, `Q-093`, `Q-122`, `Q-223`, `Q-227` |
| Description | If repay consults the RiskModule or the pause state, a faulty RiskModule or a stuck pause blocks repay and accounts drift into liquidation. |
| Impact | Borrowers lose the bonus; with a hostile LPVaultSwap the attacker collects it. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-122`, `Q-227`: repay, fee collection, debt-free withdrawal and zero-credit release never call the RiskModule and never read the pause state; fee collection and zero-credit release do not touch the Adapter at all. Repay and debt-free withdrawal run through the AaveAdapter, whose implementation is trusted for custody (`Q-223`); a hostile Adapter upgrade must wait the 5-day normal delay, inside which every borrower can repay and withdraw (`FINDING-099`). |
| Status | Resolved in design |
| Verification | `TEST-132`, `TEST-099`, `TEST-192`, `TEST-195`, `PROP-032`, `PROP-057` |

#### FINDING-068: Compromised Convex rewrites a stored borrow intent

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | Convex, web app |
| Reference | `Q-073`, `Q-106`, `Q-149` |
| Description | Stored intent parameters (receiver, amount, maximum spend) are effectively calldata; an attacker who controls Convex edits them and a user resuming in another tab signs. |
| Impact | Borrowed GHO redirected for every user who resumes a tampered intent. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-149`: Convex stores only intent ID and status; the browser rebuilds calldata from the user's inputs and the bundled manifest, and the wallet shows receiver and amount. |
| Status | Resolved in design |
| Verification | `TEST-145`, `TEST-146` |

#### FINDING-069: Standing approvals to the upgradeable Adapter

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | Web app, AaveAdapter |
| Reference | `Q-093`, `Q-123`, `Q-144`, `Q-223` |
| Description | Under `Q-223` every repayer approves the upgradeable AaveAdapter, which pulls the repay asset to the proxy; a standing allowance left on the Adapter can be drained by a hostile Adapter upgrade, and an NFT approved to the LPVault but not yet pledged can be pledged by it. |
| Impact | Wallet funds beyond the Avana debt at risk. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | Accepted risk. Owner: Avana Labs (web app and Adapter upgrades). The app requests only an exact approval to the Adapter for the amount of the current repay, consumed in the same transaction, and a per-`tokenId` NFT approval to the immutable LPVault immediately before the pledge; it never requests `setApprovalForAll` or an unlimited allowance, and it shows and offers to revoke any leftover Adapter allowance. Bound: a residual allowance is at most the amount the user approved for one repay; a hostile Adapter needs the 5-day normal delay, during which cancellers can cancel it and users can revoke (`Q-228`, `FINDING-099`). |
| Status | Accepted risk |
| Verification | `TEST-147`, `TEST-029`, `TEST-130` |

#### FINDING-070: Fake backing through an upgradeable pool-to-token map

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | Critical |
| Component | Collateralization, AaveAdapter |
| Reference | `Q-092`, `Q-126`, `Q-224`, `Q-240` |
| Description | A faulty MarketRegistry maps a worthless full-range pool to a valuable market's vault token, and that token is minted against it. |
| Impact | Borrowing against fake collateral. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-126`, `Q-224`, `Q-240`: the immutable Collateralization credits a pledge only if the vault token is bound to it (`collateralization()`), the factory-derived pool equals the immutable `vaultToken.pool()` and the range is full; it takes the market ID and LPOracle for the pledge check from the vault token's immutable `marketId()` and `lpOracle()`, so a faulty registry cannot attach a pledge to another market's checks or oracle; the Adapter mints exactly the credited units it returns. |
| Status | Resolved in design |
| Verification | `TEST-011`, `TEST-133`, `TEST-171`, `TEST-186`, `PROP-006`, `PROP-054` |

#### FINDING-071: Zero-credit record treated as stray

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | Medium |
| Component | LPVault, Collateralization |
| Reference | `Q-104`, `Q-134`, `Q-228` |
| Description | If a fully seized record is closed, the NFT looks uncredited and the governance stray-NFT return could take it with the depositor's fees and donated liquidity; fee collection also required an active record. |
| Impact | Loss of the depositor's fees and residual liquidity after a governance mistake or compromise. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-134`: the record stays open at 0 credited units in Collateralization and the NFT stays in LPVault custody under its depositor of record; only the depositor can collect fees (`LPVault.collectFees`) and release it (`Collateralization.releaseZeroCredit`). `Q-104`, `Q-228`: `returnStrayNft` is a timelock operation at the normal delay and moves only a stray NFT, one the LPVault holds with no depositor of record, so a zero-credit record is never touched. |
| Status | Resolved in design |
| Verification | `TEST-015`, `TEST-020`, `PROP-003`, `PROP-038` |

#### FINDING-072: Settlement budget drained by route sandwiching

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | LPVaultSwap, SettlementBudget (removed, `Q-397`) |
| Reference | `Q-117`, `Q-127`, `Q-159`, `Q-167`, `Q-190`, `Q-235`, `Q-236`, `Q-397` |
| Description | A builder or keeper pushes a route pool, or the debt buy route of a non-GHO liquidation, so proceeds land just above the recovery floor but below flash repayment; the budget covered the gap and the attacker back-ran. |
| Impact | Before `Q-397`: budget drained on every liquidation, then liquidations needing it reverted. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | Resolved by removal (`Q-397`): no SettlementBudget exists, so a sandwich that pushes proceeds below repayment makes the call revert `RecoveryBelowFloor` unless the caller pays the gap from its own funds through the shortfall top-up, capped by `maxShortfall`; no Avana fund pays it. `Q-159`: the multiplicative effective slippage makes the floor alone cover repayment, and every swap leg runs with its per-leg oracle `minOut` (`INV-083`). |
| Status | Resolved in design |
| Verification | `TEST-050`, `TEST-078`, `TEST-059`, `TEST-197`, `TEST-200`, `PROP-015`, `PROP-020`, `PROP-063` |

#### FINDING-073: Keeper forces the in-kind fallback

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | LPVaultSwap in-kind (removed, `Q-401`), MarketRegistry |
| Reference | `Q-084`, `Q-133`, `Q-163`, `Q-227`, `Q-228`, `Q-401` |
| Description | If in-kind is entered on a caught route failure, a keeper starves the inner call of gas or fills the GSM inside its bundle to take the whole bonus in kind and skip Avana's fee and the floor. |
| Impact | Loss of Avana's fee and of the recovery-floor protection. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | Resolved by removal (`Q-401`): in-kind settlement no longer exists, so no keeper can enter it by starving a call of gas or by moving a pool. With every route failing, a liquidation reverts `NoRouteAvailable`, and Avana's fee and the recovery floor apply to every liquidation that completes. Earlier rule, superseded: in-kind was enabled only by a timelock operation (`Q-133`, `Q-163`, `Q-228`). |
| Status | Resolved in design |
| Verification | `TEST-053`, `TEST-194`, `PROP-021` |

#### FINDING-074: Per-leg unwind minimums re-create a spot-price veto

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | Medium |
| Component | LPVault liquidation |
| Reference | `Q-085`, `Q-131` |
| Description | Per-token `amount0Min`/`amount1Min` from the oracle let a borrower or builder move the pool spot past the tolerance and make `decreaseLiquidity` revert repeatedly. |
| Impact | Liquidation griefing. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-131`: liquidity is removed with zero per-token minimums; the only floor is total GHO recovered. |
| Status | Resolved in design |
| Verification | `TEST-047`, `TEST-116` |

#### FINDING-075: One-wei donation bricks repay or liquidation

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | PositionProxy, LPVaultSwap |
| Reference | `Q-097`, `Q-124` |
| Description | Zero-balance assertions ("the proxy holds 0 GHO after", "LPVaultSwap ends with zero balance") fail forever after a one-wei transfer to the contract. |
| Impact | A victim cannot repay or exit; or every liquidation halts. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-124`: contracts check before/after deltas, never absolute balances; dust is ignored and there is no sweep role. |
| Status | Resolved in design |
| Verification | `TEST-080`, `TEST-092`, `PROP-016` |

#### FINDING-076: Liquidation shield through a top-up into a degraded market

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | RiskModule pledge gates, LPVaultSwap |
| Reference | `Q-087`, `Q-118`, `Q-121`, `Q-128`, `Q-132` |
| Description | A borrower tops up a minimum NFT into an Expired market; under the most-restrictive rule the whole account becomes unliquidatable and Aave values the stale market at its last price. |
| Impact | One small NFT freezes liquidation of an arbitrarily large account. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-121` and `Q-132`: top-ups only into Live or Drifting markets; `Q-128`: staleness is per account but a late top-up cannot create it. The pre-positioning residual is `FINDING-094`. |
| Status | Resolved in design |
| Verification | `TEST-012`, `TEST-102` |

#### FINDING-077: Grace latch re-triggered by a caught feed failure

| Field | Value |
|---|---|
| Source | Design review (attacker round and decision check); Formal verification (Quint simulator) |
| Severity | High |
| Component | LPOracle grace latch |
| Reference | `QNT-T12` (`graceReadLatchMissTest`), `Q-088`, `Q-129`, `Q-154` |
| Description | If any caught error sets the Expired flag, an attacker calls `poke()` with a gas limit that makes the reads fail and restarts the grace period at will; conversely a read-based latch misses an outage with no read in between. |
| Impact | Accounts between the grace HF and 1 shielded from liquidation indefinitely, or no grace after a real outage. |
| Evidence | `quint/avana_tests.qnt` |
| Resolution | `Q-154`: Expired is flagged only from source timestamps on both routes, never from a caught error; `poke()` requires `pokeMinGas`; `recoveredAt` is the first fresh update; one grace window per outage. |
| Status | Resolved in design |
| Verification | `TEST-042`, `TEST-049` |

#### FINDING-078: Cap filling blocks rescue top-ups

| Field | Value |
|---|---|
| Source | Design review (attacker round and decision check) |
| Severity | High |
| Component | RiskModule caps, ParameterStore, Collateralization |
| Reference | `Q-150`, `Q-157`, `Q-227`, `Q-230`, `Q-396` |
| Description | Debt-free pledges across sybil wallets fill the caps at near-zero cost; borrowers then cannot top up in a price drop. A slice open to any indebted account is filled by wallets borrowing the minimum. |
| Impact | Borrowers liquidated who could have rescued themselves. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-150`: a `topUpSliceUsd` slice (ParameterStore) reserved for top-ups of indebted accounts; `Q-157`: usable only while the account's HF is below `rescueHealthFactor` (1.10) and only up to the amount that restores it; Collateralization books the charge the RiskModule returns. `Q-227`: Frozen still allows top-ups of indebted accounts. `Q-230`: every pledge is worth at least `minPledgeUsd` ($10), which prices each sybil pledge but does not by itself stop cap filling; the slice keeps rescue top-ups open. Cap squatting by debt-free LPs outside the slice is an accepted risk (`FINDING-232`, `Q-396`). |
| Status | Resolved in design |
| Verification | `TEST-013`, `TEST-097`, `TEST-196` |

#### FINDING-079: Recovery multisig used as an instant loosen key

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | Pause state, governance |
| Reference | `Q-083`, `Q-137`, `Q-138`, `Q-156`, `Q-206`, `Q-227`, `Q-228` |
| Description | A compromised Recovery multisig instantly lifts a Guardian borrow pause on a depegging market and borrows in the same bundle; who clears quarantines was unstated. |
| Impact | Borrowing against a known-bad market. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | Superseded by `Q-227` and `Q-228`: the Recovery multisig, GuardianRestrictions, quarantine and per-function pauses no longer exist. The only emergency switch is the MarketRegistry pause state; `unfreeze` and `unpause` need `APPLICATION_PAUSE_GUARDIAN` (Emergency Guardian 3-of-5, Aave Protocol Guardian) or `APPLICATION_ADMIN`, and neither guardian holds any parameter or upgrade power, so lifting a state only returns to the values the timelock set; every loosening is a normal-delay (5-day) timelock operation any canceller can cancel. Residual: a compromised pause guardian unfreezes during a depeg and borrowing resumes. Bound: borrowing still passes the RiskModule's price-state, freshness and health-factor gates; per-market containment is an Aave reserve freeze, which only Aave lifts; the other pause guardian can freeze again at once. |
| Status | Resolved in design |
| Verification | `TEST-066`, `TEST-192`, `PROP-041`, `PROP-057` |

#### FINDING-080: Exploit waits out the Guardian incident deadline

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | Medium |
| Component | Pause state |
| Reference | `Q-083`, `Q-138`, `Q-206`, `Q-164`, `Q-227` |
| Description | If every Guardian restriction expires, an exploit path disabled by the Guardian reopens automatically when the extender is slow. |
| Impact | Exploit resumes after the deadline. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | Superseded by `Q-227`: the incident clock and its deadline no longer exist. Frozen and Paused have no expiry and persist until `unfreeze` or `unpause` by `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`, so a disabled path never reopens by itself. Persistence costs no liveness, because liquidation, repay, fee collection and debt-free withdrawal stay open in every pause state. |
| Status | Resolved in design |
| Verification | `TEST-065`, `TEST-101`, `TEST-192` |

#### FINDING-081: Short-delay tightening halts liquidations

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | ParameterStore, AvanaTimelock |
| Reference | `Q-114`, `Q-139`, `Q-209`, `Q-210`, `Q-228` |
| Description | A compromised governance multisig schedules tightening setters that make every liquidation fail (slippage allowance, grace HF, TWAP tolerance); they run at the 12-hour short delay, while loosening back waits the 5-day normal delay. |
| Impact | Liquidations halted for days while bad debt grows. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-139`, `Q-209`, `Q-210`: the ParameterStore's on-chain liveness bounds ensure every allowed value still lets liquidations run: the slippage allowance never below the market's `slippageAllowanceMinBps` (set at listing, normal delay), the grace HF never below `graceHealthFactorMin` = 0.90, the grace duration never above `graceDurationMax` = 7,200 s, and the TWAP tolerance never below `twapToleranceMinTicks` = 10 ticks; record limits no longer exist (`Q-194`). `Q-228`: each tightening is a timelock operation that any canceller can cancel during its 12 hours. Example: from the launch values, a compromised proposer can move the TWAP tolerance from 50 ticks down to 10 ticks at the lowest, the grace HF from 0.95 down to 0.90 at the lowest and the grace window from 30 minutes up to 2 hours at the longest; in each case accounts below HF 0.90 stay liquidatable and a reference liquidation still settles (`TEST-064`). |
| Status | Resolved in design |
| Verification | `TEST-064`, `TEST-194`, `PROP-042` |

#### FINDING-082: Keeper wipe including the standby

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | LPVaultSwap keeper list |
| Reference | `Q-082`, `Q-139`, `Q-155`, `Q-213`, `Q-228`, `Q-400` |
| Description | Keeper removal is fast (12-hour short delay) and re-adding takes the 5-day normal delay; removing every keeper including the standby would halt keeper liquidation. |
| Impact | No liquidations until keepers are re-added. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-139`, `Q-155`: `removeKeeper` cannot go below `keeperFloor`, 1 active keeper (Avana's own, `Q-400`), out of at most `MAX_KEEPERS` = 32 per chain; more keepers can be added at the normal delay, and new borrowing halts only when 0 active keepers remain. `Q-213`: `liquidatePermissionless` lets anyone liquidate with their own debt asset even with no approved keeper. |
| Status | Resolved in design |
| Verification | `TEST-045`, `TEST-098`, `TEST-174`, `PROP-035` |

#### FINDING-083: Malicious route installed on the short delay

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | High |
| Component | Settlement routes, debt buy routes, MarketRegistry |
| Reference | `Q-062`, `Q-151`, `Q-228`, `Q-235` |
| Description | If route changes ran at a short delay, a hostile settlement, buy or sell-back route would go live faster than borrowers can exit and capture slippage on every liquidation. |
| Impact | Value extraction from every liquidation. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | `Q-151`, `Q-228`: `setRoute`, `setBuyRoute` and `setSellBackRoute` are MarketRegistry operations at the 5-day normal delay, cancellable by any canceller; `disableRoute` and `disableBuyRoute` run at the 12-hour short delay; `restoreRoute` and `restoreBuyRoute` run at the short delay only for a route previously approved at the normal delay. |
| Status | Resolved in design |
| Verification | `TEST-054`, `TEST-063`, `TEST-194` |

#### FINDING-084: Keeper reimbursement farming

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | Low |
| Component | Keeper agreement |
| Reference | `Q-098`, `Q-115` |
| Description | A keeper that is also a builder inflates the priority fees it pays itself and claims reimbursement. |
| Impact | Overpayment from the reimbursement budget. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | Accepted risk. Avana's own approved keepers liquidate every account whatever its size, and Avana pays their gas as its own operating cost (`Q-381`); no external keeper is reimbursed, and liquidation never depends on a keeper's profit. With no reimbursement claim, a builder can only delay inclusion of Avana's keeper transactions; Avana caps the priority tip per transaction and sends through private order flow to several builders. Owner: Avana Labs (keeper operations). Bound: the tip cap per transaction. |
| Status | Accepted risk |
| Verification | `TEST-141` |

#### FINDING-085: Web bundle or manifest swapped in the supply chain

| Field | Value |
|---|---|
| Source | Design review (attacker round) |
| Severity | Medium |
| Component | Web app, release manifest |
| Reference | `Q-073`, `Q-115`, `Q-223` |
| Description | A tampered release swaps the LPVault or AaveAdapter address so users approve their NFT or their repay asset to an attacker. |
| Impact | Theft of NFTs and repay amounts approved through the tampered app. |
| Evidence | Attack sequence in Description; reproduced by the Verification tests |
| Resolution | Accepted risk. Owner: Avana Labs (release process). Every release manifest is validated against its schema and against the deployed addresses on-chain, then approved before publication; the browser builds calldata only from that bundled manifest (`Q-043`, `Q-073`), and before requesting an approval the app checks key addresses on-chain (`vaultToken.adapter()`, `vaultToken.collateralization()`, the LPVault bound to Collateralization). Bound: NFTs and repay amounts approved through a tampered release before the on-chain address check or the release review detects it; each NFT approval covers one `tokenId` and each Adapter approval one repay amount. |
| Status | Accepted risk |
| Verification | `TEST-146`, `TEST-149`, `TEST-134` |

### E. Design review: decision check

#### FINDING-086: Keeper grants through grantDelay cannot be cancelled

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | High |
| Component | AvanaTimelock, LPVaultSwap keeper list |
| Reference | `Q-136`, `Q-155`, `Q-228` |
| Description | OpenZeppelin `cancel` reaches only scheduled operations; a `grantRole` with a `grantDelay` executes at once and only delays membership, so neither the DAO nor the Guardian can cancel it; the DAO also reacts slower than the keeper delay. |
| Impact | A compromised Avana multisig adds keepers or operational roles with no possible veto. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Superseded by `Q-228`: the AccessManager and its `grantDelay` no longer exist. `addKeeper` is a timelock operation at the 5-day normal delay that any canceller can cancel; every role grant or revocation on an Avana contract is a role-change operation at the normal delay, cancellable only by `DAO_CANCELLER_ROLE` (the Aave governance executor), so neither the governance multisig nor a guardian can grant itself power or block its own removal. The governance multisig only proposes and cancels; it has no immediate power. |
| Status | Resolved in design |
| Verification | `TEST-045`, `TEST-067`, `TEST-194`, `PROP-035`, `PROP-058` |

#### FINDING-087: Recovery alone can quarantine every keeper

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | High |
| Component | LPVaultSwap keeper list, governance |
| Reference | `Q-137`, `Q-138`, `Q-139`, `Q-156`, `Q-206`, `Q-213`, `Q-227` |
| Description | Under `Q-137` Recovery alone set quarantines cleared only by the timelock, so a compromised Recovery could halt liquidation for at least the timelock delay. |
| Impact | Liquidation halt with no independent check. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Superseded by `Q-227`: the Recovery multisig and quarantine no longer exist. Keepers leave only through `removeKeeper`, a 12-hour short-delay timelock operation that cannot go below `keeperFloor` (`Q-139`); the pause state never stops liquidation; and `liquidatePermissionless` keeps liquidation open to anyone with GHO even with no approved keeper (`Q-213`). |
| Status | Resolved in design |
| Verification | `TEST-045`, `TEST-098`, `TEST-174`, `TEST-192` |

#### FINDING-088: Exits still call the upgradeable RiskModule

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | High |
| Component | Collateralization, RiskModule |
| Reference | `Q-055`, `Q-109`, `Q-122`, `Q-158`, `Q-209`, `Q-240` |
| Description | Debt-free withdrawals and liquidation debits decremented cap counters in the upgradeable RiskModule, so a faulty RiskModule could revert exits and liquidation. |
| Impact | Exits and liquidation blocked by an upgrade. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | `Q-158`, `Q-240`: the immutable Collateralization keeps and decrements the cap counters with saturating math, and exits never call the RiskModule. `Q-209`: at pledge the RiskModule computes the cap charge (from the LPOracle, split into regular and top-up slice) with the current counters Collateralization passes as arguments; Collateralization books the result after custody in the same transaction. |
| Status | Resolved in design |
| Verification | `TEST-014`, `TEST-132`, `PROP-032` |

#### FINDING-089: Served price undefined while feeds disagree

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Medium |
| Component | LPOracle, LPVaultSwap |
| Reference | `Q-112`, `Q-128`, `Q-162`, `Q-183`, `Q-199`, `Q-208` |
| Description | With both routes fresh but disagreeing, Drifting let Aave liquidate at served prices without saying which route is served, and the TWAP test was gone. |
| Impact | A malfunctioning primary showing a depeg liquidates healthy accounts at the full bonus. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | `Q-162`: liquidation of every account holding that market pauses while the routes disagree; borrowing stays blocked. `Q-199`: the pause starts at the first disagreement stored by `poke()` or a successful Avana call (keepers poke every heartbeat) and lasts at most `disagreementPauseMax`. `Q-208`: a disagreement that persists past `disagreementPauseMax` makes the market Expired for liquidation (`INV-059`), so no route is ever served for liquidation while the routes disagree; repay and debt-free withdrawal stay open. |
| Status | Resolved in design |
| Verification | `TEST-044`, `TEST-049`, `TEST-157`, `TEST-159`, `PROP-022`, `PROP-049` |

#### FINDING-090: In-kind enable authority and speed unstated

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Medium |
| Component | LPVaultSwap in-kind (removed, `Q-401`), MarketRegistry |
| Reference | `Q-133`, `Q-163`, `Q-206`, `Q-227`, `Q-228`, `Q-401` |
| Description | `Q-133` said governance enables in-kind after observed route failure without naming the role or delay; as a loosening it would wait the normal delay. |
| Impact | A market with both routes failed could not be liquidated for days. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Resolved by removal (`Q-401`): in-kind settlement and `enableInKind` no longer exist. A market whose routes fail is repaired by `useStandbyRoute` (short delay) or a route change; the caller's shortfall top-up covers route losses up to `maxShortfallBps`; and a guardian freezes new borrowing on the market once monitoring confirms the approved routes cannot settle valid liquidations at the required size (`Q-399`). Losses while the routes are down fall within the incident window the caps are sized for (`Q-192`). |
| Status | Resolved in design |
| Verification | `TEST-053`, `TEST-194`, `PROP-021` |

#### FINDING-091: Paused state blocks rescue top-ups

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Medium |
| Component | MarketRegistry pause state |
| Reference | `Q-136`, `Q-138`, `Q-164`, `Q-206`, `Q-227`, `Q-228`, `Q-252` |
| Description | A persisting pledge restriction also blocks risk-reducing top-ups; under `Q-227` Paused blocks every pledge including top-ups of indebted accounts, and a rogue pause guardian could keep pausing. |
| Impact | A rogue pause guardian keeps top-ups blocked until its role is removed. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | `Q-252` (`FINDING-159`): `pause(reason)` carries a reason; under `Paused(General)` a rescue top-up of an indebted account below `rescueHealthFactor` (1.10), with a charge no larger than its restore amount, still completes, and only `Paused(MintPathSuspect)`, the state for a suspect minting path, refuses every pledge. Changed rules: `INV-026`, `INV-067`, `REQ-MREG-024`, `REQ-ADAPTER-083`, `REQ-RISK-066`. Earlier bound, still in force for `MintPathSuspect`: the pause-guardian holders (Emergency Guardian 3-of-5, Aave Protocol Guardian) and Avana Labs own it. Frozen, the state for containing new risk, still allows top-ups of indebted accounts (`Q-164`, `Q-227`). Under Paused, repay, debt-free withdrawal and liquidation stay open, so a borrower can still rescue by repaying. Bound: the other pause guardian unpauses at once, or `APPLICATION_ADMIN` through a timelock operation at the normal delay; a guardian that keeps pausing loses its role through a role-change operation at the 5-day normal delay, which only the Aave governance executor can cancel (`Q-228`). |
| Status | Resolved in spec |
| Verification | `TEST-012`, `TEST-065`, `TEST-192`, `TEST-235`, `PROP-057` |

#### FINDING-092: Recipient-only transfer rule lets a hostile LPVaultSwap supply seized tokens

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Medium |
| Component | Vault token, LPVaultSwap |
| Reference | `Q-120`, `Q-165`, `Q-222`, `Q-224`, `ATTACK-137` |
| Description | Under `Q-224` the vault token checks only the recipient, and the Hub is an allowed recipient for any sender. LPVaultSwap receives seized vault tokens from the Hub in `liquidationCall`; a hostile LPVaultSwap implementation could, instead of having the Adapter burn them (`burnSeized`), call `Spoke.supply` for itself, so the Spoke's `transferFrom` moves them to the Hub, and borrow against them. The pair rule of `Q-120` that closed this earlier is gone. |
| Impact | Collateral with no Collateralization record, outside Avana's settlement; borrowing against it up to the debt reserves' `drawCap`; the victims' records left until reconcile on exit. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Accepted risk. Owner: Avana Labs (LPVaultSwap code review and the timelock that upgrades it). The reviewed LPVaultSwap has no supply or borrow path and has the Adapter burn every seized unit in the same call (selector inventory). Bound: a hostile implementation must pass the 5-day normal delay, cancellable by any canceller, during which borrowers can exit; it can obtain units only through `liquidationCall` as `LIQUIDATION_MANAGER` on accounts Aave deems liquidatable, with Aave's sizing (`Q-222`); reconcile on exit keeps each victim's remaining NFTs releasable and the outstanding units backed by the pending-settlement balance (`Q-201`); borrowing against the supplied units is bounded by each debt reserve's `drawCap`. |
| Status | Accepted risk |
| Verification | `TEST-189`, `TEST-131`, `TEST-154` |

#### FINDING-093: Reserve ID cannot be a vault-token immutable

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Informational |
| Component | Vault token, AaveAdapter, PositionProxy |
| Reference | `Q-126` |
| Description | The vault token is deployed before `Spoke.addReserve`, so it cannot store the reserve ID. |
| Impact | An implementation that reads the reserve ID from config would reopen `FINDING-066`. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Reserve IDs are derived at call time from immutables with `Hub.getAssetId(token)` and `Spoke.getReserveId(hub, assetId)`; the Adapter passes the derived ID to the proxy, and the MarketRegistry's record is compared with it by the drift check, never used in its place. |
| Status | Resolved in design |
| Verification | `TEST-030` |

#### FINDING-094: Minimum NFT in a stale-prone market shields the whole account

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Medium |
| Component | LPVaultSwap price gates, listing |
| Reference | `Q-128`, `Q-182`, `Q-230`, `Q-234`, `Q-247` |
| Description | Because staleness blocks liquidation of the whole account, a borrower can pre-position a minimum NFT (worth at least `minPledgeUsd`, $10) in a market whose feed goes stale more often; `Q-132` blocks only late top-ups. A debt reserve whose feed goes stale has the same effect on every account holding it (`FINDING-101`). |
| Impact | Liquidation of the whole account delayed while that market is Cached or Expired. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | `Q-247` (`FINDING-134`): liquidation needs fresh prices only for the market it seizes and the debt reserve it repays, and a stale market counts in Aave's health factor at no more than its accepted price (1 once Expired), so a minimum NFT in a stale market no longer delays liquidation of the account's other markets; only that market's own seizure waits for a fresh price or a standby switch (`Q-248`). Changed rules: `INV-030`, `INV-072`, `INV-075`, `INV-087`. |
| Status | Resolved in spec |
| Verification | `TEST-049`, `TEST-139`, `TEST-196`, `TEST-226`, `TEST-230` |

#### FINDING-095: Compromised keeper at the floor cannot be revoked at once

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Low |
| Component | LPVaultSwap keeper list |
| Reference | `Q-139`, `Q-155`, `Q-156`, `Q-228`, `Q-400` |
| Description | At `keeperFloor` a compromised keeper cannot be removed until a replacement is added through a normal-delay timelock operation. |
| Impact | A compromised keeper can keep liquidating within the rules for that period. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Accepted risk. Owner: Avana Labs (keeper list, proposed through the governance multisig). Bound: for at most the 5-day normal delay of `addKeeper` plus the 12-hour short delay of `removeKeeper`, every liquidation the keeper runs is limited by the recovery floor, the effective slippage and the per-leg oracle `minOut` (`Q-139`, `Q-155`, `Q-196`); with no SettlementBudget (`Q-397`) the keeper spends only its own funds and no Avana fund pays it. At `keeperFloor` 1 (`Q-400`) the floor is Avana's own keeper, so the remedy is to add a replacement key and then remove the compromised one. |
| Status | Accepted risk |
| Verification | `TEST-045`, `TEST-050`, `TEST-200` |

#### FINDING-096: Callbacks arrive from non-Avana addresses while the lock is held

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Medium |
| Component | Lock contract, LPVaultSwap |
| Reference | `Q-045`, `Q-148`, `Q-223`, `Q-235` |
| Description | The FlashMinter's `onFlashLoan` and Uniswap or Curve swap callbacks of settlement, buy and sell-back routes come from non-Avana addresses during a locked call; a literal "only from the fixed set" rule (AaveAdapter, Collateralization, LPVault, LPVaultSwap) would reject them. |
| Impact | Every flash-funded or routed liquidation would revert. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | The FlashMinter's `onFlashLoan` and the swap callbacks of route pools, including the pools of debt buy and sell-back routes, are exempt from the fixed-set rule and keep their own caller checks: `onFlashLoan` accepts only the GHO FlashMinter with LPVaultSwap as initiator, and a Uniswap or Curve callback accepts only the pool fixed in the route (factory-derived for Uniswap) (`Q-045`, `Q-148`, `Q-235`). |
| Status | Resolved in design |
| Verification | `TEST-046`, `TEST-060`, `TEST-197`, `PROP-036`, `PROP-037` |

#### FINDING-097: Recovery can restore a route disabled for cause

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Low |
| Component | Settlement routes, debt buy routes, governance |
| Reference | `Q-151`, `Q-156`, `Q-206`, `Q-227`, `Q-228` |
| Description | "Restore a previously approved route instantly via Recovery" includes routes disabled because they were bad. |
| Impact | A compromised Recovery restores a known-bad route. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Superseded by `Q-227` and `Q-228`: the Recovery multisig no longer exists. `restoreRoute` and `restoreBuyRoute` are timelock operations at the 12-hour short delay, proposed by the governance multisig and cancellable by any canceller (governance multisig, Emergency Guardian, Aave Protocol Guardian, Aave governance executor), and only for a route previously approved at the normal delay. Residual: a restored route that was disabled for cause; bound: the 12-hour cancellation window, and each liquidation through it must still meet the recovery floor `minGho`, so it costs at most the effective slippage per liquidation until `disableRoute` runs again. |
| Status | Resolved in design |
| Verification | `TEST-054`, `TEST-066`, `TEST-194` |

#### FINDING-099: Adapter implementation holds custody power over every proxy position

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | High |
| Component | AaveAdapter, PositionProxy, vault token |
| Reference | `Q-223`, `Q-224`, `Q-226`, `Q-228`, `ATTACK-122`, `ATTACK-124`, `ATTACK-125` |
| Description | Under `Q-223` the AaveAdapter executes every borrower action: it is the only caller every PositionProxy accepts, the only minter, burner and registry writer of every vault token, and the spender of every repay allowance. Its implementation is upgradeable (UUPS, `Q-226`). |
| Impact | A faulty or hostile Adapter implementation can borrow every debt reserve against every proxy up to each `drawCap`; withdraw supplied vault tokens; mint vault tokens to the Hub, itself or any registered proxy (bounded by the Hub `addCap`); burn any holder's vault tokens, including the Hub's; register any address as a proxy; spend allowances granted to the Adapter; pledge any NFT whose owner approved the LPVault. It cannot send an NFT to anyone but its depositor of record, change `LIQUIDATION_MANAGER`, raise any Aave cap or spend a First-Loss Reserve. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Accepted risk. Owner: Avana Labs (Adapter code review and audits) and the timelock signers. Bound: an Adapter upgrade is a timelock operation at the 5-day normal delay, which the governance multisig, the Emergency Guardian, the Aave Protocol Guardian or the Aave governance executor can cancel (`Q-228`); repay and debt-free withdrawal never read the pause state, so a borrower who repays every debt reserve and withdraws each NFT (one call per NFT) leaves well inside the delay; draws are capped by each debt reserve's `drawCap` and mints by the Hub `addCap`. |
| Status | Accepted risk |
| Verification | `TEST-130`, `TEST-195`, `TEST-194`, `TEST-214` |

#### FINDING-100: One beacon upgrade changes every PositionProxy at once

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | High |
| Component | ProxyManager (beacon), PositionProxy |
| Reference | `Q-225`, `Q-226`, `Q-228`, `ATTACK-123` |
| Description | Every PositionProxy is an OpenZeppelin `BeaconProxy` whose beacon is the ProxyManager; `setProxyImplementation` replaces the code of every proxy in one call, with no per-proxy opt-out (`Q-225`). |
| Impact | A faulty proxy implementation affects every account on every Borrow Spoke at the same moment; a hostile one acts on every position with the Adapter's custody power (`FINDING-099`). |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Accepted risk. Owner: Avana Labs (proxy implementation review) and the timelock signers. Bound: `setProxyImplementation` and the ProxyManager's own upgrade need `APPLICATION_ADMIN`, held only by the timelock, at the 5-day normal delay with every canceller able to cancel (`Q-228`); a new implementation still accepts calls only from the Adapter, cannot rebind a proxy and has no transfer path for the NFT, which stays in LPVault custody and returns only to its depositor of record; borrowers can exit inside the delay. |
| Status | Accepted risk |
| Verification | `TEST-191`, `TEST-210`, `TEST-187`, `PROP-064` |

#### FINDING-101: A stale debt-asset feed blocks liquidation of every account holding that debt

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Medium |
| Component | LPVaultSwap price gates, RiskModule, debt-reserve listing |
| Reference | `Q-128`, `Q-234`, `Q-238`, `Q-247`, `Q-248`, `ATTACK-129` |
| Description | LPVaultSwap requires every debt feed of the account within `liquidationPriceMaxAge` (`Q-238`), and staleness of any reserve blocks liquidation of the whole account (`Q-234`). A stalled Chainlink feed of one non-GHO debt asset therefore stops liquidation of every account that holds that debt, in every market. |
| Impact | Liquidation of every account holding the stale debt is delayed until the feed updates; borrowing and withdraw-with-debt for those accounts stop as well. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Accepted risk, narrowed by `Q-247` and `Q-248`: only liquidations that repay the stale reserve wait; a liquidation of the same account that repays another reserve proceeds, with the stale debt counted at no less than its accepted price (its stress price once Expired), and each debt asset's DebtOracle fails over to its alternate route and can be switched to its standby by a guardian. Owner: Avana Labs and the Aave V4 risk service providers (debt-reserve listing). A debt reserve is listed only with a feed that meets the required update cadence (`Q-182`, `Q-233`, `Q-274`); GHO uses Aave's fixed source, which has no age. Bound: repayment of the stale reserve resumes with the next fresh round or the standby switch; losses in the meantime are inside caps sized with the pause-loss bound over the 48-hour incident window, which includes a debt-price term (`Q-192`). |
| Status | Accepted risk |
| Verification | `TEST-201`, `TEST-049`, `TEST-139`, `TEST-230`, `TEST-231` |

#### FINDING-102: A debt-asset price rally makes stable-LP accounts liquidatable together

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Medium |
| Component | Debt-reserve listing, caps, LPVaultSwap buy leg |
| Reference | `Q-192`, `Q-233`, `Q-234`, `Q-235`, `ATTACK-128` |
| Description | Stable LP collateral does not move with WETH. If WETH is a debt reserve, a WETH rally raises every WETH-indebted account's debt value at once and can push many of them below HF 1 together, while each liquidation must buy WETH through the buy leg in the same market move. |
| Impact | A cluster of liquidations that all buy the rallying asset, with buy-route depth and slippage at their worst; losses beyond the First-Loss Reserve of that asset if caps ignore the rally. Example: an account with $10,000 of stable LP at CF 0.80 and $6,800 of WETH debt has HF 1.176; a 25 % WETH rise makes the debt $8,500 and HF 0.94. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Launch condition. Condition: a non-GHO debt reserve gets a `drawCap` above 0 only after both legs of its liquidation (buy and sell-back) pass stress validation at the depth needed for a rally scenario, its `buySlippageAllowanceBps` and `buyRouteDepthThresholdGho` are set, its First-Loss Reserve is funded to its minimum, and caps are sized with the debt-price term of the pause-loss bound (`Q-192`, `Q-233`, `Q-235`). Who: the Aave V4 risk service providers and Avana Labs at the debt-reserve listing. |
| Status | Launch condition |
| Verification | `TEST-202`, `TEST-197`, `TEST-127`, `TEST-139` |

#### FINDING-103: Buy-leg cost could be billed to the settlement budget

| Field | Value |
|---|---|
| Source | Design review (decision check) |
| Severity | Medium |
| Component | LPVaultSwap, SettlementBudget (removed, `Q-397`), debt buy routes |
| Reference | `Q-127`, `Q-235`, `Q-236`, `ATTACK-126`, `ATTACK-127`, `Q-397` |
| Description | In a non-GHO liquidation the keeper chooses `maxGhoSpend` and the buy route spends GHO; if the waterfall had drawn the budget for any shortfall, a keeper or builder could inflate the GHO spent (sandwiching the buy route, or over-sizing `debtToCover` so that unspent debt asset is sold back at a loss) and bill the difference to the SettlementBudget. |
| Impact | Before the fixes: the budget drained through inflated buy-leg costs, and later liquidations that needed it reverted. |
| Evidence | Decision conflict in Description; confirmed by the Verification tests |
| Resolution | Resolved by removal: settlement has no buy leg (every liquidation settles in the debt asset it repays, `INV-070`, `Q-333`) and the SettlementBudget no longer exists (`Q-397`), so no buy-leg cost and no budget draw remain to inflate; the caller sizes `debtToCover` and its funding (flash principal, exact premium and `callerFunds`) for the repayment Aave V4's dust rule may require, and pays any rounding gap at final settlement through its shortfall top-up, bounded by `maxShortfall` (`INV-034`). Earlier fix, superseded: a bound on the GHO spent (`GhoSpendTooHigh`, `Q-235`) and capped draws (`Q-236`). |
| Status | Resolved in design |
| Verification | `TEST-197`, `TEST-198`, `TEST-200`, `PROP-059`, `PROP-063` |

### F. Formal verification, risk review and user simulation

#### FINDING-104: An unsettled seized-unit burn blocks every pledge and withdrawal of a market

| Field | Value |
|---|---|
| Source | Formal verification (custody contracts) |
| Severity | Medium |
| Component | AaveAdapter backing check, Collateralization, vault token |
| Reference | `Q-224`, `Q-257` |
| Description | `burnSeized` checks only the caller, the Lock holder, the market and `units > 0`; nothing ties it to a later `settleSeizure` or `settlePending`. A non-conforming LPVaultSwap can have seized units burned and never settle them. The Adapter's absolute check `totalSupply == totalCredited + pending.units` then fails for every later call. Example: two NFTs of 5,000,000,000 and 4,000,000,000 units; an orphan burn of 1,575,000,000; the depositor repays and withdraws the 4,000,000,000-unit NFT, and the check `3,425,000,000 == 3,425,000,000 + 1,575,000,000` reverts `BackingMismatch`. |
| Impact | Every pledge and withdrawal of the market reverts, debt-free exits included, until an Adapter upgrade lands after the normal delay; no conforming call restores the equality. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-257`: the backing check is one-sided and keeps the market's backing gap. After every pledge, withdrawal, partial removal, re-credit and repay with collateral the Adapter requires `totalSupply ≤ totalCredited + pending.units` and that `totalCredited + pending.units − totalSupply` read after its call into Collateralization equals the same quantity read before its first mint or burn. `settlePending(x)` requires `totalSupply + x ≤ totalCredited + pending.units`. Equality holds while every burn is settled in the same call. In the example the market keeps accepting pledges and withdrawals, with the gap held at 1,575,000,000 units, and the liquidity behind the orphan burn stays in custody. Changed rules: `REQ-ADAPTER-069`, `REQ-ADAPTER-075`, `INV-001`, `INV-080`, `REQ-VAULT-029`, `REQ-VAULT-139`, `REQ-VTOKEN-016`, `REQ-COLL-012`, `SPEC-BACK-009`, `SPEC-BACK-012`, `PROP-001`, `PROP-054`. |
| Status | Resolved in spec |
| Verification | `TEST-241`, `PROP-065`, `PROP-001`, `PROP-054` |

#### FINDING-105: A stray NFT could be pledged with the LPVault as depositor

| Field | Value |
|---|---|
| Source | Formal verification (custody contracts) |
| Severity | Low |
| Component | LPVault custody, Collateralization pledge |
| Reference | `Q-223`, `Q-258` |
| Description | `receiveNft(owner, tokenId)` requires `NFPM.ownerOf(tokenId) == owner` and then calls `transferFrom(owner, LPVault, tokenId)`. For a stray NFT already held by the LPVault, `owner == LPVault` passes and the self-transfer succeeds, so a hostile Adapter can call `pledge(LPVault, proxy, vaultToken, tokenId)`. Example: stray NFT 99 with liquidity 2,000,000,000 is credited to an attacker's proxy, which borrows against it. |
| Impact | Liquidity awaiting its governance return is borrowed against and can be seized; `returnStrayNft` reverts while it is pledged, and a later return would send it to an Avana contract. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-258`: `receiveNft` reverts `NotTokenOwner()` when `owner == address(this)`, and `pledge` reverts `InvalidDepositor(depositor)` when the depositor is the LPVault or Collateralization. A reviewed Adapter passes `msg.sender`, which is never either contract. Changed rules: `REQ-VAULT-147`, `REQ-VAULT-007`, `REQ-COLL-005`. |
| Status | Resolved in spec |
| Verification | `TEST-252`, `TEST-015` |

#### FINDING-106: Per-bucket exposure counters do not equal the slice and regular parts of open records

| Field | Value |
|---|---|
| Source | Formal verification (custody contracts) |
| Severity | Informational |
| Component | Collateralization exposure counters |
| Reference | `Q-157` |
| Description | Exits release the top-up slice first, so the slice counter refills before the regular counter and no longer equals the slice part of the market's open records. Example: caps $1,000 regular and $200 slice; record A books $1,000 regular, record B (an eligible top-up) books $200 slice; A exits in full and the counters read slice $0 and regular $200 while B still carries a $200 slice part. |
| Impact | None: the totals that bound exposure hold. The invariant as written could not be proved, so a test asserting it would fail on correct code. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The invariant states what holds: for each market the regular and slice counters together equal Σ `remainingCharge` over its open records; each token and depositor counter equals Σ `remainingCharge` over the open records in its scope; regular ≤ `marketUsdCap` and slice ≤ `topUpSliceUsd`. Changed rules: `INV-027`. |
| Status | Resolved in spec |
| Verification | `TEST-097`, `PROP-028`, `PROP-029` |

#### FINDING-107: Credited value can exceed the immediate removal value by one raw unit per leg

| Field | Value |
|---|---|
| Source | Formal verification (custody contracts) |
| Severity | Informational |
| Component | Vault-token units, LPOracle, LPVault removal |
| Reference | `Q-066`, `Q-124` |
| Description | Uniswap rounds each removed leg down by less than one raw unit, and the LPOracle's one-unit price margin does not cover that for small positions. Example: liquidity `L = 1` at pool price 1, both legs at $1 and 6 decimals, removes (0, 0) against a credited value of 199 (8-decimal USD). Over 17,053 sampled positions the largest shortfall was 378, that is $0.00000378. |
| Impact | A position's realizable value can fall short of its LPOracle value by at most one raw unit of each token. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The unit rule states the bound and where it is absorbed: removal rounds each leg down by less than one raw unit, and the collateral factor and `floorRoundingAllowanceGho` cover the difference. Changed rules: `SPEC-UNIT-003`. |
| Status | Resolved in spec |
| Verification | `TEST-217`, `TEST-074`, `TEST-072` |

#### FINDING-108: The pending-settlement invariant named the wrong custodian

| Field | Value |
|---|---|
| Source | Formal verification (custody contracts) |
| Severity | Informational |
| Component | Collateralization pending settlement, LPVault |
| Reference | `Q-201`, `Q-211` |
| Description | The backing invariant said the liquidity behind pending units stays in LPVault custody until `settlePending`. Reconciliation instead removes that liquidity and collects its principal to Collateralization, which pays it out of its own balance. |
| Impact | None on behavior; a test written from the old sentence would check the wrong contract's balance. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The invariant states that the pool tokens behind pending units, removed and collected at reconciliation, are held by Collateralization and paid only to LPVaultSwap in the `settlePending` call whose burn retires those units. Changed rules: `INV-001`. |
| Status | Resolved in spec |
| Verification | `TEST-152`, `TEST-170`, `TEST-083` |

#### FINDING-109: The debt-free withdrawal check omitted the reconcile wait

| Field | Value |
|---|---|
| Source | Formal verification (custody contracts) |
| Severity | Informational |
| Component | Debt-free withdrawal, reconcile on exit |
| Reference | `Q-201` |
| Description | The verification target for debt-free withdrawal listed only an Aave pause or a Hub halt as reasons a withdrawal can wait. An account with an unsettled seizure also waits while the Hub's shares and assets differ, because reconciliation needs them equal. |
| Impact | None on behavior; the procedure would have flagged a correct wait as a liveness failure. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The verification procedure for debt-free withdrawal includes the third case, an account with an unsettled seizure while Hub shares ≠ assets (`REQ-VAULT-143`). The invariant already states it; its wording was confirmed unchanged. Changed rules: none (`INV-045` confirmed). |
| Status | Resolved in spec |
| Verification | `TEST-099`, `TEST-150`, `TEST-193` |

#### FINDING-110: A role grant could hand out admin power that then acts without delay

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Medium |
| Component | AvanaTimelock, every upgradeable Avana contract |
| Reference | `Q-228`, `Q-259`, `ATTACK-152` |
| Description | The rule that only the timelock holds admin roles was enforced only at initialization. `grantRole(APPLICATION_ADMIN, X)` on an upgradeable contract, or `grantRole(DEFAULT_ADMIN_ROLE, X)` on the timelock, is a role-change operation, which only the Aave governance executor can cancel. Once it executes, `X` upgrades or reconfigures directly. Example: a compromised governance multisig schedules `AaveAdapter.grantRole(APPLICATION_ADMIN, X)` at 1,780,000,000; the guardians' cancels revert; anyone executes it at 1,780,432,000; `X` upgrades the Adapter in the next block. |
| Impact | A hostile Adapter implementation with no cancel window for the upgrade itself: borrowing every debt reserve to each `drawCap` and withdrawing supplied vault tokens. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-259`: every upgradeable Avana contract overrides `_grantRole` to revert `AdminRoleOnlyTimelock(role, account)` when `role` is `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` and `account` is not the timelock; the timelock reverts the same error for `DEFAULT_ADMIN_ROLE` granted to any account but itself. Moving to a new timelock is an upgrade of each contract at the normal delay that every canceller can cancel. The compromised-key table no longer lists role grants as a route to admin power. Changed rules: `REQ-ACCESS-032`, `REQ-ACCESS-153`, `INV-068`, `INV-084`, and the errors pieces of every upgradeable contract. |
| Status | Resolved in spec |
| Verification | `TEST-242`, `PROP-070`, `TEST-214` |

#### FINDING-111: Exits and the health floor depended on the upgradeable MarketRegistry

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Medium |
| Component | PositionProxy, AaveAdapter repay and withdraw |
| Reference | `Q-227`, `Q-260` |
| Description | `repay` reverted `UnknownDebtReserve` unless the MarketRegistry approved the reserve, and `withdraw` read the market, its reserve and the debt-reserve list from the MarketRegistry. A faulty MarketRegistry could therefore block every repay and withdrawal, or return an empty debt-reserve list so that a withdrawal with debts (1, 1, 1) in three reserves took the debt-free path, with no pause check, no RiskModule and no health floor. |
| Impact | Exits blocked for every account, or an indebted account leaving at Aave's HF 1 instead of the 1.10 opening floor then in force (removed by `Q-398`). |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-260`: an account is debt-free exactly when `spoke.getUserAccountData(proxy).borrowCount == 0`. `repay` drops the registry check; the Spoke rejects reserves it does not lend. Withdrawals resolve the reserve from the vault token, the Hub and the Spoke (`getAssetId`, `getReserveId`), check `vaultToken.spoke() == spoke`, and check the token against the VaultTokenFactory. The Adapter's exit paths read no MarketRegistry state, so repay and debt-free withdrawal hold for any MarketRegistry implementation. Changed rules: `REQ-PROXY-027`, `REQ-PROXY-033`, `REQ-PROXY-034`, `REQ-PROXY-037`, `REQ-ADAPTER-047`, `REQ-ADAPTER-068`, the repay and withdrawal steps of 3.3 and 3.4, `INV-043`, `INV-045`. |
| Status | Resolved in spec |
| Verification | `TEST-243`, `TEST-099`, `TEST-133` |

#### FINDING-112: The buy-leg allowance could halt or over-draw non-GHO liquidations

| Field | Value |
|---|---|
| Source | Formal verification (governance and control); Formal verification (liquidation); Design review (risk round) |
| Severity | Medium |
| Component | ParameterStore, MarketRegistry listing, LPVaultSwap two-leg settlement |
| Reference | `Q-235`, `Q-261`, `Q-397` |
| Description | Only the bounds [1, 300] bps constrained `buySlippageAllowanceBps`, and the two-leg slippage inequality was checked off-chain. Two failures followed. (1) A short-delay tightening to 1 bps capped a 5,000 USDC buy at 5,000.5 GHO, below a GSM buy at a 0.20 % fee (5,010 GHO), so both buy routes reverted and USDC-debt liquidation stopped while borrowing continued. (2) At the minimum bonus (10,200 bps) with `cBuy` 200 or 300 bps the inequality gives `s = 0`: every conversion loss reverts, and in that branch the budget pays the buy premium. Example: `D` = 2,300 USDC bought at the bound draws 24.000002 GHO, 24 times the rounding bound; at 2,500 USDC the 26.000002 GHO draw exceeds the per-call cap and the call reverts. |
| Impact | Liquidation of every account holding a non-GHO debt halted, or the SettlementBudget paying buy premiums instead of rounding. |
| Evidence | Counterexamples and scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-261`: each non-GHO debt reserve stores `buySlippageAllowanceMinBps`, set at listing to at least the larger buy route's fee plus expected impact at `buyRouteDepthThresholdGho`; `tightenBuySlippageAllowanceBps` reverts `LivenessBound` below it. `setBuySlippageAllowanceBps`, `approveDebtReserve` and `activateMarket` revert `LivenessBound` unless, for every market on the Spoke, `minLB × (10⁴ − slippageAllowanceMinBps) × 10⁴ ≥ 10⁴ × (10⁴ + maxFlashFeeBps) × (10⁴ + buySlippageAllowanceBps)`. Later decisions removed both failures: settlement has no buy leg (`Q-333`) and no SettlementBudget (`Q-397`), so no draw `Bd` exists and any gap is paid by the caller's shortfall top-up. Changed rules: `REQ-PSTORE-006`, `REQ-PSTORE-015`, `REQ-PSTORE-021`, `REQ-MREG-032`, `REQ-CONFIG-045`, `REQ-CONFIG-052`, `REQ-HUB-037`, `REQ-ACCESS-095`…`100`, `INV-047`, `SPEC-SET-001`, `SPEC-LIQ-016`, `REQ-SWAP-029`. |
| Status | Resolved in spec |
| Verification | `TEST-245`, `TEST-064`, `TEST-198` |

#### FINDING-113: An address freeze could block exits and liquidation or target Avana itself

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Medium |
| Component | MarketRegistry address freeze, AaveAdapter, LPVaultSwap, ProxyManager |
| Reference | `Q-242`, `ATTACK-139` |
| Description | A freeze checked at every Adapter entry point blocks a frozen wallet's debt-free withdrawal and `repayAllAndWithdraw`. Freezing LPVaultSwap blocks `burnSeized`, so every liquidation and `settlePending` reverts. Freezing every approved keeper leaves only the permissionless path, with no budget draw or in-kind mode, while the keeper floor still counts frozen keepers. Freezing the timelock blocks its own unfreeze, and the freezing guardian could cancel every `unfreezeAddress`. |
| Impact | Exits and liquidation stopped by one guardian action; a victim kept frozen for two normal delays. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-242`: the freeze applies only to new activity: `pledge` and `recredit` (a frozen caller is held to the rescue rules), `borrow` (caller or receiver), with-debt `withdraw` and `removeLiquidity`, `repayWithCollateral`, `deployProxy`, and a frozen caller of `liquidate` or `liquidatePermissionless` (`reportRecoveryShortfall` was removed with in-kind settlement, `Q-401`). It never reaches repay, debt-free withdrawal or removal, `repayAllAndWithdraw`, `collectFees`, `releaseZeroCredit`, `settlePending`, `burnSeized`, `PayoutEscrow.claim` (the payout escrow), rescue top-ups, contract-to-contract calls or liquidation of the frozen wallet's positions. `freezeAddress` reverts `ProtectedAddress` for the timelock, the Aave governance executor, every Avana contract, vault token, oracle and route, the Hub, every approved Spoke and First-Loss Reserve, GHO, the FlashMinter and every registered proxy, and `KeeperFloorBreached` when unfrozen keepers would fall below `keeperFloor` (1, `Q-400`). Each caller may freeze at most 20 addresses per rolling 24 hours. `unfreezeAddress` is a normal-delay operation only the DAO can cancel. Changed rules: `REQ-MREG-019`…`023`, `REQ-ADAPTER-082`, `REQ-PROXY-099`, `REQ-SWAP-105`, `REQ-SWAP-107`, `REQ-ACCESS-157`, `REQ-ROLE-107`, `EMG-070`, `INV-046`, `INV-067`, `INV-081`, `INV-085`, `SPEC-GOV-005`, `SPEC-GOV-008`. |
| Status | Resolved in spec |
| Verification | `TEST-229`, `PROP-071`, `PROP-066` |

#### FINDING-114: The short-delay list could admit risk-raising selectors

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Low |
| Component | AvanaTimelock short-delay list |
| Reference | `Q-228`, `Q-262` |
| Description | `setShortDelaySelector` refused only role, upgrade, beacon and initializer selectors. One normal-delay operation such as `setShortDelaySelector(MarketRegistry, setRoute, true)` would let new route code, `setPriceSource`, `addKeeper` or any loosening execute 12 hours after scheduling. |
| Impact | Risk-raising changes land faster than the 3-day borrower reaction the exit window assumes. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-262`: the timelock constructor fixes an immutable set `SHORT_ELIGIBLE` of `(target, selector)` pairs equal to the launch short-delay list; enabling a pair outside it reverts `InvalidShortDelaySelector(target, selector)`, and disabling an entry is always allowed. Adding a short-eligible selector needs a new timelock. Changed rules: `REQ-ACCESS-016`, `REQ-ACCESS-141`, `REQ-ACCESS-142`, `REQ-ACCESS-155`, `REQ-ROLE-105`, `REQ-CONFIG-053`, `REQ-PSTORE-002`, `INV-090`. |
| Status | Resolved in spec |
| Verification | `TEST-244`, `PROP-073` |

#### FINDING-115: The normal delay could be cut below the borrower exit window

| Field | Value |
|---|---|
| Source | Formal verification (governance and control); Design review (risk round) |
| Severity | Medium |
| Component | AvanaTimelock delays |
| Reference | `Q-228`, `Q-262` |
| Description | `setNormalDelay` accepted any value from the short delay up. After one normal-delay operation setting it to 43,200 s, an AaveAdapter upgrade is ready 43,200 s after scheduling, while a borrower with one NFT and a 3-day reaction needs 259,224 s to leave. |
| Impact | Later hostile upgrades wait 12 hours; the exit guarantee that rests on the normal delay no longer holds. |
| Evidence | Counterexamples and scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-262`: the timelock has a constant `MIN_NORMAL_DELAY = 345,600` (4 days); `setNormalDelay` requires `MIN_NORMAL_DELAY ≤ newDelay ≤ MAX_DELAY` and reverts `DelayOutOfBounds` otherwise. The exit-window rule is `r + 12 × (k + 1) ≤ normalDelay` in seconds, one 12-second block per transaction (`SPEC-GOV-014`, `SPEC-GOV-015`): with a 3-day reaction `r = 259,200` s, the 4-day floor covers a borrower with up to `k = 7,199` NFTs at every reachable delay. Together with the immutable short-delay allowlist (`FINDING-114`) the window cannot be shrunk by self-calls. Changed rules: `SPEC-GOV-003`, `SPEC-GOV-012`, `SPEC-GOV-015`, `REQ-ACCESS-125`, `REQ-ACCESS-140`, `REQ-ACCESS-148`, `REQ-ACCESS-154`, `REQ-ROLE-104`, `INV-068`, `INV-090`, parameter registry. |
| Status | Resolved in spec |
| Verification | `TEST-244`, `PROP-073`, `TEST-212` |

#### FINDING-116: The grace-window fallback started grace before the recovery

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Low |
| Component | LPOracle grace latch |
| Reference | `Q-129`, `Q-264` |
| Description | When the outage interval could not be read, `recoveredAt` fell back to `min(t0, t1)` of the fresh price, the older input. Example: token1 recovers now while token0 sits on a leg last updated 50,000 s ago; `recoveredAt = now − 50,000`, so with `graceDuration` 1,800 s the grace window ended before it began. |
| Impact | Accounts with HF in [`graceHealthFactor`, 1) lose the grace window and are liquidated at the first fresh price. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-264`: the fallback uses `max(t0, t1)` of the fresh price, the newest input, never after `block.timestamp`. Changed rules: `REQ-ORACLE-032`. |
| Status | Resolved in spec |
| Verification | `TEST-252`, `TEST-042`, `TEST-219` |

#### FINDING-117: A cancelled registration made its pool unlistable

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Low |
| Component | MarketRegistry listing, VaultTokenFactory |
| Reference | `Q-265` |
| Description | After `deployVaultToken(P)` and `registerMarket(P)` as market 1 and then `cancelRegistration(1)`, relisting with a new token reverts `TokenExistsForPool` (the factory slot is write-once), and relisting with the existing token assigns ID 2 against a token that carries ID 1, which reverts `VaultTokenMismatch`. |
| Impact | A pool whose first listing failed can never be listed. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-265`: `cancelRegistration` keeps the cancelled `marketId` reserved for its pool; a later `registerMarket` for a pool whose factory token exists reuses that `marketId` and requires the token's `lpOracle()` to match. A key maps to at most one market that is not cancelled. Changed rules: `REQ-CONFIG-007`, `REQ-CONFIG-032`, `REQ-CONFIG-048`, `REQ-MREG-030`, the cancel step of 3.8. |
| Status | Resolved in spec |
| Verification | `TEST-252` |

#### FINDING-118: A reinitializer in a PositionProxy implementation was callable by anyone

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Low |
| Component | PositionProxy, ProxyManager beacon |
| Reference | `Q-225`, `Q-266` |
| Description | UUPS contracts run a reinitializer inside `upgradeToAndCall`, but a beacon change has no per-proxy call. A reinitializer in a new PositionProxy implementation could be called first, on every proxy, by any address. |
| Impact | An outside caller initializes per-proxy state of every account after a beacon change. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-266`: a PositionProxy implementation contains no initializer other than the first and no `reinitializer`; per-proxy storage a new implementation adds is initialized lazily inside an `OnlyAdapter` function. Changed rules: `REQ-PROXY-005`, `REQ-PROXY-007`, `REQ-PROXY-086`, `REQ-ACCESS-031`. |
| Status | Resolved in spec |
| Verification | `TEST-252`, `TEST-210` |

#### FINDING-119: Pages disagreed on the delay class of the USD band and grace parameters

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | ParameterStore, parameter registry, market lifecycle |
| Reference | `Q-246` |
| Description | The parameter registry and the market lifecycle gave `usdBandLow`, `usdBandHigh`, `graceDuration` and `graceHealthFactor` short-delay tightening, but the ParameterStore has no tighten setter for them and the short-delay list does not contain one. |
| Impact | None on behavior; operators could plan a 12-hour change that the timelock schedules at the normal delay. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-246`: these four parameters change at the normal delay in both directions; the registry class column and the lifecycle step say so, and the role rules keep "every `tighten*` setter". Changed rules: parameter registry rows, `MKT-027`, `REQ-ROLE-027`, `REQ-ROLE-105`. |
| Status | Resolved in spec |
| Verification | `TEST-063`, `TEST-225` |

#### FINDING-120: A zero per-call budget cap blocked every rounding-allowance change

| Field | Value |
|---|---|
| Source | Formal verification (governance and control); Formal verification (liquidation) |
| Severity | Low |
| Component | ParameterStore, SettlementBudget caps (removed, `Q-397`) |
| Reference | `Q-267`, `Q-397` |
| Description | The configuration rule required `floorRoundingAllowanceGho ≤ perCallCap` for every approved debt reserve, but a reserve may sit at caps (0, 0) when newly approved or closed. Example: allowance 1 GHO, reserve A at a 25 GHO per-call cap, reserve B closed at (0, 0): `tightenFloorRoundingAllowanceGho(0.5 GHO)` reverts `OutOfBounds`. |
| Impact | Governance cannot lower or raise the rounding allowance while any reserve is closed. |
| Evidence | Counterexamples and scenario in Description; confirmed by the Verification tests |
| Resolution | Resolved by removal (`Q-397`): the SettlementBudget and `perCallCap` no longer exist, so a change of `floorRoundingAllowance` is checked only against its own bounds. Earlier fix, superseded: `2 × floorRoundingAllowanceGho ≤ perCallCap(spoke, r)` for every key whose caps were not both 0 (`Q-267`). |
| Status | Resolved in spec |
| Verification | `TEST-246`, `TEST-064` |

#### FINDING-121: An unobserved recovery left the Cached start stale

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | LPOracle price states |
| Reference | `Q-183` |
| Description | `failedSince` clears only at a poke that sees the market not failed. Example: a poke at 1,000,000 records a failed read; the feed recovers at 1,000,600 with no poke; a new failure starts at 1,004,000 and the poke at 1,004,100 measures from 1,000,000, so the market is Expired at once instead of Cached until 1,007,600. |
| Impact | None on safety: Cached and Expired gate the same actions for the stale market, and the outage latch reads source timestamps. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The Cached rule states its measurement: Cached is measured from the first failed read observed since the last poke that saw the market not failed; with keepers poking every heartbeat the difference from the true start is at most one heartbeat, and a late reading can only report Expired earlier, never later. Changed rules: `SPEC-ORC-013`. |
| Status | Resolved in spec |
| Verification | `TEST-039`, `TEST-219` |

#### FINDING-122: Record paging reverted on overflow instead of returning an empty page

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | Lens |
| Reference | `Q-268` |
| Description | The record walk ran from `offset` to `min(offset + limit, nextRecordId) − 1` with checked arithmetic, so `offset = 2²⁵⁶ − 8` and `limit = 200` reverted instead of returning the empty page past the end. |
| Impact | A monitoring or app call with an out-of-range offset fails instead of reading nothing. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-268`: the Lens returns an empty page when `offset ≥ nextRecordId` and otherwise walks `offset` to `offset + min(limit, nextRecordId − offset) − 1`. Changed rules: `REQ-LENS-014`, `REQ-LENS-024`. |
| Status | Resolved in spec |
| Verification | `TEST-247` |

#### FINDING-123: Predicted proxy addresses could diverge from stored proxies after a ProxyManager upgrade

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | Lens, ProxyManager, RiskModule previews |
| Reference | `Q-266`, `Q-268` |
| Description | `predictProxy` hashes the BeaconProxy creation code compiled into the ProxyManager implementation and the `initialize` call data. An upgrade that changes either changes every predicted address, so the Lens reports a new address as deployed and `previewPledge` previews an empty account for an existing borrower. |
| Impact | Wrong previews for every existing borrower after such an upgrade. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-266`, `Q-268`: the Lens, the ProxyManager view and the RiskModule preview return `ADAPTER.proxyOf(wallet, spoke)` when it is non-zero and the prediction otherwise; a ProxyManager upgrade keeps the BeaconProxy creation-code hash and the `initialize` selector. Changed rules: `REQ-LENS-008`, `REQ-PROXY-049`, `REQ-PROXY-050`, `REQ-RISK-031`. |
| Status | Resolved in spec |
| Verification | `TEST-247`, `TEST-190` |

#### FINDING-124: Two verification targets claimed more scope than the design gives

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | Verification procedure, RiskModule, AaveAdapter |
| Reference | `Q-223`, `Q-229` |
| Description | One target said the frozen-collateral refusal on borrow holds for any RiskModule; the refusal lives in the reviewed RiskModule, and with any other implementation only Aave's checks on the borrowed reserve remain. Another listed the AaveAdapter among implementations whose hostility the immutable contracts contain, but the Adapter is trusted for custody. |
| Impact | None on behavior; the procedure would have reported correct code as failing. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The verification procedure was corrected: the frozen-collateral target holds for the reviewed RiskModule, and for any RiskModule Aave refuses a paused or frozen borrowed reserve; the containment target no longer lists the AaveAdapter. The invariants were already scoped this way. Changed rules: none. |
| Status | Resolved in spec |
| Verification | `TEST-155`, `TEST-132`, `TEST-130` |

#### FINDING-125: Circuit breakers needed triggers, counting and reset that cannot block exits or liquidation

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | MarketRegistry breakers, RiskModule, LPVaultSwap |
| Reference | `Q-241`, `ATTACK-138`, `Q-399` |
| Description | Breakers combine safely with the pause state and offboarding only if three conditions hold: a trigger cannot be moved by one actor in one transaction (an LP's own withdrawal or a debt-free exit must not halt new activity), failures are counted only from completed calls (a reverted liquidation records nothing) and recording never reverts a liquidation, and a reset path exists other than the timelock. |
| Impact | Without them an attacker trips a protocol-wide halt of borrowing, or a breaker blocks the liquidation it should protect. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-241`, revised by `Q-399`: the automatic on-chain gates are (1) the oracle and stablecoin-band checks, which block new borrowing and withdrawals that leave debt; (2) the concentration gate, which blocks new borrowing and pledges that raise pool exposure while Avana's combined share of a pool, over every borrower and Spoke on the chain, exceeds `poolShareMaxBps` (10 %); and (3) the deficit freeze, which stops new borrowing on a debt reserve once the outstanding deficit of the affected CDP Spoke reaches `breakerDeficitMax` (10,000 GHO; other assets at a materiality set at listing). None counts withdrawals, and none depends on a count written by a liquidation. Price drop (3 % in 2 hours), seizure surge (above 20 % of a market in 1 hour) and route failures (3 in 1 hour) are monitoring alerts only: a reverted liquidation cannot persist a count and an on-chain counter can be gamed, so `breakerPriceDropBps`, `breakerSeizureBps`, `breakerRouteFailureCount` and `breakerCooldown` are no longer trip conditions. A guardian freezes new borrowing on a market once its approved routes are confirmed unable to settle valid liquidations at the required size. A temporary price or depth gate clears after 30 minutes of healthy observations (a provisional launch setting); a deficit or security freeze reopens only by the timelock or a guardian under 2.15. Gates are read only by new-activity checks, so repay, debt-free exits and eligible liquidations stay open. Changed rules: `SPEC-BRK-001`…`006`, `REQ-MREG-025`, `REQ-MREG-026`, `REQ-RISK-065`, `REQ-SWAP-104`, `INV-081`. |
| Status | Resolved in spec |
| Verification | `TEST-228`, `PROP-066` |

#### FINDING-126: The per-draw budget bound omitted Aave's debt rounding

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Low |
| Component | SettlementBudget (removed, `Q-397`), LPVaultSwap |
| Reference | `Q-236`, `Q-267`, `Q-397` |
| Description | Aave prices the seizure from `drawnShares × drawnIndex + premiumRay` but pulls a debt rounded up by up to `2 + ⌈drawnIndex / RAY⌉` units, and the buy bound rounds up by 1 wei. Example: USDC debt, `cBuy` 200, `drawnIndex = 1.5 RAY + 7`: an honest dust liquidation draws 1.00000353 GHO against a stated bound of 1.000002 GHO, which exceeds a per-call cap set equal to the rounding allowance. |
| Impact | Before `Q-397`: honest dust liquidations reverted `PerCallCapExceeded`. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | Resolved by removal (`Q-397`): no budget draw or per-call cap exists. Aave's rounding of the repaid debt, up to `2 + ⌈drawnIndex / RAY⌉` units, is part of the repayment the caller sizes up front; the caller sizes `debtToCover` and its funding (flash principal, exact premium and `callerFunds`) for the repayment Aave V4's dust rule may require, and pays any rounding gap at final settlement through its shortfall top-up, bounded by `maxShortfall` (`INV-034`). Earlier fix, superseded: the per-draw bound included that rounding (`Q-267`). |
| Status | Resolved in spec |
| Verification | `TEST-246`, `TEST-161` |

#### FINDING-127: The flash-fee allowance in a draw could exceed the fee charged

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Low |
| Component | LPVaultSwap waterfall, SettlementBudget (removed, `Q-397`) |
| Reference | `Q-267`, `Q-397` |
| Description | `φD` was the flash fee on `Gcov`, but a caller that brings GHO borrows a flash loan `F` smaller than `Gcov`, so `φD` exceeds the fee actually charged and the difference reaches the caller from budget GHO. Example: fee 9 bps, `F` = 1,000 GHO, `Gcov` = 1,950 GHO: `φD` was 1.755 GHO against a charged fee of 0.9 GHO. |
| Impact | Before the fix: a budget draw paid the caller up to the fee difference per call. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-267`: `φD` is the premium the flash source charges on `min(F, D)` when `F > 0`, else 0; in the example `φD` = 0.9 GHO. `Q-397` later removed the SettlementBudget, so no Avana fund can pay a caller any fee difference; `φD` still sets the premium deducted from the oracle gain (`INV-036`). Changed rules: `SPEC-LIQ-007`, `SPEC-LIQ-010`. |
| Status | Resolved in spec |
| Verification | `TEST-246`, `TEST-051` |

#### FINDING-128: The previewed seizure could differ from Aave's by one unit

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Informational |
| Component | Lens liquidation preview |
| Reference | `Q-232`, `Q-268` |
| Description | The Lens computed the expected seizure from the rounded-up debt `D`; Aave computes it from `drawnShares × drawnIndex + premiumRay ≤ D × RAY`. Example: GHO debt, `drawnIndex = 1.5 RAY + 1`, `debtToCover` 100 GHO, collateral price 2.00, 6 decimals, bonus 10,200: Aave seizes 50,999,999 units and the Lens returned 51,000,000. |
| Impact | Previews only; LPVaultSwap measures seizures by balance delta. The exact-match fork test fails for such accounts. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-268`: `expectedUnitsSeized` is Aave's collateral-to-liquidate computation on the `drawnShares` and `premiumDebtRay` that the Lens's compiled sizing returns, capped by the supplied shares as in `liquidationCall`. Changed rules: `REQ-LENS-017`, `REQ-LENS-029`. |
| Status | Resolved in spec |
| Verification | `TEST-247`, `TEST-205` |

#### FINDING-129: A 1-wei repay at Aave's dust boundary reverted a previewed liquidation

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Low |
| Component | Lens liquidation preview, LPVaultSwap |
| Reference | `Q-268` |
| Description | When the debt left after `debtToCover` sits exactly at Aave's dust threshold ($1,000), any address can repay 1 wei of the account's debt and push the remainder below it; Aave then requires the whole debt and the call reverts `MustNotLeaveDust`. Example: 1,500 GHO of debt at HF 0.70, `debtToCover` 500 GHO. |
| Impact | Griefing of keepers; the keeper must re-preview and resubmit. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-268`: for a GHO debt reserve the preview sets `debtToCover` to the account's whole debt in that reserve (Aave still repays only its target amount); for any other reserve it uses the whole debt when the remainder would be within `LENS_DUST_MARGIN_BPS` (500 bps) of the dust threshold. The robustness rule names this as its one exception. Changed rules: `REQ-LENS-028`, `REQ-SWAP-005`. |
| Status | Resolved in spec |
| Verification | `TEST-247`, `TEST-141` |

#### FINDING-130: A caller could divert Avana's fee through its own routing

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Medium |
| Component | LPVaultSwap fee and sell-back |
| Reference | `Q-231`, `Q-256`, `ATTACK-151` |
| Description | The Avana fee was 20 % of the surplus measured after the caller's routing, so every GHO the caller kept outside `R` by sandwiching its own conversion lowered the fee by 0.2 GHO, and the sell-back had no floor. Example: converting at the floor gives `R` = 5,037.902 GHO instead of 5,085 and the fee falls from 17 to 7.58 GHO; oversizing `debtToCover` by 100,000 USDC and selling the leftover back 85 GHO under value makes the fee 0. |
| Impact | Avana's only on-chain revenue taken by the liquidating caller. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Q-256`: `A = min(⌊max(0, V − Gcov − φD) × avanaFeeShareBps / 10⁴⌋, S)`, computed from oracle value, so lowering `R` or raising `Gnet` cannot lower it while `S` covers it, and `A ≤ S` keeps the no-revert property; in the example `A` stays 17 GHO. A sell-back below `⌈amount × Pdebt × 10¹⁸ / (10^dd × Pgho)⌉ × (10⁴ − buySlippageAllowanceBps) / 10⁴ − 1` GHO reverts `RecoveryBelowFloor`. Changed rules: `SPEC-LIQ-008`, `SPEC-LIQ-009`, `REQ-SWAP-022`, `REQ-SWAP-089`, `REQ-ROUTE-037`, `INV-036`, `INV-086`. |
| Status | Resolved in spec |
| Verification | `TEST-240`, `PROP-069`, `TEST-227` |

#### FINDING-131: Buy-route over-delivery could strand the extra debt asset

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Informational |
| Component | LPVaultSwap buy leg and sell-back |
| Reference | `Q-235` |
| Description | A buy route may deliver more than the requested amount. An earlier text accepted exactly the requested amount and sold back only the excess over the debt repaid, which would have left any over-delivery in LPVaultSwap. |
| Impact | Debt asset left in LPVaultSwap at transaction end. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | Already fixed in the final liquidation contract: LPVaultSwap accepts at least the requested amount (`REQ-SWAP-088`) and sells back everything above its pre-buy balance (`REQ-SWAP-089`), so the debt-asset balance returns to its start on every path. Changed rules: none in this pass. |
| Status | Resolved in spec |
| Verification | `TEST-197`, `TEST-198`, `TEST-092` |

#### FINDING-132: A dust example seized more than Aave's sizing allows

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Informational |
| Component | Liquidation flow example |
| Reference | `Q-124` |
| Description | An earlier worked example seized the last 400,000 units (0.8 GHO of value) for a debt of 0.78 GHO, more than `D × LB` = 0.7956 GHO and impossible under Aave's sizing. |
| Impact | None on behavior; a test copied from the example would assert an impossible seizure. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | Already fixed in the final liquidation flow: the example seizes 397,800 units with `V` = 0.7956 GHO, and every number was re-verified. Changed rules: none in this pass (`LIQ-060` already final). |
| Status | Resolved in spec |
| Verification | `TEST-161`, `TEST-081` |

#### FINDING-133: Reserve sizing did not cover the default of one pool token

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | High |
| Component | Caps, First-Loss Reserve, Lens |
| Reference | `Q-186`, `Q-192`, `Q-249` |
| Description | The incident sizing term is 0 for every LP drop up to 65.5 % at launch values (h0 0.95, CF 0.312, LB 1.05), so it allowed any debt cap for stable pools. A token going to $0.08 makes every maximum-LTV account in every market holding it insolvent. Example: `tokenUsdCap` $3,000,000 gives exposed debt ≈ 0.2836 × 3,000,000 = $850,800 against a 100,000 GHO reserve. |
| Impact | About $750,000 of lender loss from one token default. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-249`: the cap-sizing rule keeps the incident term (dividing by `LB` already counts bonus paid from the reserve) and adds a tail term for every non-GHO pool token `t` and debt asset `a`: `min((tokenUsdCap[t] + Σ_{m∋t} topUpSliceUsd[m]) × CF_t / minOpeningHealthFactor, Σ_spoke drawCap_a) ≤ firstLossReserveMinimum[a]`. At launch values 0.312 / 1.10 = 0.2836, so 100,000 GHO covers `tokenUsdCap` of $352,564 less slices. Caps and reserves stay DAO and service-provider values; the Lens reports `tailCoverageBps_a = ⌊funded_a × 10⁴ / max_t tail_{t,a}⌋` and monitoring pages below 100 %. Per-asset solvency is a global invariant. `FINDING-167` later dropped the division by the opening health factor, and `Q-398` removed `minOpeningHealthFactor`. Changed rules: `SPEC-CAP-007`, `SPEC-CAP-008`, `REQ-LENS-034`, `INV-074`, parameter registry notes. |
| Status | Resolved in spec |
| Verification | `TEST-216`, `TEST-247` |

#### FINDING-134: An account-wide liquidation gate let one stale market shield a whole account

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | High |
| Component | LPVaultSwap price gates, LPOracle, DebtOracle |
| Reference | `Q-234`, `Q-247`, `ATTACK-145` |
| Description | Liquidation required fresh prices for every reserve of the account. A borrower with $1,000,000 of collateral in market A who also pledges $10 in market B, or borrows 1 wei of a debt with a slow feed, makes every liquidation of the account revert whenever B is Cached, Expired or disagreeing, including liquidation of fresh market A. |
| Impact | A $10 shield against liquidation; in a systemic failure of one market every account holding it is unliquidatable everywhere. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-247`: liquidation requires fresh, agreeing prices only for the seized collateral market and the repaid debt reserve. The account's other reserves count at their served price: an Expired collateral market at 1 (10⁻⁸ USD per unit), a disagreeing one at the lower route, a stale debt at its stress price `⌈accepted × (10⁴ + debtStressRiseBps) / 10⁴⌉`, a disagreeing debt at the higher route. A failing price only lowers the HF, so it can enable liquidation of fresh reserves but never block it, and no seizure or repayment happens at a stress price. Borrow and withdraw-with-debt keep the account-wide gate. Changed rules: `LIQ-006`, `LIQ-013`, `REQ-SWAP-008`, `INV-030`, `INV-072`, `INV-075`, `INV-087`, `REQ-ORACLE-085`…`087`, `SPEC-ORC-017`, `EMG-005`…`007`, `EMG-020`, `EMG-029`, `EMG-073`. |
| Status | Resolved in spec |
| Verification | `TEST-230`, `TEST-226`, `PROP-074` |

#### FINDING-135: A persistent disagreement or outage halted liquidation beyond the sizing window

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | High |
| Component | LPOracle, MarketRegistry price routes, DebtOracle |
| Reference | `Q-192`, `Q-208`, `Q-248`, `ATTACK-140` |
| Description | After a disagreement outlasted `disagreementPauseMax`, the market was treated as Expired for liquidation until the routes agreed or a new price source executed at the normal delay, cancellable by any one canceller. Caps assume liquidation stops for at most 48 hours. A further 40 % fall of the failing token over those days turns liquidatable accounts into deficits. |
| Impact | Liquidation of the market stopped for 5 days or more; losses beyond the reserve. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-248`: every price leg is listed with a standby route that passes the same listing checks as the slot it replaces. `useStandbyRoute` is immediate for `APPLICATION_PAUSE_GUARDIAN` (short delay for `APPLICATION_ADMIN`, DAO-only cancel); the Aave governance executor can cancel a switch at once; `restorePriceRoute` is a normal-delay operation. A switch resets the disagreement start and never forces Live. Non-GHO debt is priced by a DebtOracle with the same two-route pipeline plus a standby. While one market waits, the account's other reserves stay liquidatable (`FINDING-134`). The emergency rules state the real maximum stop of each halting state, with the guardian switch inside the incident window. Changed rules: `REQ-MREG-027`, `REQ-MREG-028`, `REQ-ORACLE-091`…`093`, `SPEC-ORC-016`, `SPEC-ORC-018`, `EMG-036`, `EMG-041`, `EMG-072`, the listing steps of 3.8. |
| Status | Resolved in spec |
| Verification | `TEST-231`, `TEST-219` |

#### FINDING-136: Automatic breakers and the address freeze were missing

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | High |
| Component | RiskModule, MarketRegistry, First-Loss Reserve |
| Reference | `Q-102`, `Q-241`, `Q-242`, `Q-399` |
| Description | After a deficit took the reserve to 40,000 GHO, borrowing continued until a person acted, and the only tool against an exploiter opening positions mid-incident was the application-wide pause. |
| Impact | New risk opens during an incident; the only response stops every user's new activity. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-241`, revised by `Q-399`: the automatic on-chain gates are (1) the oracle and stablecoin-band checks, which block new borrowing and withdrawals that leave debt; (2) the concentration gate, which blocks new borrowing and pledges that raise pool exposure while Avana's combined share of a pool, over every borrower and Spoke on the chain, exceeds `poolShareMaxBps` (10 %); and (3) the deficit freeze, which stops new borrowing on a debt reserve once the outstanding deficit of the affected CDP Spoke reaches `breakerDeficitMax` (10,000 GHO; other assets at a materiality set at listing); every new deficit raises an alert. The price-drop, seizure-surge and route-failure triggers and the SettlementBudget breaker no longer exist (`Q-397`, `Q-399`); those conditions are monitoring alerts, and a guardian can still trip a market or debt reserve by hand. `Q-242`: the address freeze stops new activity of one wallet (`FINDING-113`). Neither reaches exits, liquidation or rescue top-ups. Changed rules: `REQ-FLR-014`, `EMG-028`, `EMG-045`, `REQ-ACCESS-078`. |
| Status | Resolved in spec |
| Verification | `TEST-228`, `TEST-229`, `PROP-066` |

#### FINDING-137: Aave's collateral factor, bonus curve and target HF were not drift-checked

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Medium |
| Component | RiskModule drift check |
| Reference | `Q-110`, `Q-270` |
| Description | An AIP that raises a vault reserve's CF from 3,120 to 6,000 bps lifts the maximum opening LTV to 54.5 %. `maxLB × CF` stays below 1, but the margin Avana's caps and listing sizing assume is gone, and Avana kept opening loans. |
| Impact | New debt opened against configuration the caps were not sized for. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-270`: the drift check appends `CollateralFactorAboveExpected`, `BonusBoundViolated` and `LiquidationConfigChanged`. New-account pledges, borrows and withdrawals with debt revert `ConfigDrift` when a dynamic key's CF exceeds `expectedCollateralFactorBps(m)`, when `⌈maxLB × CF / 10⁴⌉ ≥ 10⁴`, when the minimum bonus is below `minLiquidationBonus`, or when the target HF differs from `aaveTargetHealthFactor`. Liquidation is unaffected. Changed rules: `REQ-RISK-069`, `SPEC-CF-001`, `SPEC-CF-002`, `SPEC-HUB-005`, `REQ-CONFIG-044`, `REQ-CONFIG-045`, `EMG-011`, `EMG-053`. |
| Status | Resolved in spec |
| Verification | `TEST-249`, `TEST-114` |

#### FINDING-138: Every swap leg ran with a zero minimum output

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Medium |
| Component | LPVaultSwap, settlement and sell-back routes |
| Reference | `Q-250`, `ATTACK-144` |
| Description | The aggregate recovery floor protected lenders, but each leg was open to sandwiching down to that floor. Extraction per liquidation was about `s × V` + 1 GHO, 20.5 GHO on `V` = 2,047.5; on `settlePending` it came from the First-Loss Reserve. |
| Impact | Value taken from keepers, Avana's fee and pending proceeds by searchers. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-250`: LPVaultSwap passes an oracle-derived minimum to every leg, `minOut = max(1, ⌈Vleg × (10⁴ − sLeg) / 10⁴⌉ − Uleg − ⌊floorRoundingAllowanceGho / n⌋)`, applied at the swap route's pool; a route reverts `MinOutNotMet(out, minOut)` below it. Example: a USDC leg of 6,211.3 at $1 with `s` 100 bps, allowance 1 GHO and 2 legs gets about 6,148.69 GHO. Pending settlement uses `s = min(slippageAllowanceBps, 30)`. `decreaseLiquidity` keeps zero minimums because the oracle price bounds removal value. Changed rules: `REQ-ROUTE-009`, `REQ-ROUTE-042`, `REQ-SWAP-025`, `REQ-SWAP-100`, `REQ-VAULT-149`, `SPEC-LIQ-005`, `SPEC-LIQ-014`, `SPEC-LIQ-018`, `INV-083`. |
| Status | Resolved in spec |
| Verification | `TEST-232`, `PROP-068`, `TEST-227` |

#### FINDING-139: Any single canceller could cancel every liquidation repair

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Medium |
| Component | AvanaTimelock cancel rules |
| Reference | `Q-228`, `Q-263`, `ATTACK-097`, `ATTACK-139`, `Q-401` |
| Description | With the Emergency Guardian Safe compromised, it could cancel every `enableInKind`, `restoreRoute` and standby switch while a market was unliquidatable; removing its role is itself a 5-day role-change operation. |
| Impact | Liquidation of a market held halted for as long as the compromised role lasts. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-263`: an operation whose every call restores liquidation or an address (`restoreRoute`, `restoreBuyRoute`, `useStandbyRoute`, `addKeeper`, `unfreezeAddress`; `enableInKind` and `setInKindAutoTrigger` left the list when in-kind settlement was removed, `Q-401`) can be cancelled only by `DAO_CANCELLER_ROLE`; an operation mixing such calls with any other keeps the ordinary rule. `setPriceSource` keeps the ordinary rule because it installs a new source. Changed rules: `SPEC-GOV-005`, `REQ-ACCESS-020`, `REQ-ACCESS-156`, `ATTACK-097`, `INV-090`. |
| Status | Resolved in spec |
| Verification | `TEST-244`, `PROP-073` |

#### FINDING-140: A raised minimum pledge could block rescue top-ups, and loosening had no step limit

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Medium |
| Component | RiskModule pledge checks, ParameterStore |
| Reference | `Q-246`, `Q-252` |
| Description | One 12-hour operation raising `minPledgeUsd` to $100,000 stops an indebted borrower at HF 1.02 from topping up with a $20,000 NFT, who is then liquidated at a 2–5 % bonus. Loosening had no step limit either, so parameters could drift far in one operation. |
| Impact | Forced liquidations through a tightening; large unreviewed loosening steps. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-252`: a rescue top-up needs only `min(minPledgeUsd[m], RESCUE_MIN_PLEDGE_USD)` ($10). `Q-246`: each loosening is limited to ×1.5 on USD caps and +25 bps on slippage allowances (the −0.03 step on `minOpeningHealthFactor` left with that parameter, `Q-398`), once per `normalDelay` per parameter (`LoosenStepTooLarge`, `LoosenTooSoon`). Tightening keeps no step limit so it stays fast in incidents. Changed rules: `REQ-RISK-067`, `REQ-PSTORE-017`, `SPEC-GOV-011`, `REQ-ACCESS-161`. |
| Status | Resolved in spec |
| Verification | `TEST-235`, `TEST-225` |

#### FINDING-141: Token issuer actions could halt liquidation of every affected market

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Medium |
| Component | LPVault, settlement routes, PositionProxy repay, breakers |
| Reference | `Q-241`, `Q-271`, `ATTACK-058`, `ATTACK-059`, `ATTACK-148`, `ATTACK-149` |
| Description | If the USDT issuer sets `basisPointsRate > 0`, received amounts fall below sent amounts, the exact-amount checks fail, routes revert and repays of USDT debt revert. A USDC blocklist of LPVaultSwap halts every USDC market, because its address is immutable in the Spoke and the vault tokens. |
| Impact | Liquidation and repay halted in every market with the affected token. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-271`: every received pool-token and debt-asset amount is measured by balance delta (collect, route input, proxy repay), the amount received is at most the principal removed, and later steps size from the delta. `Q-241`: an ISSUER breaker probes `paused()` or `basisPointsRate()` and stops new activity in affected markets and debt reserves. A fee on a debt asset stays outside what Avana can resolve: Aave V4's Hub refuses every fee-reduced repayment (`InsufficientTransferred`), so repays and liquidations of USDT debt revert until the fee returns to 0, as for every Aave user of USDT (2.11 `REQ-SWAP-123`, playbook P-20). The token-issuer playbook covers offboarding and migration after a blocklist of an Avana contract. Changed rules: `SPEC-BACK-008`, the route `TransferMismatch` rules, the 2.5 repay rule, `REQ-SWAP-108`, `EXT-017`, `ATTACK-058`, `ATTACK-059`, `ATTACK-148`, `ATTACK-149`. |
| Status | Resolved in spec |
| Verification | `TEST-221`, `TEST-228` |

#### FINDING-142: A price-feed phase change disabled the grace latch

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Medium |
| Component | LPOracle grace latch |
| Reference | `Q-129`, `Q-272`, `ATTACK-150` |
| Description | The grace latch reads the round before the first fresh round to measure the outage. When an outage ends on the first round of a new aggregator phase, that lookup fails and no interval is found. |
| Impact | Accounts with HF 0.95–1.0 liquidated without the 30-minute grace after an outage. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-272`: when a leg's current round is the first of its phase, the LPOracle reads the previous phase's last round through `phaseAggregators(phaseId − 1)`; if that read fails it treats the lookup as evidence of a gap of at least `cachedWindow` and applies grace. Changed rules: `SPEC-ORC-014`, `REQ-ORACLE-089`, `EMG-008`, `EMG-034`. |
| Status | Resolved in spec |
| Verification | `TEST-220`, `TEST-219` |

#### FINDING-143: Pool share was tested only at pledge

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Medium |
| Component | RiskModule pool-share check, backup routes |
| Reference | `Q-187`, `Q-241`, `Q-273`, `Q-399` |
| Description | If 80 % of the other liquidity leaves a pool, Avana's share rises from 10 % to 35.7 %, and TWAP manipulation cost and backup-route depth fall about 5×, while borrowing against the market continued. |
| Impact | New debt against a market that has become cheap to manipulate and hard to liquidate. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-241`, revised by `Q-399`: the concentration gate blocks new borrowing and pledges that raise pool exposure while Avana's combined liquidity in the pool, over every borrower, market and Spoke on the chain, times 10⁴ exceeds `poolShareMaxBps` (10 %, settable lower per pool at listing) times the pool's time-weighted liquidity; `breakerPoolShareBps` is merged into it. In the example the share of 35.7 % is above 10 %, so new borrowing against the market stops; repay, exits and liquidation stay open. `Q-273`: a backup DEX route never trades through the market's own pool, and the listing check verifies it. Changed rules: `SPEC-BRK-002`, `REQ-ROUTE-043`, the listing steps of 3.8. |
| Status | Resolved in spec |
| Verification | `TEST-228`, `TEST-252` |

#### FINDING-144: Keeper reimbursement was sized as if keepers did every liquidation

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Low |
| Component | Keeper reimbursement budget |
| Reference | `Q-185`, `Q-249` |
| Description | Permissionless searchers take every liquidation with a positive payout, so approved keepers are left with the loss-making ones; a budget sized from simulations in which keepers did all liquidations runs out early in a stress event. |
| Impact | Keepers stop liquidating loss-making accounts mid-incident. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-249`: `keeperReimbursementBudget` is sized assuming keepers receive only loss-making liquidations, monitoring warns at 50 % and pages at 25 % remaining, and keepers submit through private order flow. Changed rules: the parameter registry note and the keeper section of the services description. |
| Status | Resolved in spec |
| Verification | `TEST-215`, `TEST-218` |

#### FINDING-145: Small accounts are guaranteed keeper losses

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Low |
| Component | Minimum pledge value, keeper reimbursement |
| Reference | `Q-215`, `Q-230`, `Q-277`, `ATTACK-147` |
| Description | At `minPledgeUsd` $10 the maximum debt is $2.84 and the minimum 2 % bonus pays $0.06, while liquidation costs 0.6–1.0 M gas, $40–$300 at 20–100 gwei. |
| Impact | Each such account is a reimbursement cost, or dust deficit if left unliquidated. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | Accepted risk. Owner: Avana Labs (keeper gas) and the Aave DAO (`minPledgeUsd`). `Q-277` keeps $10. Avana's own approved keepers liquidate every account whatever its size, and Avana pays their gas as its own operating cost (`Q-381`); no external keeper is reimbursed, and liquidation never depends on a keeper's profit. Bound: each account's liquidation costs at most `G(16)` = 5.15M gas; an unliquidated dust account's deficit is at most its debt, covered by the asset's First-Loss Reserve; a dust account no longer shields other markets of the account (`Q-247`). Changed rules: the `minPledgeUsd` note in the parameter registry. |
| Status | Accepted risk |
| Verification | `TEST-196`, `TEST-081`, `TEST-216` |

#### FINDING-146: Liquidation below debt × bonus pays the bonus from the reserve

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Medium |
| Component | Liquidation sizing, First-Loss Reserve |
| Reference | `Q-249`, `Q-278` |
| Description | Once collateral falls below `debt × LB`, a full seizure repays less than the debt and the gap is all bonus. Example: collateral $10,000 and debt 9,800 GHO: full seizure repays 9,524 GHO and the deficit grows from 0 to 276 GHO. Keeper speed does not remove this, because accounts fall below `LB × CF` (HF 0.3276) only in a crash, when liquidation is slowest. |
| Impact | Reserve erosion by bonus on insolvent accounts. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-278`: the deficit bound is a global invariant, `deficit_after ≤ deficit_before + seizedOracleValue × (1 − 1/LB)`, with `HF_after ≥ HF_before` while `HF_before ≥ LB × CF`. `Q-249`: the cap-sizing rule states that dividing by `LB` already counts this term. Changed rules: `INV-076`, `SPEC-CAP-007`. |
| Status | Resolved in spec |
| Verification | `TEST-216`, `TEST-218` |

#### FINDING-147: The governance Safe's own pause path took the normal delay

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Low |
| Component | AvanaTimelock short-delay list |
| Reference | `Q-262` |
| Description | With both guardians unavailable, the governance Safe could stop new activity only through `freeze` or `pause` at the normal delay of 5 days. |
| Impact | No timely stop of new activity if both guardians fail. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-262`: `freeze`, `pause`, `freezeAddress`, `tripMarketBreaker` and `tripDebtBreaker` are in `SHORT_ELIGIBLE`, so the governance Safe can stop new activity at the 12-hour short delay; these calls never block exits or liquidation. Changed rules: `REQ-ACCESS-128`, `REQ-ACCESS-155`. |
| Status | Resolved in spec |
| Verification | `TEST-244`, `TEST-063` |

#### FINDING-148: The governance Safe was the only proposer

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Medium |
| Component | AvanaTimelock proposers, governance Safe |
| Reference | `Q-245` |
| Description | If 4 of the 7 keys are lost, or the Safe renounces `PROPOSER_ROLE` by mistake, no upgrade, price-source fix, route restore or in-kind enablement can ever be proposed. Safe owner changes were instant, so 4 compromised keys could lock out the other 3. |
| Impact | Permanent loss of every repair path. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | `Q-245`: the Aave governance executor also holds `PROPOSER_ROLE`; the live-configuration check requires at least 2 proposers and no role holder outside the role table; a Safe guard limits the governance Safe to calls to the timelock and itself, and a delay module makes owner and threshold changes wait 48 hours. Changed rules: `REQ-ACCESS-004`, `REQ-ACCESS-107`, `REQ-ACCESS-160`, `REQ-ROLE-086`. |
| Status | Resolved in spec |
| Verification | `TEST-224`, `TEST-214` |

#### FINDING-149: One market's dust wave could use every market's budget window

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Low |
| Component | SettlementBudget caps (removed, `Q-397`) |
| Reference | `Q-236`, `Q-267`, `Q-397` |
| Description | Budget caps were kept per `(spoke, debt reserve)`. A dust wave in market A consumes the 500 GHO 24-hour cap, and liquidations in market B that need a draw revert for the rest of the window and become deficits. |
| Impact | Before the fix: contagion between markets through the shared budget window. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | Resolved by removal (`Q-397`): no SettlementBudget or budget window exists, so no market's dust wave can use another market's allowance; each liquidation is funded by its own caller, who sizes `debtToCover` and its funding (flash principal, exact premium and `callerFunds`) for the repayment Aave V4's dust rule may require, and pays any rounding gap at final settlement through its shortfall top-up, bounded by `maxShortfall` (`INV-034`). Earlier fix, superseded: per-market sub-caps inside each reserve's window (`Q-267`). |
| Status | Resolved in spec |
| Verification | `TEST-246`, `TEST-200` |

#### FINDING-150: Wording inconsistencies across tests and role rules

| Field | Value |
|---|---|
| Source | Design review (risk round) |
| Severity | Informational |
| Component | Test requirements, role rules, emergency rules |
| Reference | `Q-227` |
| Description | A tiny-position test stated the direction of the removal bound opposite to the Uniswap fork test, and the freeze-only key argument named no holder: both guardians hold both the pause and freeze roles. |
| Impact | None on behavior; tests and operators would act on contradictory text. |
| Evidence | Scenario in Description; confirmed by the Verification tests |
| Resolution | The tiny-position test asserts removal at the oracle ratio returns at most the oracle value plus one unit per leg, consistent with the fork test; the role and emergency rules state that both guardians hold both roles today and that the separate freeze role lets a freeze-only key be issued without unfreeze power. Changed rules: `TEST-073`, `REQ-ACCESS-009`, `EMG-042`. |
| Status | Resolved in spec |
| Verification | `TEST-073`, `TEST-116` |

#### FINDING-151: The borrow price-age limit equalled the feed heartbeat

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | High |
| Component | LPOracle feed cadence, borrow and withdraw gates, listing |
| Reference | `Q-182`, `Q-274` |
| Description | `borrowPriceMaxAge` was 3,600 s against 3,600 s heartbeats, and a heartbeat round lands 12–75 s (up to 7 minutes in congestion) after the previous one turns 3,600 s old. With two legs per market, borrow and withdraw-with-debt were refused 4.0–4.6 % of the time; 16 users signed valid borrows that reverted on-chain. With 24-hour heartbeats borrowing worked 0.05–4 % of the time. |
| Impact | Borrowing and withdrawal with debt unusable for part of every hour. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `Q-274`: each primary leg's heartbeat is at most 3,600 s and is recorded at listing; `borrowPriceMaxAge(feed) = min(heartbeat + 600, 4,200)` (4,200 s for 3,600 s feeds); a market whose USD primary has a 24-hour heartbeat is not listable. Changed rules: `REQ-ORACLE-054`, the `borrowPriceMaxAge` registry row, the listing steps of 3.8, `BOR-006`, `WDR-007`. |
| Status | Resolved in spec |
| Verification | `TEST-250` |

#### FINDING-152: A fixed floor allowance turned stressed liquidations into gas burn

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | High |
| Component | LPVaultSwap recovery floor, keeper operations |
| Reference | `Q-133`, `Q-251`, `ATTACK-141`, `ATTACK-142`, `Q-395`, `Q-401` |
| Description | During a crash routes ran 3–6 % below the oracle, so every full-size call failed `RecoveryBelowFloor`. Keepers halved down to calls under $100 (median repay $45, up to 17 calls on one account), spending $104,733 of reimbursed gas to repay $12,842, and 13 accounts waited 81 account-hours until in-kind settlement opened. |
| Impact | Reimbursement drained and liquidation delayed while conversion losses are borne only by the keeper's surplus. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `Q-251`: the caller may top up a route shortfall with its own funds in the debt asset: the floor is tested on `R + shortfall`, the shortfall is pulled from the caller and capped by `maxShortfall`, and per-leg slippage relaxes to `sLeg = min(9,999, s + min(maxShortfallBps, ⌊maxShortfall × 10⁴ / V⌋))`; example: `V` 12,422.6, routes return 12,174, the floor is 12,297, so 123 is pulled and legs run at 260 bps. No Avana fund pays a shortfall (`Q-397`). `Q-395` removed `keeperMinRepay`: Avana's keepers repay whatever Aave allows per call and answer a floor failure with a shortfall top-up, never by repeated halving. `Q-401` removed `reportRecoveryShortfall` and automatic in-kind settlement; when the approved routes are confirmed unable to settle valid liquidations at the required size, a guardian freezes new borrowing on the market (`Q-399`) while the routes are repaired. Changed rules: `SPEC-LIQ-005`, `SPEC-LIQ-019`, `REQ-SWAP-101`…`103`, `REQ-MREG-029`, `REQ-PSTORE-018`, `REQ-PSTORE-019`, the liquidation flow steps. |
| Status | Resolved in spec |
| Verification | `TEST-233`, `TEST-234` |

#### FINDING-153: The pool-share cap refused rescue top-ups during depegs

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | High |
| Component | RiskModule pool-share check |
| Reference | `Q-157`, `Q-252` |
| Description | In depegs other LPs' concentrated ranges left the price, in-range liquidity collapsed and Avana's full-range share passed 10 %, so `PoolShareExceeded` refused 69 users' pledges, including 7 rescue top-ups, in states the emergency matrix lists as open. |
| Impact | Indebted borrowers unable to add collateral and liquidated. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `Q-252`: a rescue top-up (an indebted account below `rescueHealthFactor` (1.10), charge at most the restore amount) is exempt from the pool-share test. Changed rules: `SPEC-CAP-005`, `REQ-RISK-023`, `REQ-RISK-066`. |
| Status | Resolved in spec |
| Verification | `TEST-235` |

#### FINDING-154: Repay-all sized to the quoted debt always failed

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Medium |
| Component | AaveAdapter repay, Lens, app |
| Reference | `Q-269` |
| Description | Debt accrues every second. With `maxRepaySpend` and the approval equal to the quoted debt, 100 % of first repay-all attempts reverted (226 reverts across 113 users, $3,764 of gas). |
| Impact | Borrowers cannot close in one attempt; manual buffers leave standing allowances. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `Q-269`: `quoteRepayAll = ⌈debt × (1 + rate × (deadline − now)) × 1.001⌉` sizes both `maxRepaySpend` and the approval; `repayAll` pulls `maxRepaySpend`, repays, and refunds the unused part in the same call, so the allowance ends at 0. Partial repay is unchanged. Changed rules: `REP-005`, `REP-009`, `REQ-PROXY-027`, `REQ-PROXY-028`, `REQ-ADAPTER-085`, `REQ-LENS-036`, the app quote rule. |
| Status | Resolved in spec |
| Verification | `TEST-248` |

#### FINDING-155: A joint stall of both routes was seen only after the slow route's heartbeat

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Medium |
| Component | LPOracle route failover |
| Reference | `Q-274` |
| Description | Both USDT routes stopped. The alternate had last updated 15 hours earlier and counted as fresh for 9.2 more hours, so the market stayed Live and then Drifting at $1.00 while USDT traded at $0.985, and liquidation ran at that price. |
| Impact | Liquidation at a frozen price for 9 hours. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `Q-274`: while a token is served by its alternate, liquidation requires every alternate leg within its `borrowPriceMaxAge`; otherwise the token counts as Cached for liquidation. Changed rules: `REQ-ORACLE-090`, `EMG-002`. |
| Status | Resolved in spec |
| Verification | `TEST-250`, `TEST-219` |

#### FINDING-156: Debt prices had a single source and no failover

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Medium |
| Component | Debt-asset pricing |
| Reference | `Q-238`, `Q-248` |
| Description | The USDC/USD feed stopped for 4 hours. USDC collateral legs failed over and stayed Live, but 126 accounts with USDC debt could not be liquidated for 2.9 hours and could not borrow or withdraw with debt for 3.1 hours. |
| Impact | Liquidation of every account holding a non-GHO debt stopped by one feed. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `Q-248`: each non-GHO debt reserve is priced by a DebtOracle with a primary, an alternate and a standby route, the same freshness, failover and agreement pipeline as collateral legs, never capped, served at `⌈accepted × (10⁴ + debtStressRiseBps) / 10⁴⌉` while Expired. Debt-feed stalls are part of the incident window used for cap sizing. Changed rules: `REQ-ORACLE-091`…`093`, `EXT-003`, `EXT-024`, parameter registry note. |
| Status | Resolved in spec |
| Verification | `TEST-231`, `TEST-230` |

#### FINDING-157: The USD band's upper bound blocked GHO markets at a GHO premium

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Medium |
| Component | LPOracle USD band |
| Reference | `Q-176`, `Q-275` |
| Description | The band was tested on uncapped prices with `usdBandHigh` 1.02. GHO at $1.047 makes √(q0·q1) = 1.023, so GHO/USDC was Drifting for 41.3 hours and borrowing was blocked when GHO demand was highest. |
| Impact | Borrowing blocked in every GHO market during a GHO premium. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `Q-275`: `usdBandHigh` is tested on the capped product `v0 · v1` and `usdBandLow` on the uncapped `q0 · q1`; GHO at $1.047 with USDC at $1.00 gives a capped product of 1.00, inside the band, so GHO markets stay Live above peg. Changed rules: `SPEC-ORC-011`, `REQ-ORACLE-009`. |
| Status | Resolved in spec |
| Verification | `TEST-251`, `TEST-167` |

#### FINDING-158: A slice top-up followed by a borrow turned the rescue budget into growth

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Medium |
| Component | Collateralization rescue units, RiskModule health check |
| Reference | `Q-157`, `Q-253`, `ATTACK-146`, `Q-398` |
| Description | An account in a full market topped up from the slice on every dip below 1.10 and then borrowed back to 1.10, consuming $35,000–$42,000 of slice in 90 days. |
| Impact | The rescue budget becomes growth capacity for one account. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `Q-253`: each record books its rescue units (all units of a rescue top-up, the slice part of a slice top-up), capped at its credited units after every debit. New debt, withdrawal with debt and removal with debt require the rescue-excluded HF `hfEx = HF − E / debt ≥ max(1, hardHealthFloor, minHealthFactor)` (`Q-398`; `hardHealthFloor` off by default). Example: HF 1.2000, debt $10,000, $1,000 of rescue collateral at CF 0.312 gives `E` = $312 and `hfEx` 1.1688. Regular borrowing power is unchanged. In a withdrawal or removal with debt the check runs after Collateralization's debit, so a record's rescue units leave with it and are not subtracted a second time. Changed rules: `REQ-COLL-016`, `SPEC-BACK-014`, `REQ-RISK-068`, `SPEC-CF-005`, `INV-082`, `REQ-PROXY-036`, `REQ-PROXY-038`, `REQ-ADAPTER-078`, `SPEC-PROXY-001`, the borrow and withdrawal flow steps. |
| Status | Resolved in spec |
| Verification | `TEST-236`, `PROP-067` |

#### FINDING-159: Paused refused top-ups while liquidation ran

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Medium |
| Component | MarketRegistry pause state, AaveAdapter pledge |
| Reference | `Q-227`, `Q-252` |
| Description | During a pause with liquidations running, an attentive user's top-up was refused (0–3 users across runs). The pause removed the cheapest rescue path in exactly the incidents in which liquidations happen. |
| Impact | Borrowers liquidated who tried to add collateral. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `Q-252`: the pause carries a reason. Under `Paused(General)` rescue top-ups are allowed and other pledges refused; under `Paused(MintPathSuspect)` every pledge and re-credit is refused, rescue included. Liquidation runs under both. Changed rules: `REQ-MREG-024`, `EMG-018`, `EMG-071`, `LIQ-002`. |
| Status | Resolved in spec |
| Verification | `TEST-235`, `TEST-192` |

#### FINDING-160: $10 dust accounts are cheap to open and costly to liquidate

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Low |
| Component | Minimum pledge value, keeper reimbursement |
| Reference | `Q-169`, `Q-230`, `Q-277`, `ATTACK-147` |
| Description | 40 accounts cost an attacker $2,750 of gas at about 18 gwei; at 250 gwei keepers spent $31,050 to liquidate them for $98 of debt, all of it reimbursed. |
| Impact | Reimbursement budget drained by dust accounts in a gas spike. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | Accepted risk. Owner: Avana Labs (keeper gas) and the Aave DAO (`minPledgeUsd`). `Q-277` keeps `minPledgeUsd` at $10, and `Q-381` confirms that there is no minimum debt. Avana's own approved keepers liquidate every account whatever its size, and Avana pays their gas as its own operating cost (`Q-381`); no external keeper is reimbursed, and liquidation never depends on a keeper's profit. Bound: the attacker pays at least the opening gas per account; each liquidation costs at most `G(16)` = 5.15M gas; an unliquidated dust deficit is at most its debt and is covered by the asset's First-Loss Reserve. Changed rules: none. |
| Status | Accepted risk |
| Verification | `TEST-081`, `TEST-218` |

#### FINDING-161: Liquidity added to a pledged NFT was never credited

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Low |
| Component | AaveAdapter, Collateralization, LPVault |
| Reference | `Q-134`, `Q-254`, `ATTACK-143` |
| Description | Anyone can call `increaseLiquidity` on a pledged NFT; 25 users did so expecting more collateral and their HF did not change, with $45,000 uncredited at day 90. Users also had to repay and withdraw the whole NFT to take out part of its liquidity. |
| Impact | Collateral the borrower owns does not count; partial exits need full repayment. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `Q-254`: `recredit` lets the depositor credit live liquidity above the record under the top-up checks (caps, price state, pause and freeze rules), booking the charge on a rebased exit basis so later exits release exactly the booked charge. `removeLiquidity` removes part of a record's liquidity to the depositor: debt-free with no gate, with debt under the RiskModule checks, the rescue-excluded HF and a remaining-record minimum. Both reconcile first and keep the backing gap. Changed rules: `REQ-ADAPTER-078`, `REQ-ADAPTER-079`, `REQ-COLL-014`, `REQ-COLL-015`, `REQ-VAULT-161`, `REQ-RISK-070`, `SPEC-BACK-013`, `INV-088`, the deposit and withdrawal flow steps. |
| Status | Resolved in spec |
| Verification | `TEST-237`, `TEST-238`, `PROP-065` |

#### FINDING-162: A maximum borrow at exactly HF 1.10 always failed

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Low |
| Component | Lens, app borrow sizing |
| Reference | `Q-268`, `Q-398` |
| Description | The health check runs after the Spoke call and interest accrues between preview and inclusion, so a borrow sized to exactly 1.10 reverted: 18 users made 36 reverted borrows. |
| Impact | Failed transactions and gas lost on the most common borrow action. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `Q-268`, revised by `Q-398`: `previewBorrowMax` sizes the recommended borrow at `recommendedHealthFactor` (1.10, a Lens value that no contract enforces) and the protocol maximum at Aave's HF 1.00, each scaled by `(1 + rate × (deadline − now)) × 1.005` so interest accrued before inclusion never makes the borrow revert. Example: $100,000 of collateral at a 70 % CF gives $63,636 recommended and $70,000 maximum before the margin. The app's "max" uses the margin-adjusted maximum. Changed rules: `REQ-LENS-035`, the app borrow rule. |
| Status | Resolved in spec |
| Verification | `TEST-247` |

#### FINDING-163: One account per wallet spreads one market's state to every market

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Low |
| Component | PositionProxy accounts |
| Reference | `Q-234`, `Q-276` |
| Description | After a crash the USD band of one market stayed breached for 718 hours, and the 16 multi-market accounts holding it could not borrow or withdraw with debt in any market for 30 days, because borrow-side gates are account-wide. |
| Impact | New activity blocked across all of a user's markets; liquidation of fresh markets is unaffected (`FINDING-134`). |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | Accepted risk. Owner: Avana Labs (app guidance). `Q-276` keeps one account per wallet per Borrow Spoke. Bound: only borrow and withdraw-with-debt are affected; repay, debt-free withdrawal, partial removal, fee collection and liquidation of the fresh markets continue; users who want isolation use separate wallets. Changed rules: a note in 2.5. |
| Status | Accepted risk |
| Verification | `TEST-203`, `TEST-226` |

#### FINDING-164: The largest single-market USDC borrow in the borrow examples was rounded up

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | AaveAdapter and borrow worked examples |
| Reference | `MATH-AR-37`, `SPEC-CF-003`, `SPEC-PROXY-001` |
| Description | 2.6 and 3.2 stated the largest USDC borrow at `hf = 1.10` as `15,600 / 1.10 / 0.9999 = 14,183.24` USDC. A borrow of 14,183.24 USDC gives `hf = 1,099,999,728,976,989,852 < 1.10e18` and reverts; 14,183.23 passes. |
| Impact | A worked figure that fails the opening gate; a borrow sized from it reverts. |
| Evidence | `z3/aave-risk/ar02_opening_gate.py` |
| Resolution | Both examples state `15,600 / 1.10 / 0.9999 = 14,183.2365`, so 14,183.23 USDC (rounded down; 14,183.24 reverts). The `previewBorrowMax` figures (1.105501, 572.58 GHO) are unchanged. Changed text: 2.6 Worked examples, 3.2 Worked Example. |
| Status | Resolved in spec |
| Verification | `MATH-AR-37` (COMPUTED) |

#### FINDING-165: The risk-premium example cited a minimum debt that does not exist

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | Borrow Spoke configuration |
| Reference | `MATH-AR-24d`, `SPEC-HUB-004`, `Q-169` |
| Description | The `SPEC-HUB-004` example said Aave's 1,000 GHO minimum debt keeps every real account above 9,999 drawn shares. There is no minimum debt (`Q-169`, `REQ-PROXY-016`), and a borrow of 1 wei records 1 drawn share. |
| Impact | The example justified the 1 bps margin by a bound that does not hold; the threshold check itself still holds through its aggregate form (`MATH-AR-23c`, `MATH-AR-24b`–`c`). |
| Evidence | `z3/aave-risk/ar05_risk_premium.py` |
| Resolution | The example states that there is no minimum debt, so an account can hold a single drawn share, and that the aggregate form still holds because the other accounts' slack absorbs it: one 1,000 GHO account at the 1 bps margin covers more than 10^16 one-share accounts. Changed rule: `SPEC-HUB-004` (example). |
| Status | Resolved in spec |
| Verification | `MATH-AR-24d` (PROVED), `MATH-AR-23c`, `MATH-AR-24b` |

#### FINDING-166: The restore-amount rounding bound held only while the price was at or above the stress floor

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | RiskModule restore amount |
| Reference | `MATH-AR-47c`, `MATH-AR-47d`, `SPEC-CAP-003` |
| Description | `SPEC-CAP-003` said `restoreBooked` exceeds the exact value by at most 3 units of 1e-8 USD. With `price8 = 1,000,000` and a $1.00 floor, `usdToRestore = 1` books `restoreBooked = 100` against an exact value near 0. |
| Impact | A stated rounding bound that is wrong by the factor `stressFloorUsd / price8` below the floor; the restore amount itself is correct. |
| Evidence | `z3/aave-risk/ar08_caps.py` |
| Resolution | The rounding sentence states that the bound exceeds the exact value by less than `max(price8, stressFloorUsd[m]) / price8 + 2` units of 1e-8 USD, and by less than 3 while `price8 ≥ stressFloorUsd[m]`. Changed rule: `SPEC-CAP-003` (rounding). |
| Status | Resolved in spec |
| Verification | `MATH-AR-47c` (PROVED), `MATH-AR-47d` (PROVED) |

#### FINDING-167: The cap-sizing tail term divided by the opening health factor

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | Caps, First-Loss Reserve sizing guidance, Lens |
| Reference | `MATH-AR-44b`, `MATH-ST-77`, `SPEC-CAP-007`, `SPEC-CAP-008`, `Q-249` |
| Description | The tail term bounded the debt of positions in a failing token by booked value × `CF_t / minOpeningHealthFactor`. That holds only at borrowing: interest accrued since lets debt reach booked value × `CF_t` while the account is not yet liquidatable (CF 0.312, opened at 1.10, 3.1% interest later, debt 3.1% above the bound). |
| Impact | The guidance understated each token's tail exposure by up to the factor 1.10: a 100,000 GHO reserve was stated to cover $352,564 of token cap plus slices instead of $320,512. |
| Evidence | `z3/aave-risk/ar07_pause_bad_debt.py`, `z3/settlement/st13_reserve_sizing.py` |
| Resolution | The tail term is `min((tokenUsdCap[t] + Σ_{m∋t} topUpSliceUsd[m]) × CF_t, Σ drawCap_a) ≤ firstLossReserveMinimum[a]`, because the debt those positions can carry before liquidation is at most their booked value times `CF_t` (health factor 1). `SPEC-CAP-008` computes `tail = min(⌈(tokenUsdCap[t] + Σ topUpSliceUsd[m]) × CF_t / 10^4⌉, drawCapUsd)`; its example gives $140,400 (`14,040,000,000,000`) and `tailCoverageBps = 7,122`. Changed rules: `SPEC-CAP-007` (ii), `SPEC-CAP-008`, `MKT-013`, `Q-249`, the `tokenUsdCap` row of 1.5 and the `TailCoverageView` NatSpec. |
| Status | Resolved in spec |
| Verification | `MATH-AR-44b` (PROVED), `MATH-AR-43`, `MATH-AR-52b`, `SYM-156`, `TEST-247` |

#### FINDING-168: The Hub addCap rule did not cover counters above a tightened cap

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | Hub cap sizing, RiskModule |
| Reference | `MATH-AR-50c`, `SPEC-CAP-006`, `SPEC-HUB-002`, `REQ-RISK-042` |
| Description | A cap tightening leaves existing records untouched, so `regularUsed` can exceed the new `marketUsdCap`. With `addCap` at `⌈(K + Z) / floor⌉`, credited units plus a slice top-up can exceed it: `K` lowered from $1,000,000 to $500,000 with $900,000 booked at the $1.00 floor, `Z = $100,000`, `addCap = 600,000`, and a $10,000 rescue top-up that Avana admits needs 910,000 tokens of Hub room. |
| Impact | The Hub rejects a rescue top-up that Avana admitted after a cap tightening. |
| Evidence | `z3/aave-risk/ar08_caps.py` |
| Resolution | `addCap(m) ≥ ceilDiv(max(marketUsdCap[m], regularUsed) + max(topUpSliceUsd[m], sliceUsed), stressFloorUsd[m])`, or `MAX_ALLOWED_SPOKE_CAP`, because every live record's remaining charge is at least `u × stressFloorUsd / 10^d` and `R + S ≤ max(K, R) + max(Z, S)` at every point. Changed rules: `SPEC-CAP-006`, `SPEC-HUB-002` (note). |
| Status | Resolved in spec |
| Verification | `MATH-AR-50c` (PROVED), `MATH-AR-50d` |

#### FINDING-169: A withdraw reconcile figure could not occur at any pool price

| Field | Value |
|---|---|
| Source | Formal verification (SymPy) |
| Severity | Low |
| Component | Withdraw worked example, Collateralization reconcile |
| Reference | `SYM-138d`, `SYM-138e`, `WDR-028`, `SPEC-BACK-012` |
| Description | 3.4 "Reconcile on exit" stated that removing 12,000,000,000 units returns `a0 = 11,998,500,000` with `a1 = 12,001,500,000`. With exact `TickMath` and the burn formulas at tick spacing 1, every pool price that returns that `a1` returns `a0` = 11,998,500,186 or 11,998,500,187. |
| Impact | A worked figure, and the `settlePending` payout derived from it, that no pool state produces. |
| Evidence | `sympy/sym08_units_oracle_backing_examples.py` |
| Resolution | The row states `a0 = 11,998,500,187` and `11,998.500187 USDC`, and the `settlePending` sentence `floor(11,998,500,187 × 6 / 12) = 5,999,250,093`. Changed text: 3.4 Reconcile on exit. |
| Status | Resolved in spec |
| Verification | `SYM-138d`, `SYM-138e` (hold) |

#### FINDING-170: The grace window could start before a recovery on a two-leg route or through a standby switch

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Medium |
| Component | LPOracle and DebtOracle grace latch |
| Reference | `Q-248`, `Q-264` |
| Description | With the latch set and no recovery interval, `recoveredAt` fell back to `min(max(t0, t1), now)` of the route timestamps. A route timestamp is its oldest leg, and a switched-in standby has no `seen` record, so the recovery is later than every `t_i`. Example: a standby switched in at 1,762,700,000 with its round at 1,762,697,000 and token0 at 1,762,698,000 gave `recoveredAt = 1,762,698,000` and a window ending at 1,762,699,800, before the poke. |
| Impact | Accounts with HF in [`graceHealthFactor`, 1) are liquidated at once after the outage ends. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The latch fallback takes the newest leg in use, `min(max over legs in use of updatedAt, now)`; a poke that observes a route-version change while `expiredLatched` is set starts grace at `recoveredAt = now`, and `REQ-ORACLE-065` admits that observation. The DebtOracle follows by `REQ-ORACLE-092`. Changed rules: `REQ-ORACLE-032`, `REQ-ORACLE-065`, `REQ-ORACLE-095`. |
| Status | Resolved in spec |
| Verification | `TEST-252`, `TEST-219`, `TEST-231` |

#### FINDING-171: A view could miss a disagreement no poke had seen when the pause window was 0

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Low |
| Component | LPOracle disagreement windows |
| Reference | `Q-199`, `Q-208` |
| Description | `disagreementExpired` required `disagreeSince ≠ 0`. With `disagreementPauseMax = 0` (allowed, the bound is ≤ 3,600) and `disagreeSince` read as 0 (no poke yet in the episode, or a route-version change since the last poke), neither `pauseActive` nor `disagreementExpired` held, so a view served the primary-route price and reported liquidation open. |
| Impact | A view-only caller (Aave, the Lens) could value a disagreeing market at its primary routes; every Avana caller pokes first, and the launch value 3,600 s is unaffected. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `disagreementExpired = D ∧ now ≥ s + disagreementPauseMax` with the same `s` as `pauseActive`, so `D ⇒ pauseActive ∨ disagreementExpired` for every `disagreementPauseMax ≥ 0`. Changed rules: `SPEC-ORC-016`. |
| Status | Resolved in spec |
| Verification | `TEST-230` |

#### FINDING-172: The 1.4 pause table named the wrong error for a new pledge under Paused(General)

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | Permissions and roles pause table |
| Reference | `Q-252` |
| Description | The cell for a new account's pledge under `Paused(General)` said `ApplicationPaused`; the Adapter sets `requireRescue` and the RiskModule reverts `NotRescueTopUp`. |
| Impact | Wrong error named to integrators; no behaviour change. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The cell reads "No (`NotRescueTopUp`: the Adapter sets `requireRescue`)". Changed rules: 1.4 Application pause state table. |
| Status | Resolved in spec |
| Verification | `TEST-235` |

#### FINDING-173: Two rules named different errors for one pledge below minPledgeUsd

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | RiskModule minimum pledge |
| Reference | `Q-252`, `Q-277` |
| Description | `REQ-RISK-057` said a pledge below `minPledgeUsd` not admitted as a rescue reverts `BelowMinPledge` whatever its other exemption reasons; `REQ-RISK-066` reverts `NotRescueTopUp` when the value is not its only exemption reason. Example: a $12 new-account pledge into a market with `minPledgeUsd = $50` whose pool-share cap is exceeded. |
| Impact | Two specified errors for one call; no behaviour change. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `REQ-RISK-057` reverts `BelowMinPledge(pledgeUsd, min(minPledgeUsd, RESCUE_MIN_PLEDGE_USD))` below the rescue minimum and otherwise follows `REQ-RISK-066`'s order. Changed rules: `REQ-RISK-057`. |
| Status | Resolved in spec |
| Verification | `TEST-235` |

#### FINDING-174: The REQ-PSTORE-006 example overstated the spend bound

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | ParameterStore buy slippage allowance |
| Reference | `Q-261` |
| Description | The example gave 10,048 GHO; `SPEC-LIQ-015` takes the ceiling in GHO wei, so the bound is 10,047.99 GHO and a 10,048 GHO spend reverts `GhoSpendTooHigh`. |
| Impact | Wrong figure in an example; no behaviour change. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The example reads `10,000 × 0.9998 × 1.005 = 10,047.99` GHO (`10,047.99e18` wei). Changed rules: `REQ-PSTORE-006`. |
| Status | Resolved in spec |
| Verification | `TEST-246` |

#### FINDING-175: A removed debt reserve could keep budget caps below the per-call bound

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | MarketRegistry debt reserves, SettlementBudget caps (removed, `Q-397`) |
| Reference | `Q-267`, `Q-397` |
| Description | `removeDebtReserve` left the reserve's SettlementBudget caps in place, and `REQ-CONFIG-050` checks an allowance raise only against approved reserves, so a removed key could end with `0 < perCallCap < 2 × floorRoundingAllowanceGho` against `SPEC-SET-002`'s bound for every key. Counterexample: removed key with caps (2, 2), allowance raised from 1 to 2. |
| Impact | None for honest flows: a removed reserve cannot be named, and relisting re-checks it. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | Resolved by removal (`Q-397`): the SettlementBudget and its caps no longer exist, so a removed debt reserve leaves no cap behind. Earlier fix, superseded: the removal operation zeroed the reserve's budget caps. |
| Status | Resolved in spec |
| Verification | `TEST-246` |

#### FINDING-176: The Lens paging rules gave two outcomes for one call

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | Lens |
| Reference | `Q-194`, `Q-268` |
| Description | `REQ-LENS-014` and `REQ-LENS-024` returned an empty array for an offset past the last record "for any limit", while `REQ-LENS-020` and `REQ-LENS-023` revert `LimitTooHigh` above `LENS_MAX_PAGE`. Example: `n = 1,250`, `offset = 1,250`, `limit = 201`. |
| Impact | Two specified outcomes for one call; no behaviour change. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `REQ-LENS-014` applies the limit checks of `REQ-LENS-023` first, and `REQ-LENS-024` covers limits up to `LENS_MAX_PAGE`. Changed rules: `REQ-LENS-014`, `REQ-LENS-024`. |
| Status | Resolved in spec |
| Verification | `TEST-247` |

#### FINDING-177: The pool-share breaker blocked borrowing in GHO markets at a GHO premium

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Medium |
| Component | RiskModule pool-share breaker |
| Reference | `Q-241`, `Q-273`, `Q-275` |
| Description | With GHO at $1.046 the other LPs' ranges near peg fell out of range, Avana held 41.4% of in-range liquidity, and `SPEC-BRK-002` blocked GHO/USDC borrowing and withdraw-with-debt for 44.8 hours (44.2–45.0 across seeds). |
| Impact | New activity blocked exactly when GHO demand is high, with no risk controlled: the premium cannot inflate collateral valued at the $1 ceiling. |
| Evidence | Simulation result in Description; confirmed by the Verification tests |
| Resolution | `SPEC-BRK-002` trips POOL_SHARE only while the LP's uncapped USD level is at or below peg, `q0 × q1 ≤ 10^16`; stated in `Q-241` and `EMG-068`. Changed rules: `SPEC-BRK-002`, `EMG-068`, `EMG-089`, `Q-241`. |
| Status | Resolved in spec |
| Verification | `TEST-228` |

#### FINDING-178: PROP-065 said nothing lowers the backing gap, but an unburned pending settlement does

| Field | Value |
|---|---|
| Source | Formal verification (custody contracts) |
| Severity | Informational |
| Component | Collateralization backing, LPVaultSwap pending settlement |
| Reference | `Q-257` |
| Description | `PROP-065` stated that only a `burnSeized` not followed by its debit raises the backing gap `totalCredited + pending.units − totalSupply` and that nothing lowers it. `SPEC-BACK-012` admits `settlePending(x)` whenever `totalSupply + x ≤ totalCredited + pending.units`, so after an orphan burn a non-conforming LPVaultSwap can settle without burning. Example: an orphan burn of 1,575,000,000 units, then a withdrawal that reconciles them into pending (`totalCredited = 3,425,000,000`, `pending.units = 1,575,000,000`, supply 3,425,000,000, gap 1,575,000,000); `settlePending(vt, 1,575,000,000)` without a burn passes the check and the gap falls to 0. |
| Impact | None: every remaining unit stays backed. A prover rule written from the old wording could not pass against the specified `settlePending`. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The property states that only a `settlePending(x)` called without a matching burn lowers the gap, by the units of `x` not burned in that call and never below 0 (`SPEC-BACK-012`), and its environment havocs LPVaultSwap's `burnSeized` and `settlePending` calls. Changed rule: `PROP-065`. |
| Status | Resolved in spec |
| Verification | `PROP-065`, `TEST-241` |

#### FINDING-179: Several rules listed only the exits that existed before partial removal, re-credit and deleverage release

| Field | Value |
|---|---|
| Source | Formal verification (custody contracts) |
| Severity | Informational |
| Component | Collateralization reconcile on exit, ledgers |
| Reference | `Q-201`, `Q-254`, `Q-255` |
| Description | `REQ-VAULT-129`, `REQ-VAULT-130`, `REQ-COLL-006`, `INV-008`, `INV-058` and `PROP-045` enumerated the crediting, debiting, reconciling and closing calls as `pledge`, `release`, `releaseZeroCredit` and `settleSeizure` only, while `SPEC-BACK-011` and `REQ-VAULT-140` also reconcile in `releasePartial`, `recredit` and `releaseForDeleverage`. `INV-058` also said `settlePending` has the LPVault remove liquidity, although the removal happens at reconciliation and `settlePending` transfers pool tokens Collateralization already holds. |
| Impact | None on behaviour; tests written from the shorter lists would miss three reconciling calls. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | Every list names all six reconciling calls with their `S` (current supply plus the withdrawn units in `release`, `releasePartial` and `releaseForDeleverage`; current supply in `recredit` and `releaseZeroCredit`; the snapshot in `settleSeizure`); `REQ-VAULT-129` adds `+added` at `recredit` and `−units` in `releasePartial` and `releaseForDeleverage`; `REQ-COLL-006` adds a `releaseForDeleverage` that debits every credited unit; `INV-058` has `settlePending` transfer the pending pool tokens from Collateralization to LPVaultSwap. Changed rules: `REQ-VAULT-129`, `REQ-VAULT-130`, `REQ-COLL-006`, `INV-008`, `INV-058`, `PROP-045`. |
| Status | Resolved in spec |
| Verification | `PROP-045`, `TEST-150`, `TEST-151`, `TEST-153` |

#### FINDING-180: Two rules described call orders the specified flows do not follow

| Field | Value |
|---|---|
| Source | Formal verification (custody contracts) |
| Severity | Informational |
| Component | Collateralization checks-effects-interactions, RiskModule health check |
| Reference | `Q-148`, `Q-253` |
| Description | `REQ-COLL-018` said a withdrawal or partial removal runs the health check before its call into Collateralization; the decided order runs it after `release` or `releasePartial` has returned, so a withdrawn record's rescue units are not subtracted twice. `REQ-VAULT-089` said every update completes before the LPVault removes liquidity, but reconciliation books `pending.amount0` and `amount1` from the balance delta around its own `removeLiquidity`, and runs before the call's own debit. |
| Impact | None: pool tokens have no receiver hooks and every other entry point is closed under the Lock, so no state is observable mid-call. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `REQ-COLL-018` states that a withdrawal with debt and a partial removal with debt run the check after `release` or `releasePartial` has returned. `REQ-VAULT-089` states the order per step: a reconciliation completes its record, counter, total, rescue-unit and `pending.units` updates before its `removeLiquidity` calls and books the pending amounts from the delta around each; the call's own updates complete before the LPVault returns an NFT or removes or releases liquidity for that debit, and before pool tokens leave in `settlePending`; no code outside Avana runs between those steps (`REQ-ARCH-014`). Changed rules: `REQ-COLL-018`, `REQ-VAULT-089`. |
| Status | Resolved in spec |
| Verification | `TEST-150`, `TEST-152` |

#### FINDING-181: The minimum-pledge property priced the pledge at the served price and had no rescue minimum

| Field | Value |
|---|---|
| Source | Formal verification (CVL rules against 5.2) |
| Severity | Medium |
| Component | RiskModule minimum pledge |
| Reference | `Q-230`, `Q-252`, `Q-277` |
| Description | `PROP-062` computed `pledgeUsd` from the served LPOracle price and required `minPledgeUsd[m]` for every pledge. `REQ-RISK-026` prices the minimum at the last accepted price, and `REQ-RISK-066` and `REQ-RISK-067` admit a rescue top-up down to `min(minPledgeUsd[m], RESCUE_MIN_PLEDGE_USD)`. Example: with `minPledgeUsd = $50` a $12 rescue top-up passes, which the property called a violation. |
| Impact | A prover rule written from the property would fail on correct code, or an implementation written to it would refuse rescue top-ups between $10 and `minPledgeUsd`. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The property prices the minimum at `lastAcceptedPrice().price8` and requires `min(minPledgeUsd[m], RESCUE_MIN_PLEDGE_USD)` for a rescue top-up and `minPledgeUsd[m]` for every other pledge; its example adds the $12 rescue case. Changed rule: `PROP-062`. |
| Status | Resolved in spec |
| Verification | `PROP-062`, `TEST-196`, `TEST-235` |

#### FINDING-182: The address-freeze property claimed no protected address is ever frozen

| Field | Value |
|---|---|
| Source | Formal verification (CVL rules against 5.2) |
| Severity | Low |
| Component | MarketRegistry address freeze |
| Reference | `Q-242` |
| Description | `PROP-071` stated that in every reachable state no protected address is frozen. A guardian can freeze a predicted proxy address before the proxy is deployed; once deployed it is protected and still frozen. What the gates guarantee is that no call freezes an address protected at call time. |
| Impact | A prover invariant written from the old wording fails on correct code. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The property states that `freezeAddress` never freezes an address protected at call time, that the flag rises only through such a call and falls only through `unfreezeAddress` by `APPLICATION_ADMIN`, and that an address frozen before it joined the protected set stays frozen until unfrozen. Changed rule: `PROP-071`. |
| Status | Resolved in spec |
| Verification | `PROP-071`, `TEST-229` |

#### FINDING-183: The timelock property omitted the cancel of an expired operation

| Field | Value |
|---|---|
| Source | Formal verification (CVL rules against 5.2) |
| Severity | Low |
| Component | AvanaTimelock |
| Reference | `Q-228`, `Q-263` |
| Description | `PROP-058` stated that after the grace period only `cleanupExpiredOperation` touches an operation. `SPEC-GOV-013` lets a canceller still `cancel` an expired operation. |
| Impact | A rule written from the property fails on a permitted cancel. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The property says that after expiry only `cleanupExpiredOperation` or a permitted `cancel` (under the cancel rights of the same row) touches the operation. Changed rule: `PROP-058`. |
| Status | Resolved in spec |
| Verification | `PROP-058`, `TEST-194` |

#### FINDING-184: The frozen-collateral borrow property covered reserves with no supplied shares

| Field | Value |
|---|---|
| Source | Formal verification (CVL rules against 5.2) |
| Severity | Informational |
| Component | RiskModule borrow gate |
| Reference | `Q-203`, `Q-229` |
| Description | `PROP-046` required every collateral-enabled vault-token reserve of the account to be unfrozen on a successful borrow; `REQ-ADAPTER-019` checks only reserves in the collateral scope with supplied shares. |
| Impact | A rule written from the property fails on correct code when an empty reserve is enabled and frozen. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The property names the reserves enabled as collateral with supplied shares > 0. Changed rule: `PROP-046`. |
| Status | Resolved in spec |
| Verification | `PROP-046`, `TEST-155`, `TEST-156` |

#### FINDING-185: The repay-with-collateral property omitted the buy route as a GHO recipient

| Field | Value |
|---|---|
| Source | Formal verification (CVL rules against 5.2) |
| Severity | Low |
| Component | LPVaultSwap repay with collateral |
| Reference | `Q-255` |
| Description | `PROP-072` listed the GhoFlashMinter, the debt Spoke and the wallet as the only GHO recipients. For a non-GHO debt the buy leg pays GHO to the debt reserve's buy route. |
| Impact | A rule written from the property fails on every non-GHO repay with collateral. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The property adds the debt reserve's buy route for a non-GHO debt, which takes at most `maxGhoSpend` GHO. Changed rule: `PROP-072`. |
| Status | Resolved in spec |
| Verification | `PROP-072`, `TEST-239` |

#### FINDING-186: Three external calls had no interface the rules could bind

| Field | Value |
|---|---|
| Source | Formal verification (CVL rules against 5.2) |
| Severity | Medium |
| Component | LPVaultSwap, settlement and buy routes |
| Reference | `Q-209`, `Q-255`, `Q-259` |
| Description | The GHO FlashMinter had no interface under the contracts tree, so the rules could not summarise `flashFee` and left the flash path unmodelled; LPVaultSwap exposed no view of its timelock, so the admin-holder property could state only "one holder"; routes exposed no view of their second accepted lock holder, the AaveAdapter, so the lock rules could assert only that the Lock is held. |
| Impact | Weaker rules than the properties state: the admin holder and the route lock holder were not tied to named addresses. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | Added `IGhoFlashMinter` (the subset LPVaultSwap and fork fixtures call, selectors as in GHO's FlashMinter), `TIMELOCK()` on LPVaultSwap (2.11 storage `timelock`, set once by `initialize`) and `AAVE_ADAPTER()` on settlement and buy routes (2.12). Changed text: 2.11 Storage and Functions, 2.12 Functions. Superseded by the AMM-neutral design (`Q-334`, `Q-333`): `IGhoFlashMinter` and `IGsm` are removed from `contracts/src`; LPVaultSwap flash-borrows the debt asset through `IFlashSource` (2.11 `REQ-FLASH-001`), whose callback rules `PROP-080` covers, and no buy route exists (2.12 `REQ-ROUTE-031`). |
| Status | Resolved in spec |
| Verification | `PROP-037`, `PROP-070` |

#### FINDING-187: The reconcile property listed only three reconciling calls

| Field | Value |
|---|---|
| Source | Formal verification (CVL rules against 5.2) |
| Severity | Informational |
| Component | Collateralization reconcile on exit |
| Reference | `Q-201`, `Q-254`, `Q-255` |
| Description | `PROP-045` listed `release`, `releaseZeroCredit` and `settleSeizure`; `SPEC-BACK-011` and `REQ-VAULT-140` also reconcile in `releasePartial`, `recredit` and `releaseForDeleverage`. The same text gap as `FV-CUS-F-08`. |
| Impact | The CVL rules covered three of the six calls. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The property lists the six reconciling calls of `REQ-VAULT-140` with their `S` per `SPEC-BACK-011`, and `settlePending` transfers the pool tokens from Collateralization's balance. Changed rule: `PROP-045`. |
| Status | Resolved in spec |
| Verification | `PROP-045`, `TEST-150`, `TEST-151` |

#### FINDING-188: A rescue top-up restored only part of the gap after a price fall

| Field | Value |
|---|---|
| Source | User simulation |
| Severity | Low |
| Component | RiskModule restore amount |
| Reference | `Q-157`, `Q-252` |
| Description | `SPEC-CAP-003` divided the restore amount by the accepted price. While a market is Drifting the served price, at which Aave values collateral, can be below the accepted one. USDe/USDT at day 60.25: accepted $1.9895, served $1.5480; a top-up worth the restore amount at the served price was charged 1.27 × `restoreBooked` and refused, and the largest admitted rescue restored 77.8% of the gap (HF 1.05 to 1.089 instead of 1.10). |
| Impact | Borrowers needing a rescue during a price fall could not restore the opening health factor in one top-up. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `restoreBooked = mulDiv(usdToRestore, max(price8, stressFloorUsd[m]), served8, Ceil)` with `served8 = LPOracle.latestAnswer()`: the collateral that restores the rescue target `h_o` (`rescueHealthFactor`, 1.10) at Aave's price, booked at the accepted price; the rounding bound is less than `max(price8, stressFloorUsd[m]) / served8 + 2` units. `REQ-RISK-026` states that the accepted and served prices are equal only while Live. Changed rules: `SPEC-CAP-003`, `REQ-RISK-026`. |
| Status | Resolved in spec |
| Verification | `TEST-235`, `PROP-062` |

#### FINDING-189: An oversized debtToCover sold back at the sell-back floor still lowered Avana's fee

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Low |
| Component | LPVaultSwap Avana fee |
| Reference | `Q-256` |
| Description | `SPEC-LIQ-009` capped `A` at the surplus `S = max(0, R' − Gnet − φD)`. The sell-back floor allows `cBuy` of a leftover whose size the caller chooses, so an oversized `debtToCover` sold back below value raised `Gnet` until `S` fell below the fee term. On the LIQ-069 numbers, `debtToCover` oversized by 100,000 USDC and the 100,010 USDC leftover sold 85 GHO under value (passing `minBack = 99,709.97` GHO less 1 wei) gave `Gnet = 5,085`, `S = 0`, `A = 0`, and the call completed. |
| Impact | Avana's 17.96 GHO fee went to the caller, less the caller's cost of buying the extra debt asset. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `A = min(⌊max(0, V − Gcov − φD) × avanaFeeShareBps / 10⁴⌋, max(0, R' − Gcov − φD))`; `S` and `keeperOut` stay on `Gnet`, so the round trip `Gnet − Gcov` comes from the caller's payout or the call reverts with `InsufficientProceeds`. The oversized example now owes `A = 16.966` GHO and reverts unless the caller adds it. Changed rules: `SPEC-LIQ-009`, `INV-036`, `INV-086`, `PROP-069`, `TEST-240`, `Q-256` and the fee rows of 1.2, 1.5 and 4.2. |
| Status | Resolved in spec |
| Verification | `TEST-240`, `PROP-069` |

#### FINDING-190: The deleverage health-factor threshold missed the unit allowance and rounding

| Field | Value |
|---|---|
| Source | Formal verification (liquidation); Formal verification (Z3) |
| Severity | Informational |
| Component | LPVaultSwap repay with collateral |
| Reference | `Q-255`, `MATH-ST-75` |
| Description | `SPEC-LIQ-020` said the sizing meets `x × HF ≥ V × CF` for every account with `HF ≥ CF × (10⁴ + maxFlashFeeBps) / (10⁴ − s)`. At that exact health factor the subtracted `U` and the floors of `V`, `Vnet` and `cap` leave `x × HF` just below `V × CF` (`s = 100`, `maxFlashFeeBps = 0`, `U = 2·10¹²`, `V = 10¹⁸ + 1` wei: `x·HF = 0.99999798·CF < V·CF`). |
| Impact | None on funds: the AaveAdapter reverts such a call with `HealthFactorNotImproved`. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The threshold is `HF ≥ CF × (10⁴ + maxFlashFeeBps) × V / ((10⁴ − s) × V − 10⁴ × (U + 2) − maxFlashFeeBps)` (0.3152 at CF 0.312, `s = 100` and any repayment above 1 GHO). Changed rule: `SPEC-LIQ-020`. |
| Status | Resolved in spec |
| Verification | `TEST-239` |

#### FINDING-191: The per-leg minimums could exceed the aggregate floor by more than rounding when a leg was dust

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Informational |
| Component | LPVaultSwap per-leg minimum output |
| Reference | `Q-250` |
| Description | `SPEC-LIQ-018` said `Σ minOutᵢ ≤ minGho + n + U` whenever the pool trades at the oracle-implied price. A leg worth less than its unit plus `⌊floorRoundingAllowanceGho / n⌋` has its minimum clamped at 1 while the other leg keeps only its share of the allowance: legs of 100 and 0.3 GHO at `s = 100` give minimums of 98.499999 GHO and 1 wei against `minGho = 98.296998` GHO, 0.202999 GHO above the stated bound. |
| Impact | None on funds; routes that return between the two bounds are relaxed by the shortfall top-up of `SPEC-LIQ-019`. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `Σ minOutᵢ ≤ minGho + n + U + ⌈2·c·10¹⁰ / 10^d⌉` while no leg minimum is clamped at 1, and `≤ minGho + n + 2U + ⌊floorRoundingAllowanceGho / n⌋ + ⌈2·c·10¹⁰ / 10^d⌉` in every case (the last term is the LP-price rounding of `FINDING-200`). Changed rules: `SPEC-LIQ-018`, `INV-083`. |
| Status | Resolved in spec |
| Verification | `TEST-232`, `PROP-068` |

#### FINDING-192: A whole-debt Lens quote reverted once interest accrued before inclusion

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Medium |
| Component | Lens liquidation preview |
| Reference | `Q-268` |
| Description | Aave's drawn index grows every second, so at inclusion the whole debt is above a quoted whole-debt `debtToCover`, and Aave, which then requires the whole debt, reverts with `MustNotLeaveDust`. Every preview whose repayment is the whole debt was affected: small and deeply underwater accounts, which create deficits. Example: 900 GHO owed at HF 0.90, quoted 900 GHO; one block later the debt is 900.000009 GHO and the call reverts. |
| Impact | Previewed liquidations of the accounts that most need liquidating failed until re-quoted. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `debtToCover = ⌈total × (10⁴ + LENS_DUST_MARGIN_BPS) / 10⁴⌉` with `total = getUserTotalDebt(debtReserveId, proxy)`, for a GHO debt reserve, and for any other reserve when `expectedDebtRepaid` is the whole debt, when the sizing seizes all of the account's supplied shares in the market, or when the remainder is within the margin of Aave's dust threshold. Examples: 42,478.926 GHO; 1,113 USDC with `maxGhoSpend` 1,116.339 GHO; the 900 GHO account is quoted 945 GHO. Changed rules: `REQ-LENS-028`, `REQ-SWAP-005`, `Q-268`, the `LENS_DUST_MARGIN_BPS` rows of 1.5 and 2.17. |
| Status | Resolved in spec |
| Verification | `TEST-247` |

#### FINDING-193: A collateral-limited non-GHO Lens quote reverted after a pledge

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Low |
| Component | Lens liquidation preview |
| Reference | `Q-268` |
| Description | When the seizure takes all of the market's collateral and the remainder is outside the dust margin, the Lens quoted `expectedDebtRepaid`. A pledge before inclusion raises the debt Aave sizes from that collateral above the quote, and the call reverts. Example: 20,000 USDC owed against 400 vault tokens at $2, quoted 761.904762 USDC; after a $10 pledge Aave sizes 771.428572 USDC. |
| Impact | A borrower could block a previewed liquidation with a small pledge. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | Same rule as `FINDING-192`: a sizing that seizes all of the account's supplied shares is quoted as the margined whole debt (21,000 USDC in the example). Changed rules: `REQ-LENS-028`, `REQ-SWAP-005`. |
| Status | Resolved in spec |
| Verification | `TEST-247` |

#### FINDING-194: The tail-coverage view overflowed for an unlimited draw cap

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Informational |
| Component | Lens tail coverage, First-Loss Reserve sizing |
| Reference | `Q-249` |
| Description | `REQ-LENS-034` counted an unlimited `drawCap` as `type(uint256).max`, so `drawCapUsd = Σ drawCap × Pa` overflowed and a checked implementation reverted the view; it also broke the `2¹²⁸` bound of `SPEC-CAP-008`. `SPEC-FLR-005` compared a USD-derived tail in base units with `Σ drawCap` in whole units. |
| Impact | Monitoring lost the tail-coverage view for an asset with an unlimited Spoke draw cap. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | When any `drawCap` is Aave's `MAX_ALLOWED_SPOKE_CAP`, `drawCapUsd = type(uint256).max` and the sum is not computed; `SPEC-FLR-005` writes the draw-capacity term as `Σ drawCap × 10^{d_a}`. Changed rules: `REQ-LENS-034`, `SPEC-CAP-008`, `SPEC-FLR-005`. |
| Status | Resolved in spec |
| Verification | `TEST-247` |

#### FINDING-195: The per-call cap example used parameters at which no draw happens

| Field | Value |
|---|---|
| Source | Formal verification (liquidation); Formal verification (Z3) |
| Severity | Informational |
| Component | SettlementBudget per-call cap (removed, `Q-397`) |
| Reference | `Q-267`, `MATH-ST-58`, `Q-397` |
| Description | The `SPEC-SET-002` example used `cBuy = 200` at a bonus of 10,200, where `bNet × 10⁴ = (10⁴)(10⁴ + 200)` gives `s = 0`; `SPEC-SET-001` then sets `Bd = 0` and the call reverts with `InsufficientProceeds` instead of drawing 1.00000353 GHO. |
| Impact | None; a worked example that cannot occur. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | Resolved by removal (`Q-397`): no budget draw or per-call cap exists, so the example is gone with `SPEC-SET-002`'s bound. Earlier fix, superseded: the example used `cBuy = 150`. |
| Status | Resolved in spec |
| Verification | `TEST-246` |

#### FINDING-196: The LIQ-069 account did not give the stated repayment and seizure

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Informational |
| Component | Liquidation and Lens worked examples |
| Reference | `Q-268` |
| Description | With 40,456.12 USDC owed, Aave targets 4,990.0000984 USDC, pulls 4,990,000,099 units and seizes 2,544,900,050, not the stated 4,990,000,000 and 2,544,900,000. |
| Impact | None; worked figures off by a few base units. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | The debt is 40,456.119927 USDC in `LIQ-069`, `REQ-LENS-009`, `REQ-LENS-017` and `REQ-LENS-028`: HF stays 0.9997, Aave pulls exactly 4,990,000,000 units and the account ends at 35,466.119927 USDC, HF 1.10. The GHO variant states `expectedDebtRepaid` ≈ 4,990 GHO and about 2,544.9 vault tokens. |
| Status | Resolved in spec |
| Verification | `TEST-247` |

#### FINDING-197: The deficit-coverage example wrote the share burn without the virtual offset

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Informational |
| Component | Deficit coverage worked example |
| Reference | `Q-236` |
| Description | `DEF-006` wrote `⌈475.3e18 × 2,000,000 / 2,050,000⌉`, which is 463.707317073170731708; the stated 463.707317073170731713 is the `SPEC-FLR-001` value with the Hub's virtual offset. |
| Impact | None; the expression and its value disagreed. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `DEF-006` writes `⌈475.3e18 × (2,000,000e18 + 10⁶) / (2,050,000e18 + 10⁶)⌉ = 463.707317073170731713`. |
| Status | Resolved in spec |
| Verification | `MATH-ST-89`, `MATH-ST-46`, `TEST-282` |

#### FINDING-198: A liquidation example floored the health factor to the wrong digit

| Field | Value |
|---|---|
| Source | Formal verification (liquidation) |
| Severity | Informational |
| Component | Liquidation worked example |
| Reference | `Q-268` |
| Description | `LIQ-068` step 1 wrote `⌊282,464 × 0.2812 / 79,452.85⌋ = 0.9997`; the value is 0.999698…, which floors to 0.9996. |
| Impact | None. |
| Evidence | Counterexample in Description; confirmed by the Verification tests |
| Resolution | `LIQ-068` writes `282,464 × 0.2812 / 79,452.85 ≈ 0.9997`. |
| Status | Resolved in spec |
| Verification | `MATH-ST-93`, `TEST-282` |

#### FINDING-199: The pending-settlement floor example omitted the USDT price from U

| Field | Value |
|---|---|
| Source | Formal verification (Z3) |
| Severity | Low |
| Component | LPVaultSwap pending-settlement floor |
| Reference | `MATH-ST-84`, `Q-236` |
| Description | With USDT at $0.9995, `U = 10¹² + 999,500,000,000 = 1,999,500,000,000` wei, not the stated `2·10¹²`, so `minPending` is 82.5273619005 GHO, not 82.5273619 GHO. |
| Impact | None; a worked figure. |
| Evidence | `z3/settlement/st14_worked_examples.py` |
| Resolution | The `SPEC-LIQ-014` example states `U = 1.9995·10¹²` wei and `minPending = 83.5273639 − 0.0000019995 − 1 = 82.5273619005` GHO. |
| Status | Resolved in spec |
| Verification | `TEST-232` |

#### FINDING-200: The per-leg minimums could exceed the aggregate floor by the LP price's rounding

| Field | Value |
|---|---|
| Source | Developer (Hypothesis model) |
| Severity | Informational |
| Component | LPVaultSwap per-leg minimum output |
| Reference | `HYP-85`, `Q-250` |
| Description | `INV-083` and `SPEC-LIQ-018` said the per-leg minimums sum to at most `minGho + n + U`. `V` comes from the 8-decimal LP price, up to 2 units of 10⁻⁸ USD per whole vault token below the exact value, while each leg is valued directly. DAI/USDC (`d = 12`), `c = 3,414,711,693,649,457,640` units (`V = 342,643.88` GHO), `s = 1,833`: the minimums exceed the bound by 0.0429 GHO. |
| Impact | None on funds; every leg still asks for at most its own oracle value less `sLeg`. |
| Evidence | `hypothesis/test_hyp_numeric.py` (`test_hyp85_leg_minimums_within_aggregate_floor`, pinned example) |
| Resolution | Both bounds add `⌈2·c·10¹⁰ / 10^d⌉` GHO wei of LP-price rounding (0.0683 GHO in the example). Changed rules: `INV-083`, `SPEC-LIQ-018`. |
| Status | Resolved in spec |
| Verification | `TEST-232`, `PROP-068` |

### G. AMM-neutral design review (`AMMN-R1`)

Findings of the AMM-neutral design review of 2026-11-10 (run `AMMN-R1`), against the move from one Uniswap v3 full-range market, GHO debt and one Hub on Ethereum to a shared core with one integration per AMM protocol, several Hubs and several chains. Each finding is resolved by the final design; the proving checks have not yet run against the rewritten pages.

#### FINDING-201: A narrow-range position was credited at the market range's value per unit of liquidity (×979)

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | Critical |
| Component | Collateralization pledge, LPVault intake, LPOracle |
| Reference | `AMMN-RT-01`, `Q-359`, `ATTACK-004`, `ATTACK-153`, `Q-293`, `Q-363`, `Q-366` |
| Description | Pricing is per unit of liquidity over one range, but intake required only the pool's usable ticks. A $10,000 position one tick each side of spot (`L = 100,007,500`) in a market priced over `[0.90, 1.10]` (0.097854 USD per unit) was credited as $9,786,145. |
| Impact | Borrowing up to `marketUsdCap` and `depositorUsdCap` against about $10,000 of real value; the rest becomes bad debt. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-01`) |
| Resolution | A market is one (chain, AMM protocol, pool, exact position shape); for concentrated liquidity the shape is the exact `[tickLower, tickUpper]` range, an immutable of the market's VaultToken and LPOracle. A pledge requires an exact match of the position's shape with the market's (for v3 and Slipstream: equal `tickLower` and `tickUpper`, pool derived through the market's factory equal to the vault token's pool), stated in the core and checked by each integration. Changed rules: `INV-005`, `ATTACK-004`, `ATTACK-153`, `REQ-COLL-024`, `REQ-RISK-012`, `REQ-AMM-CORE-006`, `REQ-VAULT-009`, `SPEC-BACK-001`, `REQ-VAULT-002`, `REQ-VAULT-003`, `REQ-VAULT-166`, `REQ-VAULT-167`, `REQ-VAULT-173`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-279`, `TEST-264`, `TEST-265`, `PROP-083` |

#### FINDING-202: Pricing without a clamp of the oracle ratio to the range overvalued a depegged market (×2.97)

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | Critical |
| Component | LPOracle pricing math |
| Reference | `AMMN-RT-02`, `Q-359`, `ATTACK-154`, `Q-363` |
| Description | Market `[0.99, 1.01]`, token1 at $0.952 (oracle ratio 1.05, above the range). A position of `L = 1,000,000` holds 10,000 token1 worth $9,524; unclamped math gives `y = 29,708` and a value of $28,293. Missing `10^(d1−d0)` scaling mis-scales DAI/USDC by up to 10⁶. |
| Impact | Direct theft path: borrowing against 2.97× the collateral value during a depeg, when routes are thin. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-02`) |
| Resolution | Fair composition on-chain: `value = Σ amountᵢ(oracle price vector) × priceᵢ`, never spot reserves, 50/50 or weights × price. For concentrated liquidity the oracle square-root ratio is clamped to `[sqrtRatio(tickLower), sqrtRatio(tickUpper)]`, amounts are floored then reduced by 1 raw unit, tick alignment uses signed math, and uncollected fees are excluded. The served value is the minimum over holdings reachable at the oracle prices. Changed rules: `INV-078`, `ATTACK-154`, `SPEC-AMM-CORE-001`, `SPEC-AMM-V3-001`, `REQ-AMM-SLIP-012`, `SPEC-ORC-008`, `SPEC-ORC-009`, `REQ-ORACLE-104`, `REQ-AMM-CORE-013`, `REQ-AMM-V3-006`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-279`, `TEST-266`, `PROP-083` |

#### FINDING-203: A standard Spoke turns code-level liquidation guarantees into Aave-side configuration

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | High |
| Component | Aave V4 CDP Spoke configuration, vault token, RiskModule drift check |
| Reference | `AMMN-RT-03`, `Q-362`, `ATTACK-021`, `ATTACK-155`, `Q-281`, `Q-300`, `Q-363` |
| Description | On a standard Spoke, `liquidationCall(..., receiveShares = true)` credits the liquidator Spoke supply shares with no token transfer, so the vault token's recipient rule never runs. A third party seizes 100,000 units of shares worth 105,000 at bonus 1.05; a non-zero `liquidationFee` or a borrowable vault-token reserve has the same effect. |
| Impact | Seized units with no ledger debit; debt against them that can never be liquidated (about $100k of bad debt in the review's example). |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-03`) |
| Resolution | Every CDP Spoke is a standard, unmodified Aave V4 Spoke. The listing AIP sets `receiveSharesEnabled = false` on every Avana collateral reserve, `liquidationFee = 0` (or paid to Avana's fee receiver) and no reinvestment controller, and the RiskModule drift check compares each setting on every new-activity call. Drift trips a breaker that stops new activity, never liquidation. The vault token's transfer rule allows only the AaveAdapter's mint and burn, proxy to home Hub on supply, home Hub to proxy on withdrawal, and home Hub to LPVaultSwap on seizure (`REQ-VTOKEN-025`), so any other liquidator's `liquidationCall` reverts on the token transfer. The residual risk is an Aave DAO change that enables one of the settings and is used in the same block, stated in 4.3. Changed rules: `INV-093`, `INV-011`, `INV-029`, `ATTACK-021`, `ATTACK-155`, `REQ-RISK-078`, `REQ-ADAPTER-029`, `REQ-CONFIG-076`, `REQ-VTOKEN-006`, `REQ-VTOKEN-008`, `REQ-VTOKEN-009`, `REQ-VTOKEN-040`, `REQ-VTOKEN-041`. Fix pass (2026-11-10): the exposure lasts from the Aave change until the drift check trips `CONFIG_DRIFT`, which runs on every Avana entry point and on a per-block keeper poke; a seizure outside LPVaultSwap in that window is an accepted residual risk bounded by the Spoke draw caps (`INV-093`, `REQ-RISK-078`, `ATTACK-155`, `EXT-001`; `Q-382`). |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-268`, `PROP-078` |

#### FINDING-204: Pinned proxy migration admitted attacker implementations, unpatchable versions and two proxies per (wallet, Spoke)

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | High |
| Component | PositionProxy, ProxyManager, AaveAdapter |
| Reference | `AMMN-RT-04`, `Q-359`, `ATTACK-156`, `Q-363` |
| Description | With pinned proxy versions and migration, a wallet-chosen implementation became a registered proxy that could borrow past every Avana gate; old versions could not be patched; a CREATE2 address over version-specific init code gave a wallet two accounts per (wallet, Spoke); and migration had to rewrite `r.proxy`, which the immutable ledger forbids. |
| Impact | Gate bypass on borrow, unpatchable custody bugs and broken one-account accounting. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-04`) |
| Resolution | A PositionProxy is a logic-free immutable account created by CREATE2 on first use, bound at creation to one wallet, one CDP Spoke and one market. It executes only calls from the chain's AaveAdapter, which holds all logic and upgrades through the timelock. There is no beacon, no proxy upgrade and no migration, so exits never depend on proxy code. Changed rules: `INV-063`, `INV-064`, `INV-065`, `ATTACK-156`, `REQ-PROXY-050`, `REQ-PROXY-052`, `REQ-PROXY-101`, `REQ-ARCH-177`, `REQ-ADAPTER-099`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-271`, `PROP-076` |

#### FINDING-205: Per-Spoke ledgers multiplied the Hub-wide token, depositor and pool-share caps by the number of Spokes

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | High |
| Component | Collateralization cap counters, RiskModule caps |
| Reference | `AMMN-RT-05`, `Q-359`, `Q-361`, `ATTACK-157`, `Q-279`, `Q-295`, `Q-363` |
| Description | With one ledger per CDP Spoke, each ledger admitted the full `tokenUsdCap`: three Spokes holding USDT took USDT exposure from the intended $10M to $30M, and two markets on one pool doubled the pool-share cap. |
| Impact | Routes sized for one cap must absorb a multiple of it on a depeg; the shortfall becomes Hub bad debt. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-05`) |
| Resolution | One AMM-neutral Collateralization ledger per chain holds every cap counter keyed by Hub (token, depositor, pool share), so adding Spokes or markets never adds cap room; token exposure is counted per funding Hub over every Spoke that draws from it. Changed rules: `INV-092`, `INV-027`, `INV-028`, `ATTACK-157`, `REQ-COLL-002`, `REQ-COLL-026`, `SPEC-BACK-004`, `REQ-RISK-021`, `REQ-RISK-079`, `REQ-COLL-030`, `REQ-VAULT-014`, `REQ-VAULT-034`, `REQ-AMM-CORE-013`, `REQ-AMM-V3-006`. Fix pass (2026-11-10): the pool-share cap is per pool, summed over every market (every range) of that pool on the chain, so k ranges share one cap (`INV-092`, `REQ-RISK-079`, `SPEC-CAP-005`; `Q-383`). |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-272`, `PROP-077` |

#### FINDING-206: Uniswap v4 removal hooks keep the removed tokens or block removal

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | High |
| Component | Uniswap v4 integration readiness, LPVault unwind |
| Reference | `AMMN-RT-06`, `Q-363`, `ATTACK-158`, `Q-302` |
| Description | A v4 pool's hook can take a delta on remove-liquidity or revert it; a position subscriber can gas-grief removal. The unwind then returns fewer tokens than the curve amounts, or none. |
| Impact | Liquidations of a v4 market revert or are skimmed; collateral value is overstated. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-06`) |
| Resolution | Uniswap v2, Curve StableSwap-NG, Balancer and Uniswap v4 are not listed at launch; each has a readiness section with its pricing model and the guards it must pass before listing: v2 reads `getReserves`, never `balanceOf`, with effective supply including pending `feeTo` liquidity; Curve and Balancer value at the minimum token price and check the pool's reentrancy lock before every read; Uniswap v4 requires a hook allowlist with no remove-liquidity hooks or return deltas; every AMM protocol has a per-block quote-change cap. Uniswap v4 intake checks the `PoolKey` hook address bits on-chain at listing and refuses a position with a subscriber. Changed rules: `INV-078`, `ATTACK-158`, `REQ-AMM-V4-001`, `REQ-AMM-CORE-004`, `REQ-AMM-CORE-012`, `REQ-AMM-CORE-014`, `SPEC-AMM-CORE-001`, `REQ-AMM-CORE-018`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-331` |

#### FINDING-207: Read-only reentrancy and in-transaction pool-state manipulation in v2, Curve and Balancer fair-reserve pricing

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | High |
| Component | Pricing readiness for Uniswap v2, Curve and Balancer |
| Reference | `AMMN-RT-07`, `Q-363`, `ATTACK-093`, `ATTACK-159`, `Q-302` |
| Description | Fair-reserve models read pool state (reserves, supply, invariant). During a remove-liquidity callback the state is inconsistent, and a donation or sync inside one transaction changes it. `ATTACK-093` relied on the LPOracle reading no pool state. |
| Impact | Inflated collateral value for one transaction, enough to borrow and leave. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-07`) |
| Resolution | Uniswap v2, Curve StableSwap-NG, Balancer and Uniswap v4 are not listed at launch; each has a readiness section with its pricing model and the guards it must pass before listing: v2 reads `getReserves`, never `balanceOf`, with effective supply including pending `feeTo` liquidity; Curve and Balancer value at the minimum token price and check the pool's reentrancy lock before every read; Uniswap v4 requires a hook allowlist with no remove-liquidity hooks or return deltas; every AMM protocol has a per-block quote-change cap. Changed rules: `ATTACK-093`, `ATTACK-159`, `REQ-AMM-CORE-004`, `REQ-AMM-CURVE-002`, `REQ-AMM-BAL-002`, `REQ-AMM-CORE-012`, `REQ-AMM-CORE-014`, `SPEC-AMM-CORE-001`, `REQ-AMM-CORE-018`, `REQ-AMM-V3-005`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-328`, `TEST-329`, `TEST-330` |

#### FINDING-208: TWAP buffer sized for 12-second blocks lets a dust-swap griefer keep a Base market Drifting

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | Medium |
| Component | LPOracle TWAP consistency check |
| Reference | `AMMN-RT-08`, `Q-365`, `ATTACK-041`, `ATTACK-160`, `Q-363` |
| Description | Observation cardinality `n ≥ ⌈W/12⌉ + 1` gives `n = 151` for `W = 1,800 s`, which covers 302 s on 2-second blocks; 901 are needed. One dust swap per block for 151 blocks (about $2 of gas) makes `observe` revert `OLD`. |
| Impact | New pledges and borrowing stop and the served price drops to `min(fresh, A)` for as long as the griefer pays. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-08`) |
| Resolution | TWAP is a consistency check only, and its buffer is sized per chain block time: `n ≥ ⌈W / chainBlockTime⌉ + 1`, with `chainBlockTime` an immutable per chain (Base 2 s); each integration reads `slot0` with its own decoder. Changed rules: `ATTACK-041`, `ATTACK-160`, `REQ-PSTORE-027`, `SPEC-ORC-022`, `REQ-AMM-SLIP-013`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-265` |

#### FINDING-209: Concentrated ranges unwind one-sided; route stress on two half legs understated slippage

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | High |
| Component | Settlement routes, listing stress |
| Reference | `AMMN-RT-09`, `Q-363`, `ATTACK-161`, `Q-340`, `Q-365` |
| Description | A position at or past its range edge is 100% one token. In a constant-product route of depth 10V, two V/2 legs lose 4.76% each, but one V leg loses 9.09%, so the per-leg `minOut` fails even at `s = 5%`. |
| Impact | Liquidations revert or fall to the caller top-up when the stress test said they would settle. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-09`) |
| Resolution | At listing and in the route-depth monitor, each token's route is stressed with the full position value V (the single-token composition at each range edge); each token class (stable, correlated, volatile) has its own route requirements. Changed rules: `INV-083`, `ATTACK-161`, `REQ-ROUTE-006`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-281` |

#### FINDING-210: A per-chain ProxyManager serving several Adapters allowed cross-Hub proxy squatting

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | Medium |
| Component | ProxyManager, AaveAdapter |
| Reference | `AMMN-RT-10`, `Q-359`, `ATTACK-162`, `Q-279`, `Q-363` |
| Description | With one Adapter per Hub and one ProxyManager per chain, Hub A's Adapter could deploy the CREATE2 address of `(wallet, spokeOfHubB)` first, with itself as the controlling Adapter. |
| Impact | Permanent denial of service for the wallet on Spoke B, or control of its account by the wrong Adapter. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-10`) |
| Resolution | One ProxyManager and one AaveAdapter per chain, scoped by Hub inside; `deployProxy` accepts only that Adapter; the salt binds (wallet, CDP Spoke, market). A PositionProxy is a logic-free immutable account created by CREATE2 on first use, bound at creation to one wallet, one CDP Spoke and one market. It executes only calls from the chain's AaveAdapter, which holds all logic and upgrades through the timelock. There is no beacon, no proxy upgrade and no migration, so exits never depend on proxy code. Changed rules: `INV-064`, `ATTACK-162`, `REQ-PROXY-050`, `REQ-PROXY-052`, `REQ-PROXY-055`, `REQ-PROXY-101`, `REQ-ARCH-152`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-271`, `PROP-076` |

#### FINDING-211: Cross-Hub credit lines had no registry summing every Spoke that draws a funding Hub's asset

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | High |
| Component | MarketRegistry credit lines, First-Loss Reserves |
| Reference | `AMMN-RT-11`, `Q-360`, `ATTACK-163`, `Q-283`, `Q-284`, `Q-363` |
| Description | Each Hub's registry summed only its own Spokes, so a Volatile Spoke drawing Stable Hub USDC sat outside the Stable Hub's line; its deficits landed on a Hub whose First-Loss Reserve did not recognise the Spoke. |
| Impact | Funding-Hub suppliers carry more than the approved line, including volatile-collateral shortfall risk, with no coverage. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-11`) |
| Resolution | Cross-Hub credit lines are fully specified and off at launch. The funding Hub owns the cap; one registry sums the lines per (funding Hub, asset); a pause of the funding Hub stops the line; the cap is at most that Hub's first-loss coverage. `INV-057` is a gate on new draws, and the cap-sum rule is a configuration invariant on caps. Changed rules: `INV-094`, `INV-057`, `INV-042`, `ATTACK-163`, `REQ-CONFIG-081`, `REQ-ARCH-010`, `REQ-ARCH-011`, `REQ-ARCH-029`, `REQ-ARCH-040`, `REQ-ARCH-144`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-273`, `TEST-274`, `PROP-079`, `PROP-081` |

#### FINDING-212: A vault-token Hub asset attached to a second Spoke drains or strands vault-token liquidity

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | Medium |
| Component | Vault-token Hub asset, drift check |
| Reference | `AMMN-RT-12`, `Q-359`, `Q-362`, `ATTACK-164`, `Q-281`, `Q-299`, `Q-363` |
| Description | `INV-003` assumed one Spoke per vault-token asset. A second Spoke on the same Hub asset could draw vault tokens out of the Hub, and tokens sent to LPVaultSwap would read as pending balance. |
| Impact | Backing equality breaks; vault-token liquidity leaves the Hub or is stranded. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-12`) |
| Resolution | Each vault-token Hub asset has exactly one Spoke, the market's CDP Spoke, checked at `listCollateralMarket` and by the drift check; the AaveAdapter and LPVaultSwap take the Spoke only from the vault token. Changed rules: `INV-003`, `INV-093`, `ATTACK-164`, `REQ-ADAPTER-031`, `REQ-COLL-003`, `REQ-VAULT-102`, `REQ-VTOKEN-020`, `REQ-VTOKEN-021`, `REQ-VTOKEN-038`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-268`, `PROP-078` |

#### FINDING-213: A shared SettlementBudget window let one Spoke's liquidations starve another's

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | Medium |
| Component | SettlementBudget (removed, `Q-397`) |
| Reference | `AMMN-RT-13`, `Q-362`, `ATTACK-165`, `Q-343`, `Q-363`, `Q-387`, `Q-397` |
| Description | `INV-037` capped every draw in one rolling window. A busy liquidation day in one low-quality market, or a keeper farming small draws, used the whole window, and other markets' liquidations reverted or fell to permissionless mode, which cannot draw. |
| Impact | Before the fix: contagion across markets, which `INV-075` excludes. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-13`) |
| Resolution | Resolved by removal (`Q-397`): the SettlementBudget, its windows and its reserves no longer exist, so no market's liquidations can use another market's allowance. Each liquidation is funded by its own caller: the caller sizes `debtToCover` and its funding (flash principal, exact premium and `callerFunds`) for the repayment Aave V4's dust rule may require, and pays any rounding gap at final settlement through its shortfall top-up, bounded by `maxShortfall` (`INV-034`). `INV-075` therefore holds with no shared fund. Earlier fixes, superseded: per-market windows with running sums (`Q-362`) and per-market reserved floors (`Q-387`). Changed rules: `INV-037`, `INV-038`, `INV-097`, `ATTACK-165`, `SPEC-BRK-004`, `SPEC-SET-001`…`007`, `REQ-SWAP-029`, `REQ-SWAP-061` and the 2.13 requirements, each rewritten to state the removal. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-277`, `TEST-093`, `PROP-084`, `MATH-ST-109`, `FV-LIQ-04` |

#### FINDING-214: Tokenized stocks bring market-hours feeds, corporate actions and holder allowlists

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | Medium |
| Component | Volatile LP Hub listing, feeds |
| Reference | `AMMN-RT-14`, `Q-363`, `Q-365`, `REQ-READY-001`, `ATTACK-058`, `ATTACK-059`, `ATTACK-166` |
| Description | Equity feeds pause outside market hours while the DEX price moves 24/7; splits and dividends can be rebases or mints the feed and pool see differently; issuers may refuse LPVaultSwap or a route as holder. |
| Impact | Borrowing on a stale-but-valid price across a weekend gap; liquidation refused by the issuer. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-14`) |
| Resolution | Tokenized stocks are not listed at launch (launch is a Stable LP Hub on Ethereum and on Base). `REQ-READY-001` ([2.22](../02-contracts/22-amm-integration-readiness.md)) is the listing rule for any such token: (1) a market-hours feed is listed only with closed-market staleness handling, so new borrows stop while the reference market is closed and liquidation values the token at its stress price; (2) a corporate action (split, dividend) pauses new activity in every market holding the token until the feed and the pool are re-checked; (3) the issuer's holder allowlist includes the LPVault, LPVaultSwap and every swap-route contract that holds the token, checked in the listing batch. Changed rules: `REQ-READY-001`, `ATTACK-058`, `ATTACK-059`, `ATTACK-166`, `REQ-CHAIN-001`, `REQ-CONFIG-020`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-283` |

#### FINDING-215: Copied configuration paired the wrong NFPM, factory or pool implementation

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | Low |
| Component | MarketRegistry listing, Uniswap v3 and Slipstream integrations |
| Reference | `AMMN-RT-15`, `Q-359`, `ATTACK-167`, `Q-286`, `Q-301`, `Q-305`, `Q-363`, `Q-365` |
| Description | On Base both Uniswap v3 and Slipstream exist and Slipstream has three factory generations. `getPool(t0, t1, 100)` resolves to different pools (fee 100 against `tickSpacing` 100), so a copied configuration can bind a thin attacker-seeded pool. |
| Impact | A market bound to the wrong pool or position manager. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-15`) |
| Resolution | `listCollateralMarket` checks `NFPM.factory() == factory`, `pool.factory() == factory`, `factory.getPool(t0, t1, param) == pool` (fee for v3, `tickSpacing` for Slipstream), the pool code hash and the integration's `positions()` and `slot0` decoders; each integration takes the NFPM and factory only from its own immutables. Changed rules: `INV-005`, `INV-017`, `ATTACK-167`, `REQ-CONFIG-075`, `REQ-AMM-V3-002`, `REQ-AMM-SLIP-006`, `REQ-ARCH-207`, `REQ-ARCH-209`, `REQ-ARCH-027`, `REQ-ARCH-033`, `REQ-ARCH-038`, `REQ-VAULT-174`, `REQ-VAULT-097`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-264`, `TEST-265` |

#### FINDING-216: Migration could dodge an in-flight liquidation

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, red team) |
| Severity | High |
| Component | PositionProxy migration |
| Reference | `AMMN-RT-16`, `Q-359`, `ATTACK-168`, `Q-363` |
| Description | A borrower with HF < 1 front-runs the keeper by migrating to a new proxy version, so `liquidate(oldProxy, …)` reverts, once per version. |
| Impact | Liquidation delayed while the account loses value. |
| Evidence | [`red-team.md`](../../audit/design-review/amm-neutral/red-team.md) (`AMMN-RT-16`) |
| Resolution | No migration exists. A PositionProxy is a logic-free immutable account created by CREATE2 on first use, bound at creation to one wallet, one CDP Spoke and one market. It executes only calls from the chain's AaveAdapter, which holds all logic and upgrades through the timelock. There is no beacon, no proxy upgrade and no migration, so exits never depend on proxy code. Changed rules: `INV-065`, `ATTACK-168`, `REQ-PROXY-050`, `REQ-ARCH-177`, `REQ-ADAPTER-099`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-271` |

#### FINDING-217: The Lock could not admit per-Spoke vaults and ledgers

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Critical |
| Component | Lock |
| Reference | `AMMN-FLOW-01`, `Q-362`, `ATTACK-169`, `Q-279`, `Q-296`, `Q-363`, `Q-366` |
| Description | The Lock's members were four constructor immutables (`AAVE_ADAPTER`, `COLLATERALIZATION`, `LP_VAULT`, `LP_VAULT_SWAP`). A Spoke deployed later with its own vault and ledger could never join it. |
| Impact | Every pledge, release, fee collection and seizure on a later Spoke reverts with `NotMember`. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-01`) |
| Resolution | The Lock has exactly two members, the AaveAdapter and LPVaultSwap. Every LPVault and Collateralization entry point that moves value is reachable only through them, with one AMM-neutral Collateralization ledger per chain and one immutable LPVault per AMM protocol per chain, so a new CDP Spoke or market never needs a Lock redeploy. Changed rules: `INV-091`, `INV-054`, `ATTACK-169`, `REQ-COLL-029`, `REQ-ADAPTER-096`, `REQ-ADAPTER-050`, `REQ-VAULT-150`, `REQ-VAULT-064`, `REQ-VAULT-066`, `REQ-VAULT-165`, `REQ-VAULT-098`. Fix pass (2026-11-10): `INV-091`, `INV-054`, 2.16 and `ILock` say the same thing. Collateralization's value-moving functions accept only a Lock member while the Lock is held. An LPVault's position-moving functions accept only Collateralization while the Lock is held, so they run only inside a call tree a Lock member opened. `returnStray` is timelock-only and runs only while the Lock is free (`REQ-LOCK-028`, `REQ-VAULT-150`, `REQ-VAULT-165`; `Q-362`). |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-270`, `PROP-075` |

#### FINDING-218: Liquidation and deleverage on Base assumed a GHO FlashMinter, GSM routes and a $1 GHO

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Critical |
| Component | LPVaultSwap flash and settlement |
| Reference | `AMMN-FLOW-02`, `Q-362`, `Q-365`, `ATTACK-170`, `Q-333`, `Q-334`, `Q-363` |
| Description | The GHO FlashMinter and the GSMs exist only on Ethereum; GHO on Base is a bridged token with thin depth. Every Slipstream liquidation as specified needed a GHO flash mint and GHO routes, and the recovery floor counted bridged GHO at $1. |
| Impact | No liquidation funding on Base; a hidden loss to the waterfall from a bridged-GHO discount. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-02`) |
| Resolution | LPVaultSwap flash-borrows the debt asset itself through `IFlashSource`, implemented with the Aave V3 Pool `flashLoan` (single asset, mode 0) on every chain. Before the loan it checks available liquidity and the premium against `maxFlashFeeBps`; in the callback it checks initiator, caller and the active context. The flash source is never the Hub of the CDP Spoke being liquidated, the implementation is replaceable through the timelock, and when flash liquidity is short the caller funds the debt. The GhoFlashMinter, the GSM as a primary route and the leg that buys the debt with GHO are removed. LPVaultSwap swaps the unwound tokens over the swap routes into the debt asset with a per-leg oracle `minOut`, repays the flash loan plus premium, and pays the leftover in the debt asset repaid, in this order: Avana's fee (20 % of the oracle gain, capped by the realized surplus), the keeper reward, then the borrower surplus (`Q-337`, 2.11 `SPEC-LIQ-009`, `SPEC-LIQ-022`). GHO is used only when the debt is GHO. Changed rules: `INV-040`, `INV-095`, `INV-070`, `ATTACK-170`, `REQ-SWAP-011`, `REQ-SWAP-017`, `SPEC-LIQ-004`, `SPEC-LIQ-005`, `SPEC-LIQ-006`, `REQ-SWAP-012`, `REQ-FLASH-001`, `REQ-FLASH-007`, `REQ-FLASH-010`, `SPEC-LIQ-002`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-267`, `TEST-280`, `PROP-080` |

#### FINDING-219: No L2 sequencer gate, and Base feed heartbeats failed the listing rule

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | High |
| Component | LPOracle, DebtOracle, listing |
| Reference | `AMMN-FLOW-03`, `Q-362`, `Q-364`, `ATTACK-171`, `Q-287`, `Q-363`, `Q-365` |
| Description | No page read a sequencer-uptime feed; grace started only after Expired, which a short outage never reaches; `MKT-005` required heartbeats ≤ 3,600 s while Base USD feeds use 86,400 s. |
| Impact | Liquidations on the first post-outage prices while borrowers had no access; no Slipstream market could list. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-03`) |
| Resolution | Each L2 chain has a sequencer-uptime feed (Base `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`) and a grace period after restart. While the sequencer is down or inside the grace period no new risk opens; liquidation keeps its stress rules. A feed is fresh while its age is at most its own heartbeat plus a margin (Chainlink stablecoin feeds: 82,800–86,400 s); the fixed 3,600 s rule is removed. Borrow and withdraw also require an independent second source (a deep-pool TWAP or a second oracle network) to agree within the deviation band. Liquidation keeps its stress rules: stale collateral counts as 0 from Expired and stale debt uses its stress price. Changed rules: `INV-098`, `INV-023`, `ATTACK-171`, `REQ-CHAIN-003`, `REQ-ORACLE-099`, `SPEC-ORC-019`, `LIQ-086`, `REQ-RISK-081`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-275`, `TEST-276` |

#### FINDING-220: Pinned proxies had no migration flow, and the spec still used a beacon

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | High |
| Component | PositionProxy, ProxyManager |
| Reference | `AMMN-FLOW-04`, `Q-359`, `ATTACK-172`, `Q-363` |
| Description | Aave V4 has no position transfer, so migration meant repay, withdraw and re-borrow, which new-activity gates refuse in exactly the states that force migration; a bug in a pinned `repay` could not be patched. |
| Impact | Borrowers unable to repay or withdraw, then liquidated. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-04`) |
| Resolution | A PositionProxy is a logic-free immutable account created by CREATE2 on first use, bound at creation to one wallet, one CDP Spoke and one market. It executes only calls from the chain's AaveAdapter, which holds all logic and upgrades through the timelock. There is no beacon, no proxy upgrade and no migration, so exits never depend on proxy code. Changed rules: `INV-065`, `INV-043`, `INV-045`, `ATTACK-172`, `REQ-PROXY-050`, `REQ-ARCH-177`, `REQ-ARCH-152`, `REQ-ADAPTER-099`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-271`, `PROP-076` |

#### FINDING-221: Cross-Hub debt reserves split risk ownership between Hubs

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | High |
| Component | Debt reserves, First-Loss Reserves, pending settlement |
| Reference | `AMMN-FLOW-05`, `Q-360`, `ATTACK-173`, `Q-282`, `Q-283`, `Q-284`, `Q-363` |
| Description | A Volatile CDP Spoke borrowing Stable Hub USDC was governed by its home Hub's contracts while its losses fell on Stable Hub suppliers; `DEF-013` summed exposure only on the home Hub; pending settlement always paid the GHO First-Loss Reserve. |
| Impact | Loss of the isolation the three Hub tiers exist for. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-05`) |
| Resolution | Cross-Hub credit lines are fully specified and off at launch. The funding Hub owns the cap; one registry sums the lines per (funding Hub, asset); a pause of the funding Hub stops the line; the cap is at most that Hub's first-loss coverage. `INV-057` is a gate on new draws, and the cap-sum rule is a configuration invariant on caps. Each debt reserve records its funding Hub, and pending settlement sends recovered value to the First-Loss Reserve of the market's (Hub, debt asset). Changed rules: `INV-094`, `INV-071`, `ATTACK-173`, `REQ-ARCH-008`, `REQ-ARCH-013`, `REQ-ARCH-157`, `REQ-ARCH-028`, `REQ-ARCH-038`, `REQ-ARCH-010`, `REQ-ARCH-011`, `REQ-ARCH-029`, `REQ-ARCH-040`, `REQ-ARCH-144`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-273`, `TEST-280`, `PROP-079` |

#### FINDING-222: Credit lines across Hubs were enforced off-chain only

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Medium |
| Component | MarketRegistry credit lines |
| Reference | `AMMN-FLOW-06`, `Q-360`, `ATTACK-174`, `Q-283`, `Q-363` |
| Description | A credit line spanning Hubs was a sum of per-Spoke `drawCap`s set by separate AIPs; nothing on-chain checked the sum. |
| Impact | Draw caps above the approved line. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-06`) |
| Resolution | Cross-Hub credit lines are fully specified and off at launch. The funding Hub owns the cap; one registry sums the lines per (funding Hub, asset); a pause of the funding Hub stops the line; the cap is at most that Hub's first-loss coverage. `INV-057` is a gate on new draws, and the cap-sum rule is a configuration invariant on caps. `enableDebtReserve` and every cap change check the registry sum on-chain. Changed rules: `INV-094`, `INV-057`, `ATTACK-174`, `REQ-RISK-082`, `SPEC-CAP-010`, `REQ-CONFIG-081`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-273`, `TEST-274`, `PROP-081` |

#### FINDING-223: One market per Spoke contradicted the multi-market spec

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | High |
| Component | CDP Spoke topology, PositionProxy |
| Reference | `AMMN-FLOW-07`, `Q-359`, `ATTACK-175`, `Q-280`, `Q-304`, `Q-363` |
| Description | The spec put many markets in one account on one Borrow Spoke; the proposal put one market per Spoke. The choice decides seizure keys, reserve limits, drift checks, liquidation order and how many health factors a wallet has. |
| Impact | Contradictory account model across the spec. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-07`) |
| Resolution | One CDP Spoke per (chain, Hub, AMM protocol, risk tier) lists several markets, each one collateral reserve. Each wallet gets one PositionProxy per (CDP Spoke, market), so every market has its own Aave account and health factor and nothing is cross-collateralized. Changed rules: `INV-064`, `INV-075`, `ATTACK-175`, `REQ-COLL-031`, `REQ-ARCH-004`, `REQ-ARCH-207`, `REQ-ARCH-208`, `REQ-ARCH-015`, `REQ-ARCH-156`, `REQ-COLL-005`, `REQ-VAULT-013`, `REQ-VAULT-026`, `REQ-COLL-034`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-271`, `PROP-076` |

#### FINDING-224: Full-range math was used for markets with a fixed bounded range

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | High |
| Component | LPOracle, caps, collateral factor |
| Reference | `AMMN-FLOW-08`, `Q-359`, `ATTACK-176`, `Q-293`, `Q-298`, `Q-363` |
| Description | Value per unit, vault-token decimals, `MAX_CREDITED_LIQUIDITY`, the depeg shock, the CF formula and the pool-share check all assumed full range; a bounded range out of range holds one token and earns no fees. |
| Impact | Mispriced bounded markets and mis-sized caps. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-08`) |
| Resolution | A market is one (chain, AMM protocol, pool, exact position shape); for concentrated liquidity the shape is the exact `[tickLower, tickUpper]` range, an immutable of the market's VaultToken and LPOracle. Pricing is fair composition with the oracle ratio clamped to the range (see `FINDING-202`); caps and collateral factor are derived per market shape. Changed rules: `INV-005`, `INV-078`, `ATTACK-176`, `REQ-VAULT-002`, `REQ-VAULT-003`, `REQ-VAULT-166`, `REQ-VAULT-167`, `REQ-VAULT-173`, `REQ-VTOKEN-022`, `SPEC-UNIT-001`, `SPEC-UNIT-004`, `REQ-VTOKEN-036`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-279`, `TEST-266`, `PROP-083` |

#### FINDING-225: Pool spot moves turned liquidation into a revert in drained or thin pools

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | High |
| Component | LPVaultSwap unwind and recovery floor |
| Reference | `AMMN-FLOW-09`, `Q-363`, `ATTACK-177`, `Q-401` |
| Description | Anyone, including the borrower, can move the pool spot before removal so the unwound mix is worth less than the recovery floor at oracle prices; `liquidatePermissionless` reverts `RecoveryBelowFloor`. |
| Impact | Repeatable, cheap liquidation blocking in a drained pool. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-09`) |
| Resolution | The fair-composition quote does not move with spot. A spot move changes only the unwound mix; per-leg oracle `minOut` holds, and the caller's shortfall top-up covers a gap, so the liquidation does not depend on the pool's spot. In-kind settlement no longer exists (`Q-401`): when the routes cannot settle, the call reverts `NoRouteAvailable` and a guardian freezes new borrowing on the market while the routes are repaired (`Q-399`). Changed rules: `INV-078`, `INV-039`, `ATTACK-177`, `SPEC-AMM-CORE-001`, `LIQ-082`, `REQ-SWAP-025`, `SPEC-LIQ-012`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-266`, `TEST-281` |

#### FINDING-226: Slipstream differs from Uniswap v3 in the calls the flows rely on

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | High |
| Component | Aerodrome Slipstream integration |
| Reference | `AMMN-FLOW-10`, `Q-365`, `ATTACK-178`, `Q-291`, `Q-301`, `Q-305`, `Q-363` |
| Description | Slipstream factories key pools by `tickSpacing`, its NFT `positions()` returns `tickSpacing` where v3 returns `fee`, `slot0` has 6 fields (the v3 ABI reads the wrong word for `unlocked`), fees can be dynamic, and unstaked positions pay an `unstakedFee` share. |
| Impact | v3-shaped code reverts or checks the wrong value on Slipstream. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-10`) |
| Resolution | The Aerodrome Slipstream integration implements the AMM integration interface with its own pool lookup by `tickSpacing`, `positions()` and 6-field `slot0` decoders, the pool fee read live for the TWAP tolerance, the three NPM and factory generations, and unstaked NFTs only (a gauge-staked NFT is refused). Changed rules: `ATTACK-178`, `REQ-VAULT-001`, `REQ-VAULT-002`, `REQ-VAULT-004`, `REQ-VAULT-174`, `REQ-VAULT-166`, `REQ-VAULT-097`, `REQ-AMM-SLIP-001`, `REQ-AMM-SLIP-002`, `REQ-AMM-SLIP-003`, `REQ-VAULT-173`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-265` |

#### FINDING-227: One vault token per pool blocked relisting, tiers and ranges

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Medium |
| Component | VaultTokenFactory, market identity |
| Reference | `AMMN-FLOW-11`, `Q-359`, `ATTACK-179`, `Q-299`, `Q-363` |
| Description | Market identity was `tokenOfPool(pool)`, so a pool could not carry two ranges or tiers and could never be relisted on a new CDP Spoke after offboarding. |
| Impact | No path to a second range, a second tier or a relisting after a ledger or vault fix. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-11`) |
| Resolution | A market is one (chain, AMM protocol, pool, exact position shape); for concentrated liquidity the shape is the exact `[tickLower, tickUpper]` range, an immutable of the market's VaultToken and LPOracle. `listCollateralMarket` creates the VaultToken and LPOracle per market, so one pool can carry several markets and be relisted on a new Spoke. Changed rules: `ATTACK-179`, `REQ-VTOKEN-021`, `REQ-COLL-003`, `REQ-VAULT-102`, `REQ-VTOKEN-020`, `REQ-VTOKEN-038`, `REQ-VTOKEN-028`. Fix pass (2026-11-10): vault tokens are keyed by `(spoke, marketKey)`, so a market can be relisted after wind-down; 2.8 no longer reserves one token per pool for life (`REQ-CONFIG-007`, `REQ-MREG-030`, `REQ-VTOKEN-020`; `Q-359`). |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-264`, `TEST-279` |

#### FINDING-228: Aave-side halts and pauses stop repay, debt-free withdraw and liquidation

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | High |
| Component | Aave Hub and Spoke halts |
| Reference | `AMMN-FLOW-12`, `Q-365`, `ATTACK-180`, `Q-346`, `Q-363` |
| Description | Avana's pause states never block exits or liquidation, but an Aave Hub halt of a CDP Spoke or a pause of a vault-token reserve blocks all three, and halting a Spoke is the obvious containment step for one market. |
| Impact | The exits guarantee fails in the case it is meant for. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-12`) |
| Resolution | 4.3 states the Aave-side halt scope: a halt stops add, remove, draw, restore and share transfers, so supply, withdraw, borrow, repay and liquidation; deficit coverage, premium refresh and fee shares continue. Containment of a CDP Spoke uses the reserve freeze and `drawCap = 0`, never a halt or reserve pause while debt exists; the drift check reports a halted Spoke and the playbook gives a keeper path once Aave lifts it. Changed rules: `INV-081`, `ATTACK-180`, `REQ-SWAP-039`, `REQ-SWAP-119`, `REQ-SWAP-055`. Fix pass (2026-11-10): an Aave halt stops exits; this is an accepted risk with the Aave-halt playbook (`EMG-052`, `EMG-064`, `INV-081`, `ATTACK-180`; `Q-346`). Owner: Aave DAO (halt flags). Bound: positions open while the halt lasts, within each market's caps. |
| Status | Accepted risk |
| Verification | `TEST-127`, `TEST-268` |

#### FINDING-229: Liquidation access depended on an undecided Spoke variant

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | High |
| Component | Aave V4 CDP Spoke, vault token |
| Reference | `AMMN-FLOW-13`, `Q-362`, `ATTACK-181`, `Q-363` |
| Description | 32 places assumed the liquidation-manager variant. The standard-Spoke alternative holds only if every path that moves vault tokens out of the Hub checks the recipient: `receiveShares`, fee shares, reinvestment, a second Spoke on the asset, zero-amount transfers. |
| Impact | A third party seizes collateral or triggers a deficit report outside LPVaultSwap. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-13`) |
| Resolution | Every CDP Spoke is a standard, unmodified Aave V4 Spoke. The listing AIP sets `receiveSharesEnabled = false` on every Avana collateral reserve, `liquidationFee = 0` (or paid to Avana's fee receiver) and no reinvestment controller, and the RiskModule drift check compares each setting on every new-activity call. Drift trips a breaker that stops new activity, never liquidation. The vault token's transfer rule allows only the AaveAdapter's mint and burn, proxy to home Hub on supply, home Hub to proxy on withdrawal, and home Hub to LPVaultSwap on seizure (`REQ-VTOKEN-025`), so any other liquidator's `liquidationCall` reverts on the token transfer. Changed rules: `INV-093`, `INV-011`, `ATTACK-181`, `REQ-ADAPTER-028`, `REQ-ADAPTER-029`, `REQ-ADAPTER-030`, `REQ-ADAPTER-036`, `REQ-RISK-078`, `REQ-VTOKEN-006`, `REQ-VTOKEN-025`, `REQ-CONFIG-076`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-268`, `PROP-078` |

#### FINDING-230: Non-GHO debt and non-stable collateral were routed through GHO

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | High |
| Component | LPVaultSwap settlement, swap routes |
| Reference | `AMMN-FLOW-14`, `Q-362`, `Q-363`, `ATTACK-182`, `Q-333`, `Q-339`, `Q-365` |
| Description | An ETH debt against an ETH/LST market flash-minted GHO, bought ETH, then sold ETH and the LST for GHO: two swaps through GHO depth. Routes existed only for stablecoins. |
| Impact | Correlated and Volatile markets could not list or liquidate at size. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-14`) |
| Resolution | LPVaultSwap flash-borrows the debt asset itself through `IFlashSource`, implemented with the Aave V3 Pool `flashLoan` (single asset, mode 0) on every chain. Before the loan it checks available liquidity and the premium against `maxFlashFeeBps`; in the callback it checks initiator, caller and the active context. The flash source is never the Hub of the CDP Spoke being liquidated, the implementation is replaceable through the timelock, and when flash liquidity is short the caller funds the debt. The GhoFlashMinter, the GSM as a primary route and the leg that buys the debt with GHO are removed. LPVaultSwap swaps the unwound tokens over the swap routes into the debt asset with a per-leg oracle `minOut`, repays the flash loan plus premium, and pays the leftover in the debt asset repaid, in this order: Avana's fee (20 % of the oracle gain, capped by the realized surplus), the keeper reward, then the borrower surplus (`Q-337`, 2.11 `SPEC-LIQ-009`, `SPEC-LIQ-022`). GHO is used only when the debt is GHO. Each token class has route requirements, and each market's debt cap follows the measured depth of its own routes. Changed rules: `INV-083`, `INV-070`, `ATTACK-182`, `REQ-SWAP-011`, `REQ-SWAP-017`, `SPEC-LIQ-004`, `SPEC-LIQ-005`, `SPEC-LIQ-006`, `REQ-SWAP-022`, `REQ-ROUTE-001`, `REQ-ROUTE-002`, `REQ-ROUTE-036`, `REQ-ROUTE-039`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-280`, `TEST-281` |

#### FINDING-231: Lend Spoke lenders bore uncovered deficits first-come

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Medium |
| Component | Lend Spoke, First-Loss Reserves |
| Reference | `AMMN-FLOW-15`, `Q-360`, `Q-365`, `ATTACK-183`, `Q-363` |
| Description | An uncovered deficit stays counted in the Hub's assets; lenders who withdraw first leave at full value and the last carry the loss. |
| Impact | Unequal loss among Lend Spoke suppliers. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-15`) |
| Resolution | The First-Loss Reserve of each (Hub, debt asset) covers deficits first; a cross-Hub line's cap is at most the funding Hub's first-loss coverage; the uncovered remainder is an Aave-side Hub loss, stated with its rule in 4.3 and published per drawing Spoke. Changed rules: `INV-071`, `INV-094`, `ATTACK-183`, `REQ-HUB-021`, `REQ-HUB-103`, `REQ-FLR-001`, `REQ-RISK-082`, `SPEC-CAP-010`, `DEF-015`, `DEF-020`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-273` |

#### FINDING-232: A debt-free LP could fill every cap at no cost

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Medium |
| Component | Collateralization cap counters |
| Reference | `AMMN-FLOW-16`, `Q-361`, `ATTACK-184`, `Q-363`, `Q-396` |
| Description | Caps are charged at pledge; a whale or sybil wallets pledge debt-free, keep earning fees and block new borrowers. |
| Impact | New borrowing refused while caps are full; no loss. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-16`) |
| Resolution | Accepted risk (`Q-396`). Owner: Avana Labs and the risk service providers who set caps at listing. The idle-collateral mechanism of the earlier fix pass (`Idle` cap bucket, `releaseIdle`, `admitIdleCharge`, `idleUsdCap`, `idleBookingSeconds`, `IDLE_UTILIZATION_BPS`, `Q-384`) is removed. Bound: a full cap refuses only new pledges, never repay, exits, liquidation or rescue top-ups, which use the reserved slice (`topUpSliceUsd`, 10 % of the market cap); cap counters are keyed by Hub in one ledger, so the depositor cap covers every Spoke and market of the Hub and limits one wallet's share; caps are set at listing and raised through the timelock; monitoring alerts on cap use by accounts with no debt. The squatter earns pool fees on its own capital and no loss reaches lenders. Changed rules: `INV-092`, `ATTACK-184`, `REQ-ADAPTER-095`, `REQ-RISK-080`. |
| Status | Accepted risk |
| Verification | `TEST-272`, `PROP-077` |

#### FINDING-233: Instance scope left components unassigned or singular

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Medium |
| Component | Deployment topology |
| Reference | `AMMN-FLOW-17`, `Q-359`, `ATTACK-185`, `Q-279`, `Q-363` |
| Description | The instance table omitted the DebtOracle, flash source, swap routes, First-Loss Reserves per funding Hub and the Lend Spoke; `BOR-005` named one Hub. |
| Impact | Unassigned components and an incomplete borrow-receiver refusal list. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-17`) |
| Resolution | Every contract has a stated scope: per chain (ProxyManager, VaultTokenFactory, Timelock, AaveAdapter, LPVaultSwap, Collateralization, MarketRegistry, ParameterStore, RiskModule, PayoutEscrow (the payout escrow), Lock, DebtOracle, the `IFlashSource` implementation; the Lens as periphery), per AMM protocol per chain (LPVault, pricing library), per market (VaultToken, LPOracle), per wallet × Spoke × market (PositionProxy); one Lend Spoke per chain; one First-Loss Reserve per (Hub, debt asset). The SettlementBudget was later removed (`Q-397`). The receiver refusal list is every Avana Hub and Spoke on the chain. Changed rules: `ATTACK-185`, `REQ-CHAIN-002`, `REQ-ARCH-034`, `REQ-ARCH-155`, `REQ-HUB-021`, `REQ-PROXY-017`, `REQ-LENS-001`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-224`, `TEST-271` |

#### FINDING-234: A per-chain ProxyManager with several Adapters allowed proxy squatting

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Medium |
| Component | ProxyManager |
| Reference | `AMMN-FLOW-18`, `Q-359`, `ATTACK-186`, `Q-279`, `Q-363` |
| Description | Same mechanism as `FINDING-210`: with several Adapters, one could deploy another Hub's proxy address first. |
| Impact | Denial of service for a wallet on one Spoke. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-18`) |
| Resolution | One ProxyManager and one AaveAdapter per chain; `deployProxy` accepts only that Adapter; the salt binds (wallet, CDP Spoke, market). Changed rules: `INV-064`, `ATTACK-186`, `REQ-PROXY-050`, `REQ-PROXY-052`, `REQ-PROXY-055`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-271`, `PROP-076` |

#### FINDING-235: Pause, freeze and Guardian were per Hub and per chain while shared code was not

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Medium |
| Component | Pause states, Guardian, address freeze |
| Reference | `AMMN-FLOW-19`, `Q-361`, `ATTACK-187`, `Q-285`, `Q-363` |
| Description | A bug in shared code reaches every Hub on a chain, but each pause was one call per Hub per chain; a frozen address kept acting on other Hubs. |
| Impact | Slow or partial containment. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-19`) |
| Resolution | Every cap, pause, breaker, route permission and emergency control lives in the per-chain contracts keyed by Hub (and by Spoke and market where it applies); each chain has its own Timelock, Safe and Guardian set; a borrow reads the pause of its home Hub and of the debt reserve's funding Hub. Changed rules: `INV-049`, `INV-094`, `ATTACK-187`, `REQ-CHAIN-001`, `REQ-CHAIN-002`, `REQ-ARCH-153`, `REQ-ARCH-154`, `REQ-ARCH-182`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-273` |

#### FINDING-236: An oracle switch could halt liquidation

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Medium |
| Component | AaveOracle source, drift check |
| Reference | `AMMN-FLOW-20`, `Q-362`, `ATTACK-188`, `Q-363` |
| Description | If the Aave DAO points the CDP Spoke's AaveOracle at another source, every liquidation of the market reverts `StalePrice` with no Avana-side remedy. |
| Impact | Liquidation of one market stopped by an Aave-side configuration change. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-20`) |
| Resolution | The AaveOracle source of each Avana reserve is one of the drift-checked Spoke settings: a mismatch trips the breaker, which stops new activity only; changing the source is a joint operation through `listCollateralMarket` that sets the market's LPOracle. Changed rules: `INV-093`, `ATTACK-188`, `REQ-ORACLE-101`, `REQ-ORACLE-091`, `REQ-HUB-105`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-268`, `PROP-078` |

#### FINDING-237: Listing rules excluded the launch and planned markets

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Medium |
| Component | Market listing |
| Reference | `AMMN-FLOW-21`, `Q-359`, `ATTACK-189`, `Q-286`, `Q-363` |
| Description | Slipstream pools failed the canonical-factory rule; WBTC/WETH failed the even-decimals rule; tokens without a Core Hub CF had no CF source; `deployCdpSpoke` could not create an Aave Spoke. |
| Impact | No path to list Slipstream, odd-decimal pairs or tokens without a Core Hub CF. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-21`) |
| Resolution | Listing rules are per AMM integration (factory, pool lookup, decoders). `deployCdpSpoke` creates the Aave Spoke and its AaveOracle entry and registers them under a Hub with an integration; `listCollateralMarket` creates the VaultToken and LPOracle, sets the exact shape and wires the reserve; `enableDebtReserve` sets the funding Hub and asset, checks caps and swap routes, and enables borrowing. Changed rules: `ATTACK-189`, `REQ-CONFIG-077`, `REQ-CONFIG-031`, `REQ-ARCH-207`, `REQ-ARCH-209`, `REQ-ARCH-027`, `REQ-ARCH-033`, `REQ-ARCH-038`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-265`, `TEST-283` |

#### FINDING-238: Wind-down never ended, and immutable vaults had no exit

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Medium |
| Component | Market offboarding |
| Reference | `AMMN-FLOW-22`, `Q-363`, `ATTACK-190` |
| Description | With no force-close and CF > 0 while debt exists, one dormant borrower keeps a market's feed, routes and keepers forever; a bug in an immutable LPVault or ledger had no path out except each user's withdraw. |
| Impact | Unbounded wind-down cost per market. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-22`) |
| Resolution | Market keys let the same pool be relisted on a new CDP Spoke, so a ledger or vault fix moves users through withdraw and re-pledge; withdraw never depends on proxy code; a dormant market stays served at its caps until its last account repays or is liquidated. Changed rules: `INV-045`, `ATTACK-190`, `MKT-057`, `REQ-CONFIG-080`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-271` |

#### FINDING-239: The proposal's "borrower surplus" did not exist in the waterfall

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Low |
| Component | LPVaultSwap waterfall |
| Reference | `AMMN-FLOW-23`, `Q-363`, `ATTACK-191`, `Q-337`, `Q-359` |
| Description | The spec paid the surplus after funding and Avana's fee to the caller; only in-kind settlement paid the borrower. |
| Impact | Text conflict; no loss. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-23`) |
| Resolution | LPVaultSwap swaps the unwound tokens over the swap routes into the debt asset with a per-leg oracle `minOut`, repays the flash loan plus premium, and pays the leftover in the debt asset repaid, in this order: Avana's fee (20 % of the oracle gain, capped by the realized surplus), the keeper reward, then the borrower surplus (`Q-337`, 2.11 `SPEC-LIQ-009`, `SPEC-LIQ-022`). GHO is used only when the debt is GHO. Changed rules: `INV-035`, `INV-036`, `ATTACK-191`, `SPEC-LIQ-010`, `SPEC-LIQ-022`, `REQ-SWAP-026`, `REQ-SWAP-027`, `REQ-SWAP-076`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-280` |

#### FINDING-240: Two-token and tokenId keys were built into shared code

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Low |
| Component | Collateralization records, pending settlement, indexing |
| Reference | `AMMN-FLOW-24`, `Q-359`, `ATTACK-192`, `Q-292`, `Q-297`, `Q-363` |
| Description | Records, pending settlement and indexes used `amount0`/`amount1` and `tokenId`; Curve, Balancer and v2 positions have n tokens and no tokenId, and `tokenId` alone collides across position managers and chains. |
| Impact | Shared immutable code that cannot hold a later AMM protocol. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-24`) |
| Resolution | Positions are identified by `positionKey` (bytes32) plus `integrationId`; every amount is an n-token array; pending settlement holds n tokens; indexing keys by (chain, integration, positionKey). Changed rules: `INV-002`, `INV-006`, `INV-007`, `ATTACK-192`, `REQ-VAULT-027`, `REQ-VAULT-152`, `REQ-COLL-006`, `REQ-VAULT-016`, `REQ-COLL-027`, `REQ-VAULT-106`, `REQ-VAULT-175`, `REQ-VAULT-077`, `REQ-COLL-028`, `REQ-VAULT-060`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-264`, `TEST-265` |

#### FINDING-241: Keeper floors multiplied per Hub and chain

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Low |
| Component | LPVaultSwap keepers |
| Reference | `AMMN-FLOW-25`, `Q-359`, `ATTACK-193`, `Q-289`, `Q-363` |
| Description | Each LPVaultSwap needs three active keepers or its Hub halts borrowing; three Hubs on two chains needed six keeper sets. |
| Impact | Operating cost; borrowing halted on a Hub with too few keepers. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-25`) |
| Resolution | One LPVaultSwap per chain, so the keeper floor of 3 is per chain, funded before activation on each chain. Changed rules: `INV-048`, `ATTACK-193`, `REQ-CHAIN-002`, `REQ-ARCH-040`, `REQ-ARCH-069`, `REQ-ARCH-129`, `REQ-ACCESS-054`, `LIQ-063`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-098` |

#### FINDING-242: Repay with collateral was refused under Paused

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, flow walkthroughs) |
| Severity | Medium |
| Component | LPVaultSwap repay with collateral |
| Reference | `AMMN-FLOW-26`, `Q-363`, `ATTACK-194`, `Q-347` |
| Description | During a crash with `Paused(General)`, a borrower without outside funds could not deleverage, while keepers could liquidate the account at a bonus. |
| Impact | Avoidable liquidation bonus paid by the borrower. |
| Evidence | [`flow-walkthroughs.md`](../../audit/design-review/amm-neutral/flow-walkthroughs.md) (`AMMN-FLOW-26`) |
| Resolution | Repay with collateral, with its partial removal and re-credit, runs under `Paused(General)` when it only lowers debt and the health factor does not fall; it stays refused under `MintPathSuspect`. Changed rules: `INV-089`, `INV-067`, `ATTACK-194`, `REQ-SWAP-106`, `REQ-SWAP-116`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-280` |

#### FINDING-243: Seizure walked an unbounded record list, so some accounts could not be liquidated in one transaction

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | High |
| Component | Collateralization records, LPVaultSwap seizure |
| Reference | `AMMN-GAS-01`, `Q-362`, `Q-287`, `Q-294`, `Q-366` |
| Description | Each debited record costs about 240k gas and Aave's dust rule seizes the last chunk whole. 125 records of $8 need 1.31M + 125 × 0.24M = 31.3M gas, above the 16.78M per-transaction cap. |
| Impact | An account that is liquidatable but cannot be liquidated; its debt becomes bad debt. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-01`) |
| Resolution | At most 16 records per account per market (`MAX_RECORDS_PER_ACCOUNT_MARKET`); a pledge at the cap reverts `TooManyRecords`, rescue top-ups count against it, and value is added through re-credit. Worst-case seizure gas is 1.31M + 16 × 0.29M = 5.95M, under 36% of the per-transaction cap. Changed rules: `INV-096`, `INV-015`, `REQ-VAULT-025`, `SPEC-BACK-016`, `REQ-AMM-CORE-015`, `REQ-COLL-005`, `REQ-COLL-025`, `REQ-VAULT-054`, `REQ-VAULT-128`, `REQ-VAULT-108`, `DEP-006`, `LIQ-022`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-269`, `PROP-082` |

#### FINDING-244: The $10 minimum pledge did not cover liquidation gas on Ethereum

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | High |
| Component | RiskModule minimums |
| Reference | `AMMN-GAS-02`, `Q-362`, `Q-287`, `Q-381` |
| Description | At 10 gwei a liquidation is unprofitable below about $3,400 of debt on Ethereum, so small debts are never liquidated at normal gas prices. |
| Impact | Small accounts accumulate as bad debt. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-02`) |
| Resolution | Resolved by decision: no minimum; Avana keeper pays gas (`Q-381`, superseding the minimum debt of `Q-311`, `Q-317`, `Q-362` and `Q-380`). Avana has no minimum debt on any chain; a borrower may borrow any amount. Avana's own approved keepers liquidate every account with HF < 1 and Avana pays the gas, with the permissionless fallback kept, so liquidation never depends on a keeper making a profit. The 16-record cap stays, because one liquidation of the largest account must fit the per-transaction gas limit: `G = 1.31M + 0.24M × 16 = 5.15M ≤ 16,777,216`. `SPEC-CHAIN-001` states only the per-chain gas model in gas units, used for the record cap and Avana's keeper gas budget. Changed rules: `INV-096`, `SPEC-CHAIN-001`, `REQ-RISK-083`, `LIQ-087`, `REQ-RISK-077`, `SPEC-CAP-009`, 2.11 `REQ-SWAP-032`, `REQ-SWAP-101`. |
| Status | Resolved in design |
| Verification | `TEST-278`, `TEST-269`, `PROP-082`, `MATH-ST-108` |

#### FINDING-245: Uniswap v4 hooks and position subscribers can block or gas-grief removal

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | High |
| Component | Uniswap v4 integration readiness |
| Reference | `AMMN-GAS-03`, `Q-363`, `ATTACK-158`, `Q-302` |
| Description | Remove-liquidity hooks and subscriber callbacks run inside removal and can revert or burn gas. |
| Impact | Liquidation of a v4 market blocked. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-03`) |
| Resolution | Uniswap v2, Curve StableSwap-NG, Balancer and Uniswap v4 are not listed at launch; each has a readiness section with its pricing model and the guards it must pass before listing: v2 reads `getReserves`, never `balanceOf`, with effective supply including pending `feeTo` liquidity; Curve and Balancer value at the minimum token price and check the pool's reentrancy lock before every read; Uniswap v4 requires a hook allowlist with no remove-liquidity hooks or return deltas; every AMM protocol has a per-block quote-change cap. The v4 intake refuses a position with a subscriber and the LPVault never subscribes; v4 swap routes use hook-free pools only. Changed rules: `ATTACK-158`, `REQ-AMM-V4-001`, `REQ-AMM-CORE-004`, `REQ-AMM-CORE-012`, `REQ-AMM-CORE-014`, `SPEC-AMM-CORE-001`, `REQ-AMM-CORE-018`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-283` |

#### FINDING-246: Breaker reports could be starved of gas through the 63/64 rule

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Medium |
| Component | Circuit breakers |
| Reference | `AMMN-GAS-04`, `Q-367`, `ATTACK-042`, `Q-399` |
| Description | A caller sends just enough gas that the gas-limited `try` recording a breaker report fails while the outer call succeeds, so breakers never latch. |
| Impact | Breakers silently disabled. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-04`) |
| Resolution | Resolved by removal (`Q-399`): no breaker counts reports written by liquidations any more, so no breaker depends on a gas-limited record. The `gasleft()` rule stays for the remaining gas-limited `try` calls: before each, the caller requires `gasleft() ≥ limit × 64/63 + POST_CALL_GAS` and reverts `InsufficientGas` otherwise; it covers the payout transfers whose failure moves the amount to the PayoutEscrow (`INV-061`) and the issuer probe. Changed rules: `ATTACK-042`, `REQ-SWAP-103`, `REQ-SWAP-104`, `REQ-MREG-026`, `SPEC-ORC-023`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-268` |

#### FINDING-247: The `pokeMinGas` floor was not derived from the 63/64 rule

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Medium |
| Component | LPOracle poke |
| Reference | `AMMN-GAS-05`, `Q-367`, `ATTACK-042` |
| Description | Feed and pool reads had no explicit gas, so a starved poke could record an outage or skip a read. |
| Impact | A gas-starved poke latches a wrong state. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-05`) |
| Resolution | Every feed and pool read has an explicit gas stipend; `gasleft() ≥ FEED_CALL_GAS × 64/63 + REMAINING_POKE_GAS` is required before each, and `POKE_MIN_GAS_FLOOR` is at least the measured full-poke gas. Changed rules: `INV-031`, `ATTACK-042`, `SPEC-ORC-023`, `REQ-ORACLE-102`, `REQ-ORACLE-038`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-276` |

#### FINDING-248: The liquidation flow assumed GHO flash minting and GSMs that do not exist on Base

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Medium |
| Component | LPVaultSwap flash |
| Reference | `AMMN-GAS-06`, `Q-362`, `Q-365` |
| Description | Same root cause as `FINDING-218` and `FINDING-263`. |
| Impact | No liquidation funding on Base. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-06`) |
| Resolution | LPVaultSwap flash-borrows the debt asset itself through `IFlashSource`, implemented with the Aave V3 Pool `flashLoan` (single asset, mode 0) on every chain. Before the loan it checks available liquidity and the premium against `maxFlashFeeBps`; in the callback it checks initiator, caller and the active context. The flash source is never the Hub of the CDP Spoke being liquidated, the implementation is replaceable through the timelock, and when flash liquidity is short the caller funds the debt. The GhoFlashMinter, the GSM as a primary route and the leg that buys the debt with GHO are removed. Changed rules: `INV-095`, `INV-040`, `REQ-FLASH-001`, `REQ-FLASH-002`, `REQ-FLASH-003`, `REQ-FLASH-005`, `REQ-FLASH-006`, `REQ-ROUTE-031`, `REQ-CHAIN-001`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-267`, `PROP-080` |

#### FINDING-249: Crash throughput is capped by route depth and the per-transaction cap, not by the Lock

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Medium |
| Component | Liquidation liveness |
| Reference | `AMMN-GAS-07`, `Q-367`, `Q-344` |
| Description | In a 20% crash the number of liquidations per block is bounded by route depth at 1%, flash headroom and gas per call. |
| Impact | A capped market may not clear before prices move further. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-07`) |
| Resolution | Each market's `marketUsdCap` is sized so the capped market liquidates within `liquidationPriceMaxAge` at the 95th-percentile gas share, using its route depth, the flash source's available liquidity and the 16-record bound; each liquidation is funded by its own caller, so no shared fund links markets (`Q-397`). Changed rules: `INV-096`, `INV-097`, `REQ-SWAP-002`, `SPEC-LIQ-021`, `REQ-SWAP-118`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-269`, `TEST-281` |

#### FINDING-250: Pausable or blocklisting tokens on shared contracts and route intermediates halted other markets

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Medium |
| Component | Swap routes, LPVaultSwap |
| Reference | `AMMN-GAS-08`, `Q-367`, `Q-342`, `Q-401` |
| Description | A USDC pause stopped volatile markets whose route passed through USDC; a blocklist of LPVaultSwap stopped every market holding the token; USDT's `approve` needs `forceApprove`. |
| Impact | Liquidation halts in markets that do not hold the paused token. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-08`) |
| Resolution | A token's primary and alternate routes share no intermediate token, checked at `setRoute`; approvals use `forceApprove` and return to 0; tokens with an ERC-777 implementer are refused at listing; a route whose token is blocked fails over to the alternate route, which shares no intermediate token, and a payout transfer the token refuses goes to the PayoutEscrow, now Avana's payout escrow (automatic in-kind was removed, `Q-401`). Changed rules: `INV-021`, `INV-039`, `REQ-SWAP-023`, `REQ-SWAP-031`, `REQ-SWAP-064`, `REQ-ROUTE-003`, `REQ-ROUTE-005`, `EMG-063`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-281`, `TEST-283` |

#### FINDING-251: The Lock's immutable allowlist could not name per-Spoke LPVaults and ledgers

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Critical |
| Component | Lock |
| Reference | `AMMN-GAS-09`, `Q-362`, `Q-279` |
| Description | Same root cause as `FINDING-217`. |
| Impact | Every flow on a later Spoke reverts. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-09`) |
| Resolution | The Lock has exactly two members, the AaveAdapter and LPVaultSwap. Every LPVault and Collateralization entry point that moves value is reachable only through them, with one AMM-neutral Collateralization ledger per chain and one immutable LPVault per AMM protocol per chain, so a new CDP Spoke or market never needs a Lock redeploy. Changed rules: `INV-091`, `INV-054`, `REQ-VAULT-150`, `REQ-ADAPTER-050`. Fix pass (2026-11-10): `INV-091`, `INV-054`, 2.16 and `ILock` say the same thing. Collateralization's value-moving functions accept only a Lock member while the Lock is held. An LPVault's position-moving functions accept only Collateralization while the Lock is held, so they run only inside a call tree a Lock member opened. `returnStray` is timelock-only and runs only while the Lock is free (`REQ-LOCK-028`, `REQ-VAULT-150`, `REQ-VAULT-165`; `Q-362`). |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-270`, `PROP-075` |

#### FINDING-252: SettlementBudget read 75 cold buckets per draw, and markets shared one window

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Low |
| Component | SettlementBudget (removed, `Q-397`) |
| Reference | `AMMN-GAS-10`, `Q-362`, `Q-343`, `Q-397` |
| Description | Each draw read every bucket of the rolling window; the window was shared by every market. |
| Impact | Before the fix: gas per draw and cross-market contention. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-10`) |
| Resolution | Resolved by removal (`Q-397`): the SettlementBudget no longer exists, so no liquidation reads or writes a budget window. Earlier fix, superseded: per-market windows with a running sum per key. Changed rules: `INV-097`, `REQ-SWAP-029`, `REQ-SWAP-061`, `SPEC-SET-003`, `SPEC-SET-005`, `SPEC-SET-006`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-277`, `PROP-084` |

#### FINDING-253: Small repay front-runs pushed a keeper's partial liquidation into Aave's dust rule

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Low |
| Component | Keeper sizing |
| Reference | `AMMN-GAS-11`, `Q-367`, `ATTACK-057`, `Q-345` |
| Description | A 1-wei repay before a keeper's call changes the leftover debt so Aave's dust rule applies and the call's `minPayout` fails. |
| Impact | Griefing of one liquidation attempt. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-11`) |
| Resolution | Keepers set `debtToCover` at least 5% below the dust boundary or as a full close, with at least 1% tolerance on `minPayout`, and use private order flow on Ethereum. Changed rules: `ATTACK-057`, `REQ-SWAP-005`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-247` |

#### FINDING-254: `activeKeeperCount` had no keeper bound and was read on the borrow path

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Low |
| Component | LPVaultSwap keepers |
| Reference | `AMMN-GAS-12`, `Q-367` |
| Description | An unbounded keeper list made the borrow-path count read grow with the list. |
| Impact | Gas growth on borrow. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-12`) |
| Resolution | `addKeeper` caps the list at `MAX_KEEPERS = 32`. Changed rules: `INV-048`, `REQ-SWAP-107`, `REQ-SWAP-034`, `REQ-RISK-071`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-098` |

#### FINDING-255: n-token unwinds scale settlement legs and oracle reads with n

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Low |
| Component | LPVaultSwap unwind |
| Reference | `AMMN-GAS-13`, `Q-367`, `Q-294`, `Q-297` |
| Description | Each extra token adds a swap leg, a `minOut` and an oracle read. |
| Impact | Higher liquidation gas for n-token markets. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-13`) |
| Resolution | The unwind removes exactly the seized units and returns n token amounts with per-token minimums; an integration may exit to a single token with the oracle floor on that output; n is capped per market type; native ETH is accepted only while the Lock is held. Changed rules: `INV-083`, `REQ-AMM-CORE-015`, `REQ-AMM-CURVE-005`, `REQ-COLL-005`, `REQ-COLL-025`, `REQ-VAULT-025`, `REQ-VAULT-054`, `REQ-VAULT-128`, `REQ-VAULT-175`, `REQ-VAULT-077`, `REQ-COLL-028`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-281`, `TEST-283` |

#### FINDING-256: Slipstream's unstaked-only rule had to be enforced

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Low |
| Component | Aerodrome Slipstream integration |
| Reference | `AMMN-GAS-14`, `Q-365`, `ATTACK-178`, `Q-301` |
| Description | A gauge-staked Slipstream NFT has different fee and custody behaviour, and staking later adds a gauge liveness dependency. |
| Impact | Wrong fee accounting or a liveness dependency on the gauge. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-14`) |
| Resolution | Slipstream intake accepts unstaked NFTs only and refuses a gauge-staked NFT; the LPVault never stakes. Changed rules: `ATTACK-178`, `REQ-AMM-SLIP-009`, `REQ-VAULT-174`, `REQ-VAULT-097`, `REQ-AMM-SLIP-001`, `REQ-AMM-SLIP-002`, `REQ-AMM-SLIP-003`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-265` |

#### FINDING-257: Hot structs could be packed into fewer storage slots

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Informational |
| Component | Collateralization, MarketRegistry, ParameterStore |
| Reference | `AMMN-GAS-15`, `Q-367`, `Q-303` |
| Description | `BackingRecord` with its list links used 10 slots where 5 suffice; `OracleLeg`, `GlobalParams`, `PledgeCounters` and `BreakerWindow` also pack smaller. |
| Impact | About 110k gas per pledge and 5k per debited record. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-15`) |
| Resolution | `BackingRecord` packs into 5 slots (`positionKey`-indexed, with list links), and the other hot structs pack as listed in the gas review; the storage layout is checked in CI. Rules: `SPEC-BACK-016`, `REQ-VAULT-015`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-269` |

#### FINDING-258: Per-market values could be immutables and cached reads

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, gas and DoS) |
| Severity | Informational |
| Component | VaultToken, LPOracle, LPVaultSwap |
| Reference | `AMMN-GAS-16`, `Q-367` |
| Description | Pool, tokens, vault token, LPOracle, reserve IDs, decimals and range are fixed per market but were re-read from storage several times per liquidation. |
| Impact | Avoidable cold reads per liquidation. |
| Evidence | [`gas-dos.md`](../../audit/design-review/amm-neutral/gas-dos.md) (`AMMN-GAS-16`) |
| Resolution | Per-market values are immutables of the market's VaultToken and LPOracle; LPVaultSwap reads the market once and passes a context whose hash each callee checks against the registry's stored commitment. Rules: `REQ-CONFIG-005`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-269` |

#### FINDING-259: Stablecoin Chainlink heartbeats are 23–24 hours, not at most 1 hour

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, integration assumptions) |
| Severity | Critical |
| Component | LPOracle, DebtOracle freshness |
| Reference | `AMMN-INT-01`, `Q-364`, `Q-366` |
| Description | On Ethereum USDC/USD and USDS/USD have 82,800 s heartbeats and USDT/USD and GHO/USD 86,400 s; on Base every stable feed is 86,400 s. At block 26,383,651 the USDT/USD round was 67,704 s old. |
| Impact | The launch market cannot be listed; with the old 4,200 s age limit, borrowing would be stopped most of the day. |
| Evidence | [`integration-assumptions.md`](../../audit/design-review/amm-neutral/integration-assumptions.md) (`AMMN-INT-01`) |
| Resolution | A feed is fresh while its age is at most its own heartbeat plus a margin (Chainlink stablecoin feeds: 82,800–86,400 s); the fixed 3,600 s rule is removed. Borrow and withdraw also require an independent second source (a deep-pool TWAP or a second oracle network) to agree within the deviation band. Liquidation keeps its stress rules: stale collateral counts as 0 from Expired and stale debt uses its stress price. Changed rules: `INV-023`, `INV-030`, `INV-031`, `INV-055`, `INV-056`, `SPEC-ORC-019`, `REQ-ORACLE-090`, `REQ-ADAPTER-016`, `REQ-CONFIG-021`. Fix pass (2026-11-10): each token may have a pre-approved standby second source that either guardian switches to at once; switching back needs the timelock, and `EMG-103` keeps the market Live as `REQ-ORACLE-100` requires (`SPEC-ORC-020`, `REQ-ORACLE-100`, `REQ-PSTORE-028`, `EMG-103`; `Q-385`). |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-276`, `TEST-117` |

#### FINDING-260: The GSM addresses in EXT-013 belong to seized GSMs

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, integration assumptions) |
| Severity | High |
| Component | External dependencies, conversion routes |
| Reference | `AMMN-INT-02`, `Q-365`, `ATTACK-170`, `Q-341` |
| Description | GSM USDC `0xFeeb…9535` and GSM USDT `0x535b…6B7B` return `getIsSeized() = true`, an exposure cap of 0 and no liquidity. |
| Impact | Every route through those GSMs reverts. |
| Evidence | [`integration-assumptions.md`](../../audit/design-review/amm-neutral/integration-assumptions.md) (`AMMN-INT-02`) |
| Resolution | The GSM is no longer a primary route or a flash dependency. 4.3 states only verified facts about the GSMs and removes the seized addresses; any GSM used as a swap route must report not seized, not frozen and an exposure cap above 0 at route approval and in the route health check. Changed rules: `ATTACK-170`, `REQ-ROUTE-011`, `REQ-ROUTE-002`, `REQ-ROUTE-005`, `REQ-ROUTE-030`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-281` |

#### FINDING-261: The live USDC GSM has no buy-side liquidity

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, integration assumptions) |
| Severity | Medium |
| Component | Debt buy route |
| Reference | `AMMN-INT-03`, `Q-362`, `Q-365`, `Q-341` |
| Description | The USDC GSM held about $0.03 available to buy, so it could not be the primary USDC buy route. |
| Impact | Every USDC-debt liquidation would use the backup route. |
| Evidence | [`integration-assumptions.md`](../../audit/design-review/amm-neutral/integration-assumptions.md) (`AMMN-INT-03`) |
| Resolution | The leg that buys the debt with GHO is removed: LPVaultSwap flash-borrows the debt asset itself through `IFlashSource`, so no buy route exists. Changed rules: `INV-070`, `INV-095`, `REQ-ROUTE-031`, `REQ-ROUTE-002`, `REQ-ROUTE-005`, `REQ-ROUTE-011`, `REQ-ROUTE-030`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-267`, `TEST-280` |

#### FINDING-262: The liquidation-manager Spoke in Aave's repository is not the one Avana's interface called

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, integration assumptions) |
| Severity | High |
| Component | Aave V4 CDP Spoke |
| Reference | `AMMN-INT-04`, `Q-362`, `ATTACK-181`, `Q-281`, `Q-300`, `Q-365` |
| Description | The only liquidation-manager variant in `aave/aave-v4` reverts the 5-argument `liquidationCall`, exposes a 4-argument one, allows one collateral reserve per Spoke and one debt reserve per user, and has no dust rule or target-HF sizing. |
| Impact | Avana's required Spoke existed in no Aave source. |
| Evidence | [`integration-assumptions.md`](../../audit/design-review/amm-neutral/integration-assumptions.md) (`AMMN-INT-04`) |
| Resolution | Every CDP Spoke is a standard, unmodified Aave V4 Spoke. The listing AIP sets `receiveSharesEnabled = false` on every Avana collateral reserve, `liquidationFee = 0` (or paid to Avana's fee receiver) and no reinvestment controller, and the RiskModule drift check compares each setting on every new-activity call. Drift trips a breaker that stops new activity, never liquidation. The vault token's transfer rule allows only the AaveAdapter's mint and burn, proxy to home Hub on supply, home Hub to proxy on withdrawal, and home Hub to LPVaultSwap on seizure (`REQ-VTOKEN-025`), so any other liquidator's `liquidationCall` reverts on the token transfer. Changed rules: `INV-093`, `ATTACK-181`, `REQ-CONFIG-074`, `REQ-VTOKEN-006`, `REQ-VTOKEN-008`, `REQ-VTOKEN-009`, `REQ-VTOKEN-040`, `REQ-VTOKEN-041`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-268`, `PROP-078` |

#### FINDING-263: Base has no GHO FlashMinter or GSM

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, integration assumptions) |
| Severity | Critical |
| Component | LPVaultSwap flash |
| Reference | `AMMN-INT-05`, `Q-362`, `Q-365`, `ATTACK-170`, `Q-333`, `Q-334`, `Q-336` |
| Description | The Base address book lists only the GHO token, its CCIP pool and stewards. |
| Impact | Step 1 of the liquidation flow cannot run on Base. |
| Evidence | [`integration-assumptions.md`](../../audit/design-review/amm-neutral/integration-assumptions.md) (`AMMN-INT-05`) |
| Resolution | LPVaultSwap flash-borrows the debt asset itself through `IFlashSource`, implemented with the Aave V3 Pool `flashLoan` (single asset, mode 0) on every chain. Before the loan it checks available liquidity and the premium against `maxFlashFeeBps`; in the callback it checks initiator, caller and the active context. The flash source is never the Hub of the CDP Spoke being liquidated, the implementation is replaceable through the timelock, and when flash liquidity is short the caller funds the debt. The GhoFlashMinter, the GSM as a primary route and the leg that buys the debt with GHO are removed. Changed rules: `INV-040`, `INV-095`, `ATTACK-170`, `REQ-FLASH-001`, `REQ-FLASH-002`, `REQ-FLASH-005`, `REQ-ROUTE-031`, `REQ-SWAP-011`, `REQ-SWAP-017`, `SPEC-LIQ-004`, `SPEC-LIQ-005`, `SPEC-LIQ-006`, `REQ-SWAP-012`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-267`, `PROP-080` |

#### FINDING-264: No L2 sequencer uptime check

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, integration assumptions) |
| Severity | High |
| Component | LPOracle, DebtOracle |
| Reference | `AMMN-INT-06`, `Q-362`, `Q-365`, `ATTACK-171` |
| Description | Base has the Chainlink L2 Sequencer Uptime feed `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`; the spec read none. |
| Impact | Borrows and liquidations on stale rounds after an outage. |
| Evidence | [`integration-assumptions.md`](../../audit/design-review/amm-neutral/integration-assumptions.md) (`AMMN-INT-06`) |
| Resolution | Each L2 chain has a sequencer-uptime feed (Base `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`) and a grace period after restart. While the sequencer is down or inside the grace period no new risk opens; liquidation keeps its stress rules. Changed rules: `INV-098`, `ATTACK-171`, `REQ-CHAIN-003`, `REQ-ORACLE-099`, `LIQ-086`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-275` |

#### FINDING-265: A transfer restriction alone does not make LPVaultSwap the only settler

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, integration assumptions) |
| Severity | High |
| Component | Vault token, Aave V4 CDP Spoke |
| Reference | `AMMN-INT-07`, `Q-362`, `ATTACK-155`, `Q-281`, `Q-365` |
| Description | `receiveShares = true` credits Spoke supply shares with no ERC-20 transfer and fee shares move by `payFeeShares`; the restriction holds only while `receiveSharesEnabled == false` and `liquidationFee == 0`. |
| Impact | One DAO configuration change lets any liquidator seize shares without a ledger debit. |
| Evidence | [`integration-assumptions.md`](../../audit/design-review/amm-neutral/integration-assumptions.md) (`AMMN-INT-07`) |
| Resolution | Every CDP Spoke is a standard, unmodified Aave V4 Spoke. The listing AIP sets `receiveSharesEnabled = false` on every Avana collateral reserve, `liquidationFee = 0` (or paid to Avana's fee receiver) and no reinvestment controller, and the RiskModule drift check compares each setting on every new-activity call. Drift trips a breaker that stops new activity, never liquidation. The vault token's transfer rule allows only the AaveAdapter's mint and burn, proxy to home Hub on supply, home Hub to proxy on withdrawal, and home Hub to LPVaultSwap on seizure (`REQ-VTOKEN-025`), so any other liquidator's `liquidationCall` reverts on the token transfer. Changed rules: `INV-093`, `INV-011`, `INV-014`, `ATTACK-155`, `REQ-RISK-078`, `REQ-ADAPTER-029`, `REQ-CONFIG-076`. Fix pass (2026-11-10): the exposure lasts from the Aave change until the drift check trips `CONFIG_DRIFT`, which runs on every Avana entry point and on a per-block keeper poke; a seizure outside LPVaultSwap in that window is an accepted residual risk bounded by the Spoke draw caps (`INV-093`, `REQ-RISK-078`, `ATTACK-155`, `EXT-001`; `Q-382`). |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-268`, `PROP-078` |

#### FINDING-266: EXT-001 understated the scope of a Hub halt

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, integration assumptions) |
| Severity | Informational |
| Component | External dependencies |
| Reference | `AMMN-INT-08`, `Q-365`, `ATTACK-180`, `Q-290` |
| Description | `reportDeficit`, `eliminateDeficit`, `payFeeShares` and `refreshPremium` check only `active`, so they continue under a halt. |
| Impact | None to safety. |
| Evidence | [`integration-assumptions.md`](../../audit/design-review/amm-neutral/integration-assumptions.md) (`AMMN-INT-08`) |
| Resolution | EXT-001 states that a halt stops add, remove, draw, restore and share transfers (supply, withdraw, borrow, repay and liquidation) while deficit coverage, premium refresh and fee shares continue. Changed rules: `ATTACK-180`, `REQ-ARCH-118`, `REQ-ARCH-120`, `REQ-HUB-021`, `REQ-HUB-063`, `REQ-FLR-022`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-127` |

#### FINDING-267: A vault and ledger per Spoke conflicted with the immutable Lock

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, architecture options) |
| Severity | Medium |
| Component | Lock, LPVault, Collateralization |
| Reference | `AMMN-ARCH-01`, `Q-362`, `Q-279`, `Q-291`, `Q-296` |
| Description | Adding a vault and ledger with each Spoke meant redeploying the Lock and every contract that stores it, or making membership governance-extendable. |
| Impact | Either a redeploy per Spoke or a mutable Lock. |
| Evidence | [`architecture-options.md`](../../audit/design-review/amm-neutral/architecture-options.md) (`AMMN-ARCH-01`) |
| Resolution | The Lock has exactly two members, the AaveAdapter and LPVaultSwap. Every LPVault and Collateralization entry point that moves value is reachable only through them, with one AMM-neutral Collateralization ledger per chain and one immutable LPVault per AMM protocol per chain, so a new CDP Spoke or market never needs a Lock redeploy. Changed rules: `INV-091`, `INV-054`, `REQ-VAULT-150`, `REQ-COLL-002`, `REQ-COLL-029`, `REQ-VAULT-075`, `REQ-COLL-032`, `REQ-VTOKEN-044`, `REQ-VAULT-001`, `REQ-VAULT-002`, `REQ-VAULT-004`, `REQ-VAULT-174`. Fix pass (2026-11-10): `INV-091`, `INV-054`, 2.16 and `ILock` say the same thing. Collateralization's value-moving functions accept only a Lock member while the Lock is held. An LPVault's position-moving functions accept only Collateralization while the Lock is held, so they run only inside a call tree a Lock member opened. `returnStray` is timelock-only and runs only while the Lock is free (`REQ-LOCK-028`, `REQ-VAULT-150`, `REQ-VAULT-165`; `Q-362`). |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-270`, `PROP-075` |

#### FINDING-268: One market per Spoke multiplied DAO work without isolating shared code

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, architecture options) |
| Severity | Medium |
| Component | CDP Spoke topology |
| Reference | `AMMN-ARCH-02`, `Q-359`, `Q-280` |
| Description | One Spoke per market raised a listing from 4 DAO calls to about 12 plus 3 deployments and split the credit line into M caps, while markets of one AMM protocol share code anyway. The topology simulation measured 16 governance actions per market for several markets per Spoke against 38–56. |
| Impact | Governance cost with no isolation gain. |
| Evidence | [`architecture-options.md`](../../audit/design-review/amm-neutral/architecture-options.md) (`AMMN-ARCH-02`) |
| Resolution | One CDP Spoke per (chain, Hub, AMM protocol, risk tier) lists several markets, each one collateral reserve. Each wallet gets one PositionProxy per (CDP Spoke, market), so every market has its own Aave account and health factor and nothing is cross-collateralized. Changed rules: `INV-064`, `INV-075`, `REQ-ARCH-004`, `REQ-ARCH-207`, `REQ-ARCH-208`, `REQ-ARCH-015`, `REQ-ARCH-156`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-271`, `PROP-076` |

#### FINDING-269: Per-Hub copies of shared contracts added work without reducing blast radius

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, architecture options) |
| Severity | Low |
| Component | AaveAdapter, LPVaultSwap scope |
| Reference | `AMMN-ARCH-03`, `Q-359`, `Q-279`, `Q-348`, `Q-362` |
| Description | Every per-Hub instance runs the same implementation under the same timelock and Guardian, so per-Hub copies triple deployments without isolating a code bug or a role compromise. |
| Impact | Deployment and upgrade cost; implied isolation that does not exist. |
| Evidence | [`architecture-options.md`](../../audit/design-review/amm-neutral/architecture-options.md) (`AMMN-ARCH-03`) |
| Resolution | One AaveAdapter and one LPVaultSwap per chain, scoped by Hub inside; every cap, pause and breaker is keyed by Hub. Changed rules: `INV-018`, `INV-092`, `REQ-SWAP-032`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-272` |

#### FINDING-270: A single Aave flash source makes liquidation depend on one external reserve

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, architecture options) |
| Severity | High |
| Component | IFlashSource |
| Reference | `AMMN-ARCH-04`, `Q-362`, `Q-282`, `Q-334`, `Q-335`, `Q-336`, `Q-348`, `Q-365`, `Q-366` |
| Description | Liquidation stops whenever the flash reserve is paused, flash-disabled, drained, repriced or deprecated, which happens most under stress. |
| Impact | Liquidation halt on a chain. |
| Evidence | [`architecture-options.md`](../../audit/design-review/amm-neutral/architecture-options.md) (`AMMN-ARCH-04`) |
| Resolution | LPVaultSwap flash-borrows the debt asset itself through `IFlashSource`, implemented with the Aave V3 Pool `flashLoan` (single asset, mode 0) on every chain. Before the loan it checks available liquidity and the premium against `maxFlashFeeBps`; in the callback it checks initiator, caller and the active context. The flash source is never the Hub of the CDP Spoke being liquidated, the implementation is replaceable through the timelock, and when flash liquidity is short the caller funds the debt. The GhoFlashMinter, the GSM as a primary route and the leg that buys the debt with GHO are removed. Changed rules: `INV-095`, `INV-040`, `REQ-FLASH-001`, `REQ-FLASH-002`, `REQ-FLASH-005`, `REQ-FLASH-006`, `REQ-FLASH-008`, `REQ-ARCH-008`, `REQ-ARCH-013`, `REQ-ARCH-157`, `REQ-ARCH-028`, `REQ-ARCH-038`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-267`, `PROP-080` |

#### FINDING-271: A Base launch had no sequencer handling and depended on unverified Base facts

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, architecture options) |
| Severity | Medium |
| Component | Chains |
| Reference | `AMMN-ARCH-05`, `Q-365`, `Q-287`, `Q-362` |
| Description | No sequencer rule, unmeasured Base flash and conversion limits, and Aave V4 on Base unverified. |
| Impact | A Base launch without its chain-specific controls. |
| Evidence | [`architecture-options.md`](../../audit/design-review/amm-neutral/architecture-options.md) (`AMMN-ARCH-05`) |
| Resolution | Ethereum and Base launch together; Aave V4 is live on Base. Each chain has its own Timelock, Safe and Guardian set and its own parameters (block time, sequencer, feeds, gas model); no chain has a minimum debt (`Q-381`). Each L2 chain has a sequencer-uptime feed (Base `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`) and a grace period after restart. While the sequencer is down or inside the grace period no new risk opens; liquidation keeps its stress rules. Changed rules: `INV-098`, `INV-096`, `REQ-CHAIN-001`, `REQ-CHAIN-002`, `REQ-CHAIN-003`, `REQ-CHAIN-004`, `SPEC-CHAIN-001`, `REQ-ORACLE-099`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-275`, `TEST-265`, `TEST-278` |

#### FINDING-272: Interfaces that would be immutable were still shaped for Uniswap v3

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, architecture options) |
| Severity | Medium |
| Component | AMM integration interface, VaultTokenFactory, ledger |
| Reference | `AMMN-ARCH-06`, `Q-359`, `Q-291`, `Q-292`, `Q-297` |
| Description | Markets were keyed by pool address and positions by NFT; Uniswap v4 and Balancer have no pool address, Curve has no closed-form composition, and three of six AMM protocols compound fees. |
| Impact | A later AMM protocol would need a second factory and ledger. |
| Evidence | [`architecture-options.md`](../../audit/design-review/amm-neutral/architecture-options.md) (`AMMN-ARCH-06`) |
| Resolution | The AMM integration interface identifies positions by `positionKey` plus `integrationId`, uses n-token arrays and has five functions (custody, composition at an oracle price vector, unwind of exactly x units with per-token minimums, fees, risk metadata), with hooks for pools keyed by address or id, rolled-in fees, native ETH, rate tokens and AMM protocols with no closed-form pricing. Changed rules: `INV-002`, `INV-006`, `REQ-VAULT-001`, `REQ-VAULT-002`, `REQ-VAULT-004`, `REQ-VAULT-174`, `REQ-VAULT-166`, `REQ-VAULT-152`, `REQ-COLL-006`, `REQ-VAULT-016`, `REQ-COLL-027`, `REQ-VAULT-027`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-264`, `TEST-265`, `TEST-283` |

#### FINDING-273: The decided Borrow Spoke did not exist; the safest existing option is the standard Spoke with three required settings

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, architecture options) |
| Severity | High |
| Component | Aave V4 CDP Spoke |
| Reference | `AMMN-ARCH-07`, `Q-362`, `ATTACK-181`, `Q-281` |
| Description | `Q-222` depended on a Spoke no Aave commit contains; the variant that exists forces one market per Spoke and one debt per account. |
| Impact | Launch blocked on new Aave code. |
| Evidence | [`architecture-options.md`](../../audit/design-review/amm-neutral/architecture-options.md) (`AMMN-ARCH-07`) |
| Resolution | Every CDP Spoke is a standard, unmodified Aave V4 Spoke. The listing AIP sets `receiveSharesEnabled = false` on every Avana collateral reserve, `liquidationFee = 0` (or paid to Avana's fee receiver) and no reinvestment controller, and the RiskModule drift check compares each setting on every new-activity call. Drift trips a breaker that stops new activity, never liquidation. The vault token's transfer rule allows only the AaveAdapter's mint and burn, proxy to home Hub on supply, home Hub to proxy on withdrawal, and home Hub to LPVaultSwap on seizure (`REQ-VTOKEN-025`), so any other liquidator's `liquidationCall` reverts on the token transfer. Changed rules: `INV-093`, `ATTACK-181`, `REQ-ADAPTER-028`, `REQ-ADAPTER-029`, `REQ-ADAPTER-030`, `REQ-ADAPTER-036`, `REQ-RISK-078`, `REQ-VTOKEN-025`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-268`, `PROP-078` |

#### FINDING-274: The Lens was in the audited immutable core but carries no security role

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, architecture options) |
| Severity | Low |
| Component | Lens |
| Reference | `AMMN-ARCH-08`, `Q-359`, `Q-288` |
| Description | No core contract calls the Lens and nothing it returns authorizes an action, yet its interface is 888 lines. |
| Impact | Audit scope with no security return. |
| Evidence | [`architecture-options.md`](../../audit/design-review/amm-neutral/architecture-options.md) (`AMMN-ARCH-08`) |
| Resolution | The Lens is periphery, outside the audited core, one per chain; LPVaultSwap re-checks everything a preview reports. Changed rules: `INV-052`, `REQ-LENS-001`, `REQ-ARCH-155`, `REQ-ARCH-206`, `REQ-ARCH-045`, `REQ-ACCESS-066`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-247` |

#### FINDING-275: The proposal and the spec disagreed on the PositionProxy upgrade model

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, architecture options) |
| Severity | Informational |
| Component | PositionProxy |
| Reference | `AMMN-ARCH-09`, `Q-359` |
| Description | The proposal pinned each proxy; 2.5 made the ProxyManager the beacon of every proxy. |
| Impact | Conflicting custody trust statements. |
| Evidence | [`architecture-options.md`](../../audit/design-review/amm-neutral/architecture-options.md) (`AMMN-ARCH-09`) |
| Resolution | A PositionProxy is a logic-free immutable account created by CREATE2 on first use, bound at creation to one wallet, one CDP Spoke and one market. It executes only calls from the chain's AaveAdapter, which holds all logic and upgrades through the timelock. There is no beacon, no proxy upgrade and no migration, so exits never depend on proxy code. Changed rules: `INV-065`, `REQ-PROXY-050`, `REQ-PROXY-101`, `REQ-ARCH-177`, `REQ-ARCH-152`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-271` |

#### FINDING-276: Drift checks duplicated rules the liquidation-manager Spoke enforces in code

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, architecture options) |
| Severity | Informational |
| Component | RiskModule drift check |
| Reference | `AMMN-ARCH-10`, `Q-362` |
| Description | Under `Q-222` the field checks added code and gas but no protection; under a standard Spoke they are the main control. |
| Impact | None. |
| Evidence | [`architecture-options.md`](../../audit/design-review/amm-neutral/architecture-options.md) (`AMMN-ARCH-10`) |
| Resolution | With the standard Spoke the drift checks are the primary control and stay: `receiveSharesEnabled`, `liquidationFee`, the reinvestment controller, borrowability of the vault-token reserve and the AaveOracle source. Changed rules: `INV-093`, `INV-029`, `REQ-ADAPTER-028`, `REQ-ADAPTER-029`, `REQ-ADAPTER-030`, `REQ-ADAPTER-036`, `REQ-RISK-078`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-268`, `PROP-078` |

#### FINDING-277: Cross-Hub draw caps were checked by the wrong Hub, so a funding Hub's line and cross-Hub cap did not bind

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, state machine) |
| Severity | High |
| Component | MarketRegistry credit lines |
| Reference | `AMMN-SM-01`, `Q-360`, `Q-283`, `Q-366` |
| Description | Quint property TOPO-05 failed: draw caps on a funding Hub's asset could sum above its credit line, because each home Hub checked only its own Spokes. |
| Impact | Funding-Hub suppliers exposed beyond the approved line. |
| Evidence | [`state-machine.md`](../../audit/design-review/amm-neutral/state-machine.md) (`AMMN-SM-01`) |
| Resolution | Cross-Hub credit lines are fully specified and off at launch. The funding Hub owns the cap; one registry sums the lines per (funding Hub, asset); a pause of the funding Hub stops the line; the cap is at most that Hub's first-loss coverage. `INV-057` is a gate on new draws, and the cap-sum rule is a configuration invariant on caps. Lowering a line or cross-Hub cap reverts until the caps under it are lowered first. Changed rules: `INV-094`, `INV-057`, `REQ-RISK-082`, `SPEC-CAP-010`, `REQ-CONFIG-081`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-273`, `PROP-079` |

#### FINDING-278: "drawn ≤ drawCap" is a gate on new draws, not a state invariant

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, state machine) |
| Severity | Low |
| Component | Hub draw caps |
| Reference | `AMMN-SM-02`, `Q-360` |
| Description | TOPO-04 failed in every design: a cap cut or accrued interest leaves a Spoke above its cap. |
| Impact | An invariant that normal operation breaks. |
| Evidence | [`state-machine.md`](../../audit/design-review/amm-neutral/state-machine.md) (`AMMN-SM-02`) |
| Resolution | `INV-057`: no draw completes that leaves `drawn + premium + deficit` above the Spoke's `drawCap`; a cap cut or interest can leave a Spoke above its cap, and then only repayment, liquidation and coverage lower it. The cap-sum rule stays a configuration invariant on caps. Changed rules: `INV-057`, `MKT-057`, `REQ-ADAPTER-023`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-274`, `PROP-081` |

#### FINDING-279: Pinned proxies could be stranded: an Adapter upgrade stops serving old versions, and migration is a gated re-borrow

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, state machine) |
| Severity | Critical |
| Component | PositionProxy, AaveAdapter |
| Reference | `AMMN-SM-03`, `Q-359` |
| Description | TOPO-07, 08 and 09 failed: once an Adapter drops an old proxy version, a paused borrower cannot repay or withdraw, and caps or freezes can strand migration. |
| Impact | Breaks "exits never blocked". |
| Evidence | [`state-machine.md`](../../audit/design-review/amm-neutral/state-machine.md) (`AMMN-SM-03`) |
| Resolution | A PositionProxy is a logic-free immutable account created by CREATE2 on first use, bound at creation to one wallet, one CDP Spoke and one market. It executes only calls from the chain's AaveAdapter, which holds all logic and upgrades through the timelock. There is no beacon, no proxy upgrade and no migration, so exits never depend on proxy code. Changed rules: `INV-063`, `INV-064`, `INV-065`, `INV-043`, `INV-045`, `REQ-PROXY-050`, `REQ-ARCH-177`, `REQ-ARCH-152`, `REQ-ADAPTER-099`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-271`, `PROP-076` |

#### FINDING-280: On a standard Spoke, `receiveShares` liquidation bypassed LPVaultSwap and the ledger

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, state machine) |
| Severity | High |
| Component | Aave V4 CDP Spoke, Collateralization |
| Reference | `AMMN-SM-04`, `Q-362`, `Q-281` |
| Description | TOPO-02b and TOPO-03 failed: a third party took Spoke supply shares with no token transfer, so per-proxy supply no longer equalled credited units, and a non-LPVaultSwap caller triggered a deficit report. |
| Impact | Stuck units and a broken settlement path. |
| Evidence | [`state-machine.md`](../../audit/design-review/amm-neutral/state-machine.md) (`AMMN-SM-04`) |
| Resolution | Every CDP Spoke is a standard, unmodified Aave V4 Spoke. The listing AIP sets `receiveSharesEnabled = false` on every Avana collateral reserve, `liquidationFee = 0` (or paid to Avana's fee receiver) and no reinvestment controller, and the RiskModule drift check compares each setting on every new-activity call. Drift trips a breaker that stops new activity, never liquidation. The vault token's transfer rule allows only the AaveAdapter's mint and burn, proxy to home Hub on supply, home Hub to proxy on withdrawal, and home Hub to LPVaultSwap on seizure (`REQ-VTOKEN-025`), so any other liquidator's `liquidationCall` reverts on the token transfer. Changed rules: `INV-093`, `INV-008`, `INV-041`, `REQ-ADAPTER-036`, `REQ-VTOKEN-025`, `REQ-RISK-078`, `REQ-ADAPTER-029`, `REQ-CONFIG-076`. Fix pass (2026-11-10): the exposure lasts from the Aave change until the drift check trips `CONFIG_DRIFT`, which runs on every Avana entry point and on a per-block keeper poke; a seizure outside LPVaultSwap in that window is an accepted residual risk bounded by the Spoke draw caps (`INV-093`, `REQ-RISK-078`, `ATTACK-155`, `EXT-001`; `Q-382`). |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-268`, `PROP-078` |

#### FINDING-281: One market per Spoke did not isolate token price risk, and per-Hub token caps missed cross-Hub exposure

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, state machine) |
| Severity | Medium |
| Component | Isolation invariant, token caps |
| Reference | `AMMN-SM-05`, `Q-361` |
| Description | TOPO-10 failed by design: a USDC price shock moves every account holding USDC, on every Spoke. TOPO-X2 failed: the Stable Hub's `tokenUsdCap[USDC]` did not count a foreign Spoke drawing from it. |
| Impact | An isolation claim the design cannot meet, and uncounted token exposure. |
| Evidence | [`state-machine.md`](../../audit/design-review/amm-neutral/state-machine.md) (`AMMN-SM-05`) |
| Resolution | `INV-075` isolates markets from pool-level failures only (feeds, oracle state, breakers, pool depth, routes); token prices are shared by design. Token exposure is counted per funding Hub over every Spoke that draws from it. Changed rules: `INV-075`, `INV-092`, `REQ-COLL-026`, `REQ-RISK-079`, `SPEC-CAP-002`, `SPEC-CAP-007`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-272`, `PROP-077` |

#### FINDING-282: A funding Hub's pause did not stop other Hubs' Spokes drawing its liquidity

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral, `AMMN-R1`, state machine) |
| Severity | Medium |
| Component | Pause scope |
| Reference | `AMMN-SM-06`, `Q-361`, `Q-283`, `Q-360` |
| Description | TOPO-X1 failed: under a Stable Hub pause, a Volatile Spoke still borrowed Stable Hub USDC. |
| Impact | A pause that leaves new draws open. |
| Evidence | [`state-machine.md`](../../audit/design-review/amm-neutral/state-machine.md) (`AMMN-SM-06`) |
| Resolution | A borrow reads the pause state of its home Hub and of the debt reserve's funding Hub; repay, liquidation and exits read neither (`INV-081`). Changed rules: `INV-094`, `INV-024`, `REQ-HUB-103`, `BOR-019`, `REQ-CONFIG-081`, `LIQ-088`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-273`, `PROP-079` |

### H. Spec-stage counterexamples recorded after the AMM-neutral review

Three spec-stage counterexamples had no finding. They are recorded here with the bound that applies.

#### FINDING-283: A 24-hour failure of both USDC routes with no standby switch liquidated accounts healthy at market prices

| Field | Value |
|---|---|
| Source | Formal verification (simulation) |
| Severity | Low |
| Component | LPOracle stress valuation, standby routes |
| Reference | `Q-247`, `Q-248`, `SIM-02H`, `SIM-02I`, `Q-368` |
| Description | With both USDC routes failed for 24 h and no standby switch, USDC markets count as worthless and USDC debt is valued at its accepted price plus 5% (`Q-247`). Accounts that also hold a fresh market or GHO debt are liquidated there: 24.7 liquidations of accounts healthy at market prices against 0.3 without the outage, and $9,592 of borrower loss. |
| Impact | Borrower loss bounded by the liquidation bonus on the fresh collateral; no bad debt and no USDC repaid at a stress price. |
| Evidence | `simulation/README.md` (`SIM-02H`) |
| Resolution | Stress valuation stays: liquidation must not trust a market with no fresh route. The loss is bounded by the liquidation bonus on fresh collateral, and the pause guardian's standby switch (`useStandbyRoute`, effective at once) ends the outage; a switch within 30 minutes removes every forced liquidation (`SIM-02I`). The bound and the 30-minute switch target are the Guardian's playbook duty. Rules: `REQ-ARCH-188`, `REQ-ARCH-202`, `REQ-ORACLE-093`. |
| Status | Accepted risk |
| Verification | `TEST-230`, `TEST-231` |

#### FINDING-284: With no approved keeper for 48 hours, the permissionless fallback left tail bad debt

| Field | Value |
|---|---|
| Source | Formal verification (simulation) |
| Severity | Medium |
| Component | LPVaultSwap permissionless liquidation, keepers |
| Reference | `Q-082`, `Q-213`, `SIM-04C`, `Q-368` |
| Description | With no approved keeper for 48 h on the tail path, the permissionless fallback (`Q-213`) liquidates only where the call pays: 312 calls, 114 accounts left and 9,874 GHO of bad debt (worst seed 12,109), against 351,280 GHO with nobody liquidating and 0 with the standby keeper. |
| Impact | Bad debt in the deficit and coverage flow of the (Hub, debt asset), within the First-Loss Reserve sizing. |
| Evidence | `simulation/README.md` (`SIM-04C`) |
| Resolution | The permissionless fallback is a liveness backstop that runs only where it pays; the duty to clear unprofitable accounts sits with the approved keepers (floor of 3 per chain, `INV-048`) and the standby keeper's agreement. Since `Q-381` Avana has no minimum debt, and Avana's own keepers liquidate every account and pay the gas, so clearing an account never depends on its profitability (`INV-096`). Residual bad debt goes to the First-Loss Reserve of the market's (Hub, debt asset). Rules: `REQ-SWAP-034`, `LIQ-087`, `REQ-RISK-083`, `SPEC-CHAIN-001`. |
| Status | Accepted risk |
| Verification | `TEST-098`, `TEST-215`, `TEST-278` |

#### FINDING-285: A hostile LPVaultSwap could seize an Expired market in full for one unit of debt

| Field | Value |
|---|---|
| Source | Formal verification (Quint) |
| Severity | Medium |
| Component | LPVaultSwap, stress valuation |
| Reference | `Q-128`, `Q-227`, `Q-247`, `QNT-T24`, `INV-018`, `Q-368` |
| Description | Aave values an Expired market at its minimum price, so a liquidation sized at that price seizes the whole supply of the market. Trace: alice holds mA and mB on one Spoke with debt; mA falls to price 1; mB's feeds fail and mB becomes Expired. The reviewed LPVaultSwap seizes the fresh mA and refuses every amount on mB; a hostile one seizes all 600 units of mB for 1 GHO. |
| Impact | Loss of one account's stale-market collateral, only under a hostile LPVaultSwap upgrade that passed the timelock. |
| Evidence | `quint/README.md` (`QNT-F1`, `QNT-T24`) |
| Resolution | The reviewed LPVaultSwap refuses seizure of an Expired market (`INV-030`). A hostile LPVaultSwap is inside the upgrade blast radius of `INV-018`: it needs a timelocked upgrade at the normal delay, cancellable by every canceller, which is the bound accepted for every LPVaultSwap fault. Rules: `REQ-ORACLE-085`, `LIQ-053`, `REQ-ARCH-155`. |
| Status | Accepted risk |
| Verification | `TEST-230`, `TEST-154` |

### I. Formal-verification findings against the AMM-neutral spec (`FV-CUS-R5`, `FV-CTL-R5`)

#### FINDING-286: The stray-position return had no Lock member in its call tree, against the Lock entry rule

| Field | Value |
|---|---|
| Source | Formal verification (custody contracts) |
| Severity | Informational |
| Component | Lock, LPVault |
| Reference | `FV-CUS-F-10`, `REQ-LOCK-028`, `REQ-VAULT-165`, `Q-362` |
| Description | `REQ-LOCK-028` required fee collection, zero-credit release and stray-position return to enter through the AaveAdapter, while `REQ-VAULT-165` makes an LPVault's `returnStray` callable by the chain's timelock alone, outside the Lock. Counterexample: the timelock calls `returnStray` with `holder = 0` and moves a position with no Lock member in the call tree. |
| Impact | Two specified entry rules for one function; no value moves outside the rules, because `returnStray` touches only a position with no custody entry. |
| Evidence | `FV-CUS-F-10` (check `FV-CUS-42-surface`, run `FV-CUS-R5`) |
| Resolution | `REQ-LOCK-028` now reads: fee collection and zero-credit release MUST enter through the AaveAdapter; the one exception is an LPVault's `returnStray`, which moves only a position with no custody entry, is callable only by the chain's timelock and reverts while the Lock is held (`REQ-VAULT-165`). `REQ-VAULT-165` is unchanged. Changed rule: `REQ-LOCK-028`. |
| Status | Resolved: `FV-CUS-42-surface` Verified in run `FV-CUS-R6` against the final `REQ-LOCK-028` |
| Verification | `TEST-060`, `TEST-270`, `PROP-075`; `FV-CUS-42-surface` must print resolved in the next `FV-CUS` run |

#### FINDING-287: Short-delay lists named a tolerance and a setter that do not exist and marked three parameters Short with no tighten setter

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | Timelock short-delay list, ParameterStore, market lifecycle |
| Reference | `FV-CTL-F-25`, `MKT-027`, `REQ-ACCESS-141`, `REQ-ACCESS-155`, `REQ-ROLE-027`, `Q-362` |
| Description | `MKT-027` listed `twapToleranceTicks` and omitted `consistencyToleranceBps`; the 2.15 launch list named `tightenFloorRoundingAllowanceGho` (2.9 defines `tightenFloorRoundingAllowance`) and omitted `tightenMaxFlashFeeBps`; 1.5 and 1.4 marked `idleUsdCap`, `idleBookingSeconds` and `coverageRatioBps` Short although no tighten selector exists for them. |
| Impact | An incident tightening of those parameters would wait the normal delay; no loss. |
| Evidence | `FV-CTL-F-25` (check `FV-CTL-58`, run `FV-CTL-R5`) |
| Resolution | `MKT-027` names `consistencyToleranceBps` in place of `twapToleranceTicks`. The 2.15 launch list and `REQ-ACCESS-155` name `tightenFloorRoundingAllowance` and add `tightenMaxFlashFeeBps`. A parameter with no tighten setter is not Short-eligible, so `idleUsdCap`, `idleBookingSeconds` and `coverageRatioBps` change at the normal delay. `Q-396` later removed `idleUsdCap` and `idleBookingSeconds`. Changed rules: `MKT-027`, `REQ-ACCESS-155`, `REQ-ACCESS-141`. |
| Status | Resolved (re-verified in `FV-CTL-R6`, 2026-11-10) |
| Verification | `TEST-063`, `TEST-244`, `PROP-073`; `FV-CTL-58` Verified in `FV-CTL-R6` |

#### FINDING-288: Four tighten-only setters were missing from the immutable short-delay set

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Low |
| Component | Timelock `SHORT_ELIGIBLE`, ParameterStore, SettlementBudget (removed, `Q-397`) |
| Reference | `FV-CTL-F-26`, `REQ-ACCESS-141`, `REQ-ACCESS-155`, `REQ-PSTORE-024`, `Q-362`, `Q-397` |
| Description | `ParameterStore.tightenFloorRoundingAllowance` and `tightenMaxFlashFeeBps` (2.9) and `SettlementBudget.tightenAssetWindow` and `tightenMarketWindow` (2.13) are Short on their owning pages but were absent from `SHORT_ELIGIBLE`, which listed the undefined `tightenFloorRoundingAllowanceGho`. `SHORT_ELIGIBLE` is immutable, so these tightenings would wait the normal delay for the life of the timelock. |
| Impact | A flash-fee or settlement-window tightening during an incident waits 5 days instead of 12 hours. |
| Evidence | `FV-CTL-F-26` (check `FV-CTL-153`, run `FV-CTL-R5`) |
| Resolution | `SHORT_ELIGIBLE` holds every tighten-only setter that exists, under its owning page's name: `tightenFloorRoundingAllowance` and `tightenMaxFlashFeeBps` on the ParameterStore, and `tightenCaps`, `tightenAssetWindow` and `tightenMarketWindow` on the SettlementBudget; the undefined name is dropped. `Q-397` later removed the SettlementBudget, so `tightenCaps`, `tightenAssetWindow` and `tightenMarketWindow` left `SHORT_ELIGIBLE`; the two ParameterStore setters stay. On 2026-11-13 the 2.15 launch list also gained `tightenMarketSpeedLimits` and `tightenDebtSpeedLimit`, the two speed-limit tighteners 2.9 marks short (`Q-411`, `REQ-PSTORE-036`). Changed rules: `REQ-ACCESS-141`, `REQ-ACCESS-155`. |
| Status | Resolved (re-verified on 2026-11-13) |
| Verification | `TEST-063`, `TEST-244`, `PROP-073`; `FV-CTL-153` Verified on 2026-11-13 |

#### FINDING-289: The Lens and the ParameterStore bounded the flash premium with a rounded-up ceiling that LPVaultSwap refuses

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Low |
| Component | Lens, ParameterStore, LPVaultSwap |
| Reference | `FV-CTL-F-27`, `REQ-LENS-029`, `REQ-PSTORE-024`, `REQ-FLASH-002`, `REQ-SWAP-013`, `SPEC-LIQ-015`, `Q-317` |
| Description | The Lens `premiumWithinMax` used `φ ≤ ⌈D × maxFlashFeeBps / 10⁴⌉` and `REQ-PSTORE-024` used `⌈amount × maxFlashFeeBps / 10⁴⌉`, while LPVaultSwap checks `φ × 10⁴ ≤ maxFlashFeeBps × F`. Z3: `F = D = 99`, maximum 100 bps, Pool premium 51 bps, `φ = 1` (half-up): the Lens says yes and LPVaultSwap reverts `FlashFeeTooHigh`. At launch values: `F` = 1,950,000,500 at 10 bps and `φ` = 1,950,001; the ceiling admits it and LPVaultSwap refuses (19,500,010,000 > 19,500,005,000). |
| Impact | A keeper following the Lens submits a flash-funded liquidation that reverts; the caller-funded path still settles it. |
| Evidence | `FV-CTL-F-27` (check `FV-CTL-78`, run `FV-CTL-R5`) |
| Resolution | One form everywhere: `φ × 10⁴ ≤ maxFlashFeeBps × F`, with `F` the flash amount in the call (not `D`); it is exact and has no rounding. `REQ-LENS-029` (`premiumWithinMax`), `REQ-PSTORE-024` (example `10e6 × 10⁴ ≤ 10 × 20,000e6`) and `REQ-FLASH-002` use it, and `INV-095`, `TEST-052` and `PROP-080` state it. Changed rules: `REQ-LENS-029`, `REQ-PSTORE-024`, `REQ-FLASH-002`. |
| Status | Resolved (re-verified in `FV-CTL-R6`, 2026-11-10) |
| Verification | `TEST-052`, `TEST-267`, `PROP-080`; `FV-CTL-78` Verified in `FV-CTL-R6` |

#### FINDING-290: The roles page kept the two-argument proxy salt, four Lock members and an old LPVault caller list

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | Roles page, ProxyManager, Lock, LPVault |
| Reference | `FV-CTL-F-28`, `REQ-ROLE-020`, `REQ-ROLE-021`, `REQ-ROLE-038`, `REQ-PROXY-051`, `REQ-ACCESS-147`, `REQ-ADAPTER-050`, `REQ-LOCK-004`, `Q-362` |
| Description | 1.4 `REQ-ROLE-020` gave `deployProxy(wallet, spoke)` with salt `(wallet, spoke)`, `REQ-ROLE-021` said the Lock had four members, and `REQ-ROLE-038` listed `releaseLiquidity` and omitted `topUpPosition` and `collectFees`, against `REQ-PROXY-051`, `REQ-LOCK-004` and the 2.2 caller table. |
| Impact | Contradictory role text; a reviewer reading 1.4 would expect one proxy per (wallet, Spoke) and a four-member Lock. |
| Evidence | `FV-CTL-F-28` (check `FV-CTL-04`, run `FV-CTL-R5`) |
| Resolution | `REQ-ROLE-020`: `deployProxy(wallet, spoke, marketId)` with salt `keccak256(abi.encode(wallet, spoke, marketId))` and `ProxyExists` per triple. `REQ-ROLE-021`: the Lock has two members, the AaveAdapter and LPVaultSwap. `REQ-ROLE-038`: `receivePosition(marketId, owner, positionKey)`, `topUpPosition`, `returnPosition(positionKey)`, `unwind(positionKey, units, minAmounts, recipient)`, `releaseToDepositor`, `collectFees(positionKey, depositor)`. Changed rules: `REQ-ROLE-020`, `REQ-ROLE-021`, `REQ-ROLE-038`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-270`, `PROP-075`; `FV-CTL-04` must print resolved in the next `FV-CTL` run |

#### FINDING-291: The exclusivity rule named a Hub-to-Adapter transfer that the vault token refuses

| Field | Value |
|---|---|
| Source | Formal verification (governance and control) |
| Severity | Informational |
| Component | RiskModule exclusivity rule, vault token, PositionProxy |
| Reference | `FV-CTL-F-29`, `REQ-ADAPTER-036`, `REQ-VTOKEN-006`, `REQ-VTOKEN-041`, `REQ-PROXY-008`, `Q-362` |
| Description | `REQ-ADAPTER-036` allowed "Hub supply, Hub to Adapter, and Hub to LPVaultSwap on seizure"; the vault token refuses Hub to Adapter, because a withdrawal goes Hub to proxy. A registered proxy as liquidator also passes the token check (Hub to proxy is the withdrawal path); exclusivity there rests on `REQ-PROXY-008`, which neither page named. |
| Impact | Text error; exclusivity holds on the token rule plus the proxy's call builder. |
| Evidence | `FV-CTL-F-29` (check `FV-CTL-162`, run `FV-CTL-R5`) |
| Resolution | `REQ-ADAPTER-036`: only proxy to Hub supply, Hub to proxy withdrawal (after which the Adapter burns from the proxy) and Hub to LPVaultSwap seizure (`REQ-VTOKEN-006`); a registered proxy never calls `liquidationCall`, because the Adapter's call builder has no such selector (`REQ-PROXY-008`). The same sentence follows the liquidator rule in `REQ-VTOKEN-006`. The Aave V4 Hub assumptions of 4.3 (`EXT-001`) name the same transfers: Adapter mint to a registered proxy, proxy to its home Hub on supply, home Hub to that proxy on withdrawal (the Hub→proxy path), home Hub to LPVaultSwap on seizure and Adapter burn, and state that the Adapter never receives the token from the Hub. Changed rules: `REQ-ADAPTER-036`, `REQ-VTOKEN-006`, `EXT-001`. |
| Status | Resolved in spec — re-verification pending |
| Verification | `TEST-180`, `TEST-090`; `FV-CTL-162` must print resolved in the next `FV-CTL` run |

#### FINDING-292: A released token worth less than one raw unit of the debt asset made every liquidation of the account revert with `NoRouteAvailable`

| Field | Value |
|---|---|
| Source | Developer (Hypothesis model) |
| Severity | Medium |
| Component | LPVaultSwap per-leg minimum output, routed settlement |
| Reference | `HYP-36`, `SPEC-LIQ-018`, `REQ-SWAP-022`, `REQ-SWAP-100`, `REQ-SWAP-102`, `LIQ-075`, `Q-250`, `Q-251` |
| Description | `REQ-SWAP-022` swapped every released token `i ≠ T` with `aᵢ > 0`, and `SPEC-LIQ-018` gives each leg `minOutᵢ ≥ 1`. Since liquidation settles straight into the debt asset, a token with more decimals and a much lower price than the debt asset can be released in an amount worth under one raw unit of it; every route then returns 0 and reverts with `MinOutNotMet`, so the call reverts with `NoRouteAvailable`. The probe of `REQ-SWAP-102` ran at `minOut = 1` and reverted the same way, so no shortfall was shown and in-kind never opened automatically (both were later removed, `Q-401`). Example (HYP-36): DAI/USDC market, USDC debt at $0.70, DAI at $0.05000016; a near-floor USDC debt of under 0.002 USDC fails flash-funded with `FlashFeeTooHigh`, and the caller-funded retry releases 7,349,976,535,931 wei of DAI, `Vleg = 0`, `Uleg = 1`, both routes quote 0 and the call reverts with `NoRouteAvailable`. The same leg appears in any liquidation of a position near the edge of its range. |
| Impact | Liveness loss in one market: the account cannot be liquidated by any keeper, permissionless caller or caller-funded path while the condition holds, and its deficit is never recorded; the loss grows with the position. |
| Evidence | `hypothesis/test_hyp_state_machine.py` (`keepers_sweep`, `HYP-36` liveness, falsifying sequence ending in `crash_and_liquidate(price=5000016, rid=1)`) |
| Resolution | A released token `i ≠ T` with `aᵢ > 0` and `Vlegᵢ ≤ Ulegᵢ` is a dust leg: it is not swapped, counts 0 toward `R`, is left out of `n'`, and goes whole to the call's residue recipient (`msg.sender`; `r.wallet` in `deleverage`), in `liquidate`, `liquidatePermissionless`, `settlePending` and `deleverage`. Its floor term `⌈Vlegᵢ(10⁴ − s)/10⁴⌉ − Ulegᵢ` is at most 0, so `minRec` already allows for it, and the tokens handed over are worth less than `Ulegᵢ + 1` debt units. Changed rules: `SPEC-LIQ-018`, `REQ-SWAP-022`, `REQ-SWAP-121` (new), `LIQ-029`, `LIQ-075`, `LIQ-090` (new). |
| Status | Resolved in spec — re-verification pending |
| Verification | `MATH-ST-111`, `HYP-36`, `TEST-232`, `PROP-068` |

#### FINDING-293: A flash source whose own address is a Spoke could still borrow from a Hub of the chain

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral final re-check, new attack N1) |
| Severity | Low |
| Component | LPVaultSwap flash path, `IFlashSource` implementation |
| Reference | `ATTACK-195`, `INV-095`, `REQ-FLASH-001`, `REQ-FLASH-005`, `REQ-FLASH-006`, Q-386, Q-388 |
| Description | The flash path compared the source's lender address with the liquidated reserve's Hub. A replacement source that is a flash Spoke on an Aave V4 Hub has a Spoke address, so it passed even when its Spoke drew from that Hub, and the setter refused only a lender that was itself a recorded Hub. LPVaultSwap checked the funding Hub while the source checked the home Hub. |
| Impact | Not reachable at launch (the source is the Aave V3 Pool). With a replacement source, a liquidation could repay a Hub with that Hub's own liquidity. |
| Evidence | [`final-recheck.md`](../../audit/design-review/amm-neutral/final-recheck.md) (N1) |
| Resolution | The flash-source implementation reports the pool or Hub it borrows from (`LENDER()`), and the source is refused when `MarketRegistry.isRecordedHub(LENDER())` is true, that is when that address is any Hub recorded on the chain: by `MarketRegistry.setFlashSource` (`InvalidRoute`) and by LPVaultSwap on every flash call (`FlashSourceIsHub`); `recordHub` refuses the current source's `LENDER()`, so the order of recording does not matter. The check covers every registered Hub, so the home-Hub and funding-Hub identities no longer matter. Changed rules: `INV-095`, `REQ-FLASH-001`, `REQ-FLASH-005`, `REQ-FLASH-006`. |
| Status | Resolved in spec |
| Verification | `TEST-285`, `TEST-267`, `PROP-096`, `MATH-ST-110` |

#### FINDING-294: A blocklisted fee recipient made every routed liquidation in that asset revert

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral final re-check, new attack N2a) |
| Severity | Low |
| Component | LPVaultSwap payouts, PayoutEscrow |
| Reference | `ATTACK-196`, `INV-036`, `INV-061`, `REQ-SWAP-028`, `REQ-SWAP-064`, `REQ-SWAP-076`, `REQ-ESCROW-018`, Q-389 |
| Description | The transfer of Avana's fee `A` to `feeRecipient` was unguarded, so if Circle or Tether blocklisted the treasury Safe, every routed liquidation with `S > 0` and every `settlePending` residue in that asset reverted on the chain until a normal-delay `setFeeRecipient` (5 days) took effect. A blocklisted keeper address had the same effect on its own calls. |
| Impact | A chain-wide halt of routed liquidation in one debt asset, on an issuer action, for up to the normal delay. |
| Evidence | [`final-recheck.md`](../../audit/design-review/amm-neutral/final-recheck.md) (N2a) |
| Resolution | Every fee and payout transfer is gas-limited and its failure never reverts a liquidation or `settlePending`: a transfer that reverts, returns `false` or runs out of gas moves the amount to the PayoutEscrow (the payout escrow, whose only job this is since `Q-401`), credited to the account (the borrower, `feeRecipient` or the caller), which claims it later. Changed rules: `INV-036`, `INV-061`, `REQ-SWAP-028`, `REQ-SWAP-064`, `REQ-SWAP-076`, `REQ-ESCROW-018`. |
| Status | Resolved in spec |
| Verification | `TEST-286`, `TEST-173`, `TEST-229` |

#### FINDING-295: A transfer fee on a debt asset made every flash-funded liquidation of that reserve revert

| Field | Value |
|---|---|
| Source | Design review (AMM-neutral final re-check, new attack N2b) |
| Severity | Medium |
| Component | LPVaultSwap flash path and payouts, `IFlashSource` implementation, debt breaker |
| Reference | `ATTACK-197`, `INV-095`, `REQ-FLASH-003`, `REQ-SWAP-026`, `REQ-SWAP-108`, `REQ-SWAP-122`, `REQ-SWAP-123`, Q-390 |
| Description | `REQ-SWAP-108` said a 5,000 USDT flash arrives as 4,995 USDT and LPVaultSwap passes on 4,995, but `REQ-FLASH-003` forwarded exactly the amount and then required `balance ≥ amount + premium` after LPVaultSwap returned `F + φ` net of the fee. Once Tether set `basisPointsRate > 0`, every flash-funded liquidation and every `deleverage` of a USDT debt reserve reverted. |
| Impact | Only caller-funded and in-kind liquidation remained for that reserve while the fee was on. |
| Evidence | [`final-recheck.md`](../../audit/design-review/amm-neutral/final-recheck.md) (N2b) |
| Resolution | The flash path and every payout measure received amounts by balance delta, and LPVaultSwap repays the source so that it receives `F + φ` after the fee. A non-zero transfer fee on a debt asset trips that reserve's debt breaker (`ISSUER`, read by the issuer probe `basisPointsRate()`): new borrows stop. Repayments of that asset do not settle while the fee is on: Aave V4's Hub refuses a fee-reduced repayment (`InsufficientTransferred`), so liquidation, repay and `deleverage` of it revert until the fee returns to 0 and resume in the next block after (`REQ-SWAP-123`, `TEST-048`); the balance-delta flash path below stays as defence in depth. Listing requires a transfer fee of 0 at listing time. Example at 10 bps: a 5,000 USDT flash at 5 bps arrives as 4,995 USDT, and LPVaultSwap sends `⌈5,002.5 / 0.999⌉` = 5,007.507508 USDT so the source receives 5,002.5; the source's balance is measured after each transfer and topped up at most `MAX_REPAY_TRANSFERS` = 4 times (`REQ-SWAP-122`). Changed rules: `INV-095`, `REQ-FLASH-003`, `REQ-SWAP-026`, `REQ-SWAP-108`, `REQ-SWAP-122`, `REQ-SWAP-123`. |
| Status | Resolved in spec |
| Verification | `TEST-287`, `TEST-221`, `TEST-048`, `PROP-097`, `MATH-ST-112` |
