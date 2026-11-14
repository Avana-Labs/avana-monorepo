# AMM-neutral architecture: state-machine model of the multi-Hub topology

Date: 2026-11-10. Scope: the proposed multi-Hub, multi-Spoke topology (per-Hub AaveAdapter, LPVaultSwap, MarketRegistry, ParameterStore and pause state; per-CDP-Spoke LPVault and Collateralization; one LP market per CDP Spoke; a Volatile-home Spoke drawing USDC from the Stable Hub; PositionProxy pinned to a version per wallet × Spoke with opt-in migration; liquidation through a standard Spoke with a transfer-restricted vault token), checked against [4.1 Global Invariants](../../../spec/04-security/01-global-invariants.md) and the Hub, proxy and lifecycle sections of the spec.

## Files and commands

| File | What it holds |
|---|---|
| [`docs/spec/05-verification/quint/topology.qnt`](../../../spec/05-verification/quint/topology.qnt) | The state machine: 2 Hubs, 3 CDP Spokes, actions, invariants `TOPO-01` … `TOPO-10`, `TOPO-X1`, `TOPO-X2` |
| [`docs/spec/05-verification/quint/topology_tests.qnt`](../../../spec/05-verification/quint/topology_tests.qnt) | 20 deterministic scenarios: one counterexample per finding under the proposal, the same steps under the fixed design, and the hardest path of each property that holds |
| [`docs/spec/05-verification/quint/topology_run.sh`](../../../spec/05-verification/quint/topology_run.sh) | 40 simulator runs (property × design × step relation), with an expectation per run |

```
cd docs/spec/05-verification
npx quint typecheck quint/topology.qnt && npx quint test quint/topology_tests.qnt   # 20 passing, ~10 s
quint/topology_run.sh                                                             # 1,000 traces x 25 steps per run, 8 in parallel
```

`run_all.sh` picks up both `.qnt` files for `quint typecheck` and `quint test`; `topology_run.sh` is run by hand. Quint 0.22.4.

## Model

| Part | Modelled as |
|---|---|
| Hubs | `STABLE` and `VOLATILE`, each with a GHO and a USDC reserve: liquidity, `drawn`, `deficit` and `drawCap` per (Hub, asset, Spoke), `added`, a credit line and a cross-Hub cap per (Hub, asset), a Coverage Spoke balance per (Hub, asset) |
| CDP Spokes | `S1` (home STABLE, M1 = USDC/USDT), `S2` (home STABLE, M2 = DAI/USDC), `S3` (home VOLATILE, M3 = ETH/USDC). S1 and S2 draw GHO and USDC from STABLE; S3 draws GHO from VOLATILE and USDC from STABLE (the cross-Hub credit line) |
| Per Spoke | LPVault custody (NFT owner `VAULT_Sx`) and a Collateralization ledger (records, reconcile on exit, pending settlement) |
| Per market | vault-token supply, Spoke supply per holder, LPVaultSwap holdings, pending units and the liquidity behind them, the proxy registry |
| Per Hub | AaveAdapter (lowest proxy version it serves), LPVaultSwap (seizes only its own Spokes' markets), pause state `None`/`Frozen`/`Paused`, token caps, the registry that checks draw caps |
| Proxies | `(wallet, Spoke, version)`; created on first pledge at the latest version; `bound(wallet, Spoke)` is the current one |
| Prices | token prices in cents (USDC, USDT, DAI, ETH); an LP unit is one unit of each leg; CF 80 % (M1, M2) and 60 % (M3); stale collateral counts as 0; USDC debt is priced at the USDC token price |
| Actors | 2 wallets, any payer, the Hub LPVaultSwaps, an outside liquidator, a faulty LPVaultSwap (`stepFaulty` only), guardians, governance (an executed timelock operation per action), Aave governance |

Actions: pledge, borrow, repay, debt-free and indebted withdrawal, partial removal, re-credit, donation (`increaseLiquidity` by anyone), liquidation (own Hub, another Hub, outside liquidator with `receiveShares`, faulty LPVaultSwap), deficit report (inside liquidation), settle pending, coverage, interest, a price shock per market (moves one leg token), a pool-local shock per market (feed stale or recovered), pause and freeze per Hub, market breakers, market delisting (Offboarding + Aave freeze, `MKT-038`), debt-reserve delisting (drawCap 0 + freeze, `MKT-045`), Aave `receiveSharesEnabled`, a new proxy version, an Adapter upgrade, proxy migration, and governance changes to draw caps, cross-Hub caps, credit lines and token caps.

Migration follows Aave V4: a position cannot move between users, so the Adapter repays the old proxy's debt with a flash loan, withdraws its supply, re-supplies it to the new proxy, re-borrows the same debt and re-points the ledger records, in one call. Aave refuses a supply into a frozen reserve, a borrow from a frozen reserve or past `drawCap`, and a borrow at HF < 1, in every design.

### Two readings

`s.design` holds five switches. `PROPOSAL` is the literal reading of the proposal; `FIXED` applies the fixes below. Each switch can be set alone.

| Switch | PROPOSAL | FIXED |
|---|---|---|
| `capScope` | the home Hub's registry checks a Spoke's draw caps over the home Hub's Spokes (the proposal scopes risk settings to the Hub) | the funding Hub's registry owns every draw cap on its assets and checks them against its credit line and cross-Hub cap |
| `pauseScope` | a borrow reads its home Hub's pause state | a borrow also reads the funding Hub's pause state |
| `proxySupport` | an Adapter upgrade may stop serving older proxy versions (nothing in the proposal requires otherwise) | an Adapter upgrade reverts while a proxy of an older version holds collateral or debt; migration reads no Avana stop |
| `liqVariant` | standard Spoke: public `liquidationCall`, vault token accepts only its Hub's LPVaultSwap (the proposal under review) | liquidation-manager Spoke: only the home Hub's LPVaultSwap may call `liquidationCall` |
| `tokenCapScope` | a Hub's token caps count its own (home) Spokes | a Hub's token caps count every Spoke that draws from it |

### Bounds and abstractions

- Sizes: 2 wallets, 6 NFTs (two per market, 6 and 4 units), 2 proxy versions, debts in whole units, prices 40, 70, 100 or 130 cents in random runs (any value in tests). Draw caps: STABLE USDC 8 (S1) + 7 (S2) + 5 (S3) = line 20, cross-Hub cap 5; STABLE GHO 10 + 10 = line 20; VOLATILE GHO 10 (S3). Token caps: STABLE USDC 26.
- Aave liquidation: flat 5 % bonus, no close factor; when the collateral cannot cover the requested repayment plus bonus, all of it is seized and the repayment falls to what it covers; the deficit is reported when the account's only collateral is empty with debt left. Aave's drawCap check counts drawn plus deficit.
- Not modelled: swaps, the SettlementBudget, fees, keepers, in-kind settlement, timelock delays, address freezes, Hub halts, interest-rate curves (interest is a +1 step), the USD value of caps (caps count units).
- Simulation is random sampling, not proof. Each finding below is backed by a deterministic test; the simulator found every counterexample except one noted in the table.

## Results

`HOLDS` means no violation in the tests or in 1,000 random traces × 25 steps per run for that design and step relation; `VIOLATED` gives the finding.

| ID | Property | PROPOSAL | FIXED | Evidence |
|---|---|---|---|---|
| TOPO-01 | Per Spoke, the vault custodies exactly the NFTs of the ledger's open records, each with at least its credited units; pending units equal the liquidity held for them | HOLDS | HOLDS | P-01, F-01 (with a faulty LPVaultSwap); every test |
| TOPO-02 | Per market, vault-token supply == Σ credited + pending == Spoke shares + LPVaultSwap holdings | HOLDS | HOLDS | P-02, F-02 (faulty LPVaultSwap); `faultySwapPendingTest`, `ammnSm04ReceiveSharesTest` |
| TOPO-02b | Per proxy, Spoke supply == Σ credited (INV-008) | VIOLATED (AMMN-SM-04) | HOLDS with reviewed components | `ammnSm04ReceiveSharesTest`; simulator did not reach it in 1,000 traces (P-02b) |
| TOPO-03 | No record, token, seizure, settlement, debt or deficit through another Spoke or Hub, or past the market's own LPVaultSwap and ledger | VIOLATED (AMMN-SM-04) | HOLDS | P-03, F-03; `crossHubLiquidationRefusedTest` |
| TOPO-04 | Each Hub's drawn total ≤ the sum of its draw caps (state form) | VIOLATED (AMMN-SM-02) | VIOLATED (AMMN-SM-02) | P-04, F-04 |
| TOPO-04g | No draw leaves drawn + deficit above the Spoke's drawCap (gate form) | HOLDS | HOLDS | P-04g, F-ALL |
| TOPO-05 | Draw caps on a funding Hub's asset sum to ≤ its credit line, foreign Spokes' caps to ≤ its cross-Hub cap, and no foreign draw exceeds that cap | VIOLATED (AMMN-SM-01) | HOLDS | P-05, F-05 |
| TOPO-06 | A Hub's suppliers lose only through deficits of Spokes that draw from that Hub; coverage pays only its own (Hub, asset); Hub books balance | HOLDS | HOLDS | P-06, F-06; `deficitAttributionTest` |
| TOPO-07 | Repay, debt-free withdrawal and removal, liquidation and pending settlement are available exactly as with every Avana stop cleared | VIOLATED (AMMN-SM-03) | HOLDS | P-07, F-07 |
| TOPO-08 | Migration never duplicates or orphans collateral or debt | VIOLATED (AMMN-SM-03, orphaning) | HOLDS | P-08, F-08; `migrationPreservesTest` |
| TOPO-09 | Delisting never strands a borrower | VIOLATED (AMMN-SM-03) | HOLDS | P-09, F-09 |
| TOPO-10 | A shock in one market never changes another Spoke's account values | VIOLATED (AMMN-SM-05) | VIOLATED (AMMN-SM-05, by design) | P-10, F-10 |
| TOPO-10p | The same for pool-local shocks (stale feed, disagreement, drained pool) | HOLDS | HOLDS | P-10p, F-ALL; `poolShockIsolatedTest` |
| TOPO-X1 | A Hub's pause stops every new draw of its liquidity | VIOLATED (AMMN-SM-06) | HOLDS | P-X1, F-ALL |
| TOPO-X2 | Collateral holding a token, on every Spoke that draws from a Hub, stays within that Hub's token cap | VIOLATED (AMMN-SM-05) | HOLDS | P-X2, F-ALL |

Migration never duplicated anything in either design: the account's credited units, Spoke supply and debt move whole, the old proxy ends empty, and at most one proxy per (wallet, Spoke) holds a position. The TOPO-08 violation is orphaning only.

### Simulator runs

`topology_run.sh`, 1,000 traces × 25 steps per run, 8 in parallel; 40 runs in about 13 minutes of wall time, the longest single run 486 s (`F-ALL`). `P-` runs start from the proposal, `F-` runs from the fixed design; `stepFaulty` adds an LPVaultSwap implementation that keeps seized tokens without settling them.

| Result | Runs |
|---|---|
| Held, as expected | P-01, P-02, P-06 (`stepFaulty`); P-04g, P-10p; F-01, F-02, F-03, F-06, F-07, F-08, F-09 (`stepFaulty`); F-05; F-ALL, F-ALL0, F-ALLC (every FIXED property, from the loaded, empty and crashed states); F-ALLF (every FIXED property except TOPO-02b, `stepFaulty`) |
| Counterexample found (a finding) | P-03, P-04, P-05, P-07, P-08, P-09, P-10, P-X1, P-X2; F-04, F-10 |
| Counterexample not reached in 1,000 traces (test covers it) | P-02b |
| Witnesses reached | a liquidation, a deficit, a Stable USDC deficit from S3, a coverage payment, a migration, a migration under a pause, pending units, a pending settlement, a withdrawal from a delisted market, a repay and a liquidation under `Paused` |

## Findings

### AMMN-SM-01 — Cross-Hub draw caps are checked by the wrong Hub, so a funding Hub's line and cross-Hub cap do not bind

Severity: Medium. Properties: TOPO-05. Spec: `SPEC-HUB-003`, `INV-057`, `REQ-HUB-017`, `REQ-HUB-080`, `INV-029`, `MKT-044` (`Q-233`, `Q-236`).

The proposal scopes risk settings, budgets and caps to a Hub and gives each Spoke its own draw caps. `SPEC-HUB-003` keys the credit line by asset only (`creditLine[a]`) and sets a source-Hub draw to `drawCap = creditLine[a]` for "the Borrow Spoke". With two Hubs that both hold USDC, and three Spokes drawing Stable USDC from two different home Hubs, no single registry sees every cap on Stable USDC: the Stable Hub's checks cover S1 and S2, the Volatile Hub's cover S3.

Counterexample (`ammnSm01CapsAboveLineTest`, `ammnSm01CrossCapIgnoredTest`):

1. Start: Stable USDC caps S1 8 + S2 7 + S3 5 = 20 = line; cross-Hub cap 5.
2. `gov.setDrawCap(S1, USDC, 13)`: the Stable registry checks S1 + S2 = 20 ≤ 20 and accepts. Caps on Stable USDC now sum to 25 > 20.
3. Separately, from the loaded state: `gov.setCrossHubCap(STABLE, USDC, 0)` (the Stable Hub withdraws its line to other Hubs) is accepted, S3's cap of 5 stays, and `borrow(alice, S3, USDC, 1)` succeeds: foreign draw 4 > cross-Hub cap 0.
4. Same for `gov.setCreditLine(STABLE, USDC, 15)`: accepted because S1 + S2 = 15, with S3's 5 on top.

Simulator: P-05 found step 3 (seed `0x8f62ce2df1bb1`, 19 steps, ending `gov.setCrossHubCap(STABLE, USDC, 0)`).

Fix: key credit lines and cross-Hub caps by (funding Hub, asset). The funding Hub's registry owns every `drawCap` on its assets, including those of other Hubs' Spokes; `enableDebtReserve` and every cap change run in the funding Hub's scope and require `Σ_s drawCap(h, a, s) ≤ creditLine(h, a)` and `Σ_{s foreign} drawCap(h, a, s) ≤ crossCap(h, a)`; lowering a credit line or cross-Hub cap reverts until the caps under it are lowered first; the drift check of each RiskModule compares the sum over all Spokes that draw the asset, not only its own. Replace "the Borrow Spoke's drawCap on that Hub's asset is `creditLine[a]`" in `SPEC-HUB-003` with the per-Spoke allocation. Verified by `ammnSm01FixedTest` and F-05.

### AMMN-SM-02 — "drawn ≤ drawCap" is a gate on new draws, not a state invariant

Severity: Low (specification). Properties: TOPO-04 (both designs). Spec: `INV-057`, `SPEC-HUB-003`, `MKT-045`, `MKT-039`.

`INV-057` states that the amount drawn by each Borrow Spoke is at most its `drawCap`. Aave V4 checks the cap only when a draw happens. Two normal events break the state form, in every design:

- Cap cut (`ammnSm02CapCutTest`): loaded state (alice 8 GHO drawn on S1) → `gov.setDrawCap(S2, GHO, 0)` → `delistDebtReserve(S1, GHO)`, which `MKT-045` itself prescribes (drawCap 0 while debt is outstanding). Stable GHO drawn 8 > Σ caps 0.
- Interest (`ammnSm02InterestTest`): caps S1 GHO 8, S2 GHO 0 → `accrue(STABLE, GHO)` → drawn 9 > 8.

Simulator: P-04 (seed `0x2e4c4a2ebb5af`, ending `gov.setDrawCap(S3, GHO, 0)` with 4 GHO drawn) and F-04 (seed `0x852d28fe3b4b7`). The gate form TOPO-04g held in every run.

Fix: restate `INV-057` as a gate: "no draw completes that leaves `drawn + premium + deficit` above the Spoke's `drawCap`; a cap cut or interest can leave a Spoke above its cap, and then only repayment, liquidation and coverage lower it". Keep the cap-sum rule of AMMN-SM-01 as a configuration invariant on caps, not on drawn amounts.

### AMMN-SM-03 — Pinned proxies can be stranded: an Adapter upgrade stops serving old versions, and migration is a gated re-borrow

Severity: High. Properties: TOPO-07, TOPO-08, TOPO-09. Spec: `INV-064`, `INV-065`, `REQ-PROXY-001`, `REQ-PROXY-005`, `INV-043`, `INV-045`, `INV-067`, `INV-081`, `MKT-038`, `MKT-040`, `MKT-045` (`Q-225`).

Today one beacon upgrade moves every proxy at once (`INV-065`), so an Adapter never meets an old proxy. With pinned versions, each AaveAdapter (UUPS, one per Hub) must keep driving every proxy version ever deployed, and nothing in the proposal requires it. A wallet that does not migrate then depends on migration, which Aave V4 can only do as repay + withdraw + re-supply + re-borrow. That path passes through the pledge and borrow gates and through Aave's freeze and `drawCap` checks, which exits never read.

Counterexamples (loaded state; alice: 8 GHO on S1, debt-free record 2 on S2):

1. Pause (`ammnSm03PauseBlocksExitTest`): `releaseVersion` → `upgradeAdapter(STABLE)` (serves version 2 only) → `setPause(STABLE, Paused)`. Alice cannot repay her S1 debt or withdraw her debt-free S2 NFT; with the pause cleared she can (through migration). Exits now depend on the pause state (TOPO-07).
2. Cap cut (`ammnSm03CapCutOrphansTest`): `releaseVersion` → `upgradeAdapter(STABLE)` → `gov.setDrawCap(S1, GHO, 3)`. The re-borrow of 8 GHO fails Aave's drawCap, the Adapter no longer drives the v1 proxy: alice's 8 GHO debt and 6 units of collateral are orphaned (TOPO-08). Only a liquidation, once HF < 1, can touch them.
3. Delisting (`ammnSm03DelistStrandsTest`): `releaseVersion` → `upgradeAdapter(STABLE)` → `offboardMarket(M2)`. The Aave freeze refuses the re-supply, so alice's debt-free M2 NFT cannot leave (TOPO-09). The same with `delistDebtReserve(S1, GHO)` for her S1 debt.

Simulator: P-07 (seed `0x215ce58b8aa00`: VOLATILE `Frozen` → `releaseVersion` → `upgradeAdapter(VOLATILE)`; under `Frozen` a debt-free account cannot re-pledge and an indebted one cannot re-borrow), P-08 (seed `0x15ae75ea795953`: `releaseVersion` → `upgradeAdapter(VOLATILE)` → … → `offboardMarket(M3)`), P-09 (seed `0xfbaa5d18fa146`: `upgradeAdapter(STABLE)` → `delistDebtReserve(S1, GHO)`).

Fix:

- Freeze the proxy-facing interface: every AaveAdapter implementation must drive every PositionProxy version that holds collateral or debt; an upgrade that drops a version reverts while any proxy of it is live (`proxySupport = KEPT`). State it next to `INV-065`, and add it to the Lens checks after every upgrade.
- Migration is opt-in and never needed for an exit. It reads no Avana stop (it adds no risk: same collateral, same debt, same HF), and its Aave-side failures (frozen reserve, cap cut) leave the old proxy fully serviceable.
- Rewrite `INV-064` and `REQ-PROXY-001`: the CREATE2 salt includes the version, `proxyOf(wallet, spoke)` moves only inside a migration that empties the old proxy, and the old proxy stays registered (`INV-012` is append-only) and serviceable.

Verified by `ammnSm03FixedTest` (under `Paused`, with M2 offboarded and S1's cap cut to 3, alice can repay and withdraw; bob migrates under the pause) and F-07, F-08, F-09.

### AMMN-SM-04 — On a standard Spoke, `receiveShares` liquidation bypasses LPVaultSwap and the ledger

Severity: Medium. Properties: TOPO-03, TOPO-02b. Spec: `INV-011`, `INV-013`, `INV-008`, `INV-041`, `INV-058`, `INV-029`, `REQ-ADAPTER-029`, `REQ-HUB-003`, `REQ-HUB-060`.

The proposal under review uses a standard Spoke with public `liquidationCall` and relies on the vault token's recipient rule so that only LPVaultSwap can take seized collateral. Aave V4's `receiveShares = true` path credits the liquidator with Spoke supply shares and moves no token, so the recipient rule never runs. It needs only the reserve's `receiveSharesEnabled` flag (an Aave Spoke configuration, not an Avana one) and an unfrozen reserve. Avana's drift check (`INV-029`) detects the flag but only stops new borrowing; it cannot stop the seizure.

Counterexample (`ammnSm04ReceiveSharesTest`):

1. Loaded state; `Aave.setReceiveSharesEnabled(S3)`.
2. `priceShock(M3, ETH, 40)`: bob's S3 account (4 GHO, 4 units of M3) falls below HF 1.
3. `Spoke.liquidationCall(receiveShares)` by an outside liquidator repays 4 GHO and takes 3 units as Spoke shares. Bob's proxy has 1 unit of supply against 4 credited (TOPO-02b); no LPVaultSwap seized and no ledger debit happened (TOPO-03).
4. `withdraw(bob, 5)` reconciles: 3 units move to pending settlement. `settlePending` can never run, because LPVaultSwap holds no tokens for them and the liquidator's shares can never leave the Hub (the vault token refuses the transfer). The units stay pending, and the liquidator holds shares it cannot withdraw.

The same path lets a non-LPVaultSwap caller trigger the deficit report (`INV-041` says only LPVaultSwap's liquidation reports deficits). Supply per market stays equal to credited + pending (TOPO-02 holds), so the damage is stuck units and a broken settlement path, not lost backing.

Simulator: P-03 (seed `0x1f66689546db28`, 20 steps, ending `Aave.setReceiveSharesEnabled(S3)` → `removeLiquidity(bob)` → outside `liquidationCall`). P-02b did not reach the per-proxy gap in 1,000 traces; the test shows it.

Fix: keep the liquidation-manager Spoke (`REQ-HUB-003`), where only the home Hub's LPVaultSwap can call `liquidationCall` and `receiveShares` is refused in code. If a standard Spoke is used, the Aave DAO payload must make `receiveSharesEnabled` false unchangeable for vault-token reserves (a Spoke implementation that rejects it), since a drift alarm alone does not protect the ledger. Verified by `ammnSm04FixedTest` and F-03.

### AMMN-SM-05 — One market per Spoke does not isolate token price risk, and per-Hub token caps miss cross-Hub exposure

Severity: Medium. Properties: TOPO-10, TOPO-X2. Spec: `INV-075`, `INV-027`, `INV-028`, `INV-074`, `MKT-013`.

Pricing values an LP unit as Σ amountᵢ × priceᵢ over approved token prices. M1 (USDC/USDT), M2 (DAI/USDC) and M3 (ETH/USDC) all hold USDC, and S3's USDC debt is priced in USDC. A USDC move "in market M1" moves accounts on all three Spokes.

Counterexample (`ammnSm05TokenShockTest`, both designs): loaded state → `priceShock(M1, USDC, 70)`. Alice's S2 collateral value falls from 6 × 200 × 80 to 6 × 170 × 80; her S3 collateral falls to 6 × 170 × 60 and her S3 USDC debt to 3 × 70 × 100. Simulator: P-10 (seed `0x180b89faa7402f`, ending `priceShock(M1, USDC, 130)`) and F-10. Pool-local shocks stay isolated (TOPO-10p held in every run, `poolShockIsolatedTest`), which is what `INV-075` claims.

The cap side does not cover it. Token caps (`tokenUsdCap`) live in each Hub's ParameterStore and count that Hub's markets. S3 belongs to the Volatile Hub but draws Stable USDC, so the Stable Hub's lenders carry M3's USDC and ETH legs while the Stable Hub's counter never sees them.

Counterexample (`ammnSm05TokenCapTest`): loaded state (Stable USDC cap 26) → `pledge(bob, NFT 4 into M2)`. The Stable ParameterStore counts S1 + S2 = 20 ≤ 26 and accepts; the USDC collateral behind Stable debt is 30 (M3's 10 included). Simulator: P-X2 (seed `0x37a46007bbe75`, from an empty start).

Fix: restate `INV-075` (and the proposal's "one market per Spoke for isolation") as isolation from pool-level failures only: feeds, oracle state, breakers, pool depth and routes; token price moves are shared by design. Count token exposure per funding Hub over every Spoke that draws from it (`tokenCapScope = FUNDING`), so the Stable Hub's `tokenUsdCap[USDC]` includes M3, and size cross-Hub caps with the solvency check of `INV-074` per funding Hub. Verified by F-ALL (TOPO-X2 held) and `ammnSm05TokenCapTest` (the FIXED pledge is refused).

### AMMN-SM-06 — A funding Hub's pause does not stop other Hubs' Spokes drawing its liquidity

Severity: Medium. Properties: TOPO-X1. Spec: `EMG-039`, `INV-049`, `INV-067`, `INV-024`, `INV-020`.

`EMG-039` gives the application one pause state, read by the AaveAdapter on borrow. Per Hub, the Volatile Hub's Adapter reads the Volatile pause state when S3 borrows Stable USDC. A Stable Hub incident (USDC depeg, a Stable-side oracle or cap problem) paused on the Stable Hub leaves its USDC open to S3.

Counterexample (`ammnSm06FundingPauseTest`): loaded state → `setPause(STABLE, Paused)` → `borrow(alice, S3, USDC, 1)` succeeds. Simulator: P-X1 (seed `0x1b527d368f918d`, 11 steps).

Fix: a borrow reads the pause state of its home Hub and of the debt reserve's funding Hub (`pauseScope = FUNDING`); repay, liquidation and exits read neither (`INV-081` unchanged). Verified by `ammnSm06FundingPauseTest` (under the Stable pause, S3's Stable USDC borrow is refused while its Volatile GHO borrow and its USDC repay stay open) and F-ALL.

## Properties that hold, and why

- **TOPO-01, TOPO-02** (custody and supply) held in both designs with a faulty LPVaultSwap that keeps seized tokens: each Spoke's ledger and vault are immutable pairs bound to one market, LPVaultSwap seizes only its own Hub's markets, and reconcile on exit plus `settlePending` close any gap (`faultySwapPendingTest`). This depends on the token and ledger taking the market's Spoke from immutables, never from a call argument.
- **TOPO-03, Hub routing** held in both designs: another Hub's LPVaultSwap cannot liquidate S3 (`crossHubLiquidationRefusedTest`), and every debt, deficit and draw sits on the reserve's own funding Hub. The violation is the `receiveShares` bypass of AMMN-SM-04 only.
- **TOPO-06** (supplier loss) held: S3's USDC deficit lands on (STABLE, USDC, S3), only the Stable USDC Coverage Spoke can cover it, and the Volatile Hub's lenders bear only S3's GHO (`deficitAttributionTest`). The Stable Hub's lenders do carry every deficit of S3's USDC line; that is the intended cross-Hub risk, bounded only once AMMN-SM-01 and AMMN-SM-05 are fixed.
- **TOPO-08, duplication**: migration moved credit, supply and debt whole, emptied the old proxy and re-pointed the records in both designs.

## Limits

- Random simulation with 2 wallets, 6 NFTs and 25-step traces is not proof; the FIXED results say no counterexample was found within these bounds.
- The model counts caps in units, not USD, and leaves out the SettlementBudget, routes, the in-kind path and keeper incentives; findings on those for this topology are in [gas-dos.md](gas-dos.md) and [verification-coverage.md](verification-coverage.md).
- Interest is a +1 step on every debt; Aave's premium and rate curves are not modelled. Address freezes and Aave Hub halts are not modelled; an Aave halt of (Stable USDC, S3) would stop S3's USDC repay and liquidation, as `REQ-HUB-090` already records for one Hub.
