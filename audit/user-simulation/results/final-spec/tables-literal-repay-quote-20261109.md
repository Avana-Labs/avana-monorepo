### Personas (seed 20261109, feed profile `spec`, repay quote `literal`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 179 | 91 | 88 | 0 | $7,892 | $48 | $0 | $86 | $0 | 0.98% | 73% | 42 / 42 / 0 |
| active_lp | 120 | 65 | 55 | 37 | 0 | $16,253 | $61 | $10 | $291 | $0 | 1.59% | 85% | 29 / 29 / 0 |
| leveraged | 100 | 64 | 36 | 64 | 6 | $17,046 | $125 | $51 | $338 | $113 | 2.12% | 86% | 26 / 26 / 0 |
| small | 120 | 44 | 76 | 24 | 3 | $177 | $1 | $0 | $94 | $2 | 54.24% | 100% | 14 / 14 / 0 |
| whale | 20 | 18 | 1 | 15 | 0 | $479,896 | $2,395 | $870 | $255 | $0 | 0.04% | 0% | 4 / 4 / 0 |
| multi_market | 85 | 66 | 14 | 57 | 11 | $17,874 | $64 | $19 | $151 | $775 | 0.86% | 79% | 17 / 16 / 0 |
| mobile | 110 | 72 | 38 | 53 | 3 | $4,641 | $25 | $8 | $106 | $36 | 2.05% | 88% | 23 / 23 / 0 |
| forgetful | 90 | 63 | 27 | 59 | 11 | $9,637 | $44 | $29 | $68 | $138 | 0.77% | 62% | 0 / 0 / 0 |
| usdc_borrower | 70 | 42 | 28 | 42 | 2 | $13,545 | $73 | $29 | $113 | $19 | 0.89% | 74% | 19 / 19 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 86 |
| accounts | 76 |
| bonus_paid | $1,086 |
| debt_repaid | $30,492 |
| deficit | $0 |
| budget_draws | $1 |
| keeper_reimbursement | $57,109 |
| keeper_pnl | $-57,075 |
| searcher_profit | $36 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $32,975 |
| max_gas_usd | $904 |
| dust calls (repay < $100) | 43 |
| calls on the dust attacker's accounts / on other accounts | 40 / 46 |
| other accounts: calls repaying under $100 / gas / debt repaid / reimbursed / most calls on one account | 3 / $26,516 / $30,394 / $26,059 / 3 |
| liquidations seizing a fresh market while another market of the account was Cached, Expired or disagreeing (Q-247) | 11 |
| by episode | USDe crash 72, GHO/USDC drain 11, pause + USDe aftershock 3 |
| by caller/mode | keeper/gho 85, permissionless/gho 1 |
| by debt asset | GHO 73, USDC 13 |
| by market | USDC/USDT 3, USDe/USDT 78, GHO/USDC 5 |
| liquidation blocked (account-hours by reason) | StalePrice(Cached/Expired) 998.3 h (81 accounts), StalePrice(disagree_pause) 0.7 h (1 accounts), StalePrice(disagree_expired) 0.5 h (3 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| pledge | `DeadlineExpired` | 16 | 14 | $354 |
| pledge | `Dropped(not mined)` | 7 | 6 | $0 |
| borrow | `DeadlineExpired` | 6 | 5 | $52 |
| borrow | `BadNonce` | 5 | 5 | $47 |
| withdraw | `DeadlineExpired` | 4 | 4 | $30 |
| collectFees | `DeadlineExpired` | 4 | 3 | $14 |
| borrow | `Dropped(not mined)` | 2 | 2 | $0 |
| withdraw | `Dropped(not mined)` | 2 | 2 | $0 |
| pledge | `CapExceeded(market)` | 1 | 1 | $13 |
| repayAllAndWithdraw | `DeadlineExpired` | 1 | 1 | $5 |
| repay | `DeadlineExpired` | 1 | 1 | $4 |
| repay | `Dropped(not mined)` | 1 | 1 | $0 |
| removeLiquidity | `DeadlineExpired` | 1 | 1 | $9 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| pledge | `CapExceeded(market)` | 1144 | 303 |
| borrow | `PriceNotLive(Drifting:band)` | 870 | 10 |
| pledge | `NotFullRange` | 385 | 377 |
| repayWithCollateral | `StalePrice(Cached/Expired)` | 111 | 12 |
| pledge | `SliceNotAvailable` | 81 | 18 |
| top-up | `PriceNotAccepted(Cached/Expired)` | 61 | 11 |
| repayWithCollateral | `MinOutNotMet` | 59 | 5 |
| recredit | `CapExceeded(market)` | 45 | 11 |
| pledge | `PoolShareExceeded` | 39 | 39 |
| removeLiquidity(rebalance) | `HealthFactorTooLow` | 37 | 20 |
| borrow | `DrawCapExceeded` | 26 | 20 |
| recredit | `SliceNotAvailable` | 24 | 6 |
| borrow | `ApplicationPaused` | 19 | 7 |
| borrow | `BreakerTripped(POOL_SHARE)` | 10 | 6 |
| borrow | `BreakerTripped(POOL_SHARE,MANUAL)` | 7 | 6 |
| borrow | `ApplicationFrozen` | 6 | 6 |
| pledge | `NotRescueTopUp` | 6 | 3 |
| removeLiquidity(rebalance) | `PriceNotLive(Drifting:band)` | 5 | 2 |
| recredit | `PoolShareExceeded` | 5 | 1 |
| top-up | `PoolShareExceeded` | 4 | 4 |
| pledge | `CapExceeded(depositor)` | 3 | 3 |
| pledge(loop) | `SliceNotAvailable` | 3 | 3 |
| removeLiquidity(rebalance) | `ApplicationPaused` | 3 | 3 |
| top-up | `SliceNotAvailable` | 2 | 2 |
| pledge | `ApplicationFrozen` | 2 | 1 |
| repayWithCollateral | `ApplicationPaused` | 2 | 1 |
| pledge | `BelowMinPledge` | 1 | 1 |
| removeLiquidity(rebalance) | `BreakerTripped(POOL_SHARE)` | 1 | 1 |
| borrow | `PriceNotLive(Cached/Expired)` | 1 | 1 |
| repayWithCollateral | `StalePrice(disagree_pause)` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | concentrated_rejected | 377 | 385 | app (now), contracts (later) |
| 2 | cap_full | 322 | 1229 | app + governance |
| 3 | low_ltv | 298 | 298 | app + risk |
| 4 | fees_manual | 114 | 198 | app (contracts optional) |
| 5 | gas_exceeds_value | 81 | 81 | app + parameter |
| 6 | used_partial_removal | 57 | 137 | outcome |
| 7 | liquidated | 37 | 86 | app |
| 8 | deadline_expired | 25 | 33 | app |
| 9 | partial_removal_refused | 23 | 46 | app |
| 10 | no_alerts | 22 | 62 | app/services |
| 11 | used_repay_with_collateral | 21 | 23 | outcome |
| 12 | drawcap_exhausted | 20 | 26 | app + Aave governance |
| 13 | recredit_refused | 18 | 75 | app |
| 14 | exit_via_repay_with_collateral | 18 | 18 | outcome |
| 15 | deleverage_refused | 17 | 173 | app |
| 16 | borrow_blocked_price | 11 | 871 | spec parameter + app |
| 17 | topup_refused_stale | 11 | 61 | app |
| 18 | borrow_blocked_breaker | 9 | 17 | app |
| 19 | tx_dropped | 9 | 12 | app |
| 20 | bad_nonce | 5 | 5 | app |
| 21 | topup_refused_pool_share | 4 | 4 | contracts/spec |
| 22 | depositor_cap_split | 3 | 3 | governance |
| 23 | topup_refused_slice | 2 | 2 | spec parameter + app |
| 24 | borrow_blocked_other_market | 2 | 2 | contracts + app |
| 25 | exit_needs_external_funds | 2 | 2 | contracts |
| 26 | rescued_by_topup_exemption | 1 | 4 | outcome |
| 27 | below_min | 1 | 1 | app |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| added liquidity sitting uncredited in pledged NFTs (USD) | $99,618 | 11 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 57 |
| uncollected fees in the vault (claimable at any time) | $20,351 | 440 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age | Blocked by a market breaker |
|---|---|---|---|---|
| USDC/USDT | 96.6% | 0.0% | 0.1% | 3.3% |
| GHO/USDC | 97.8% | 0.1% | 0.0% | 2.1% |
| DAI/USDC | 98.5% | 1.0% | 0.4% | 0.1% |
| USDe/USDT | 63.3% | 33.4% | 0.0% | 3.3% |
| USDC debt price | 100.0% | 0.0% | 0.0% | 0.0% |

### Invariants

515219 checks over 23 kinds; violations: {'rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026)': 3}

| Invariant | Checks |
|---|---|
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1114 |
| address freeze gates match EMG-070 | 9 |
| backing: supply <= credited + pending, equal with a conforming LPVaultSwap (Q-257) | 364 |
| credited == sum of records | 364 |
| custody iff open record | 70087 |
| debt conservation per account | 119618 |
| fee conservation per NFT | 109813 |
| liquidation GHO conservation | 86 |
| market regular counter <= cap | 364 |
| probe: state gates match the 3.6 emergency matrix | 189 |
| re-credit: record credited == live liquidity | 18 |
| record live liquidity >= credited | 70087 |
| record live liquidity >= credited after removal | 137 |
| repay with collateral: conversion covers the flash loan (SPEC-LIQ-020) | 23 |
| repay-all leaves no allowance (refund of the unused pull, REP-009) | 417 |
| rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026) | 15 |
| rescue units <= credited per record | 71150 |
| rescue-excluded HF >= 1.10 after every borrow (REQ-RISK-068) | 574 |
| rescue-excluded HF >= 1.10 after partial removal with debt | 71 |
| routed liquidation meets the recovery floor (R + shortfall >= minGho) | 86 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 70087 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $0, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $42,198 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $3,339,987, DAI/USDC $3,303,489, USDe/USDT $2,686,451 |
| third-party repay service | {'repaid': 4, 'repaid_in_None': 4, 'usd': 143129.41721672908} |

### Rule probes vs the 3.6 emergency matrix (observed / expected)

| State (market, day) | new | topup | rescue | borrow | repay | collect | wd_free | wd_debt | remove_debt | rwc | repay_all_wd | liq |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Live (USDC/USDT, 5.00) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Market breaker tripped (GHO/USDC, 9.00) | N (PoolShareExceeded) | N (PoolShareExceeded) | Y | N (BreakerTripped(POOL_SHARE)) | Y | Y | Y | N (BreakerTripped(POOL_SHARE)) | N (BreakerTripped(POOL_SHARE)) | Y | Y | Y |
| Alternate past borrowPriceMaxAge (seizure as Cached) (USDC/USDT, 18.53) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | N (PriceTooOld) | N (StalePrice(alt_past_borrow_age)) | Y | N (StalePrice(alt_past_borrow_age)) |
| Live (USDC/USDT, 18.75) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Live (USDC/USDT, 19.20) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Live (USDC/USDT, 19.61) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Alternate past borrowPriceMaxAge (seizure as Cached) (DAI/USDC, 52.02) | Y | Y | Y | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | N (PriceTooOld) | N (StalePrice(alt_past_borrow_age)) | Y | N (StalePrice(alt_past_borrow_age)) |
| Cached (DAI/USDC, 52.69) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | N (StalePrice(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Expired (DAI/USDC, 52.74) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | N (StalePrice(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Grace after recovery, manual breaker still tripped (DAI/USDC, 53.25) | N (PoolShareExceeded) | N (PoolShareExceeded) | Y | N (BreakerTripped(POOL_SHARE,MANUAL)) | Y | Y | Y | N (BreakerTripped(POOL_SHARE,MANUAL)) | N (BreakerTripped(POOL_SHARE,MANUAL)) | Y | Y | N (GraceHealthFactor) |
| Drifting (feed disagreement) (USDe/USDT, 60.21) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_pause)) | Y | N (StalePrice(disagree_pause)) |
| Disagreement beyond disagreementPauseMax (USDe/USDT, 60.25) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_expired)) | Y | N (StalePrice(disagree_expired)) |
| Market breaker tripped (USDe/USDT, 66.00) | N (PoolShareExceeded) | N (PoolShareExceeded) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | N (PriceNotLive(Drifting:band)) | Y | Y | Y |
| Application Frozen (USDC/USDT, 75.10) | N (ApplicationFrozen) | Y | Y | N (ApplicationFrozen) | Y | Y | Y | Y | Y | Y | Y | Y |
| Application Paused (General) (USDC/USDT, 76.00) | N (NotRescueTopUp) | N (NotRescueTopUp) | Y | N (ApplicationPaused) | Y | Y | Y | N (ApplicationPaused) | N (ApplicationPaused) | N (ApplicationPaused) | Y | Y |
| Alternate past borrowPriceMaxAge (seizure as Cached) (USDC/USDT, 85.06) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | N (PriceTooOld) | N (StalePrice(alt_past_borrow_age)) | Y | N (StalePrice(alt_past_borrow_age)) |
| Live (USDC/USDT, 85.10) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |

### Final-spec features

| Measure | Value |
|---|---|
| standby switches (day, token, slot, call) | 85.07 USDC primary useStandbyRoute; 18.54 USDT primary useStandbyRoute; 24.60 USDT primary restorePriceRoute; 52.04 DAI DAI/USDC tripMarketBreaker; 53.29 DAI DAI/USDC resetMarketBreaker |
| tokens listable (every primary leg heartbeat <= 3,600 s) | USDC True, USDT True, DAI True, GHO True, USDe True |
| GHO/USDC Drifting(USD band) during the GHO premium | 0.0 h |
| USDT stall: minutes a USDT market was seizable on a leg older than borrowPriceMaxAge | 0 |
| USDC primary stall: USDC debt borrow gate / repayment gate closed | 38 / 38 min |
| USDC/USDT oracle minutes | drifting_band_min 0, drifting_twap_min 0, disagree_min 56, cached_min 0, expired_min 0, alt_past_borrow_age_min 76 |
| GHO/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 132, disagree_min 0, cached_min 0, expired_min 0, alt_past_borrow_age_min 38 |
| DAI/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 436, disagree_min 0, cached_min 60, expired_min 761, alt_past_borrow_age_min 1001 |
| USDe/USDT oracle minutes | drifting_band_min 43070, drifting_twap_min 705, disagree_min 129, cached_min 0, expired_min 0, alt_past_borrow_age_min 38 |
| latched breakers (day, market, reason) | none |
| borrowing blocked by a market breaker (hours, from 10-minute samples) | DAI/USDC POOL_SHARE 2.2; DAI/USDC POOL_SHARE,MANUAL 1.0; GHO/USDC POOL_SHARE 44.8; GHO/USDC during gho_premium 44.8; USDC/USDT POOL_SHARE 72.2; USDC/USDT during usdt_depeg 72.2; USDe/USDT POOL_SHARE 72.0; USDe/USDT during usdt_depeg 72.0 |
| caller shortfall top-ups: calls / GHO | 29 / $152 |
| shortfall reports / automatic in-kind openings | 0 / none |
| Avana fee (oracle value) | $214 |
| rescue: attacker_borrowed_after_first_slice | 0.0 |
| rescue: attacker_slice_used | 42197.845684647895 |
| rescue: borrowed_after_slice_all | 0 |
| rescue: rescue_excluded_borrow_refusals | 1388 |
| rescue: rescue_excluded_refusals_attacker | 1388 |
| rescue: rescue_units_booked | 21747.33384467581 |
| rescue: stats | {'restore_below_rescue_minimum': 1, 'refused:SliceNotAvailable': 1, 'refused:PriceNotAccepted': 61, 'sized_to_restore': 4, 'sized_to_restore_below_accepted': 4, 'planned:pool_share+breaker': 4, 'rescue_topups_done': 4, 'rescue_topups_done:pool_share': 4, 'rescue_topups_done:breaker': 4} |
| deleverage | conversion_loss_usd 71.41, done 23, refused:ApplicationPaused 2, refused:MinOutNotMet 59, refused:StalePrice 112, repaid_usd 130445.0 |
| recredit | done 18, liquidity_added 34, refused:CapExceeded 45, refused:NotRescueTopUp 1, refused:PoolShareExceeded 5, refused:SliceNotAvailable 24, units 58676.87 |
| removal | done 137, reverted:DeadlineExpired 1 |
| exits | repay_all_first_attempt 100 |
| address freeze gates (EMG-070) | new account from a frozen wallet: N (AddressIsFrozen); non-rescue top-up: N (NotRescueTopUp); rescue top-up: Y; non-rescue top-up (probe account): N (NotRescueTopUp); borrow: N (AddressIsFrozen); repay: Y; partial removal with debt: N (AddressIsFrozen); repay with collateral: N (AddressIsFrozen); liquidation of its positions (gate): Y |

### Governance and attacks

- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused(General)
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 40 opened; gas paid $2750
- day 3.50: **address freeze of the dust wallets** (40 freezeAddress calls by two guardians): 40 frozen; a 21st freeze by the same guardian within 24 h refused: FreezeRateLimited
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 10.00: **cap squatting** (filler wallet w985f1 pledges $639321): regular room of USDC/USDT now $0
- day 10.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.86: **cap squatting** (filler wallet w985f2 pledges $1434): regular room of USDC/USDT now $0
- day 11.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 11.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 11.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 12.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.50: **cap squatting** (filler wallet w985f3 pledges $17363): regular room of USDC/USDT now $0
- day 12.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.93: **cap squatting** (filler wallet w985f4 pledges $5336): regular room of USDC/USDT now $0
- day 12.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.77: **cap squatting** (filler wallet w985f5 pledges $2625): regular room of USDC/USDT now $0
- day 13.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.01: **cap squatting** (filler wallet w985f6 pledges $107982): regular room of USDC/USDT now $0
- day 16.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.35: **cap squatting** (filler wallet w985f7 pledges $3610): regular room of USDC/USDT now $0
- day 16.73: **cap squatting** (filler wallet w985f8 pledges $10290): regular room of USDC/USDT now $0
- day 16.77: **cap squatting** (filler wallet w985f9 pledges $2784): regular room of USDC/USDT now $0
- day 17.27: **cap squatting** (filler wallet w985f10 pledges $10306): regular room of USDC/USDT now $0
- day 17.35: **cap squatting** (filler wallet w985f11 pledges $1426): regular room of USDC/USDT now $0
- day 17.39: **cap squatting** (filler wallet w985f12 pledges $7720): regular room of USDC/USDT now $0
- day 17.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.02: **cap squatting** (filler wallet w985f13 pledges $12842): regular room of USDC/USDT now $0
- day 18.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.40: **cap squatting** (filler wallet w985f14 pledges $4427): regular room of USDC/USDT now $0
- day 18.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.99: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 20.01: **cap squatting** (filler wallet w985f15 pledges $4187): regular room of USDC/USDT now $0
- day 21.05: **cap squatting** (filler wallet w985f16 pledges $1591): regular room of USDC/USDT now $0
- day 21.35: **cap squatting** (filler wallet w985f17 pledges $6080): regular room of USDC/USDT now $0
- day 21.39: **cap squatting** (filler wallet w985f18 pledges $2754): regular room of USDC/USDT now $0
- day 21.76: **cap squatting** (filler wallet w985f19 pledges $5374): regular room of USDC/USDT now $0
- day 23.43: **cap squatting** (filler wallet w985f20 pledges $12357): regular room of USDC/USDT now $0
- day 24.18: **cap squatting** (filler wallet w985f21 pledges $7203): regular room of USDC/USDT now $0
- day 26.01: **cap squatting** (filler wallet w985f22 pledges $1973): regular room of USDC/USDT now $0
- day 26.30: **cap squatting** (filler wallet w985f23 pledges $2739): regular room of USDC/USDT now $0
- day 26.76: **cap squatting** (filler wallet w985f24 pledges $75845): regular room of USDC/USDT now $0
- day 27.68: **cap squatting** (filler wallet w985f25 pledges $5835): regular room of USDC/USDT now $0
- day 28.68: **cap squatting** (filler wallet w985f26 pledges $7214): regular room of USDC/USDT now $0
- day 30.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.21: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 33.20: **cap squatting** (filler wallet w985f70 pledges $39759): regular room of USDC/USDT now $0
- day 33.28: **cap squatting** (filler wallet w985f71 pledges $5840): regular room of USDC/USDT now $0
- day 33.37: **cap squatting** (filler wallet w985f72 pledges $173): regular room of USDC/USDT now $0
- day 33.53: **cap squatting** (filler wallet w985f73 pledges $17516): regular room of USDC/USDT now $0
- day 33.58: **cap squatting** (filler wallet w985f74 pledges $3212): regular room of USDC/USDT now $0
- day 33.62: **cap squatting** (filler wallet w985f75 pledges $9818): regular room of USDC/USDT now $0
- day 34.12: **cap squatting** (filler wallet w985f76 pledges $1803): regular room of USDC/USDT now $0
- day 34.58: **cap squatting** (filler wallet w985f77 pledges $4624): regular room of USDC/USDT now $0
- day 34.83: **cap squatting** (filler wallet w985f78 pledges $5745): regular room of USDC/USDT now $0
- day 35.08: **cap squatting** (filler wallet w985f79 pledges $3864): regular room of USDC/USDT now $0
- day 35.99: **cap squatting** (filler wallet w985f80 pledges $10250): regular room of USDC/USDT now $0
- day 36.45: **cap squatting** (filler wallet w985f81 pledges $8650): regular room of USDC/USDT now $0
- day 36.99: **cap squatting** (filler wallet w985f82 pledges $4084): regular room of USDC/USDT now $0
- day 38.03: **cap squatting** (filler wallet w985f83 pledges $1214): regular room of USDC/USDT now $0
- day 38.16: **cap squatting** (filler wallet w985f84 pledges $23443): regular room of USDC/USDT now $0
- day 38.58: **cap squatting** (filler wallet w985f85 pledges $5050): regular room of USDC/USDT now $0
- day 39.58: **cap squatting** (filler wallet w985f86 pledges $48656): regular room of USDC/USDT now $0
- day 39.62: **cap squatting** (filler wallet w985f87 pledges $13150): regular room of USDC/USDT now $0
- day 39.66: **cap squatting** (filler wallet w985f88 pledges $31288): regular room of USDC/USDT now $0
- day 39.91: **cap squatting** (filler wallet w985f89 pledges $3751): regular room of USDC/USDT now $0
- day 41.24: **cap squatting** (filler wallet w985f90 pledges $15221): regular room of USDC/USDT now $0
- day 41.45: **cap squatting** (filler wallet w985f91 pledges $37133): regular room of USDC/USDT now $0
- day 41.66: **cap squatting** (filler wallet w985f92 pledges $9075): regular room of USDC/USDT now $0
- day 42.58: **cap squatting** (filler wallet w985f93 pledges $1114): regular room of USDC/USDT now $0
- day 42.91: **cap squatting** (filler wallet w985f94 pledges $69278): regular room of USDC/USDT now $0
- day 43.20: **cap squatting** (filler wallet w985f95 pledges $4217): regular room of USDC/USDT now $0
- day 43.41: **cap squatting** (filler wallet w985f96 pledges $10588): regular room of USDC/USDT now $0
- day 43.66: **cap squatting** (filler wallet w985f97 pledges $2480): regular room of USDC/USDT now $0
- day 44.41: **cap squatting** (filler wallet w985f98 pledges $2443): regular room of USDC/USDT now $0
- day 45.28: **cap squatting** (filler wallet w985f99 pledges $4492): regular room of USDC/USDT now $0
- day 45.78: **cap squatting** (filler wallet w985f100 pledges $2633): regular room of USDC/USDT now $0
- day 45.87: **cap squatting** (filler wallet w985f101 pledges $50893): regular room of USDC/USDT now $0
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $695842
- day 47.87: **cap squatting** (filler wallet w985f102 pledges $5042): regular room of USDC/USDT now $0
- day 48.28: **cap squatting** (filler wallet w985f103 pledges $1542): regular room of USDC/USDT now $0
- day 48.66: **cap squatting** (filler wallet w985f104 pledges $24524): regular room of USDC/USDT now $0
- day 49.24: **cap squatting** (filler wallet w985f105 pledges $1214): regular room of USDC/USDT now $0
- day 49.41: **cap squatting** (filler wallet w985f106 pledges $11765): regular room of USDC/USDT now $0
- day 49.45: **cap squatting** (filler wallet w985f107 pledges $4547): regular room of USDC/USDT now $0
- day 49.78: **cap squatting** (filler wallet w985f108 pledges $7304): regular room of USDC/USDT now $0
- day 49.95: **cap squatting** (filler wallet w985f109 pledges $2859): regular room of USDC/USDT now $0
- day 50.16: **cap squatting** (filler wallet w985f110 pledges $5404): regular room of USDC/USDT now $0
- day 50.95: **cap squatting** (filler wallet w985f111 pledges $3236): regular room of USDC/USDT now $0
- day 51.12: **cap squatting** (filler wallet w985f112 pledges $16445): regular room of USDC/USDT now $0
- day 51.95: **cap squatting** (filler wallet w985f113 pledges $2626): regular room of USDC/USDT now $0
- day 52.37: **cap squatting** (filler wallet w985f114 pledges $4089): regular room of USDC/USDT now $0
- day 52.74: **cap squatting** (filler wallet w985f115 pledges $5870): regular room of USDC/USDT now $0
- day 53.87: **cap squatting** (filler wallet w985f116 pledges $17225): regular room of USDC/USDT now $0
- day 53.99: **cap squatting** (filler wallet w985f117 pledges $1076): regular room of USDC/USDT now $0
- day 54.49: **cap squatting** (filler wallet w985f118 pledges $37943): regular room of USDC/USDT now $0
- day 54.66: **cap squatting** (filler wallet w985f119 pledges $6086): regular room of USDC/USDT now $0
- day 54.70: **cap squatting** (filler wallet w985f120 pledges $1146): regular room of USDC/USDT now $0
- day 55.66: **cap squatting** (filler wallet w985f121 pledges $9931): regular room of USDC/USDT now $0
- day 55.91: **cap squatting** (filler wallet w985f122 pledges $3329): regular room of USDC/USDT now $0
- day 56.20: **cap squatting** (filler wallet w985f123 pledges $145): regular room of USDC/USDT now $0
- day 57.28: **cap squatting** (filler wallet w985f124 pledges $4438): regular room of USDC/USDT now $0
- day 57.83: **cap squatting** (filler wallet w985f125 pledges $1917): regular room of USDC/USDT now $0
- day 57.87: **cap squatting** (filler wallet w985f126 pledges $1198): regular room of USDC/USDT now $0
- day 58.45: **cap squatting** (filler wallet w985f127 pledges $3535): regular room of USDC/USDT now $0
- day 58.70: **cap squatting** (filler wallet w985f128 pledges $27900): regular room of USDC/USDT now $0
- day 59.33: **cap squatting** (filler wallet w985f129 pledges $2255): regular room of USDC/USDT now $0
- day 60.28: **cap squatting** (filler wallet w985f130 pledges $32313): regular room of USDC/USDT now $0
- day 60.62: **cap squatting** (filler wallet w985f131 pledges $16730): regular room of USDC/USDT now $0
- day 60.83: **cap squatting** (filler wallet w985f132 pledges $15854): regular room of USDC/USDT now $0
- day 61.91: **cap squatting** (filler wallet w985f133 pledges $3626): regular room of USDC/USDT now $0
- day 62.03: **cap squatting** (filler wallet w985f134 pledges $5875): regular room of USDC/USDT now $0
- day 62.37: **cap squatting** (filler wallet w985f135 pledges $7931): regular room of USDC/USDT now $0
- day 62.66: **cap squatting** (filler wallet w985f136 pledges $18995): regular room of USDC/USDT now $0
- day 62.74: **cap squatting** (filler wallet w985f137 pledges $9429): regular room of USDC/USDT now $0
- day 62.91: **cap squatting** (filler wallet w985f138 pledges $1254): regular room of USDC/USDT now $0
- day 63.66: **cap squatting** (filler wallet w985f139 pledges $8051): regular room of USDC/USDT now $0
- day 63.74: **cap squatting** (filler wallet w985f140 pledges $97): regular room of USDC/USDT now $0
- day 63.87: **cap squatting** (filler wallet w985f141 pledges $4238): regular room of USDC/USDT now $0
- day 63.91: **cap squatting** (filler wallet w985f142 pledges $15602): regular room of USDC/USDT now $0
- day 64.16: **cap squatting** (filler wallet w985f143 pledges $13522): regular room of USDC/USDT now $0
- day 64.20: **cap squatting** (filler wallet w985f144 pledges $546): regular room of USDC/USDT now $0
- day 64.37: **cap squatting** (filler wallet w985f145 pledges $662): regular room of USDC/USDT now $0
- day 64.41: **cap squatting** (filler wallet w985f146 pledges $15514): regular room of USDC/USDT now $0
- day 64.66: **cap squatting** (filler wallet w985f147 pledges $5893): regular room of USDC/USDT now $0
- day 67.16: **cap squatting** (filler wallet w985f148 pledges $6887): regular room of USDC/USDT now $0
- day 67.33: **cap squatting** (filler wallet w985f149 pledges $4002): regular room of USDC/USDT now $0
- day 67.41: **cap squatting** (filler wallet w985f150 pledges $5193): regular room of USDC/USDT now $0
- day 67.58: **cap squatting** (filler wallet w985f151 pledges $6988): regular room of USDC/USDT now $0
- day 67.83: **cap squatting** (filler wallet w985f152 pledges $2914): regular room of USDC/USDT now $0
- day 68.08: **cap squatting** (filler wallet w985f153 pledges $773): regular room of USDC/USDT now $0
- day 69.33: **cap squatting** (filler wallet w985f154 pledges $12161): regular room of USDC/USDT now $0
- day 69.53: **cap squatting** (filler wallet w985f155 pledges $1917): regular room of USDC/USDT now $0
- day 70.28: **cap squatting** (filler wallet w985f156 pledges $2475): regular room of USDC/USDT now $0
- day 70.66: **cap squatting** (filler wallet w985f157 pledges $21323): regular room of USDC/USDT now $0
- day 70.74: **cap squatting** (filler wallet w985f158 pledges $6631): regular room of USDC/USDT now $0
- day 70.87: **cap squatting** (filler wallet w985f159 pledges $6426): regular room of USDC/USDT now $0
- day 70.91: **cap squatting** (filler wallet w985f160 pledges $34359): regular room of USDC/USDT now $0
- day 71.16: **cap squatting** (filler wallet w985f161 pledges $15127): regular room of USDC/USDT now $0
- day 71.41: **cap squatting** (filler wallet w985f162 pledges $5116): regular room of USDC/USDT now $0
- day 72.08: **cap squatting** (filler wallet w985f163 pledges $9308): regular room of USDC/USDT now $0
- day 72.87: **cap squatting** (filler wallet w985f164 pledges $2539): regular room of USDC/USDT now $0
- day 73.03: **cap squatting** (filler wallet w985f165 pledges $85): regular room of USDC/USDT now $0
- day 73.45: **cap squatting** (filler wallet w985f166 pledges $1176): regular room of USDC/USDT now $0
- day 74.49: **cap squatting** (filler wallet w985f167 pledges $382): regular room of USDC/USDT now $0
- day 77.28: **cap squatting** (filler wallet w985f221 pledges $12115): regular room of USDC/USDT now $0
- day 77.62: **cap squatting** (filler wallet w985f222 pledges $8462): regular room of USDC/USDT now $0
- day 78.37: **cap squatting** (filler wallet w985f223 pledges $4757): regular room of USDC/USDT now $0
- day 78.58: **cap squatting** (filler wallet w985f224 pledges $1732): regular room of USDC/USDT now $0
- day 78.62: **cap squatting** (filler wallet w985f225 pledges $8837): regular room of USDC/USDT now $0
- day 78.87: **cap squatting** (filler wallet w985f226 pledges $3835): regular room of USDC/USDT now $0
- day 80.24: **cap squatting** (filler wallet w985f227 pledges $2254): regular room of USDC/USDT now $0
- day 80.78: **cap squatting** (filler wallet w985f228 pledges $2768): regular room of USDC/USDT now $0
- day 81.78: **cap squatting** (filler wallet w985f229 pledges $2511): regular room of USDC/USDT now $0
- day 81.83: **cap squatting** (filler wallet w985f230 pledges $7277): regular room of USDC/USDT now $0
- day 83.41: **cap squatting** (filler wallet w985f231 pledges $155): regular room of USDC/USDT now $0
- day 83.87: **cap squatting** (filler wallet w985f232 pledges $579728): regular room of USDC/USDT now $0
- day 83.95: **cap squatting** (filler wallet w985f233 pledges $1843): regular room of USDC/USDT now $0
- day 85.12: **cap squatting** (filler wallet w985f234 pledges $38526): regular room of USDC/USDT now $0
- day 85.24: **cap squatting** (filler wallet w985f235 pledges $22916): regular room of USDC/USDT now $0
- day 85.28: **cap squatting** (filler wallet w985f236 pledges $2967): regular room of USDC/USDT now $0
- day 85.49: **cap squatting** (filler wallet w985f237 pledges $48242): regular room of USDC/USDT now $0
- day 85.74: **cap squatting** (filler wallet w985f238 pledges $19223): regular room of USDC/USDT now $0
- day 85.99: **cap squatting** (filler wallet w985f239 pledges $5923): regular room of USDC/USDT now $0
- day 86.70: **cap squatting** (filler wallet w985f240 pledges $2265): regular room of USDC/USDT now $0
- day 86.99: **cap squatting** (filler wallet w985f241 pledges $13836): regular room of USDC/USDT now $0
- day 87.62: **cap squatting** (filler wallet w985f242 pledges $8589): regular room of USDC/USDT now $0
