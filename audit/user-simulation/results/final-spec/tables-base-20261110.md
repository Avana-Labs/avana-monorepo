### Personas (seed 20261110, feed profile `spec`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 172 | 98 | 88 | 0 | $7,101 | $40 | $2 | $80 | $0 | 1.01% | 74% | 37 / 37 / 0 |
| active_lp | 120 | 68 | 52 | 35 | 1 | $16,195 | $74 | $4 | $301 | $19 | 2.03% | 88% | 30 / 30 / 0 |
| leveraged | 100 | 60 | 40 | 59 | 5 | $19,237 | $124 | $71 | $334 | $225 | 1.66% | 78% | 28 / 28 / 0 |
| small | 120 | 44 | 76 | 26 | 1 | $204 | $1 | $0 | $91 | $1 | 46.47% | 100% | 19 / 19 / 0 |
| whale | 20 | 16 | 3 | 15 | 0 | $451,455 | $2,702 | $935 | $253 | $0 | 0.05% | 0% | 3 / 3 / 0 |
| multi_market | 85 | 77 | 6 | 68 | 23 | $15,936 | $57 | $18 | $147 | $2,534 | 0.87% | 81% | 20 / 21 / 0 |
| mobile | 110 | 72 | 38 | 56 | 0 | $3,755 | $26 | $7 | $84 | $0 | 2.38% | 92% | 21 / 21 / 0 |
| forgetful | 90 | 58 | 32 | 48 | 7 | $6,610 | $31 | $12 | $72 | $157 | 1.52% | 69% | 0 / 0 / 0 |
| usdc_borrower | 70 | 53 | 17 | 53 | 5 | $11,606 | $66 | $28 | $115 | $106 | 0.89% | 77% | 13 / 13 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 87 |
| accounts | 82 |
| bonus_paid | $3,044 |
| debt_repaid | $75,423 |
| deficit | $0 |
| budget_draws | $0 |
| keeper_reimbursement | $48,952 |
| keeper_pnl | $-47,962 |
| searcher_profit | $94 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $31,826 |
| max_gas_usd | $904 |
| dust calls (repay < $100) | 41 |
| calls on the dust attacker's accounts / on other accounts | 40 / 47 |
| other accounts: calls repaying under $100 / gas / debt repaid / reimbursed / most calls on one account | 1 / $18,592 / $75,324 / $17,902 / 2 |
| liquidations seizing a fresh market while another market of the account was Cached, Expired or disagreeing (Q-247) | 22 |
| by episode | USDe crash 63, GHO/USDC drain 22, pause + USDe aftershock 2 |
| by caller/mode | permissionless/gho 2, keeper/gho 85 |
| by debt asset | GHO 69, USDC 18 |
| by market | USDe/USDT 68, USDC/USDT 11, GHO/USDC 8 |
| liquidation blocked (account-hours by reason) | StalePrice(Cached/Expired) 1621.2 h (94 accounts), StalePrice(disagree_pause) 0.8 h (3 accounts), StalePrice(disagree_expired) 0.7 h (4 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| borrow | `DrawCapExceeded` | 25 | 2 | $626 |
| pledge | `DeadlineExpired` | 18 | 16 | $438 |
| borrow | `DeadlineExpired` | 14 | 13 | $114 |
| borrow | `Dropped(not mined)` | 6 | 5 | $0 |
| collectFees | `Dropped(not mined)` | 5 | 5 | $0 |
| pledge | `Dropped(not mined)` | 4 | 2 | $0 |
| collectFees | `DeadlineExpired` | 4 | 4 | $15 |
| repay | `DeadlineExpired` | 4 | 4 | $56 |
| repayAllAndWithdraw | `Dropped(not mined)` | 3 | 2 | $0 |
| borrow | `BadNonce` | 2 | 2 | $14 |
| repay | `Dropped(not mined)` | 2 | 2 | $0 |
| withdraw | `DeadlineExpired` | 2 | 2 | $14 |
| withdraw | `Dropped(not mined)` | 2 | 2 | $0 |
| removeLiquidity | `DeadlineExpired` | 1 | 1 | $6 |
| recredit | `DeadlineExpired` | 1 | 1 | $9 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| borrow | `PriceNotLive(Drifting:band)` | 1905 | 15 |
| pledge | `CapExceeded(market)` | 1057 | 277 |
| pledge | `NotFullRange` | 382 | 370 |
| repayWithCollateral | `StalePrice(Cached/Expired)` | 146 | 10 |
| borrow | `DrawCapExceeded` | 132 | 83 |
| top-up | `PriceNotAccepted(Cached/Expired)` | 109 | 14 |
| pledge | `SliceNotAvailable` | 85 | 16 |
| repayWithCollateral | `MinOutNotMet` | 73 | 5 |
| borrow | `ApplicationPaused` | 52 | 14 |
| pledge | `PoolShareExceeded` | 50 | 42 |
| removeLiquidity(rebalance) | `HealthFactorTooLow` | 28 | 15 |
| recredit | `SliceNotAvailable` | 24 | 5 |
| borrow | `ApplicationFrozen` | 13 | 13 |
| recredit | `CapExceeded(market)` | 10 | 3 |
| borrow | `BreakerTripped(POOL_SHARE,MANUAL)` | 6 | 6 |
| recredit | `PoolShareExceeded` | 6 | 2 |
| repayWithCollateral | `ApplicationPaused` | 6 | 1 |
| borrow | `PriceNotLive(Drifting:mixed)` | 5 | 3 |
| pledge | `BelowMinPledge` | 4 | 4 |
| pledge | `NotRescueTopUp` | 4 | 4 |
| borrow | `BreakerTripped(POOL_SHARE)` | 3 | 3 |
| removeLiquidity(rebalance) | `BreakerTripped(POOL_SHARE)` | 3 | 3 |
| borrow | `PriceNotLive(Cached/Expired)` | 3 | 3 |
| top-up | `SliceNotAvailable` | 2 | 2 |
| pledge(loop) | `SliceNotAvailable` | 2 | 2 |
| repayWithCollateral | `StalePrice(disagree_pause)` | 2 | 2 |
| removeLiquidity(rebalance) | `ApplicationPaused` | 2 | 2 |
| recredit | `NotRescueTopUp` | 2 | 2 |
| pledge | `CapExceeded(depositor)` | 1 | 1 |
| pledge | `PriceNotAccepted(Drifting)` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | concentrated_rejected | 370 | 382 | app (now), contracts (later) |
| 2 | low_ltv | 300 | 300 | app + risk |
| 3 | cap_full | 294 | 1144 | app + governance |
| 4 | fees_manual | 115 | 201 | app (contracts optional) |
| 5 | drawcap_exhausted | 85 | 157 | app + Aave governance |
| 6 | gas_exceeds_value | 79 | 79 | app + parameter |
| 7 | used_partial_removal | 57 | 141 | outcome |
| 8 | liquidated | 43 | 87 | app |
| 9 | deadline_expired | 34 | 44 | app |
| 10 | no_alerts | 32 | 71 | app/services |
| 11 | partial_removal_refused | 19 | 35 | app |
| 12 | borrow_blocked_price | 18 | 1913 | spec parameter + app |
| 13 | used_repay_with_collateral | 18 | 18 | outcome |
| 14 | tx_dropped | 17 | 22 | app |
| 15 | exit_via_repay_with_collateral | 17 | 17 | outcome |
| 16 | deleverage_refused | 15 | 227 | app |
| 17 | topup_refused_stale | 14 | 109 | app |
| 18 | recredit_refused | 10 | 42 | app |
| 19 | borrow_blocked_breaker | 7 | 9 | app |
| 20 | below_min | 4 | 4 | app |
| 21 | borrow_blocked_other_market | 3 | 3 | contracts + app |
| 22 | bad_nonce | 2 | 2 | app |
| 23 | topup_refused_slice | 2 | 2 | spec parameter + app |
| 24 | rescued_by_topup_exemption | 2 | 2 | outcome |
| 25 | depositor_cap_split | 1 | 1 | governance |
| 26 | topup_refused_pool_share | 1 | 1 | contracts/spec |
| 27 | exit_needs_external_funds | 1 | 1 | contracts |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| added liquidity sitting uncredited in pledged NFTs (USD) | $8,868 | 6 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 46 |
| uncollected fees in the vault (claimable at any time) | $19,658 | 449 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age | Blocked by a market breaker |
|---|---|---|---|---|
| USDC/USDT | 96.6% | 0.0% | 0.1% | 3.3% |
| GHO/USDC | 97.8% | 0.1% | 0.0% | 2.1% |
| DAI/USDC | 98.5% | 1.0% | 0.4% | 0.1% |
| USDe/USDT | 63.3% | 33.4% | 0.0% | 3.3% |
| USDC debt price | 100.0% | 0.0% | 0.0% | 0.0% |

### Invariants

501751 checks over 23 kinds; violations: {'rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026)': 3}

| Invariant | Checks |
|---|---|
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1099 |
| address freeze gates match EMG-070 | 9 |
| backing: supply <= credited + pending, equal with a conforming LPVaultSwap (Q-257) | 364 |
| credited == sum of records | 364 |
| custody iff open record | 68380 |
| debt conservation per account | 115952 |
| fee conservation per NFT | 106898 |
| liquidation GHO conservation | 87 |
| market regular counter <= cap | 364 |
| probe: state gates match the 3.6 emergency matrix | 189 |
| re-credit: record credited == live liquidity | 23 |
| record live liquidity >= credited | 68380 |
| record live liquidity >= credited after removal | 141 |
| repay with collateral: conversion covers the flash loan (SPEC-LIQ-020) | 18 |
| repay-all leaves no allowance (refund of the unused pull, REP-009) | 393 |
| rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026) | 15 |
| rescue units <= credited per record | 69426 |
| rescue-excluded HF >= 1.10 after every borrow (REQ-RISK-068) | 591 |
| rescue-excluded HF >= 1.10 after partial removal with debt | 45 |
| routed liquidation meets the recovery floor (R + shortfall >= minGho) | 87 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 68380 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $0, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $42,152 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $3,862,111, DAI/USDC $3,726,709, USDe/USDT $1,633,621 |
| third-party repay service | {'repaid': 11, 'repaid_in_None': 11, 'usd': 173932.92395555275} |

### Rule probes vs the 3.6 emergency matrix (observed / expected)

| State (market, day) | new | topup | rescue | borrow | repay | collect | wd_free | wd_debt | remove_debt | rwc | repay_all_wd | liq |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Live (USDC/USDT, 5.00) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Market breaker tripped (GHO/USDC, 9.00) | N (PoolShareExceeded) | N (PoolShareExceeded) | Y | N (BreakerTripped(POOL_SHARE)) | Y | Y | Y | N (BreakerTripped(POOL_SHARE)) | N (BreakerTripped(POOL_SHARE)) | Y | Y | Y |
| Live (USDC/USDT, 18.53) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Live (USDC/USDT, 18.75) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Live (USDC/USDT, 19.20) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Live (USDC/USDT, 19.61) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Alternate past borrowPriceMaxAge (seizure as Cached) (DAI/USDC, 52.05) | Y | Y | Y | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | N (PriceTooOld) | N (StalePrice(alt_past_borrow_age)) | Y | N (StalePrice(alt_past_borrow_age)) |
| Cached (DAI/USDC, 52.44) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | N (StalePrice(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Expired (DAI/USDC, 52.49) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | N (StalePrice(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Grace after recovery, manual breaker still tripped (DAI/USDC, 53.25) | N (PoolShareExceeded) | N (PoolShareExceeded) | Y | N (BreakerTripped(POOL_SHARE,MANUAL)) | Y | Y | Y | N (BreakerTripped(POOL_SHARE,MANUAL)) | N (BreakerTripped(POOL_SHARE,MANUAL)) | Y | Y | N (GraceHealthFactor) |
| Drifting (feed disagreement) (USDe/USDT, 60.21) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_pause)) | Y | N (StalePrice(disagree_pause)) |
| Disagreement beyond disagreementPauseMax (USDe/USDT, 60.25) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_expired)) | Y | N (StalePrice(disagree_expired)) |
| Market breaker tripped (USDe/USDT, 66.00) | N (PoolShareExceeded) | N (PoolShareExceeded) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | N (PriceNotLive(Drifting:band)) | Y | Y | Y |
| Application Frozen (USDC/USDT, 75.10) | N (ApplicationFrozen) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | N (ApplicationFrozen) | Y | Y | Y | Y | Y | Y | Y | Y |
| Application Paused (General) (USDC/USDT, 76.00) | N (NotRescueTopUp) | N (NotRescueTopUp) | Y | N (ApplicationPaused) | Y | Y | Y | N (ApplicationPaused) | N (ApplicationPaused) | N (ApplicationPaused) | Y | Y |
| Live (USDC/USDT, 85.06) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Live (USDC/USDT, 85.10) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |

### Final-spec features

| Measure | Value |
|---|---|
| standby switches (day, token, slot, call) | 85.04 USDC primary useStandbyRoute; 18.57 USDT primary useStandbyRoute; 24.60 USDT primary restorePriceRoute; 52.07 DAI DAI/USDC tripMarketBreaker; 53.29 DAI DAI/USDC resetMarketBreaker |
| tokens listable (every primary leg heartbeat <= 3,600 s) | USDC True, USDT True, DAI True, GHO True, USDe True |
| GHO/USDC Drifting(USD band) during the GHO premium | 0.0 h |
| USDT stall: minutes a USDT market was seizable on a leg older than borrowPriceMaxAge | 0 |
| USDC primary stall: USDC debt borrow gate / repayment gate closed | 38 / 38 min |
| USDC/USDT oracle minutes | drifting_band_min 0, drifting_twap_min 0, disagree_min 61, cached_min 0, expired_min 0, alt_past_borrow_age_min 76 |
| GHO/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 130, disagree_min 0, cached_min 0, expired_min 0, alt_past_borrow_age_min 38 |
| DAI/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 71, disagree_min 0, cached_min 60, expired_min 1119, alt_past_borrow_age_min 591 |
| USDe/USDT oracle minutes | drifting_band_min 43073, drifting_twap_min 679, disagree_min 135, cached_min 0, expired_min 0, alt_past_borrow_age_min 38 |
| latched breakers (day, market, reason) | none |
| borrowing blocked by a market breaker (hours, from 10-minute samples) | DAI/USDC POOL_SHARE 1.5; DAI/USDC POOL_SHARE,MANUAL 1.0; GHO/USDC POOL_SHARE 44.7; GHO/USDC during gho_premium 44.7; USDC/USDT POOL_SHARE 71.8; USDC/USDT during usdt_depeg 71.8; USDe/USDT POOL_SHARE 71.7; USDe/USDT during usdt_depeg 71.7 |
| caller shortfall top-ups: calls / GHO | 22 / $323 |
| shortfall reports / automatic in-kind openings | 0 / none |
| Avana fee (oracle value) | $595 |
| rescue: attacker_borrowed_after_first_slice | 0.0 |
| rescue: attacker_slice_used | 42151.570565679496 |
| rescue: borrowed_after_slice_all | 0 |
| rescue: rescue_excluded_borrow_refusals | 1030 |
| rescue: rescue_excluded_refusals_attacker | 1030 |
| rescue: rescue_units_booked | 22207.99961363882 |
| rescue: stats | {'refused:PriceNotAccepted': 109, 'sized_to_restore': 2, 'sized_to_restore_below_accepted': 2, 'planned:pool_share+breaker': 2, 'rescue_topups_done': 2, 'rescue_topups_done:pool_share': 2, 'rescue_topups_done:breaker': 2} |
| deleverage | conversion_loss_usd 69.0, done 18, refused:ApplicationPaused 6, refused:MinOutNotMet 73, refused:StalePrice 148, repaid_usd 169041.23 |
| recredit | done 23, liquidity_added 33, refused:CapExceeded 10, refused:NotRescueTopUp 2, refused:PoolShareExceeded 6, refused:SliceNotAvailable 24, reverted:DeadlineExpired 1, units 61223.06 |
| removal | done 141, reverted:DeadlineExpired 1 |
| exits | repay_all_first_attempt 102 |
| address freeze gates (EMG-070) | new account from a frozen wallet: N (AddressIsFrozen); non-rescue top-up: N (NotRescueTopUp); rescue top-up: Y; non-rescue top-up (probe account): N (NotRescueTopUp); borrow: N (AddressIsFrozen); repay: Y; partial removal with debt: N (AddressIsFrozen); repay with collateral: N (AddressIsFrozen); liquidation of its positions (gate): Y |

### Governance and attacks

- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused(General)
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 40 opened; gas paid $3145
- day 3.50: **address freeze of the dust wallets** (40 freezeAddress calls by two guardians): 40 frozen; a 21st freeze by the same guardian within 24 h refused: FreezeRateLimited
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 10.00: **cap squatting** (filler wallet w985f1 pledges $671484): regular room of USDC/USDT now $0
- day 10.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 12.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.40: **cap squatting** (filler wallet w985f2 pledges $1245): regular room of USDC/USDT now $0
- day 12.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.13: **cap squatting** (filler wallet w985f3 pledges $412): regular room of USDC/USDT now $0
- day 14.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.79: **cap squatting** (filler wallet w985f4 pledges $9616): regular room of USDC/USDT now $0
- day 17.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.83: **cap squatting** (filler wallet w985f5 pledges $1509): regular room of USDC/USDT now $0
- day 18.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.32: **cap squatting** (filler wallet w985f6 pledges $1846): regular room of USDC/USDT now $0
- day 19.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.54: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 20.70: **cap squatting** (filler wallet w985f7 pledges $3770): regular room of USDC/USDT now $0
- day 20.79: **cap squatting** (filler wallet w985f8 pledges $4927): regular room of USDC/USDT now $0
- day 22.16: **cap squatting** (filler wallet w985f9 pledges $6912): regular room of USDC/USDT now $0
- day 22.70: **cap squatting** (filler wallet w985f10 pledges $10512): regular room of USDC/USDT now $0
- day 23.91: **cap squatting** (filler wallet w985f11 pledges $3533): regular room of USDC/USDT now $0
- day 25.00: **cap squatting** (filler wallet w985f12 pledges $2245): regular room of USDC/USDT now $0
- day 29.08: **cap squatting** (filler wallet w985f13 pledges $579): regular room of USDC/USDT now $0
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 33.20: **cap squatting** (filler wallet w985f69 pledges $24069): regular room of USDC/USDT now $0
- day 33.54: **cap squatting** (filler wallet w985f70 pledges $7226): regular room of USDC/USDT now $0
- day 34.25: **cap squatting** (filler wallet w985f71 pledges $9963): regular room of USDC/USDT now $0
- day 34.50: **cap squatting** (filler wallet w985f72 pledges $14731): regular room of USDC/USDT now $0
- day 34.66: **cap squatting** (filler wallet w985f73 pledges $15280): regular room of USDC/USDT now $0
- day 34.75: **cap squatting** (filler wallet w985f74 pledges $6966): regular room of USDC/USDT now $0
- day 34.95: **cap squatting** (filler wallet w985f75 pledges $7359): regular room of USDC/USDT now $0
- day 35.00: **cap squatting** (filler wallet w985f76 pledges $2433): regular room of USDC/USDT now $0
- day 35.25: **cap squatting** (filler wallet w985f77 pledges $2463): regular room of USDC/USDT now $0
- day 35.70: **cap squatting** (filler wallet w985f78 pledges $5378): regular room of USDC/USDT now $0
- day 36.79: **cap squatting** (filler wallet w985f79 pledges $405): regular room of USDC/USDT now $0
- day 38.04: **cap squatting** (filler wallet w985f80 pledges $753): regular room of USDC/USDT now $0
- day 38.20: **cap squatting** (filler wallet w985f81 pledges $10474): regular room of USDC/USDT now $0
- day 39.12: **cap squatting** (filler wallet w985f82 pledges $4836): regular room of USDC/USDT now $0
- day 39.91: **cap squatting** (filler wallet w985f83 pledges $3514): regular room of USDC/USDT now $0
- day 39.95: **cap squatting** (filler wallet w985f84 pledges $43863): regular room of USDC/USDT now $0
- day 40.70: **cap squatting** (filler wallet w985f85 pledges $2778): regular room of USDC/USDT now $0
- day 40.79: **cap squatting** (filler wallet w985f86 pledges $12549): regular room of USDC/USDT now $0
- day 43.33: **cap squatting** (filler wallet w985f87 pledges $7096): regular room of USDC/USDT now $0
- day 43.79: **cap squatting** (filler wallet w985f88 pledges $6409): regular room of USDC/USDT now $0
- day 44.29: **cap squatting** (filler wallet w985f89 pledges $8737): regular room of USDC/USDT now $0
- day 44.66: **cap squatting** (filler wallet w985f90 pledges $2643): regular room of USDC/USDT now $0
- day 45.54: **cap squatting** (filler wallet w985f91 pledges $3549): regular room of USDC/USDT now $0
- day 45.95: **cap squatting** (filler wallet w985f92 pledges $47136): regular room of USDC/USDT now $0
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $695498
- day 49.25: **cap squatting** (filler wallet w985f93 pledges $5578): regular room of USDC/USDT now $0
- day 49.45: **cap squatting** (filler wallet w985f94 pledges $1654): regular room of USDC/USDT now $0
- day 50.04: **cap squatting** (filler wallet w985f95 pledges $86): regular room of USDC/USDT now $0
- day 50.08: **cap squatting** (filler wallet w985f96 pledges $4043): regular room of USDC/USDT now $0
- day 50.12: **cap squatting** (filler wallet w985f97 pledges $1945): regular room of USDC/USDT now $0
- day 50.50: **cap squatting** (filler wallet w985f98 pledges $21418): regular room of USDC/USDT now $0
- day 50.58: **cap squatting** (filler wallet w985f99 pledges $17170): regular room of USDC/USDT now $0
- day 50.66: **cap squatting** (filler wallet w985f100 pledges $284): regular room of USDC/USDT now $0
- day 51.33: **cap squatting** (filler wallet w985f101 pledges $25249): regular room of USDC/USDT now $0
- day 51.37: **cap squatting** (filler wallet w985f102 pledges $712): regular room of USDC/USDT now $0
- day 52.20: **cap squatting** (filler wallet w985f103 pledges $975): regular room of USDC/USDT now $0
- day 52.29: **cap squatting** (filler wallet w985f104 pledges $381170): regular room of USDC/USDT now $0
- day 52.50: **cap squatting** (filler wallet w985f105 pledges $23109): regular room of USDC/USDT now $0
- day 52.75: **cap squatting** (filler wallet w985f106 pledges $2800): regular room of USDC/USDT now $0
- day 53.00: **cap squatting** (filler wallet w985f107 pledges $5875): regular room of USDC/USDT now $0
- day 53.25: **cap squatting** (filler wallet w985f108 pledges $2351): regular room of USDC/USDT now $0
- day 54.00: **cap squatting** (filler wallet w985f109 pledges $1850): regular room of USDC/USDT now $0
- day 54.12: **cap squatting** (filler wallet w985f110 pledges $12258): regular room of USDC/USDT now $0
- day 54.37: **cap squatting** (filler wallet w985f111 pledges $24747): regular room of USDC/USDT now $0
- day 54.62: **cap squatting** (filler wallet w985f112 pledges $10112): regular room of USDC/USDT now $0
- day 55.45: **cap squatting** (filler wallet w985f113 pledges $11911): regular room of USDC/USDT now $0
- day 55.58: **cap squatting** (filler wallet w985f114 pledges $3449): regular room of USDC/USDT now $0
- day 56.33: **cap squatting** (filler wallet w985f115 pledges $3067): regular room of USDC/USDT now $0
- day 56.41: **cap squatting** (filler wallet w985f116 pledges $4967): regular room of USDC/USDT now $0
- day 57.08: **cap squatting** (filler wallet w985f117 pledges $17373): regular room of USDC/USDT now $0
- day 58.16: **cap squatting** (filler wallet w985f118 pledges $11627): regular room of USDC/USDT now $0
- day 58.29: **cap squatting** (filler wallet w985f119 pledges $14697): regular room of USDC/USDT now $0
- day 60.29: **cap squatting** (filler wallet w985f120 pledges $11493): regular room of USDC/USDT now $0
- day 60.50: **cap squatting** (filler wallet w985f121 pledges $12609): regular room of USDC/USDT now $0
- day 60.79: **cap squatting** (filler wallet w985f122 pledges $2008): regular room of USDC/USDT now $0
- day 61.16: **cap squatting** (filler wallet w985f123 pledges $18975): regular room of USDC/USDT now $0
- day 61.29: **cap squatting** (filler wallet w985f124 pledges $1731): regular room of USDC/USDT now $0
- day 61.50: **cap squatting** (filler wallet w985f125 pledges $1361): regular room of USDC/USDT now $0
- day 61.58: **cap squatting** (filler wallet w985f126 pledges $2151): regular room of USDC/USDT now $0
- day 61.87: **cap squatting** (filler wallet w985f127 pledges $14740): regular room of USDC/USDT now $0
- day 62.12: **cap squatting** (filler wallet w985f128 pledges $1661): regular room of USDC/USDT now $0
- day 63.08: **cap squatting** (filler wallet w985f129 pledges $3254): regular room of USDC/USDT now $0
- day 63.58: **cap squatting** (filler wallet w985f130 pledges $17489): regular room of USDC/USDT now $0
- day 63.83: **cap squatting** (filler wallet w985f131 pledges $15440): regular room of USDC/USDT now $0
- day 63.87: **cap squatting** (filler wallet w985f132 pledges $5571): regular room of USDC/USDT now $0
- day 63.95: **cap squatting** (filler wallet w985f133 pledges $7244): regular room of USDC/USDT now $0
- day 64.12: **cap squatting** (filler wallet w985f134 pledges $10696): regular room of USDC/USDT now $0
- day 64.37: **cap squatting** (filler wallet w985f135 pledges $4300): regular room of USDC/USDT now $0
- day 65.08: **cap squatting** (filler wallet w985f136 pledges $38363): regular room of USDC/USDT now $0
- day 65.16: **cap squatting** (filler wallet w985f137 pledges $10206): regular room of USDC/USDT now $0
- day 65.41: **cap squatting** (filler wallet w985f138 pledges $8287): regular room of USDC/USDT now $0
- day 65.54: **cap squatting** (filler wallet w985f139 pledges $2414): regular room of USDC/USDT now $0
- day 65.66: **cap squatting** (filler wallet w985f140 pledges $3706): regular room of USDC/USDT now $0
- day 65.91: **cap squatting** (filler wallet w985f141 pledges $1339): regular room of USDC/USDT now $0
- day 67.16: **cap squatting** (filler wallet w985f142 pledges $24440): regular room of USDC/USDT now $0
- day 68.08: **cap squatting** (filler wallet w985f143 pledges $264): regular room of USDC/USDT now $0
- day 68.50: **cap squatting** (filler wallet w985f144 pledges $2147): regular room of USDC/USDT now $0
- day 69.66: **cap squatting** (filler wallet w985f145 pledges $6278): regular room of USDC/USDT now $0
- day 70.75: **cap squatting** (filler wallet w985f146 pledges $256): regular room of USDC/USDT now $0
- day 71.54: **cap squatting** (filler wallet w985f147 pledges $2670): regular room of USDC/USDT now $0
- day 72.12: **cap squatting** (filler wallet w985f148 pledges $1992): regular room of USDC/USDT now $0
- day 72.91: **cap squatting** (filler wallet w985f149 pledges $144): regular room of USDC/USDT now $0
- day 73.25: **cap squatting** (filler wallet w985f150 pledges $199): regular room of USDC/USDT now $0
- day 77.29: **cap squatting** (filler wallet w985f189 pledges $2485): regular room of USDC/USDT now $0
- day 77.58: **cap squatting** (filler wallet w985f190 pledges $1503): regular room of USDC/USDT now $0
- day 78.54: **cap squatting** (filler wallet w985f191 pledges $20503): regular room of USDC/USDT now $0
- day 78.62: **cap squatting** (filler wallet w985f192 pledges $7054): regular room of USDC/USDT now $0
- day 80.37: **cap squatting** (filler wallet w985f193 pledges $84060): regular room of USDC/USDT now $0
- day 81.37: **cap squatting** (filler wallet w985f194 pledges $2224): regular room of USDC/USDT now $0
- day 81.66: **cap squatting** (filler wallet w985f195 pledges $3964): regular room of USDC/USDT now $0
- day 81.87: **cap squatting** (filler wallet w985f196 pledges $139): regular room of USDC/USDT now $0
- day 83.29: **cap squatting** (filler wallet w985f197 pledges $79): regular room of USDC/USDT now $0
- day 84.83: **cap squatting** (filler wallet w985f198 pledges $5739): regular room of USDC/USDT now $0
- day 85.04: **cap squatting** (filler wallet w985f199 pledges $711): regular room of USDC/USDT now $0
- day 85.08: **cap squatting** (filler wallet w985f200 pledges $288): regular room of USDC/USDT now $0
- day 88.25: **cap squatting** (filler wallet w985f201 pledges $4401): regular room of USDC/USDT now $0
- day 88.66: **cap squatting** (filler wallet w985f202 pledges $2360): regular room of USDC/USDT now $0
- day 89.29: **cap squatting** (filler wallet w985f203 pledges $1295): regular room of USDC/USDT now $0
