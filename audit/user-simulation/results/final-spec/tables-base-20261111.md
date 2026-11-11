### Personas (seed 20261111, feed profile `spec`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 181 | 89 | 85 | 0 | $6,935 | $39 | $0 | $79 | $0 | 1.13% | 78% | 44 / 43 / 0 |
| active_lp | 120 | 56 | 64 | 21 | 1 | $20,559 | $94 | $0 | $259 | $10 | 1.28% | 84% | 21 / 20 / 0 |
| leveraged | 100 | 59 | 41 | 59 | 6 | $20,420 | $123 | $73 | $277 | $135 | 1.34% | 76% | 20 / 20 / 0 |
| small | 120 | 44 | 76 | 21 | 0 | $174 | $1 | $0 | $91 | $0 | 52.05% | 100% | 11 / 10 / 0 |
| whale | 20 | 13 | 5 | 12 | 0 | $666,619 | $2,642 | $1,411 | $243 | $0 | 0.05% | 0% | 1 / 2 / 0 |
| multi_market | 85 | 80 | 4 | 76 | 19 | $19,636 | $67 | $28 | $149 | $1,686 | 0.82% | 80% | 25 / 25 / 0 |
| mobile | 110 | 78 | 32 | 63 | 4 | $5,058 | $31 | $8 | $97 | $62 | 1.93% | 83% | 24 / 24 / 0 |
| forgetful | 90 | 62 | 28 | 54 | 7 | $8,078 | $53 | $25 | $73 | $135 | 1.06% | 68% | 0 / 0 / 0 |
| usdc_borrower | 70 | 46 | 24 | 46 | 1 | $14,505 | $75 | $29 | $112 | $15 | 0.69% | 74% | 13 / 13 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 83 |
| accounts | 78 |
| bonus_paid | $2,044 |
| debt_repaid | $50,171 |
| deficit | $0 |
| budget_draws | $0 |
| keeper_reimbursement | $50,310 |
| keeper_pnl | $-49,972 |
| searcher_profit | $139 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $31,050 |
| max_gas_usd | $904 |
| dust calls (repay < $100) | 40 |
| calls on the dust attacker's accounts / on other accounts | 40 / 43 |
| other accounts: calls repaying under $100 / gas / debt repaid / reimbursed / most calls on one account | 0 / $19,979 / $50,073 / $19,260 / 2 |
| liquidations seizing a fresh market while another market of the account was Cached, Expired or disagreeing (Q-247) | 18 |
| by episode | USDe crash 65, GHO/USDC drain 18 |
| by caller/mode | keeper/gho 80, permissionless/gho 3 |
| by debt asset | GHO 70, USDC 13 |
| by market | GHO/USDC 7, USDC/USDT 11, USDe/USDT 65 |
| liquidation blocked (account-hours by reason) | StalePrice(Cached/Expired) 1058.7 h (84 accounts), StalePrice(disagree_pause) 3.2 h (7 accounts), StalePrice(disagree_expired) 2.7 h (8 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| borrow | `DeadlineExpired` | 14 | 13 | $112 |
| pledge | `DeadlineExpired` | 12 | 12 | $285 |
| borrow | `BadNonce` | 11 | 11 | $87 |
| repayAllAndWithdraw | `DeadlineExpired` | 7 | 6 | $105 |
| borrow | `Dropped(not mined)` | 6 | 6 | $0 |
| collectFees | `DeadlineExpired` | 5 | 5 | $14 |
| repay | `Dropped(not mined)` | 4 | 4 | $0 |
| collectFees | `Dropped(not mined)` | 4 | 4 | $0 |
| pledge | `Dropped(not mined)` | 2 | 2 | $0 |
| repay | `DeadlineExpired` | 2 | 2 | $159 |
| pledge | `SliceNotAvailable` | 1 | 1 | $57 |
| removeLiquidity | `DeadlineExpired` | 1 | 1 | $6 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| borrow | `PriceNotLive(Drifting:band)` | 1011 | 12 |
| pledge | `CapExceeded(market)` | 999 | 261 |
| pledge | `NotFullRange` | 402 | 385 |
| repayWithCollateral | `StalePrice(Cached/Expired)` | 107 | 12 |
| pledge | `SliceNotAvailable` | 47 | 9 |
| pledge | `PoolShareExceeded` | 42 | 34 |
| top-up | `PriceNotAccepted(Cached/Expired)` | 42 | 9 |
| borrow | `ApplicationPaused` | 35 | 11 |
| removeLiquidity(rebalance) | `HealthFactorTooLow` | 25 | 11 |
| recredit | `CapExceeded(market)` | 24 | 7 |
| recredit | `PoolShareExceeded` | 19 | 6 |
| recredit | `SliceNotAvailable` | 15 | 3 |
| borrow | `BreakerTripped(POOL_SHARE,MANUAL)` | 10 | 10 |
| borrow | `ApplicationFrozen` | 9 | 9 |
| pledge | `PriceNotAccepted(Cached/Expired)` | 7 | 1 |
| borrow | `BreakerTripped(POOL_SHARE)` | 6 | 6 |
| top-up | `PoolShareExceeded` | 6 | 5 |
| pledge | `CapExceeded(depositor)` | 4 | 4 |
| pledge | `PriceNotAccepted(Drifting)` | 4 | 2 |
| removeLiquidity(rebalance) | `PriceNotLive(Drifting:band)` | 4 | 3 |
| borrow | `PriceNotLive(Cached/Expired)` | 3 | 3 |
| borrow | `PriceNotLive(Drifting:mixed)` | 3 | 3 |
| pledge | `NotRescueTopUp` | 3 | 3 |
| borrow | `DrawCapExceeded` | 2 | 2 |
| pledge(loop) | `SliceNotAvailable` | 2 | 2 |
| recredit | `NotRescueTopUp` | 2 | 2 |
| pledge(loop) | `PoolShareExceeded` | 1 | 1 |
| top-up | `SliceNotAvailable` | 1 | 1 |
| removeLiquidity(rebalance) | `ApplicationPaused` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | concentrated_rejected | 385 | 402 | app (now), contracts (later) |
| 2 | low_ltv | 296 | 296 | app + risk |
| 3 | cap_full | 270 | 1048 | app + governance |
| 4 | fees_manual | 119 | 193 | app (contracts optional) |
| 5 | gas_exceeds_value | 82 | 82 | app + parameter |
| 6 | used_partial_removal | 50 | 135 | outcome |
| 7 | liquidated | 39 | 83 | app |
| 8 | no_alerts | 32 | 73 | app/services |
| 9 | deadline_expired | 32 | 41 | app |
| 10 | recredit_refused | 16 | 60 | app |
| 11 | borrow_blocked_price | 15 | 1017 | spec parameter + app |
| 12 | partial_removal_refused | 14 | 30 | app |
| 13 | tx_dropped | 14 | 16 | app |
| 14 | borrow_blocked_breaker | 13 | 16 | app |
| 15 | deleverage_refused | 12 | 107 | app |
| 16 | bad_nonce | 11 | 11 | app |
| 17 | exit_via_repay_with_collateral | 11 | 11 | outcome |
| 18 | used_repay_with_collateral | 11 | 11 | outcome |
| 19 | topup_refused_stale | 9 | 42 | app |
| 20 | topup_refused_pool_share | 5 | 6 | contracts/spec |
| 21 | depositor_cap_split | 4 | 4 | governance |
| 22 | borrow_blocked_other_market | 3 | 4 | contracts + app |
| 23 | drawcap_exhausted | 2 | 2 | app + Aave governance |
| 24 | rescued_by_topup_exemption | 1 | 5 | outcome |
| 25 | topup_refused_slice | 1 | 1 | spec parameter + app |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| added liquidity sitting uncredited in pledged NFTs (USD) | $21,187 | 8 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 51 |
| uncollected fees in the vault (claimable at any time) | $21,058 | 462 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age | Blocked by a market breaker |
|---|---|---|---|---|
| USDC/USDT | 96.5% | 0.0% | 0.1% | 3.4% |
| GHO/USDC | 97.8% | 0.1% | 0.0% | 2.1% |
| DAI/USDC | 98.5% | 0.9% | 0.4% | 0.1% |
| USDe/USDT | 63.2% | 33.3% | 0.0% | 3.4% |
| USDC debt price | 100.0% | 0.0% | 0.0% | 0.0% |

### Invariants

495259 checks over 23 kinds; violations: {'rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026)': 3}

| Invariant | Checks |
|---|---|
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1060 |
| address freeze gates match EMG-070 | 9 |
| backing: supply <= credited + pending, equal with a conforming LPVaultSwap (Q-257) | 364 |
| credited == sum of records | 364 |
| custody iff open record | 68192 |
| debt conservation per account | 116248 |
| fee conservation per NFT | 101029 |
| liquidation GHO conservation | 83 |
| market regular counter <= cap | 364 |
| probe: state gates match the 3.6 emergency matrix | 189 |
| re-credit: record credited == live liquidity | 24 |
| record live liquidity >= credited | 68192 |
| record live liquidity >= credited after removal | 135 |
| repay with collateral: conversion covers the flash loan (SPEC-LIQ-020) | 11 |
| repay-all leaves no allowance (refund of the unused pull, REP-009) | 375 |
| rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026) | 15 |
| rescue units <= credited per record | 69201 |
| rescue-excluded HF >= 1.10 after every borrow (REQ-RISK-068) | 557 |
| rescue-excluded HF >= 1.10 after partial removal with debt | 26 |
| routed liquidation meets the recovery floor (R + shortfall >= minGho) | 83 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 68192 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $0, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $42,165 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $3,367,344, DAI/USDC $3,162,440, USDe/USDT $2,810,031 |
| third-party repay service | {'repaid': 9, 'repaid_in_None': 9, 'usd': 63382.260436489225} |

### Rule probes vs the 3.6 emergency matrix (observed / expected)

| State (market, day) | new | topup | rescue | borrow | repay | collect | wd_free | wd_debt | remove_debt | rwc | repay_all_wd | liq |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Live (USDC/USDT, 5.00) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Market breaker tripped (GHO/USDC, 9.00) | N (PoolShareExceeded) | N (PoolShareExceeded) | Y | N (BreakerTripped(POOL_SHARE)) | Y | Y | Y | N (BreakerTripped(POOL_SHARE)) | N (BreakerTripped(POOL_SHARE)) | Y | Y | Y |
| Alternate past borrowPriceMaxAge (seizure as Cached) (USDC/USDT, 18.53) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | N (PriceTooOld) | N (StalePrice(alt_past_borrow_age)) | Y | N (StalePrice(alt_past_borrow_age)) |
| Live (USDC/USDT, 18.75) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Live (USDC/USDT, 19.20) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Live (USDC/USDT, 19.61) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Alternate past borrowPriceMaxAge (seizure as Cached) (DAI/USDC, 52.04) | Y | Y | Y | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | N (PriceTooOld) | N (StalePrice(alt_past_borrow_age)) | Y | N (StalePrice(alt_past_borrow_age)) |
| Cached (DAI/USDC, 52.68) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | N (StalePrice(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Expired (DAI/USDC, 52.73) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | N (StalePrice(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Grace after recovery, manual breaker still tripped (DAI/USDC, 53.25) | N (PoolShareExceeded) | N (PoolShareExceeded) | Y | N (BreakerTripped(POOL_SHARE,MANUAL)) | Y | Y | Y | N (BreakerTripped(POOL_SHARE,MANUAL)) | N (BreakerTripped(POOL_SHARE,MANUAL)) | Y | Y | N (GraceHealthFactor) |
| Drifting (feed disagreement) (USDe/USDT, 60.21) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_pause)) | Y | N (StalePrice(disagree_pause)) |
| Disagreement beyond disagreementPauseMax (USDe/USDT, 60.25) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_expired)) | Y | N (StalePrice(disagree_expired)) |
| Market breaker tripped (USDe/USDT, 66.00) | N (PoolShareExceeded) | N (PoolShareExceeded) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | N (PriceNotLive(Drifting:band)) | Y | Y | Y |
| Application Frozen (USDC/USDT, 75.10) | N (ApplicationFrozen) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | N (ApplicationFrozen) | Y | Y | Y | Y | Y | Y | Y | Y |
| Application Paused (General) (USDC/USDT, 76.00) | N (CapExceeded(market)) | N (SliceNotAvailable) | Y | N (ApplicationPaused) | Y | Y | Y | N (ApplicationPaused) | N (ApplicationPaused) | N (ApplicationPaused) | Y | Y |
| Live (USDC/USDT, 85.06) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Live (USDC/USDT, 85.10) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |

### Final-spec features

| Measure | Value |
|---|---|
| standby switches (day, token, slot, call) | 85.04 USDC primary useStandbyRoute; 18.55 USDT primary useStandbyRoute; 24.60 USDT primary restorePriceRoute; 53.25 DAI primary useStandbyRoute; 58.25 DAI primary restorePriceRoute; 52.06 DAI DAI/USDC tripMarketBreaker; 53.29 DAI DAI/USDC resetMarketBreaker |
| tokens listable (every primary leg heartbeat <= 3,600 s) | USDC True, USDT True, DAI True, GHO True, USDe True |
| GHO/USDC Drifting(USD band) during the GHO premium | 0.0 h |
| USDT stall: minutes a USDT market was seizable on a leg older than borrowPriceMaxAge | 0 |
| USDC primary stall: USDC debt borrow gate / repayment gate closed | 38 / 38 min |
| USDC/USDT oracle minutes | drifting_band_min 0, drifting_twap_min 0, disagree_min 18, cached_min 0, expired_min 0, alt_past_borrow_age_min 76 |
| GHO/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 133, disagree_min 0, cached_min 0, expired_min 0, alt_past_borrow_age_min 38 |
| DAI/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 390, disagree_min 0, cached_min 60, expired_min 776, alt_past_borrow_age_min 956 |
| USDe/USDT oracle minutes | drifting_band_min 43077, drifting_twap_min 686, disagree_min 97, cached_min 0, expired_min 0, alt_past_borrow_age_min 38 |
| latched breakers (day, market, reason) | none |
| borrowing blocked by a market breaker (hours, from 10-minute samples) | DAI/USDC POOL_SHARE 1.8; DAI/USDC POOL_SHARE,MANUAL 1.0; GHO/USDC POOL_SHARE 44.5; GHO/USDC during gho_premium 44.5; USDC/USDT POOL_SHARE 73.0; USDC/USDT during usdt_depeg 73.0; USDe/USDT POOL_SHARE 73.0; USDe/USDT during usdt_depeg 73.0 |
| caller shortfall top-ups: calls / GHO | 25 / $215 |
| shortfall reports / automatic in-kind openings | 0 / none |
| Avana fee (oracle value) | $403 |
| rescue: attacker_borrowed_after_first_slice | 0.0 |
| rescue: attacker_slice_used | 42164.87335916337 |
| rescue: borrowed_after_slice_all | 0 |
| rescue: rescue_excluded_borrow_refusals | 1553 |
| rescue: rescue_excluded_refusals_attacker | 1553 |
| rescue: rescue_units_booked | 22676.05392962335 |
| rescue: stats | {'refused:PriceNotAccepted': 42, 'sized_to_restore': 5, 'sized_to_restore_below_accepted': 5, 'planned:pool_share+breaker': 5, 'rescue_topups_done': 5, 'rescue_topups_done:pool_share': 5, 'rescue_topups_done:breaker': 5} |
| deleverage | conversion_loss_usd 53.95, done 11, refused:StalePrice 107, repaid_usd 100313.99 |
| recredit | done 24, liquidity_added 38, refused:CapExceeded 24, refused:NotRescueTopUp 2, refused:PoolShareExceeded 19, refused:SliceNotAvailable 15, units 118097.13 |
| removal | done 135, reverted:DeadlineExpired 1 |
| exits | repay_all_first_attempt 100 |
| address freeze gates (EMG-070) | new account from a frozen wallet: N (AddressIsFrozen); non-rescue top-up: N (NotRescueTopUp); rescue top-up: Y; non-rescue top-up (probe account): N (NotRescueTopUp); borrow: N (AddressIsFrozen); repay: Y; partial removal with debt: N (AddressIsFrozen); repay with collateral: N (AddressIsFrozen); liquidation of its positions (gate): Y |

### Governance and attacks

- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused(General)
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 40 opened; gas paid $2451
- day 3.50: **address freeze of the dust wallets** (40 freezeAddress calls by two guardians): 40 frozen; a 21st freeze by the same guardian within 24 h refused: FreezeRateLimited
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 10.00: **cap squatting** (filler wallet w985f1 pledges $3745): regular room of USDC/USDT now $0
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
- day 15.12: **cap squatting** (filler wallet w985f2 pledges $4608): regular room of USDC/USDT now $0
- day 15.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.22: **cap squatting** (filler wallet w985f3 pledges $4717): regular room of USDC/USDT now $0
- day 17.35: **cap squatting** (filler wallet w985f4 pledges $5675): regular room of USDC/USDT now $0
- day 17.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.77: **cap squatting** (filler wallet w985f5 pledges $10187): regular room of USDC/USDT now $0
- day 17.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 20.54: **cap squatting** (filler wallet w985f6 pledges $9186): regular room of USDC/USDT now $0
- day 22.17: **cap squatting** (filler wallet w985f7 pledges $5595): regular room of USDC/USDT now $0
- day 22.25: **cap squatting** (filler wallet w985f8 pledges $6417): regular room of USDC/USDT now $0
- day 23.79: **cap squatting** (filler wallet w985f9 pledges $5455): regular room of USDC/USDT now $0
- day 27.54: **cap squatting** (filler wallet w985f10 pledges $7070): regular room of USDC/USDT now $0
- day 27.88: **cap squatting** (filler wallet w985f11 pledges $5250): regular room of USDC/USDT now $0
- day 28.92: **cap squatting** (filler wallet w985f12 pledges $2431): regular room of USDC/USDT now $0
- day 30.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 33.21: **cap squatting** (filler wallet w985f22 pledges $58629): regular room of USDC/USDT now $0
- day 33.30: **cap squatting** (filler wallet w985f23 pledges $3819): regular room of USDC/USDT now $0
- day 33.34: **cap squatting** (filler wallet w985f24 pledges $15068): regular room of USDC/USDT now $0
- day 33.59: **cap squatting** (filler wallet w985f25 pledges $4520): regular room of USDC/USDT now $0
- day 33.67: **cap squatting** (filler wallet w985f26 pledges $7208): regular room of USDC/USDT now $0
- day 34.05: **cap squatting** (filler wallet w985f27 pledges $13273): regular room of USDC/USDT now $0
- day 36.71: **cap squatting** (filler wallet w985f28 pledges $10958): regular room of USDC/USDT now $0
- day 37.09: **cap squatting** (filler wallet w985f29 pledges $3426): regular room of USDC/USDT now $0
- day 37.42: **cap squatting** (filler wallet w985f30 pledges $4619): regular room of USDC/USDT now $0
- day 37.63: **cap squatting** (filler wallet w985f31 pledges $7095): regular room of USDC/USDT now $0
- day 38.00: **cap squatting** (filler wallet w985f32 pledges $11096): regular room of USDC/USDT now $0
- day 38.25: **cap squatting** (filler wallet w985f33 pledges $19574): regular room of USDC/USDT now $0
- day 38.50: **cap squatting** (filler wallet w985f34 pledges $8652): regular room of USDC/USDT now $0
- day 38.75: **cap squatting** (filler wallet w985f35 pledges $2864): regular room of USDC/USDT now $0
- day 39.38: **cap squatting** (filler wallet w985f36 pledges $271): regular room of USDC/USDT now $0
- day 39.46: **cap squatting** (filler wallet w985f37 pledges $2499): regular room of USDC/USDT now $0
- day 39.75: **cap squatting** (filler wallet w985f38 pledges $6076): regular room of USDC/USDT now $0
- day 39.88: **cap squatting** (filler wallet w985f39 pledges $17178): regular room of USDC/USDT now $0
- day 40.88: **cap squatting** (filler wallet w985f40 pledges $2216): regular room of USDC/USDT now $0
- day 41.67: **cap squatting** (filler wallet w985f41 pledges $51800): regular room of USDC/USDT now $0
- day 42.96: **cap squatting** (filler wallet w985f42 pledges $23158): regular room of USDC/USDT now $0
- day 43.21: **cap squatting** (filler wallet w985f43 pledges $3013): regular room of USDC/USDT now $0
- day 44.38: **cap squatting** (filler wallet w985f44 pledges $244096): regular room of USDC/USDT now $0
- day 44.88: **cap squatting** (filler wallet w985f45 pledges $10519): regular room of USDC/USDT now $0
- day 45.17: **cap squatting** (filler wallet w985f46 pledges $6419): regular room of USDC/USDT now $0
- day 45.34: **cap squatting** (filler wallet w985f47 pledges $5046): regular room of USDC/USDT now $0
- day 46.05: **cap squatting** (filler wallet w985f48 pledges $7615): regular room of USDC/USDT now $0
- day 46.25: **cap squatting** (filler wallet w985f49 pledges $3323): regular room of USDC/USDT now $0
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $692999
- day 47.13: **cap squatting** (filler wallet w985f50 pledges $2398): regular room of USDC/USDT now $0
- day 47.63: **cap squatting** (filler wallet w985f51 pledges $31691): regular room of USDC/USDT now $0
- day 49.67: **cap squatting** (filler wallet w985f52 pledges $30394): regular room of USDC/USDT now $0
- day 49.92: **cap squatting** (filler wallet w985f53 pledges $11682): regular room of USDC/USDT now $0
- day 50.17: **cap squatting** (filler wallet w985f54 pledges $5122): regular room of USDC/USDT now $0
- day 50.42: **cap squatting** (filler wallet w985f55 pledges $1421): regular room of USDC/USDT now $0
- day 50.67: **cap squatting** (filler wallet w985f56 pledges $28253): regular room of USDC/USDT now $0
- day 51.55: **cap squatting** (filler wallet w985f57 pledges $177707): regular room of USDC/USDT now $0
- day 51.84: **cap squatting** (filler wallet w985f58 pledges $5127): regular room of USDC/USDT now $0
- day 51.96: **cap squatting** (filler wallet w985f59 pledges $3787): regular room of USDC/USDT now $0
- day 52.63: **cap squatting** (filler wallet w985f60 pledges $27273): regular room of USDC/USDT now $0
- day 52.75: **cap squatting** (filler wallet w985f61 pledges $21277): regular room of USDC/USDT now $0
- day 52.96: **cap squatting** (filler wallet w985f62 pledges $11963): regular room of USDC/USDT now $0
- day 54.13: **cap squatting** (filler wallet w985f63 pledges $1744): regular room of USDC/USDT now $0
- day 54.88: **cap squatting** (filler wallet w985f64 pledges $14176): regular room of USDC/USDT now $0
- day 55.84: **cap squatting** (filler wallet w985f65 pledges $9291): regular room of USDC/USDT now $0
- day 56.30: **cap squatting** (filler wallet w985f66 pledges $4492): regular room of USDC/USDT now $0
- day 56.50: **cap squatting** (filler wallet w985f67 pledges $2574): regular room of USDC/USDT now $0
- day 57.21: **cap squatting** (filler wallet w985f68 pledges $3917): regular room of USDC/USDT now $0
- day 57.80: **cap squatting** (filler wallet w985f69 pledges $253): regular room of USDC/USDT now $0
- day 58.34: **cap squatting** (filler wallet w985f70 pledges $2326): regular room of USDC/USDT now $0
- day 59.00: **cap squatting** (filler wallet w985f71 pledges $28): regular room of USDC/USDT now $0
- day 59.46: **cap squatting** (filler wallet w985f72 pledges $16535): regular room of USDC/USDT now $0
- day 59.50: **cap squatting** (filler wallet w985f73 pledges $3532): regular room of USDC/USDT now $0
- day 59.84: **cap squatting** (filler wallet w985f74 pledges $17645): regular room of USDC/USDT now $0
- day 63.71: **cap squatting** (filler wallet w985f75 pledges $9803): regular room of USDC/USDT now $0
- day 65.13: **cap squatting** (filler wallet w985f76 pledges $8241): regular room of USDC/USDT now $0
- day 65.92: **cap squatting** (filler wallet w985f77 pledges $2673): regular room of USDC/USDT now $0
- day 66.05: **cap squatting** (filler wallet w985f78 pledges $5992): regular room of USDC/USDT now $0
- day 66.96: **cap squatting** (filler wallet w985f79 pledges $5529): regular room of USDC/USDT now $0
- day 70.63: **cap squatting** (filler wallet w985f80 pledges $13242): regular room of USDC/USDT now $0
- day 70.80: **cap squatting** (filler wallet w985f81 pledges $10437): regular room of USDC/USDT now $0
- day 71.46: **cap squatting** (filler wallet w985f82 pledges $5246): regular room of USDC/USDT now $0
- day 73.38: **cap squatting** (filler wallet w985f83 pledges $1679): regular room of USDC/USDT now $0
- day 73.92: **cap squatting** (filler wallet w985f84 pledges $2423): regular room of USDC/USDT now $0
- day 74.25: **cap squatting** (filler wallet w985f85 pledges $2742): regular room of USDC/USDT now $0
- day 74.88: **cap squatting** (filler wallet w985f86 pledges $3054): regular room of USDC/USDT now $0
- day 77.25: **cap squatting** (filler wallet w985f98 pledges $45265): regular room of USDC/USDT now $0
- day 77.46: **cap squatting** (filler wallet w985f99 pledges $34525): regular room of USDC/USDT now $0
- day 78.84: **cap squatting** (filler wallet w985f100 pledges $12575): regular room of USDC/USDT now $0
- day 78.88: **cap squatting** (filler wallet w985f101 pledges $5830): regular room of USDC/USDT now $0
- day 79.42: **cap squatting** (filler wallet w985f102 pledges $31090): regular room of USDC/USDT now $0
- day 79.50: **cap squatting** (filler wallet w985f103 pledges $21219): regular room of USDC/USDT now $0
- day 80.34: **cap squatting** (filler wallet w985f104 pledges $5727): regular room of USDC/USDT now $0
- day 80.38: **cap squatting** (filler wallet w985f105 pledges $22487): regular room of USDC/USDT now $0
- day 81.05: **cap squatting** (filler wallet w985f106 pledges $20539): regular room of USDC/USDT now $0
- day 81.17: **cap squatting** (filler wallet w985f107 pledges $10017): regular room of USDC/USDT now $0
- day 81.30: **cap squatting** (filler wallet w985f108 pledges $6504): regular room of USDC/USDT now $0
- day 81.42: **cap squatting** (filler wallet w985f109 pledges $18828): regular room of USDC/USDT now $0
- day 81.67: **cap squatting** (filler wallet w985f110 pledges $7867): regular room of USDC/USDT now $0
- day 81.92: **cap squatting** (filler wallet w985f111 pledges $2146): regular room of USDC/USDT now $0
- day 82.13: **cap squatting** (filler wallet w985f112 pledges $7127): regular room of USDC/USDT now $0
- day 82.75: **cap squatting** (filler wallet w985f113 pledges $1175): regular room of USDC/USDT now $0
- day 83.55: **cap squatting** (filler wallet w985f114 pledges $3042): regular room of USDC/USDT now $0
- day 83.71: **cap squatting** (filler wallet w985f115 pledges $1626): regular room of USDC/USDT now $0
- day 83.80: **cap squatting** (filler wallet w985f116 pledges $5808): regular room of USDC/USDT now $0
- day 84.05: **cap squatting** (filler wallet w985f117 pledges $2455): regular room of USDC/USDT now $0
- day 84.09: **cap squatting** (filler wallet w985f118 pledges $131): regular room of USDC/USDT now $0
- day 84.25: **cap squatting** (filler wallet w985f119 pledges $1675): regular room of USDC/USDT now $0
- day 87.92: **cap squatting** (filler wallet w985f120 pledges $2788): regular room of USDC/USDT now $0
- day 88.17: **cap squatting** (filler wallet w985f121 pledges $2201): regular room of USDC/USDT now $0
- day 88.50: **cap squatting** (filler wallet w985f122 pledges $11157): regular room of USDC/USDT now $0
- day 88.84: **cap squatting** (filler wallet w985f123 pledges $1251): regular room of USDC/USDT now $0
- day 89.00: **cap squatting** (filler wallet w985f124 pledges $103781): regular room of USDC/USDT now $0
- day 89.92: **cap squatting** (filler wallet w985f125 pledges $13480): regular room of USDC/USDT now $0
