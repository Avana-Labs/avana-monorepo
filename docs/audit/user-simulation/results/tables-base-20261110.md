### Personas (seed 20261110, feed profile `spec`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 156 | 114 | 78 | 0 | $7,060 | $38 | $1 | $78 | $0 | 0.94% | 74% | 33 / 32 / 0 |
| active_lp | 120 | 56 | 64 | 25 | 0 | $13,842 | $69 | $0 | $328 | $0 | 2.11% | 93% | 25 / 25 / 0 |
| leveraged | 100 | 49 | 51 | 46 | 2 | $18,429 | $130 | $60 | $284 | $484 | 1.63% | 78% | 24 / 24 / 0 |
| small | 120 | 49 | 71 | 23 | 1 | $195 | $1 | $0 | $87 | $1 | 48.11% | 100% | 18 / 17 / 0 |
| whale | 20 | 19 | 1 | 17 | 0 | $599,611 | $3,095 | $961 | $234 | $0 | 0.04% | 0% | 3 / 3 / 0 |
| multi_market | 85 | 64 | 20 | 54 | 0 | $17,476 | $60 | $20 | $124 | $0 | 0.72% | 80% | 19 / 19 / 0 |
| mobile | 110 | 67 | 43 | 52 | 0 | $3,819 | $20 | $7 | $84 | $0 | 2.50% | 93% | 20 / 20 / 0 |
| forgetful | 90 | 52 | 38 | 44 | 7 | $6,148 | $26 | $16 | $72 | $288 | 1.29% | 67% | 0 / 0 / 0 |
| usdc_borrower | 70 | 45 | 25 | 44 | 2 | $11,877 | $62 | $35 | $123 | $5 | 0.78% | 78% | 12 / 12 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 77 |
| accounts | 52 |
| bonus_paid | $780 |
| debt_repaid | $18,099 |
| deficit | $0 |
| budget_draws | $8 |
| keeper_reimbursement | $53,801 |
| keeper_pnl | $-53,801 |
| searcher_profit | $0 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $52,381 |
| max_gas_usd | $776 |
| dust calls (repay < $100) | 68 |
| by episode | USDe crash 73, pause + USDe aftershock 4 |
| by caller/mode | keeper/gho 72, keeper/in_kind 5 |
| by debt asset | GHO 56, USDC 21 |
| by market | USDe/USDT 77 |
| liquidation blocked (account-hours by reason) | RecoveryBelowFloor 47.3 h (8 accounts), StalePrice(disagree_pause) 1.3 h (2 accounts), StalePrice(disagree_expired) 0.8 h (3 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| pledge | `DeadlineExpired` | 15 | 14 | $318 |
| borrow | `PriceTooOld` | 15 | 14 | $169 |
| borrow | `DeadlineExpired` | 11 | 11 | $91 |
| borrow | `HealthFactorTooLow` | 10 | 5 | $74 |
| repayAllAndWithdraw | `DeadlineExpired` | 7 | 5 | $241 |
| pledge | `Dropped(not mined)` | 6 | 6 | $0 |
| borrow | `BadNonce` | 6 | 6 | $50 |
| collectFees | `DeadlineExpired` | 5 | 5 | $15 |
| repayAllAndWithdraw | `Dropped(not mined)` | 4 | 3 | $0 |
| borrow | `Dropped(not mined)` | 3 | 3 | $0 |
| collectFees | `Dropped(not mined)` | 2 | 2 | $0 |
| repay | `Dropped(not mined)` | 2 | 2 | $0 |
| withdraw | `Dropped(not mined)` | 1 | 1 | $0 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| pledge | `CapExceeded(market)` | 1341 | 358 |
| borrow | `PriceNotLive(Drifting:band)` | 1309 | 14 |
| pledge | `NotFullRange` | 382 | 370 |
| borrow | `DrawCapExceeded` | 187 | 93 |
| pledge | `PriceNotAccepted(Cached/Expired)` | 141 | 25 |
| pledge | `SliceNotAvailable` | 78 | 17 |
| pledge | `PoolShareExceeded` | 59 | 47 |
| withdraw(rebalance) | `HealthFactorTooLow` | 49 | 22 |
| pledge | `ApplicationPaused` | 41 | 2 |
| borrow | `ApplicationPaused` | 34 | 12 |
| borrow | `PriceTooOld` | 28 | 28 |
| pledge | `PriceNotAccepted(Drifting)` | 22 | 12 |
| borrow | `ApplicationFrozen` | 12 | 12 |
| top-up | `PoolShareExceeded` | 6 | 4 |
| withdraw(rebalance) | `PriceNotLive(Drifting:band)` | 3 | 2 |
| top-up | `ApplicationPaused` | 3 | 3 |
| withdraw(rebalance) | `PriceTooOld` | 2 | 2 |
| withdraw(rebalance) | `ApplicationPaused` | 2 | 2 |
| pledge | `CapExceeded(depositor)` | 1 | 1 |
| pledge(loop) | `SliceNotAvailable` | 1 | 1 |
| top-up | `SliceNotAvailable` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | cap_full | 376 | 1420 | app + governance |
| 2 | concentrated_rejected | 370 | 382 | app (now), contracts (later) |
| 3 | low_ltv | 252 | 252 | app + risk |
| 4 | fees_manual | 106 | 212 | app (contracts optional) |
| 5 | drawcap_exhausted | 93 | 187 | app + Aave governance |
| 6 | gas_exceeds_value | 86 | 86 | app + parameter |
| 7 | whole_nft_withdraw | 53 | 134 | contracts |
| 8 | borrow_blocked_price | 47 | 1288 | spec parameter + app |
| 9 | deadline_expired | 28 | 38 | app |
| 10 | donation_not_credited | 19 | 23 | contracts + app |
| 11 | tx_dropped | 17 | 18 | app |
| 12 | exit_needs_external_funds | 17 | 17 | contracts |
| 13 | liquidated | 13 | 77 | app |
| 14 | bad_nonce | 6 | 6 | app |
| 15 | max_borrow_reverted | 5 | 10 | app (+ spec note) |
| 16 | no_alerts | 4 | 47 | app/services |
| 17 | topup_refused_pool_share | 4 | 6 | contracts/spec |
| 18 | borrow_blocked_other_market | 4 | 4 | contracts + app |
| 19 | topup_refused_paused | 3 | 3 | contracts/spec + app |
| 20 | band_blocked_gho_premium | 1 | 64 | contracts/spec |
| 21 | depositor_cap_split | 1 | 1 | governance |
| 22 | topup_refused_slice | 1 | 1 | spec parameter + app |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| donated liquidity sitting uncredited in pledged NFTs (USD) | $76,854 | 13 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 42 |
| uncollected fees in the vault (claimable at any time) | $17,229 | 399 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age |
|---|---|---|---|
| USDC/USDT | 94.6% | 1.1% | 4.3% |
| GHO/USDC | 93.9% | 2.0% | 4.1% |
| DAI/USDC | 95.9% | 0.0% | 4.1% |
| USDe/USDT | 62.7% | 34.4% | 2.9% |
| USDC debt feed | 97.8% | 0.0% | 2.2% |

### Invariants

402156 checks over 15 kinds; violations: none

| Invariant | Checks |
|---|---|
| HF >= 1.10 after every borrow (BOR-POST-003) | 493 |
| HF >= 1.10 after withdraw-with-debt | 7 |
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1033 |
| backing: supply == credited + pending | 364 |
| credited == sum of records | 364 |
| custody iff open record | 62176 |
| debt conservation per account | 104486 |
| fee conservation per NFT | 107786 |
| liquidation GHO conservation | 77 |
| market regular counter <= cap | 364 |
| probe: state gates match the 3.6 emergency matrix | 108 |
| record live liquidity >= credited | 62176 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 62176 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $315, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $39,828 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $4,443,442, DAI/USDC $3,689,790, USDe/USDT $1,678,724 |
| third-party repay service | {'repaid': 4, 'repaid_in_None': 4, 'usd': 2496.1693146711677} |

### Rule probes vs the 3.6 emergency matrix (observed / expected)

| State (market, day) | new | topup | borrow | repay | collect | wd_free | wd_debt | repay_all_wd | liq |
|---|---|---|---|---|---|---|---|---|---|
| Live (USDC/USDT, 5.00) | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Drifting (USD band breach) (GHO/USDC, 9.00) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | Y | Y |
| Live on frozen alternate, then Drifting (TWAP) (USDC/USDT, 18.75) | N (PriceNotAccepted(Drifting)) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:twap)) | Y | Y | Y | N (PriceNotLive(Drifting:twap)) | Y | Y |
| Live on frozen alternate, then Drifting (TWAP) (USDC/USDT, 18.90) | N (PriceNotAccepted(Drifting)) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:twap)) | Y | Y | Y | N (PriceNotLive(Drifting:twap)) | Y | Y |
| Expired (USDC/USDT, 19.20) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Grace after recovery (USDC/USDT, 19.61) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | N (GraceHealthFactor) |
| Drifting (feed disagreement) (USDe/USDT, 60.21) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | Y | N (StalePrice(disagree_pause)) |
| Disagreement beyond disagreementPauseMax (USDe/USDT, 60.25) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | Y | N (StalePrice(disagree_expired)) |
| Drifting (USD band breach) (USDe/USDT, 66.00) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | Y | Y |
| Application Frozen (USDC/USDT, 75.10) | N (ApplicationFrozen) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (ApplicationFrozen) | Y | Y | Y | Y | Y | Y |
| Application Paused (USDC/USDT, 76.00) | N (ApplicationPaused) | N (ApplicationPaused) | N (ApplicationPaused) | Y | Y | Y | N (ApplicationPaused) | Y | Y |
| USDC debt feed stale (collateral Live on alternate) (USDC/USDT, 85.10) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | Y | N (DebtPriceStale) |

### Governance and attacks

- day 60.19: governance schedules enableInKind(USDe/USDT) after 1.0 h of RecoveryBelowFloor
- day 60.69: enableInKind(USDe/USDT) executed after the 12 h short delay
- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 40 opened; gas paid $3145
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 10.00: **cap squatting** (filler wallet w985f1 pledges $122358): regular room of USDC/USDT now $0
- day 10.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 12.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.30: **cap squatting** (filler wallet w985f2 pledges $2140): regular room of USDC/USDT now $0
- day 14.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.54: **cap squatting** (filler wallet w985f3 pledges $14084): regular room of USDC/USDT now $0
- day 17.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.48: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.52: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.56: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.60: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 20.02: **cap squatting** (filler wallet w985f4 pledges $9775): regular room of USDC/USDT now $0
- day 20.60: **cap squatting** (filler wallet w985f5 pledges $1017): regular room of USDC/USDT now $0
- day 22.56: **cap squatting** (filler wallet w985f6 pledges $28963): regular room of USDC/USDT now $0
- day 27.44: **cap squatting** (filler wallet w985f7 pledges $2473): regular room of USDC/USDT now $0
- day 29.15: **cap squatting** (filler wallet w985f8 pledges $5342): regular room of USDC/USDT now $0
- day 30.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.17: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.21: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.25: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.30: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.34: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.38: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.42: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.46: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.50: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.55: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.59: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.63: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.67: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.71: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.75: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.80: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.84: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.88: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.92: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.96: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.00: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.05: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.09: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.13: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.17: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.21: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.25: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.30: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.34: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.38: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.42: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.21: **cap squatting** (filler wallet w985f51 pledges $45150): regular room of USDC/USDT now $0
- day 33.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 33.51: **cap squatting** (filler wallet w985f52 pledges $19412): regular room of USDC/USDT now $0
- day 34.51: **cap squatting** (filler wallet w985f53 pledges $24694): regular room of USDC/USDT now $0
- day 34.63: **cap squatting** (filler wallet w985f54 pledges $15280): regular room of USDC/USDT now $0
- day 34.76: **cap squatting** (filler wallet w985f55 pledges $7001): regular room of USDC/USDT now $0
- day 35.01: **cap squatting** (filler wallet w985f56 pledges $2209): regular room of USDC/USDT now $0
- day 38.72: **cap squatting** (filler wallet w985f57 pledges $4836): regular room of USDC/USDT now $0
- day 39.84: **cap squatting** (filler wallet w985f58 pledges $46332): regular room of USDC/USDT now $0
- day 40.84: **cap squatting** (filler wallet w985f59 pledges $17927): regular room of USDC/USDT now $0
- day 41.80: **cap squatting** (filler wallet w985f60 pledges $3514): regular room of USDC/USDT now $0
- day 42.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.65: **cap squatting** (filler wallet w985f61 pledges $22767): regular room of USDC/USDT now $0
- day 43.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 45.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 45.12: **cap squatting** (filler wallet w985f62 pledges $8393): regular room of USDC/USDT now $0
- day 45.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 45.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 46.09: **cap squatting** (filler wallet w985f63 pledges $2525): regular room of USDC/USDT now $0
- day 46.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 46.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $697416
- day 47.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.76: **cap squatting** (filler wallet w985f64 pledges $869): regular room of USDC/USDT now $0
- day 49.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.05: **cap squatting** (filler wallet w985f65 pledges $4043): regular room of USDC/USDT now $0
- day 50.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.65: **cap squatting** (filler wallet w985f66 pledges $21217): regular room of USDC/USDT now $0
- day 51.27: **cap squatting** (filler wallet w985f67 pledges $25249): regular room of USDC/USDT now $0
- day 51.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.99: **cap squatting** (filler wallet w985f68 pledges $758): regular room of USDC/USDT now $0
- day 52.33: **cap squatting** (filler wallet w985f69 pledges $381170): regular room of USDC/USDT now $0
- day 52.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.17: **cap squatting** (filler wallet w985f70 pledges $8537): regular room of USDC/USDT now $0
- day 53.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.42: **cap squatting** (filler wallet w985f71 pledges $2260): regular room of USDC/USDT now $0
- day 53.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.69: **cap squatting** (filler wallet w985f72 pledges $36641): regular room of USDC/USDT now $0
- day 54.82: **cap squatting** (filler wallet w985f73 pledges $11911): regular room of USDC/USDT now $0
- day 54.94: **cap squatting** (filler wallet w985f74 pledges $10114): regular room of USDC/USDT now $0
- day 56.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.22: **cap squatting** (filler wallet w985f75 pledges $16984): regular room of USDC/USDT now $0
- day 57.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.49: **cap squatting** (filler wallet w985f76 pledges $14410): regular room of USDC/USDT now $0
- day 58.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.58: **cap squatting** (filler wallet w985f77 pledges $2457): regular room of USDC/USDT now $0
- day 59.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.42: **cap squatting** (filler wallet w985f78 pledges $1945): regular room of USDC/USDT now $0
- day 60.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.76: **cap squatting** (filler wallet w985f79 pledges $17841): regular room of USDC/USDT now $0
- day 60.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.17: **cap squatting** (filler wallet w985f80 pledges $7945): regular room of USDC/USDT now $0
- day 61.26: **cap squatting** (filler wallet w985f81 pledges $18900): regular room of USDC/USDT now $0
- day 61.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.60: **cap squatting** (filler wallet w985f82 pledges $2011): regular room of USDC/USDT now $0
- day 61.90: **cap squatting** (filler wallet w985f83 pledges $14740): regular room of USDC/USDT now $0
- day 62.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.20: **cap squatting** (filler wallet w985f84 pledges $17382): regular room of USDC/USDT now $0
- day 63.28: **cap squatting** (filler wallet w985f85 pledges $3254): regular room of USDC/USDT now $0
- day 63.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.72: **cap squatting** (filler wallet w985f86 pledges $15175): regular room of USDC/USDT now $0
- day 64.05: **cap squatting** (filler wallet w985f87 pledges $16110): regular room of USDC/USDT now $0
- day 64.22: **cap squatting** (filler wallet w985f88 pledges $10349): regular room of USDC/USDT now $0
- day 64.30: **cap squatting** (filler wallet w985f89 pledges $4300): regular room of USDC/USDT now $0
- day 64.39: **cap squatting** (filler wallet w985f90 pledges $100): regular room of USDC/USDT now $0
- day 64.80: **cap squatting** (filler wallet w985f91 pledges $5357): regular room of USDC/USDT now $0
- day 64.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.06: **cap squatting** (filler wallet w985f92 pledges $5712): regular room of USDC/USDT now $0
- day 65.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.44: **cap squatting** (filler wallet w985f93 pledges $13110): regular room of USDC/USDT now $0
- day 65.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.69: **cap squatting** (filler wallet w985f94 pledges $3624): regular room of USDC/USDT now $0
- day 65.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.95: **cap squatting** (filler wallet w985f95 pledges $1139): regular room of USDC/USDT now $0
- day 66.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.37: **cap squatting** (filler wallet w985f96 pledges $13624): regular room of USDC/USDT now $0
- day 66.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.04: **cap squatting** (filler wallet w985f97 pledges $34880): regular room of USDC/USDT now $0
- day 67.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.21: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.51: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.36: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.59: **cap squatting** (filler wallet w985f98 pledges $2116): regular room of USDC/USDT now $0
- day 73.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.35: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.39: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.43: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.47: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.52: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.56: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.60: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.64: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.68: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.72: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.77: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.81: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.85: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.89: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.93: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.97: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.02: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.06: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.10: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.14: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.18: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.22: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.27: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.31: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.35: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.39: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.43: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.47: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.52: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.56: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.60: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.64: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.68: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.72: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.77: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.81: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.85: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.89: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.93: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.97: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 77.02: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 77.06: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 77.10: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 77.27: **cap squatting** (filler wallet w985f102 pledges $1203): regular room of USDC/USDT now $0
- day 77.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.36: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.99: **cap squatting** (filler wallet w985f103 pledges $19990): regular room of USDC/USDT now $0
- day 78.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.91: **cap squatting** (filler wallet w985f104 pledges $6844): regular room of USDC/USDT now $0
- day 78.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.01: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.65: **cap squatting** (filler wallet w985f105 pledges $83643): regular room of USDC/USDT now $0
- day 81.32: **cap squatting** (filler wallet w985f106 pledges $7054): regular room of USDC/USDT now $0
- day 81.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.25: **cap squatting** (filler wallet w985f107 pledges $3857): regular room of USDC/USDT now $0
- day 82.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.03: **cap squatting** (filler wallet w985f108 pledges $115): regular room of USDC/USDT now $0
- day 85.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.34: **cap squatting** (filler wallet w985f109 pledges $5406): regular room of USDC/USDT now $0
- day 86.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.23: **cap squatting** (filler wallet w985f110 pledges $86): regular room of USDC/USDT now $0
- day 87.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.15: **cap squatting** (filler wallet w985f111 pledges $4356): regular room of USDC/USDT now $0
- day 88.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.03: **cap squatting** (filler wallet w985f112 pledges $2196): regular room of USDC/USDT now $0
- day 89.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
