### Personas (seed 20261113, feed profile `spec`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 147 | 123 | 78 | 0 | $7,763 | $32 | $1 | $79 | $0 | 0.98% | 78% | 45 / 45 / 0 |
| active_lp | 120 | 52 | 69 | 28 | 0 | $14,359 | $65 | $5 | $284 | $0 | 1.85% | 92% | 18 / 18 / 0 |
| leveraged | 100 | 57 | 43 | 57 | 11 | $13,805 | $131 | $48 | $407 | $213 | 2.92% | 93% | 31 / 31 / 0 |
| small | 120 | 42 | 78 | 27 | 0 | $159 | $1 | $0 | $83 | $0 | 51.89% | 100% | 8 / 8 / 0 |
| whale | 20 | 16 | 3 | 13 | 0 | $555,750 | $3,437 | $1,132 | $247 | $0 | 0.04% | 0% | 2 / 3 / 0 |
| multi_market | 85 | 57 | 24 | 54 | 18 | $15,568 | $53 | $25 | $151 | $1,415 | 1.14% | 77% | 13 / 12 / 0 |
| mobile | 110 | 69 | 41 | 47 | 2 | $3,352 | $14 | $5 | $95 | $15 | 2.17% | 91% | 20 / 20 / 0 |
| forgetful | 90 | 49 | 41 | 44 | 5 | $4,808 | $25 | $13 | $71 | $44 | 1.84% | 80% | 0 / 0 / 0 |
| usdc_borrower | 70 | 45 | 25 | 45 | 0 | $17,142 | $87 | $37 | $128 | $0 | 0.94% | 69% | 19 / 19 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 81 |
| accounts | 76 |
| bonus_paid | $1,689 |
| debt_repaid | $41,834 |
| deficit | $0 |
| budget_draws | $0 |
| keeper_reimbursement | $48,297 |
| keeper_pnl | $-48,003 |
| searcher_profit | $38 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $31,050 |
| max_gas_usd | $904 |
| dust calls (repay < $100) | 40 |
| calls on the dust attacker's accounts / on other accounts | 40 / 41 |
| other accounts: calls repaying under $100 / gas / debt repaid / reimbursed / most calls on one account | 0 / $17,933 / $41,736 / $17,247 / 3 |
| liquidations seizing a fresh market while another market of the account was Cached, Expired or disagreeing (Q-247) | 17 |
| by episode | USDe crash 61, GHO/USDC drain 17, pause + USDe aftershock 3 |
| by caller/mode | keeper/gho 78, permissionless/gho 3 |
| by debt asset | GHO 73, USDC 8 |
| by market | USDC/USDT 9, GHO/USDC 2, USDe/USDT 70 |
| liquidation blocked (account-hours by reason) | StalePrice(Cached/Expired) 1895.2 h (83 accounts), StalePrice(disagree_pause) 0.2 h (1 accounts), StalePrice(disagree_expired) 0.2 h (1 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| pledge | `DeadlineExpired` | 13 | 12 | $274 |
| pledge | `Dropped(not mined)` | 6 | 6 | $0 |
| repay | `DeadlineExpired` | 5 | 5 | $31 |
| borrow | `DeadlineExpired` | 4 | 4 | $46 |
| collectFees | `DeadlineExpired` | 4 | 4 | $12 |
| borrow | `BadNonce` | 3 | 3 | $18 |
| collectFees | `Dropped(not mined)` | 3 | 3 | $0 |
| repayAllAndWithdraw | `DeadlineExpired` | 3 | 3 | $106 |
| borrow | `Dropped(not mined)` | 2 | 2 | $0 |
| withdraw | `DeadlineExpired` | 2 | 2 | $26 |
| repay | `Dropped(not mined)` | 2 | 2 | $0 |
| pledge | `CapExceeded(market)` | 1 | 1 | $17 |
| removeLiquidity | `DeadlineExpired` | 1 | 1 | $6 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| borrow | `PriceNotLive(Drifting:band)` | 2313 | 17 |
| pledge | `CapExceeded(market)` | 1336 | 350 |
| pledge | `NotFullRange` | 401 | 386 |
| repayWithCollateral | `StalePrice(Cached/Expired)` | 213 | 11 |
| repayWithCollateral | `MinOutNotMet` | 145 | 6 |
| top-up | `PriceNotAccepted(Cached/Expired)` | 143 | 14 |
| pledge | `SliceNotAvailable` | 85 | 22 |
| borrow | `ApplicationPaused` | 55 | 16 |
| recredit | `SliceNotAvailable` | 34 | 9 |
| removeLiquidity(rebalance) | `HealthFactorTooLow` | 24 | 13 |
| recredit | `CapExceeded(market)` | 24 | 6 |
| pledge | `PoolShareExceeded` | 23 | 16 |
| recredit | `PoolShareExceeded` | 22 | 6 |
| repayWithCollateral | `ApplicationPaused` | 18 | 1 |
| borrow | `PriceNotLive(Cached/Expired)` | 15 | 8 |
| borrow | `ApplicationFrozen` | 14 | 14 |
| borrow | `BreakerTripped(POOL_SHARE,MANUAL)` | 8 | 8 |
| pledge | `CapExceeded(depositor)` | 6 | 6 |
| top-up | `SliceNotAvailable` | 6 | 5 |
| borrow | `BreakerTripped(POOL_SHARE)` | 5 | 5 |
| borrow | `PriceNotLive(Drifting:mixed)` | 4 | 1 |
| pledge | `BelowMinPledge` | 3 | 3 |
| removeLiquidity(rebalance) | `BreakerTripped(POOL_SHARE)` | 3 | 3 |
| pledge(loop) | `SliceNotAvailable` | 3 | 3 |
| removeLiquidity(rebalance) | `PriceNotLive(Drifting:band)` | 3 | 3 |
| pledge | `NotRescueTopUp` | 3 | 3 |
| top-up | `PoolShareExceeded` | 2 | 1 |
| recredit | `NotRescueTopUp` | 2 | 2 |
| removeLiquidity(rebalance) | `ApplicationPaused` | 2 | 2 |
| pledge | `PriceNotAccepted(Drifting)` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | concentrated_rejected | 386 | 401 | app (now), contracts (later) |
| 2 | cap_full | 373 | 1425 | app + governance |
| 3 | low_ltv | 245 | 245 | app + risk |
| 4 | fees_manual | 99 | 183 | app (contracts optional) |
| 5 | gas_exceeds_value | 89 | 89 | app + parameter |
| 6 | used_partial_removal | 43 | 109 | outcome |
| 7 | liquidated | 37 | 81 | app |
| 8 | no_alerts | 30 | 71 | app/services |
| 9 | borrow_blocked_price | 25 | 2332 | spec parameter + app |
| 10 | deadline_expired | 24 | 32 | app |
| 11 | used_repay_with_collateral | 21 | 25 | outcome |
| 12 | recredit_refused | 20 | 83 | app |
| 13 | exit_via_repay_with_collateral | 20 | 20 | outcome |
| 14 | deleverage_refused | 18 | 376 | app |
| 15 | partial_removal_refused | 18 | 33 | app |
| 16 | topup_refused_stale | 14 | 143 | app |
| 17 | tx_dropped | 13 | 13 | app |
| 18 | borrow_blocked_breaker | 11 | 13 | app |
| 19 | borrow_blocked_other_market | 8 | 15 | contracts + app |
| 20 | depositor_cap_split | 6 | 6 | governance |
| 21 | rescued_by_topup_exemption | 5 | 15 | outcome |
| 22 | topup_refused_slice | 5 | 6 | spec parameter + app |
| 23 | bad_nonce | 3 | 3 | app |
| 24 | below_min | 3 | 3 | app |
| 25 | topup_refused_pool_share | 1 | 2 | contracts/spec |
| 26 | liquidated_unable_to_act | 1 | 1 | contracts/spec + app |
| 27 | exit_needs_external_funds | 1 | 1 | contracts |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| added liquidity sitting uncredited in pledged NFTs (USD) | $47,179 | 10 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 41 |
| uncollected fees in the vault (claimable at any time) | $17,329 | 379 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age | Blocked by a market breaker |
|---|---|---|---|---|
| USDC/USDT | 96.5% | 0.0% | 0.1% | 3.4% |
| GHO/USDC | 97.8% | 0.1% | 0.0% | 2.1% |
| DAI/USDC | 98.5% | 1.2% | 0.2% | 0.2% |
| USDe/USDT | 63.3% | 33.4% | 0.0% | 3.3% |
| USDC debt price | 100.0% | 0.0% | 0.0% | 0.0% |

### Invariants

449478 checks over 23 kinds; violations: {'rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026)': 3}

| Invariant | Checks |
|---|---|
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 964 |
| address freeze gates match EMG-070 | 9 |
| backing: supply <= credited + pending, equal with a conforming LPVaultSwap (Q-257) | 364 |
| credited == sum of records | 364 |
| custody iff open record | 60658 |
| debt conservation per account | 103168 |
| fee conservation per NFT | 98665 |
| liquidation GHO conservation | 81 |
| market regular counter <= cap | 364 |
| probe: state gates match the 3.6 emergency matrix | 189 |
| re-credit: record credited == live liquidity | 18 |
| record live liquidity >= credited | 60658 |
| record live liquidity >= credited after removal | 109 |
| repay with collateral: conversion covers the flash loan (SPEC-LIQ-020) | 25 |
| repay-all leaves no allowance (refund of the unused pull, REP-009) | 410 |
| rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026) | 15 |
| rescue units <= credited per record | 61566 |
| rescue-excluded HF >= 1.10 after every borrow (REQ-RISK-068) | 526 |
| rescue-excluded HF >= 1.10 after partial removal with debt | 40 |
| routed liquidation meets the recovery floor (R + shortfall >= minGho) | 81 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 60658 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $0, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $42,058 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $3,922,534, DAI/USDC $2,782,955, USDe/USDT $2,506,697 |
| third-party repay service | {'repaid': 3, 'repaid_in_None': 3, 'usd': 147486.83799244897} |

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
| Cached (DAI/USDC, 52.17) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | N (StalePrice(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Expired (DAI/USDC, 52.22) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | N (StalePrice(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Grace after recovery, manual breaker still tripped (DAI/USDC, 53.25) | N (PoolShareExceeded) | N (PoolShareExceeded) | Y | N (BreakerTripped(POOL_SHARE,MANUAL)) | Y | Y | Y | N (BreakerTripped(POOL_SHARE,MANUAL)) | N (BreakerTripped(POOL_SHARE,MANUAL)) | Y | Y | N (GraceHealthFactor) |
| Drifting (feed disagreement) (USDe/USDT, 60.21) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_pause)) | Y | N (StalePrice(disagree_pause)) |
| Disagreement beyond disagreementPauseMax (USDe/USDT, 60.25) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_expired)) | Y | N (StalePrice(disagree_expired)) |
| Market breaker tripped (USDe/USDT, 66.00) | N (PoolShareExceeded) | N (PoolShareExceeded) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | N (PriceNotLive(Drifting:band)) | Y | Y | Y |
| Application Frozen (USDC/USDT, 75.10) | N (ApplicationFrozen) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | N (ApplicationFrozen) | Y | Y | Y | Y | Y | Y | Y | Y |
| Application Paused (General) (USDC/USDT, 76.00) | N (CapExceeded(market)) | N (SliceNotAvailable) | Y | N (ApplicationPaused) | Y | Y | Y | N (ApplicationPaused) | N (ApplicationPaused) | N (ApplicationPaused) | Y | Y |
| Alternate past borrowPriceMaxAge (seizure as Cached) (USDC/USDT, 85.06) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | N (PriceTooOld) | N (StalePrice(alt_past_borrow_age)) | Y | N (StalePrice(alt_past_borrow_age)) |
| Live (USDC/USDT, 85.10) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |

### Final-spec features

| Measure | Value |
|---|---|
| standby switches (day, token, slot, call) | 85.07 USDC primary useStandbyRoute; 18.56 USDT primary useStandbyRoute; 24.60 USDT primary restorePriceRoute; 52.07 DAI DAI/USDC tripMarketBreaker; 53.29 DAI DAI/USDC resetMarketBreaker |
| tokens listable (every primary leg heartbeat <= 3,600 s) | USDC True, USDT True, DAI True, GHO True, USDe True |
| GHO/USDC Drifting(USD band) during the GHO premium | 0.0 h |
| USDT stall: minutes a USDT market was seizable on a leg older than borrowPriceMaxAge | 0 |
| USDC primary stall: USDC debt borrow gate / repayment gate closed | 38 / 38 min |
| USDC/USDT oracle minutes | drifting_band_min 0, drifting_twap_min 1, disagree_min 60, cached_min 0, expired_min 0, alt_past_borrow_age_min 66 |
| GHO/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 128, disagree_min 0, cached_min 0, expired_min 0, alt_past_borrow_age_min 38 |
| DAI/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 0, disagree_min 0, cached_min 60, expired_min 1501, alt_past_borrow_age_min 215 |
| USDe/USDT oracle minutes | drifting_band_min 43074, drifting_twap_min 709, disagree_min 129, cached_min 0, expired_min 0, alt_past_borrow_age_min 28 |
| latched breakers (day, market, reason) | none |
| borrowing blocked by a market breaker (hours, from 10-minute samples) | DAI/USDC POOL_SHARE 2.5; DAI/USDC POOL_SHARE,MANUAL 1.0; GHO/USDC POOL_SHARE 44.8; GHO/USDC during gho_premium 44.8; USDC/USDT POOL_SHARE 73.0; USDC/USDT during usdt_depeg 73.0; USDe/USDT POOL_SHARE 72.3; USDe/USDT during usdt_depeg 72.3 |
| caller shortfall top-ups: calls / GHO | 21 / $151 |
| shortfall reports / automatic in-kind openings | 0 / none |
| Avana fee (oracle value) | $335 |
| rescue: attacker_borrowed_after_first_slice | 0.0 |
| rescue: attacker_slice_used | 42058.26580764843 |
| rescue: borrowed_after_slice_all | 0 |
| rescue: rescue_excluded_borrow_refusals | 1555 |
| rescue: rescue_excluded_refusals_attacker | 1555 |
| rescue: rescue_units_booked | 32055.178052994317 |
| rescue: stats | {'refused:PriceNotAccepted': 143, 'restore_below_rescue_minimum': 1, 'refused:SliceNotAvailable': 1, 'sized_to_restore': 14, 'sized_to_restore_below_accepted': 14, 'planned:pool_share+breaker': 15, 'rescue_topups_done': 15, 'rescue_topups_done:pool_share': 15, 'rescue_topups_done:breaker': 15} |
| deleverage | conversion_loss_usd 73.96, done 25, refused:ApplicationPaused 18, refused:MinOutNotMet 145, refused:StalePrice 213, repaid_usd 143377.81 |
| recredit | done 18, liquidity_added 37, refused:ApplicationFrozen 1, refused:CapExceeded 24, refused:NotRescueTopUp 2, refused:PoolShareExceeded 22, refused:SliceNotAvailable 34, units 67557.93 |
| removal | done 109, reverted:DeadlineExpired 1 |
| exits | repay_all_first_attempt 97 |
| address freeze gates (EMG-070) | new account from a frozen wallet: N (AddressIsFrozen); non-rescue top-up: N (NotRescueTopUp); rescue top-up: Y; non-rescue top-up (probe account): N (NotRescueTopUp); borrow: N (AddressIsFrozen); repay: Y; partial removal with debt: N (AddressIsFrozen); repay with collateral: N (AddressIsFrozen); liquidation of its positions (gate): Y |

### Governance and attacks

- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused(General)
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 40 opened; gas paid $2946
- day 3.50: **address freeze of the dust wallets** (40 freezeAddress calls by two guardians): 40 frozen; a 21st freeze by the same guardian within 24 h refused: FreezeRateLimited
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 12.63: **cap squatting** (filler wallet w985f1 pledges $990000): regular room of USDC/USDT now $500329
- day 12.67: **cap squatting** (filler wallet w985f2 pledges $500329): regular room of USDC/USDT now $0
- day 12.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.01: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.94: **cap squatting** (filler wallet w985f3 pledges $8738): regular room of USDC/USDT now $0
- day 18.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 21.19: **cap squatting** (filler wallet w985f4 pledges $14183): regular room of USDC/USDT now $0
- day 21.48: **cap squatting** (filler wallet w985f5 pledges $1056): regular room of USDC/USDT now $0
- day 24.86: **cap squatting** (filler wallet w985f6 pledges $10676): regular room of USDC/USDT now $0
- day 25.23: **cap squatting** (filler wallet w985f7 pledges $1190): regular room of USDC/USDT now $0
- day 26.73: **cap squatting** (filler wallet w985f8 pledges $1417): regular room of USDC/USDT now $0
- day 27.44: **cap squatting** (filler wallet w985f9 pledges $1208): regular room of USDC/USDT now $0
- day 28.48: **cap squatting** (filler wallet w985f10 pledges $2938): regular room of USDC/USDT now $0
- day 30.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 37.04: **cap squatting** (filler wallet w985f11 pledges $4826): regular room of USDC/USDT now $0
- day 37.08: **cap squatting** (filler wallet w985f12 pledges $2120): regular room of USDC/USDT now $0
- day 37.54: **cap squatting** (filler wallet w985f13 pledges $2083): regular room of USDC/USDT now $0
- day 37.83: **cap squatting** (filler wallet w985f14 pledges $7473): regular room of USDC/USDT now $0
- day 38.67: **cap squatting** (filler wallet w985f15 pledges $17767): regular room of USDC/USDT now $0
- day 39.79: **cap squatting** (filler wallet w985f16 pledges $20956): regular room of USDC/USDT now $0
- day 40.21: **cap squatting** (filler wallet w985f17 pledges $3421): regular room of USDC/USDT now $0
- day 40.92: **cap squatting** (filler wallet w985f18 pledges $3741): regular room of USDC/USDT now $0
- day 41.17: **cap squatting** (filler wallet w985f19 pledges $7983): regular room of USDC/USDT now $0
- day 41.33: **cap squatting** (filler wallet w985f20 pledges $271): regular room of USDC/USDT now $0
- day 41.75: **cap squatting** (filler wallet w985f21 pledges $2057): regular room of USDC/USDT now $0
- day 42.96: **cap squatting** (filler wallet w985f22 pledges $33945): regular room of USDC/USDT now $0
- day 43.54: **cap squatting** (filler wallet w985f23 pledges $10625): regular room of USDC/USDT now $0
- day 44.21: **cap squatting** (filler wallet w985f24 pledges $1183): regular room of USDC/USDT now $0
- day 45.83: **cap squatting** (filler wallet w985f25 pledges $2841): regular room of USDC/USDT now $0
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $693091
- day 47.21: **cap squatting** (filler wallet w985f26 pledges $696): regular room of USDC/USDT now $0
- day 47.46: **cap squatting** (filler wallet w985f27 pledges $1326): regular room of USDC/USDT now $0
- day 47.71: **cap squatting** (filler wallet w985f28 pledges $537): regular room of USDC/USDT now $0
- day 48.38: **cap squatting** (filler wallet w985f29 pledges $5231): regular room of USDC/USDT now $0
- day 48.92: **cap squatting** (filler wallet w985f30 pledges $3347): regular room of USDC/USDT now $0
- day 49.29: **cap squatting** (filler wallet w985f31 pledges $12002): regular room of USDC/USDT now $0
- day 50.04: **cap squatting** (filler wallet w985f32 pledges $13576): regular room of USDC/USDT now $0
- day 50.25: **cap squatting** (filler wallet w985f33 pledges $15766): regular room of USDC/USDT now $0
- day 51.00: **cap squatting** (filler wallet w985f34 pledges $722): regular room of USDC/USDT now $0
- day 52.04: **cap squatting** (filler wallet w985f35 pledges $992): regular room of USDC/USDT now $0
- day 52.21: **cap squatting** (filler wallet w985f36 pledges $11590): regular room of USDC/USDT now $0
- day 52.25: **cap squatting** (filler wallet w985f37 pledges $6070): regular room of USDC/USDT now $0
- day 52.50: **cap squatting** (filler wallet w985f38 pledges $7577): regular room of USDC/USDT now $0
- day 53.71: **cap squatting** (filler wallet w985f39 pledges $2780): regular room of USDC/USDT now $0
- day 55.04: **cap squatting** (filler wallet w985f40 pledges $11576): regular room of USDC/USDT now $0
- day 55.71: **cap squatting** (filler wallet w985f41 pledges $5095): regular room of USDC/USDT now $0
- day 57.92: **cap squatting** (filler wallet w985f42 pledges $5641): regular room of USDC/USDT now $0
- day 58.17: **cap squatting** (filler wallet w985f43 pledges $9531): regular room of USDC/USDT now $0
- day 58.29: **cap squatting** (filler wallet w985f44 pledges $5116): regular room of USDC/USDT now $0
- day 58.42: **cap squatting** (filler wallet w985f45 pledges $678): regular room of USDC/USDT now $0
- day 58.67: **cap squatting** (filler wallet w985f46 pledges $1643): regular room of USDC/USDT now $0
- day 58.75: **cap squatting** (filler wallet w985f47 pledges $1458): regular room of USDC/USDT now $0
- day 59.46: **cap squatting** (filler wallet w985f48 pledges $12451): regular room of USDC/USDT now $0
- day 59.58: **cap squatting** (filler wallet w985f49 pledges $4739): regular room of USDC/USDT now $0
- day 59.71: **cap squatting** (filler wallet w985f50 pledges $20598): regular room of USDC/USDT now $0
- day 59.96: **cap squatting** (filler wallet w985f51 pledges $8130): regular room of USDC/USDT now $0
- day 60.29: **cap squatting** (filler wallet w985f52 pledges $3662): regular room of USDC/USDT now $0
- day 60.83: **cap squatting** (filler wallet w985f53 pledges $36787): regular room of USDC/USDT now $0
- day 61.17: **cap squatting** (filler wallet w985f54 pledges $9506): regular room of USDC/USDT now $0
- day 61.42: **cap squatting** (filler wallet w985f55 pledges $139433): regular room of USDC/USDT now $0
- day 61.79: **cap squatting** (filler wallet w985f56 pledges $11543): regular room of USDC/USDT now $0
- day 61.92: **cap squatting** (filler wallet w985f57 pledges $3305): regular room of USDC/USDT now $0
- day 62.25: **cap squatting** (filler wallet w985f58 pledges $2446): regular room of USDC/USDT now $0
- day 62.79: **cap squatting** (filler wallet w985f59 pledges $17063): regular room of USDC/USDT now $0
- day 62.96: **cap squatting** (filler wallet w985f60 pledges $592): regular room of USDC/USDT now $0
- day 63.38: **cap squatting** (filler wallet w985f61 pledges $694): regular room of USDC/USDT now $0
- day 64.38: **cap squatting** (filler wallet w985f62 pledges $8663): regular room of USDC/USDT now $0
- day 66.08: **cap squatting** (filler wallet w985f63 pledges $3064): regular room of USDC/USDT now $0
- day 66.62: **cap squatting** (filler wallet w985f64 pledges $1946): regular room of USDC/USDT now $0
- day 66.67: **cap squatting** (filler wallet w985f65 pledges $49427): regular room of USDC/USDT now $0
- day 71.62: **cap squatting** (filler wallet w985f66 pledges $3317): regular room of USDC/USDT now $0
- day 71.67: **cap squatting** (filler wallet w985f67 pledges $13331): regular room of USDC/USDT now $0
- day 71.75: **cap squatting** (filler wallet w985f68 pledges $2183): regular room of USDC/USDT now $0
- day 72.17: **cap squatting** (filler wallet w985f69 pledges $61270): regular room of USDC/USDT now $0
- day 72.62: **cap squatting** (filler wallet w985f70 pledges $26667): regular room of USDC/USDT now $0
- day 72.67: **cap squatting** (filler wallet w985f71 pledges $8545): regular room of USDC/USDT now $0
- day 73.58: **cap squatting** (filler wallet w985f72 pledges $3126): regular room of USDC/USDT now $0
- day 73.88: **cap squatting** (filler wallet w985f73 pledges $3287): regular room of USDC/USDT now $0
- day 74.83: **cap squatting** (filler wallet w985f74 pledges $10524): regular room of USDC/USDT now $0
- day 74.96: **cap squatting** (filler wallet w985f75 pledges $6441): regular room of USDC/USDT now $0
- day 77.25: **cap squatting** (filler wallet w985f80 pledges $8166): regular room of USDC/USDT now $0
- day 79.46: **cap squatting** (filler wallet w985f81 pledges $1362): regular room of USDC/USDT now $0
- day 80.08: **cap squatting** (filler wallet w985f82 pledges $9621): regular room of USDC/USDT now $0
- day 80.42: **cap squatting** (filler wallet w985f83 pledges $30480): regular room of USDC/USDT now $0
- day 81.00: **cap squatting** (filler wallet w985f84 pledges $19114): regular room of USDC/USDT now $0
- day 81.58: **cap squatting** (filler wallet w985f85 pledges $3581): regular room of USDC/USDT now $0
- day 81.79: **cap squatting** (filler wallet w985f86 pledges $23198): regular room of USDC/USDT now $0
- day 83.58: **cap squatting** (filler wallet w985f87 pledges $3302): regular room of USDC/USDT now $0
- day 83.62: **cap squatting** (filler wallet w985f88 pledges $4114): regular room of USDC/USDT now $0
- day 84.00: **cap squatting** (filler wallet w985f89 pledges $12018): regular room of USDC/USDT now $0
- day 84.54: **cap squatting** (filler wallet w985f90 pledges $486): regular room of USDC/USDT now $0
- day 84.58: **cap squatting** (filler wallet w985f91 pledges $16608): regular room of USDC/USDT now $0
- day 85.17: **cap squatting** (filler wallet w985f92 pledges $11032): regular room of USDC/USDT now $0
- day 85.50: **cap squatting** (filler wallet w985f93 pledges $7940): regular room of USDC/USDT now $0
- day 85.79: **cap squatting** (filler wallet w985f94 pledges $4973): regular room of USDC/USDT now $0
