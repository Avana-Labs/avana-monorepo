### Personas (seed 20261111, feed profile `spec`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 172 | 98 | 75 | 0 | $6,888 | $38 | $0 | $80 | $0 | 0.97% | 75% | 42 / 42 / 0 |
| active_lp | 120 | 59 | 61 | 24 | 0 | $22,223 | $61 | $0 | $315 | $0 | 1.60% | 88% | 22 / 22 / 0 |
| leveraged | 100 | 54 | 46 | 54 | 4 | $20,056 | $112 | $70 | $257 | $53 | 1.28% | 74% | 21 / 21 / 0 |
| small | 120 | 49 | 71 | 29 | 0 | $169 | $1 | $0 | $92 | $0 | 49.63% | 100% | 12 / 11 / 0 |
| whale | 20 | 15 | 5 | 13 | 0 | $604,268 | $3,665 | $966 | $292 | $0 | 0.05% | 0% | 3 / 3 / 0 |
| multi_market | 85 | 77 | 5 | 73 | 1 | $19,666 | $63 | $34 | $140 | $23 | 0.77% | 77% | 26 / 27 / 0 |
| mobile | 110 | 71 | 39 | 58 | 3 | $5,184 | $31 | $9 | $87 | $27 | 1.59% | 83% | 22 / 22 / 0 |
| forgetful | 90 | 57 | 33 | 51 | 6 | $9,033 | $60 | $34 | $77 | $174 | 0.80% | 68% | 0 / 0 / 0 |
| usdc_borrower | 70 | 45 | 25 | 45 | 0 | $15,792 | $74 | $45 | $112 | $0 | 0.65% | 64% | 14 / 14 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 91 |
| accounts | 54 |
| bonus_paid | $279 |
| debt_repaid | $9,728 |
| deficit | $0 |
| budget_draws | $8 |
| keeper_reimbursement | $63,300 |
| keeper_pnl | $-63,300 |
| searcher_profit | $0 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $60,524 |
| max_gas_usd | $904 |
| dust calls (repay < $100) | 79 |
| by episode | USDe crash 87, pause + USDe aftershock 4 |
| by caller/mode | keeper/gho 84, keeper/in_kind 7 |
| by debt asset | GHO 84, USDC 7 |
| by market | USDe/USDT 91 |
| liquidation blocked (account-hours by reason) | RecoveryBelowFloor 67.0 h (11 accounts), StalePrice(disagree_pause) 2.5 h (4 accounts), StalePrice(disagree_expired) 0.5 h (3 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| borrow | `PriceTooOld` | 15 | 14 | $154 |
| borrow | `HealthFactorTooLow` | 14 | 7 | $112 |
| collectFees | `DeadlineExpired` | 14 | 13 | $49 |
| borrow | `DeadlineExpired` | 12 | 12 | $90 |
| pledge | `DeadlineExpired` | 12 | 12 | $265 |
| pledge | `Dropped(not mined)` | 7 | 6 | $0 |
| borrow | `BadNonce` | 7 | 7 | $61 |
| repay | `Dropped(not mined)` | 3 | 2 | $0 |
| collectFees | `Dropped(not mined)` | 2 | 2 | $0 |
| repayAllAndWithdraw | `DeadlineExpired` | 2 | 2 | $22 |
| withdraw | `DeadlineExpired` | 2 | 2 | $28 |
| repay | `DeadlineExpired` | 2 | 1 | $88 |
| pledge | `CapExceeded(market)` | 1 | 1 | $31 |
| borrow | `DebtPriceTooOld` | 1 | 1 | $8 |
| withdraw | `Dropped(not mined)` | 1 | 1 | $0 |
| repayAllAndWithdraw | `Dropped(not mined)` | 1 | 1 | $0 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| pledge | `CapExceeded(market)` | 1091 | 288 |
| borrow | `PriceNotLive(Drifting:band)` | 730 | 12 |
| pledge | `NotFullRange` | 402 | 385 |
| pledge | `PriceNotAccepted(Cached/Expired)` | 124 | 27 |
| pledge | `PoolShareExceeded` | 68 | 53 |
| pledge | `ApplicationPaused` | 68 | 5 |
| withdraw(rebalance) | `HealthFactorTooLow` | 61 | 23 |
| pledge | `SliceNotAvailable` | 58 | 12 |
| borrow | `ApplicationPaused` | 35 | 11 |
| borrow | `PriceTooOld` | 30 | 30 |
| top-up | `PoolShareExceeded` | 26 | 1 |
| pledge | `PriceNotAccepted(Drifting)` | 11 | 7 |
| borrow | `ApplicationFrozen` | 8 | 8 |
| withdraw(rebalance) | `PriceNotLive(Drifting:band)` | 4 | 2 |
| withdraw(rebalance) | `ApplicationPaused` | 4 | 4 |
| pledge | `CapExceeded(depositor)` | 3 | 3 |
| withdraw(rebalance) | `PriceTooOld` | 3 | 2 |
| pledge | `ApplicationFrozen` | 3 | 1 |
| pledge | `BelowMinPledge` | 2 | 2 |
| pledge(loop) | `PoolShareExceeded` | 1 | 1 |
| top-up | `SliceNotAvailable` | 1 | 1 |
| borrow | `PriceNotLive(Drifting:mixed)` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | concentrated_rejected | 385 | 402 | app (now), contracts (later) |
| 2 | cap_full | 300 | 1150 | app + governance |
| 3 | low_ltv | 280 | 280 | app + risk |
| 4 | fees_manual | 111 | 205 | app (contracts optional) |
| 5 | gas_exceeds_value | 80 | 80 | app + parameter |
| 6 | whole_nft_withdraw | 57 | 156 | contracts |
| 7 | borrow_blocked_price | 52 | 776 | spec parameter + app |
| 8 | deadline_expired | 38 | 44 | app |
| 9 | donation_not_credited | 22 | 27 | contracts + app |
| 10 | liquidated | 15 | 91 | app |
| 11 | tx_dropped | 11 | 14 | app |
| 12 | exit_needs_external_funds | 10 | 10 | contracts |
| 13 | no_alerts | 8 | 57 | app/services |
| 14 | max_borrow_reverted | 7 | 14 | app (+ spec note) |
| 15 | bad_nonce | 7 | 7 | app |
| 16 | borrow_blocked_other_market | 5 | 5 | contracts + app |
| 17 | depositor_cap_split | 3 | 3 | governance |
| 18 | below_min | 2 | 2 | app |
| 19 | topup_refused_pool_share | 1 | 26 | contracts/spec |
| 20 | liquidated_unable_to_act | 1 | 4 | contracts/spec + app |
| 21 | band_blocked_gho_premium | 1 | 1 | contracts/spec |
| 22 | topup_refused_slice | 1 | 1 | spec parameter + app |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| donated liquidity sitting uncredited in pledged NFTs (USD) | $95,090 | 12 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 48 |
| uncollected fees in the vault (claimable at any time) | $19,902 | 432 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age |
|---|---|---|---|
| USDC/USDT | 94.4% | 1.0% | 4.6% |
| GHO/USDC | 93.8% | 2.0% | 4.2% |
| DAI/USDC | 95.8% | 0.0% | 4.2% |
| USDe/USDT | 62.9% | 34.4% | 2.8% |
| USDC debt feed | 97.7% | 0.0% | 2.3% |

### Invariants

429262 checks over 15 kinds; violations: none

| Invariant | Checks |
|---|---|
| HF >= 1.10 after every borrow (BOR-POST-003) | 530 |
| HF >= 1.10 after withdraw-with-debt | 5 |
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1132 |
| backing: supply == credited + pending | 364 |
| credited == sum of records | 364 |
| custody iff open record | 67643 |
| debt conservation per account | 110766 |
| fee conservation per NFT | 112063 |
| liquidation GHO conservation | 91 |
| market regular counter <= cap | 364 |
| probe: state gates match the 3.6 emergency matrix | 108 |
| record live liquidity >= credited | 67643 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 67643 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $65, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $40,438 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $4,644,110, DAI/USDC $2,654,774, USDe/USDT $2,762,783 |
| third-party repay service | {'repaid': 5, 'repaid_in_None': 5, 'usd': 10182.435042965264} |

### Rule probes vs the 3.6 emergency matrix (observed / expected)

| State (market, day) | new | topup | borrow | repay | collect | wd_free | wd_debt | repay_all_wd | liq |
|---|---|---|---|---|---|---|---|---|---|
| Live (USDC/USDT, 5.00) | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Drifting (USD band breach) (GHO/USDC, 9.00) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | Y | Y |
| Live on frozen alternate, then Drifting (TWAP) (USDC/USDT, 18.75) | N (PriceNotAccepted(Drifting)) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:twap)) | Y | Y | Y | N (PriceNotLive(Drifting:twap)) | Y | Y |
| Live on frozen alternate, then Drifting (TWAP) (USDC/USDT, 18.90) | N (PriceNotAccepted(Drifting)) | Y | N (PriceNotLive(Drifting:twap)) | Y | Y | Y | N (PriceNotLive(Drifting:twap)) | Y | Y |
| Expired (USDC/USDT, 19.20) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Grace after recovery (USDC/USDT, 19.61) | Y | Y | Y | Y | Y | Y | Y | Y | N (GraceHealthFactor) |
| Drifting (feed disagreement) (USDe/USDT, 60.21) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | Y | N (StalePrice(disagree_pause)) |
| Disagreement beyond disagreementPauseMax (USDe/USDT, 60.25) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | Y | N (StalePrice(disagree_expired)) |
| Drifting (USD band breach) (USDe/USDT, 66.00) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | Y | Y |
| Application Frozen (USDC/USDT, 75.10) | N (ApplicationFrozen) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (ApplicationFrozen) | Y | Y | Y | Y | Y | Y |
| Application Paused (USDC/USDT, 76.00) | N (ApplicationPaused) | N (ApplicationPaused) | N (ApplicationPaused) | Y | Y | Y | N (ApplicationPaused) | Y | Y |
| USDC debt feed stale (collateral Live on alternate) (USDC/USDT, 85.10) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | Y | N (DebtPriceStale) |

### Governance and attacks

- day 60.18: governance schedules enableInKind(USDe/USDT) after 1.0 h of RecoveryBelowFloor
- day 60.68: enableInKind(USDe/USDT) executed after the 12 h short delay
- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 40 opened; gas paid $2451
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 10.00: **cap squatting** (filler wallet w985f1 pledges $1030): regular room of USDC/USDT now $0
- day 10.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 12.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.01: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.16: **cap squatting** (filler wallet w985f2 pledges $11740): regular room of USDC/USDT now $0
- day 15.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.52: **cap squatting** (filler wallet w985f3 pledges $4683): regular room of USDC/USDT now $0
- day 17.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.28: **cap squatting** (filler wallet w985f4 pledges $5393): regular room of USDC/USDT now $0
- day 19.62: **cap squatting** (filler wallet w985f24 pledges $2457): regular room of USDC/USDT now $0
- day 19.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.75: **cap squatting** (filler wallet w985f25 pledges $3563): regular room of USDC/USDT now $0
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 22.20: **cap squatting** (filler wallet w985f26 pledges $18651): regular room of USDC/USDT now $0
- day 25.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 26.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 26.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 26.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.31: **cap squatting** (filler wallet w985f27 pledges $2448): regular room of USDC/USDT now $0
- day 28.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.21: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.19: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.23: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.27: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.32: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.36: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.40: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.44: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.48: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.52: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.57: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.61: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.65: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.69: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.73: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.77: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.82: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.86: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.90: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.94: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.98: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.02: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.07: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.11: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.15: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.19: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.23: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.27: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.32: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.36: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.40: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.44: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.48: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.52: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.57: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.61: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.65: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.69: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.73: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.77: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.23: **cap squatting** (filler wallet w985f62 pledges $112042): regular room of USDC/USDT now $0
- day 33.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 35.45: **cap squatting** (filler wallet w985f63 pledges $15520): regular room of USDC/USDT now $0
- day 36.07: **cap squatting** (filler wallet w985f64 pledges $10958): regular room of USDC/USDT now $0
- day 37.36: **cap squatting** (filler wallet w985f65 pledges $160): regular room of USDC/USDT now $0
- day 37.65: **cap squatting** (filler wallet w985f66 pledges $7095): regular room of USDC/USDT now $0
- day 37.86: **cap squatting** (filler wallet w985f67 pledges $271): regular room of USDC/USDT now $0
- day 37.99: **cap squatting** (filler wallet w985f68 pledges $4460): regular room of USDC/USDT now $0
- day 38.15: **cap squatting** (filler wallet w985f69 pledges $30671): regular room of USDC/USDT now $0
- day 38.40: **cap squatting** (filler wallet w985f70 pledges $8695): regular room of USDC/USDT now $0
- day 38.65: **cap squatting** (filler wallet w985f71 pledges $2780): regular room of USDC/USDT now $0
- day 39.28: **cap squatting** (filler wallet w985f72 pledges $17178): regular room of USDC/USDT now $0
- day 40.57: **cap squatting** (filler wallet w985f73 pledges $5390): regular room of USDC/USDT now $0
- day 42.20: **cap squatting** (filler wallet w985f74 pledges $3013): regular room of USDC/USDT now $0
- day 42.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.30: **cap squatting** (filler wallet w985f75 pledges $10309): regular room of USDC/USDT now $0
- day 43.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.86: **cap squatting** (filler wallet w985f76 pledges $247843): regular room of USDC/USDT now $0
- day 44.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.66: **cap squatting** (filler wallet w985f77 pledges $23054): regular room of USDC/USDT now $0
- day 44.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 45.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 45.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 45.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 45.67: **cap squatting** (filler wallet w985f78 pledges $21634): regular room of USDC/USDT now $0
- day 45.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 46.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 46.60: **cap squatting** (filler wallet w985f79 pledges $7475): regular room of USDC/USDT now $0
- day 46.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $697413
- day 47.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.19: **cap squatting** (filler wallet w985f80 pledges $17704): regular room of USDC/USDT now $0
- day 50.44: **cap squatting** (filler wallet w985f81 pledges $5122): regular room of USDC/USDT now $0
- day 50.69: **cap squatting** (filler wallet w985f82 pledges $1421): regular room of USDC/USDT now $0
- day 50.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.99: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.25: **cap squatting** (filler wallet w985f83 pledges $28020): regular room of USDC/USDT now $0
- day 51.54: **cap squatting** (filler wallet w985f84 pledges $177707): regular room of USDC/USDT now $0
- day 51.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.51: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.15: **cap squatting** (filler wallet w985f85 pledges $23963): regular room of USDC/USDT now $0
- day 53.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.23: **cap squatting** (filler wallet w985f86 pledges $5871): regular room of USDC/USDT now $0
- day 53.86: **cap squatting** (filler wallet w985f87 pledges $12572): regular room of USDC/USDT now $0
- day 54.45: **cap squatting** (filler wallet w985f88 pledges $7802): regular room of USDC/USDT now $0
- day 54.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.51: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.24: **cap squatting** (filler wallet w985f89 pledges $2329): regular room of USDC/USDT now $0
- day 57.53: **cap squatting** (filler wallet w985f90 pledges $28): regular room of USDC/USDT now $0
- day 57.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.62: **cap squatting** (filler wallet w985f91 pledges $1531): regular room of USDC/USDT now $0
- day 58.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.92: **cap squatting** (filler wallet w985f92 pledges $209): regular room of USDC/USDT now $0
- day 59.05: **cap squatting** (filler wallet w985f93 pledges $16535): regular room of USDC/USDT now $0
- day 59.21: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.57: **cap squatting** (filler wallet w985f94 pledges $22040): regular room of USDC/USDT now $0
- day 61.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.33: **cap squatting** (filler wallet w985f95 pledges $17612): regular room of USDC/USDT now $0
- day 61.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.49: **cap squatting** (filler wallet w985f96 pledges $3569): regular room of USDC/USDT now $0
- day 61.54: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.51: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.62: **cap squatting** (filler wallet w985f97 pledges $9226): regular room of USDC/USDT now $0
- day 64.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.47: **cap squatting** (filler wallet w985f98 pledges $13191): regular room of USDC/USDT now $0
- day 65.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.28: **cap squatting** (filler wallet w985f99 pledges $979765): regular room of USDC/USDT now $0
- day 67.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.54: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.20: **cap squatting** (filler wallet w985f100 pledges $2665): regular room of USDC/USDT now $0
- day 70.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.50: **cap squatting** (filler wallet w985f101 pledges $11388): regular room of USDC/USDT now $0
- day 70.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.92: **cap squatting** (filler wallet w985f102 pledges $10368): regular room of USDC/USDT now $0
- day 70.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.09: **cap squatting** (filler wallet w985f103 pledges $1655): regular room of USDC/USDT now $0
- day 74.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.88: **cap squatting** (filler wallet w985f104 pledges $9259): regular room of USDC/USDT now $0
- day 75.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.35: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.39: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.43: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.47: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.51: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.55: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.60: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.64: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.68: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.72: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.76: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.80: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.85: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.89: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.93: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.97: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.01: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.05: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.10: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.14: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.18: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.22: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.26: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.30: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 77.26: **cap squatting** (filler wallet w985f127 pledges $31240): regular room of USDC/USDT now $0
- day 77.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.43: **cap squatting** (filler wallet w985f128 pledges $20896): regular room of USDC/USDT now $0
- day 77.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.84: **cap squatting** (filler wallet w985f129 pledges $7834): regular room of USDC/USDT now $0
- day 78.88: **cap squatting** (filler wallet w985f130 pledges $12575): regular room of USDC/USDT now $0
- day 79.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.98: **cap squatting** (filler wallet w985f131 pledges $15566): regular room of USDC/USDT now $0
- day 80.10: **cap squatting** (filler wallet w985f132 pledges $15297): regular room of USDC/USDT now $0
- day 80.19: **cap squatting** (filler wallet w985f133 pledges $22487): regular room of USDC/USDT now $0
- day 80.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.62: **cap squatting** (filler wallet w985f134 pledges $18456): regular room of USDC/USDT now $0
- day 81.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.96: **cap squatting** (filler wallet w985f135 pledges $28808): regular room of USDC/USDT now $0
- day 82.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.17: **cap squatting** (filler wallet w985f136 pledges $7755): regular room of USDC/USDT now $0
- day 82.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.43: **cap squatting** (filler wallet w985f137 pledges $2129): regular room of USDC/USDT now $0
- day 83.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.83: **cap squatting** (filler wallet w985f138 pledges $8578): regular room of USDC/USDT now $0
- day 83.91: **cap squatting** (filler wallet w985f139 pledges $3245): regular room of USDC/USDT now $0
- day 83.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.08: **cap squatting** (filler wallet w985f140 pledges $2368): regular room of USDC/USDT now $0
- day 84.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.84: **cap squatting** (filler wallet w985f141 pledges $1583): regular room of USDC/USDT now $0
- day 84.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.43: **cap squatting** (filler wallet w985f142 pledges $1966): regular room of USDC/USDT now $0
- day 88.68: **cap squatting** (filler wallet w985f143 pledges $10232): regular room of USDC/USDT now $0
- day 88.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.89: **cap squatting** (filler wallet w985f144 pledges $103724): regular room of USDC/USDT now $0
- day 89.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
