# Simulation recorded results

Copied from docs/spec/05-verification/simulation/README.md (Results and Run log) as of 2026-11-10.

## Results

- **Bad debt** is zero in every brief scenario (depegs, provider-wide outages up to 72h on the USDC path, correlated drops to 0.80, keeper outages, interest) at every pool risk factor 0.20–0.40. An account opened at HF 1.10 reaches HF 1 at a 9.1% value drop (one token at 0.826) and is insolvent only when one token falls below (CF/1.10)²: 0.0201 at prf 0.20, 0.0453 at 0.30, 0.0804 at 0.40.
- **Bad debt appears only when a pool token goes to zero while liquidation of its markets stops**: a 48h provider-wide outage on the tail path (21k at prf 0.20, 224k at 0.30, 374k at 0.40 on the 2M book), no keeper of any kind for 48h (351k at 0.40), routes reverting with in-kind never opened (330k on the collapse path), or approved keepers skipping dust (`SIM-05C`). With working feeds and keepers the tail path ends with no bad debt at any prf: every account is liquidated on the way down.
- **Oracle timing under the final rules**: a provider-wide failure is Cached for exactly the 1h window from the first failed read and Expired after it in all 320 measured spells (`SIM-02D`); a silent stall stops seizure and borrowing within 78 minutes of the stall at 10-minute resolution (`SIM-02C`); borrowing on a stale price lasts at most 1.0h of a 12h stall, so the stale-price attacker of `ATTACK-056` never borrows (`SIM-03C`, `SIM-03D`).
- **The alternate route under Q-274**: when only a token's primary and TOKEN/X leg freeze while X/USD keeps updating, the market stays Drifting with seizure paused until the frozen leg passes its 87,000 s `feedMaxAge`, instead of Cached then Expired; on the USDT collapse this spent 141 Expired steps where a reverting outage spent 282, and delayed the first liquidation in the accounts' fresh markets by at least 1h, with the same bad debt (`SIM-02F`).
- **Standby routes**: a wrong primary stuck at $1 during the USDC depeg blocks 18.3 accounts for 320 account-hours without a switch; a switch within 15 minutes or 1h cuts it to 0.2–0.4 account-hours, 4h to 9.3 (`SIM-02G`). A 30-minute switch also ends a USDC route outage before the 1h Cached window expires, so no stress valuation occurs (`SIM-02I`).
- **Settlement**: the effective slippage keeps the floor above the debt for every non-dust liquidation, so the SettlementBudget drew nothing in every scenario except the dust wave of `SIM-05E` (121 draws, 29.73 GHO, largest market 19.61 GHO in any 24h against its 125 GHO sub-cap). Avana's fee from oracle value is paid whenever the surplus covers it (97 GHO on the USDC path at prf 0.40).
- **Shortfall top-up and in-kind**: with the backup route 3–8% below market, callers closed 1,683 gaps with top-ups and every liquidation ran at full size (`SIM-06A`, `SIM-06E`); with it 15% below market, shortfall reports opened in-kind at 9.2h against 15.2h for governance at the short delay (`SIM-06D`). A route that reverts proves no shortfall (`REQ-SWAP-102`), so only the 12h short-delay opening applies; on the collapse path it still kept bad debt at 0 (`SIM-06B`).
- **Keeper cost, not bad debt, is the main expense**: a slow collapse makes keepers re-liquidate as each price step pushes accounts back below HF 1. On the tail path with target HF 1.10, about 950 calls and $56k of reimbursement per 2M book at 20 gwei; $324k (default book) to $375k (dust-heavy) at 100 gwei. Target 1.02 / 1.05 / 1.20 gives $225k / $107k / $28k at 20 gwei (`SIM-05D`).
- **Incident controls**: `Paused(General)` with every market breaker tripped changes no liquidation outcome (961 vs 959 calls, no bad debt) and refuses no rescue top-up; `Paused(MintPathSuspect)` refused 33 top-up attempts and raised borrower loss from $21,518 to $21,562 (`SIM-04D`).
- **Grace** (0–2h at HF 0.90–0.95) added no bad debt; every outage that reached Expired started one window per market and one for the DebtOracle, from source-timestamp evidence.


## Run log

### 2026-11-10

- Command: `cd docs/spec/05-verification && for f in $(find simulation -name '*.py' | sort); do .venv/bin/python "$f"; echo "exit=$?"; done` (the simulation part of `run_all.sh`).
- Python 3.9.6, standard library only.
- Seeds 11/22/33 (sim05 Part B and D, sim07: 11/22; sim02 timeline: seeds 0–39; `SIM-00A`: `random.Random(5)`, 600 cases). Bounds: prf 0.20–0.40 (0.10–0.50 in sim08), outages 1–72h, horizons 74–122h (two years in sim07), 200 accounts (600 in the dust-heavy book).
- Wall time 360 s on a shared machine.

| Script | Holds | Counterexample | Exit code |
|---|---|---|---|
| `_simcore.py` | 2 | 0 | 0 |
| `sim01_depeg.py` | 4 | 1 | 0 |
| `sim02_oracle_outage.py` | 8 | 1 | 0 |
| `sim03_correlated_drop.py` | 4 | 0 | 0 |
| `sim04_keeper_outage.py` | 3 | 1 | 0 |
| `sim05_gas_dust.py` | 3 | 2 | 0 |
| `sim06_route_stress.py` | 5 | 0 | 0 |
| `sim07_interest_accrual.py` | 2 | 1 | 0 |
| `sim08_recommendations.py` | 4 | 0 | 0 |
| **Total** | **35** | **6** | **0** |
