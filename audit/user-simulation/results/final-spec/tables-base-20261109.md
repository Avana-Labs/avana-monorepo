### Personas (seed 20261109, feed profile `spec`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 183 | 87 | 86 | 0 | $8,143 | $51 | $0 | $2 | $0 | 0.03% | 2% | 46 / 46 / 0 |
| active_lp | 120 | 63 | 57 | 33 | 3 | $17,224 | $93 | $6 | $10 | $21 | 0.05% | 3% | 25 / 25 / 0 |
| leveraged | 100 | 75 | 25 | 75 | 9 | $16,309 | $180 | $49 | $12 | $144 | 0.10% | 1% | 32 / 32 / 0 |
| small | 120 | 81 | 39 | 49 | 3 | $151 | $1 | $0 | $2 | $1 | 1.36% | 74% | 26 / 26 / 0 |
| whale | 20 | 17 | 2 | 14 | 0 | $489,563 | $2,530 | $970 | $7 | $0 | 0.00% | 0% | 3 / 3 / 0 |
| multi_market | 85 | 82 | 3 | 71 | 5 | $18,592 | $82 | $20 | $6 | $54 | 0.04% | 5% | 18 / 8 / 0 |
| mobile | 110 | 74 | 36 | 53 | 4 | $4,641 | $32 | $9 | $3 | $83 | 0.06% | 7% | 18 / 18 / 0 |
| forgetful | 90 | 64 | 26 | 61 | 16 | $9,414 | $59 | $25 | $2 | $211 | 0.03% | 0% | 0 / 0 / 0 |
| usdc_borrower | 70 | 44 | 26 | 44 | 4 | $15,107 | $91 | $34 | $3 | $41 | 0.03% | 0% | 19 / 19 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 98 |
| accounts | 84 |
| bonus_paid | $557 |
| debt_repaid | $25,405 |
| deficit | $0 |
| keeper_reimbursement | $9,499 |
| keeper_pnl | $-9,498 |
| searcher_profit | $7 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $4,095 |
| max_gas_usd | $127 |
| dust calls (repay < $100) | 43 |
| calls on the dust attacker's accounts / on other accounts | 40 / 58 |
| other accounts: calls repaying under $100 / gas / debt repaid / reimbursed / most calls on one account | 3 / $5,432 / $25,307 / $5,631 / 3 |
| liquidations seizing a fresh market while another market of the account was Cached, Expired or disagreeing (Q-247) | 0 |
| by episode | USDe crash 95, pause + USDe aftershock 3 |
| by caller/mode | keeper/routed 96, permissionless/routed 2 |
| by debt asset | GHO 73, USDC 25 |
| by market | USDe/USDT 98 |
| liquidation blocked (account-hours by reason) | StalePrice(Cached/Expired) 1265.5 h (107 accounts), StalePrice(disagree_pause) 4.3 h (6 accounts), StalePrice(disagree_expired) 1.7 h (10 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| collectFees | `DeadlineExpired` | 23 | 20 | $3 |
| pledge | `DeadlineExpired` | 14 | 13 | $7 |
| collectFees | `Dropped(not mined)` | 13 | 12 | $0 |
| borrow | `DeadlineExpired` | 9 | 9 | $2 |
| repay | `DeadlineExpired` | 6 | 5 | $1 |
| pledge | `Dropped(not mined)` | 5 | 5 | $0 |
| borrow | `Dropped(not mined)` | 4 | 4 | $0 |
| withdraw | `DeadlineExpired` | 4 | 4 | $0 |
| borrow | `BadNonce` | 2 | 2 | $0 |
| borrow | `DrawCapExceeded` | 2 | 1 | $0 |
| pledge | `CapExceeded(market)` | 2 | 2 | $1 |
| repayAllAndWithdraw | `DeadlineExpired` | 2 | 2 | $1 |
| repayAllAndWithdraw | `Dropped(not mined)` | 1 | 1 | $0 |
| repay | `Dropped(not mined)` | 1 | 1 | $0 |
| pledge | `SliceNotAvailable` | 1 | 1 | $1 |
| withdraw | `Dropped(not mined)` | 1 | 1 | $0 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| borrow | `PriceNotLive(Drifting:band)` | 2869 | 25 |
| pledge | `CapExceeded(market)` | 981 | 244 |
| pledge | `NotFullRange` | 385 | 377 |
| repayWithCollateral | `MinOutNotMet` | 118 | 7 |
| repayWithCollateral | `StalePrice(Cached/Expired)` | 97 | 13 |
| top-up | `PriceNotAccepted(Cached/Expired)` | 67 | 15 |
| pledge | `PoolShareExceeded` | 59 | 30 |
| borrow | `ApplicationPaused` | 58 | 21 |
| pledge | `SliceNotAvailable` | 47 | 13 |
| recredit | `CapExceeded(market)` | 22 | 6 |
| removeLiquidity(rebalance) | `HealthFactorTooLow` | 17 | 8 |
| borrow | `BreakerTripped(POOL_SHARE)` | 15 | 10 |
| recredit | `SliceNotAvailable` | 15 | 3 |
| borrow | `ApplicationFrozen` | 15 | 15 |
| recredit | `PoolShareExceeded` | 14 | 4 |
| borrow | `DrawCapExceeded` | 12 | 8 |
| top-up | `PoolShareExceeded` | 11 | 10 |
| removeLiquidity(rebalance) | `PriceNotLive(Drifting:band)` | 10 | 6 |
| borrow | `BreakerTripped(POOL_SHARE,MANUAL)` | 6 | 6 |
| pledge | `CapExceeded(depositor)` | 3 | 3 |
| removeLiquidity(rebalance) | `ApplicationPaused` | 3 | 3 |
| pledge | `BelowMinPledge` | 2 | 2 |
| removeLiquidity(rebalance) | `BreakerTripped(POOL_SHARE,MANUAL)` | 2 | 2 |
| repayWithCollateral | `StalePrice(disagree_pause)` | 2 | 2 |
| pledge | `NotRescueTopUp` | 2 | 2 |
| top-up | `SliceNotAvailable` | 1 | 1 |
| removeLiquidity(rebalance) | `BreakerTripped(POOL_SHARE)` | 1 | 1 |
| recredit | `BreakerTripped(MANUAL)` | 1 | 1 |
| repayWithCollateral | `StalePrice(disagree_expired)` | 1 | 1 |
| borrow | `PriceNotLive(Drifting:mixed)` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | concentrated_rejected | 377 | 385 | app (now), contracts (later) |
| 2 | low_ltv | 342 | 383 | app + risk |
| 3 | cap_full | 257 | 1030 | app + governance |
| 4 | fees_manual | 235 | 434 | app (contracts optional) |
| 5 | used_partial_removal | 57 | 162 | outcome |
| 6 | liquidated | 45 | 98 | app |
| 7 | deadline_expired | 45 | 58 | app |
| 8 | used_repay_with_collateral | 28 | 31 | outcome |
| 9 | borrow_blocked_price | 25 | 2870 | spec parameter + app |
| 10 | no_alerts | 25 | 69 | app/services |
| 11 | exit_via_repay_with_collateral | 23 | 23 | outcome |
| 12 | tx_dropped | 21 | 25 | app |
| 13 | deleverage_refused | 20 | 219 | app |
| 14 | partial_removal_refused | 16 | 33 | app |
| 15 | topup_refused_stale | 15 | 67 | app |
| 16 | recredit_refused | 14 | 53 | app |
| 17 | borrow_blocked_breaker | 14 | 21 | app |
| 18 | topup_refused_pool_share | 10 | 11 | contracts/spec |
| 19 | drawcap_exhausted | 9 | 14 | app + Aave governance |
| 20 | rescued_by_topup_exemption | 5 | 10 | outcome |
| 21 | depositor_cap_split | 3 | 3 | governance |
| 22 | bad_nonce | 2 | 2 | app |
| 23 | below_min | 2 | 2 | app |
| 24 | exit_needs_external_funds | 2 | 2 | contracts |
| 25 | topup_refused_slice | 1 | 1 | spec parameter + app |
| 26 | gas_exceeds_value | 1 | 1 | app + parameter |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| added liquidity sitting uncredited in pledged NFTs (USD) | $67,794 | 9 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 55 |
| uncollected fees in the vault (claimable at any time) | $19,768 | 497 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age | Blocked by a market breaker |
|---|---|---|---|---|
| USDC/USDT | 96.5% | 0.0% | 0.1% | 3.4% |
| GHO/USDC | 97.8% | 0.1% | 0.0% | 2.1% |
| DAI/USDC | 98.4% | 1.0% | 0.4% | 0.2% |
| USDe/USDT | 63.2% | 33.4% | 0.0% | 3.3% |
| USDC debt price | 100.0% | 0.0% | 0.0% | 0.0% |

### Invariants

572608 checks over 27 kinds; violations: none

| Invariant | Checks |
|---|---|
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1279 |
| address freeze gates match EMG-070 | 9 |
| backing: supply <= credited + pending, equal with a conforming LPVaultSwap (Q-257) | 364 |
| credited == sum of records | 364 |
| custody iff open record | 79402 |
| debt conservation per account | 137366 |
| fee conservation per NFT | 110832 |
| flash premium within maxFlashFeeBps (LIQ-030) | 98 |
| flash premium within maxFlashFeeBps (REP-018, LIQ-030) | 189 |
| liquidation debt-asset conservation (SPEC-LIQ-010) | 98 |
| market regular counter <= cap | 364 |
| no borrower surplus when a shortfall was paid (LIQ-POST-016) | 98 |
| probe: state gates match the 3.6 emergency matrix | 189 |
| re-credit: record credited == live liquidity | 15 |
| record live liquidity >= credited | 79402 |
| record live liquidity >= credited after removal | 162 |
| repay with collateral: conversion covers the flash loan (SPEC-LIQ-020) | 31 |
| repay-all leaves no allowance (refund of the unused pull, REP-009) | 730 |
| rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026) | 15 |
| rescue units <= credited per record | 80674 |
| rescue-excluded HF >= 1.00 (or the hard floor) after every borrow (REQ-RISK-068) | 714 |
| rescue-excluded HF >= 1.00 (or the hard floor) after partial removal with debt | 69 |
| routed liquidation meets the recovery floor (R + shortfall >= minOut) | 98 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 79402 |
| waterfall A + Kr + B = Y, each >= 0 (LIQ-031, SPEC-LIQ-022) | 98 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $0, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $62,897 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $3,286,320, DAI/USDC $3,266,892, USDe/USDT $2,333,422 |
| third-party repay service | {'repaid': 6, 'repaid_in_None': 6, 'usd': 146975.48384241018} |

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
| Drifting (feed disagreement) (USDe/USDT, 60.21) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | Y | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_pause)) | Y | N (StalePrice(disagree_pause)) |
| Disagreement beyond disagreementPauseMax (USDe/USDT, 60.25) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | Y | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_expired)) | Y | N (StalePrice(disagree_expired)) |
| Market breaker tripped (USDe/USDT, 66.00) | N (PoolShareExceeded) | N (PoolShareExceeded) | Y | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | N (PriceNotLive(Drifting:band)) | Y | Y | Y |
| Application Frozen (USDC/USDT, 75.10) | N (ApplicationFrozen) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | N (ApplicationFrozen) | Y | Y | Y | Y | Y | Y | Y | Y |
| Application Paused (General) (USDC/USDT, 76.00) | N (CapExceeded(market)) | N (SliceNotAvailable) | Y | N (ApplicationPaused) | Y | Y | Y | N (ApplicationPaused) | N (ApplicationPaused) | N (ApplicationPaused) | Y | Y |
| Alternate past borrowPriceMaxAge (seizure as Cached) (USDC/USDT, 85.06) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | N (PriceTooOld) | N (StalePrice(alt_past_borrow_age)) | Y | N (StalePrice(alt_past_borrow_age)) |
| Live (USDC/USDT, 85.10) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |

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
| monitoring alerts, seizure and route failures (day, market, reason) | none |
| borrowing blocked by a market breaker (hours, from 10-minute samples) | DAI/USDC POOL_SHARE 2.5; DAI/USDC POOL_SHARE,MANUAL 1.0; GHO/USDC POOL_SHARE 45.0; GHO/USDC during gho_premium 45.0; USDC/USDT POOL_SHARE 72.7; USDC/USDT during usdt_depeg 72.7; USDe/USDT POOL_SHARE 72.3; USDe/USDT during usdt_depeg 72.3 |
| caller shortfall top-ups: calls / USD in the debt asset | 55 / $319 |
| flash-funded / caller-funded liquidations; flash premium paid | 98 / 0; $13 |
| keeper reward / borrower surplus (debt asset) | $129 / $0 |
| failed keeper attempts (RecoveryBelowFloor or MinOutNotMet) | 0 |
| Avana fee (oracle value) | $108 |
| rescue: attacker_borrowed_after_first_slice | 13543.823628917453 |
| rescue: attacker_slice_used | 62896.613253804455 |
| rescue: borrowed_after_slice_all | 13543.823628917453 |
| rescue: rescue_excluded_borrow_refusals | 0 |
| rescue: rescue_excluded_refusals_attacker | 0 |
| rescue: rescue_units_booked | 34260.46060098303 |
| rescue: stats | {'refused:PriceNotAccepted': 67, 'sized_to_restore': 10, 'sized_to_restore_below_accepted': 10, 'planned:pool_share+breaker': 10, 'rescue_topups_done': 10, 'rescue_topups_done:pool_share': 10, 'rescue_topups_done:breaker': 10} |
| deleverage | conversion_loss_usd 69.01, done 31, refused:ApplicationPaused 1, refused:MinOutNotMet 118, refused:StalePrice 100, repaid_usd 141113.2 |
| recredit | done 15, liquidity_added 26, refused:BreakerTripped 1, refused:CapExceeded 22, refused:NotRescueTopUp 1, refused:PoolShareExceeded 14, refused:SliceNotAvailable 15, units 47849.4 |
| removal | done 162 |
| exits | repay_all_first_attempt 124 |
| address freeze gates (EMG-070) | new account from a frozen wallet: N (AddressIsFrozen); non-rescue top-up: N (NotRescueTopUp); rescue top-up: Y; non-rescue top-up (probe account): N (NotRescueTopUp); borrow: N (AddressIsFrozen); repay: Y; partial removal with debt: N (AddressIsFrozen); repay with collateral: N (AddressIsFrozen); liquidation of its positions (gate): Y |

### Governance and attacks

- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused(General)
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 40 opened; gas paid $14
- day 3.50: **address freeze of the dust wallets** (40 freezeAddress calls by two guardians): 40 frozen; a 21st freeze by the same guardian within 24 h refused: FreezeRateLimited
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 10.00: **cap squatting** (filler wallet w985f1 pledges $972): regular room of USDC/USDT now $0
- day 10.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.44: **cap squatting** (filler wallet w985f2 pledges $1526): regular room of USDC/USDT now $0
- day 10.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 11.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 11.62: **cap squatting** (filler wallet w985f3 pledges $17342): regular room of USDC/USDT now $0
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 12.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.25: **cap squatting** (filler wallet w985f4 pledges $5164): regular room of USDC/USDT now $0
- day 12.51: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.68: **cap squatting** (filler wallet w985f5 pledges $27055): regular room of USDC/USDT now $0
- day 12.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.87: **cap squatting** (filler wallet w985f6 pledges $5424): regular room of USDC/USDT now $0
- day 15.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.14: **cap squatting** (filler wallet w985f7 pledges $2321): regular room of USDC/USDT now $0
- day 16.31: **cap squatting** (filler wallet w985f8 pledges $3912): regular room of USDC/USDT now $0
- day 16.89: **cap squatting** (filler wallet w985f9 pledges $7720): regular room of USDC/USDT now $0
- day 17.35: **cap squatting** (filler wallet w985f10 pledges $10306): regular room of USDC/USDT now $0
- day 17.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.49: **cap squatting** (filler wallet w985f11 pledges $5261): regular room of USDC/USDT now $0
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
- day 26.68: **cap squatting** (filler wallet w985f12 pledges $2547): regular room of USDC/USDT now $0
- day 26.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 26.81: **cap squatting** (filler wallet w985f13 pledges $3612): regular room of USDC/USDT now $0
- day 27.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.61: **cap squatting** (filler wallet w985f14 pledges $5624): regular room of USDC/USDT now $0
- day 27.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.08: **cap squatting** (filler wallet w985f15 pledges $17371): regular room of USDC/USDT now $0
- day 29.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.83: **cap squatting** (filler wallet w985f16 pledges $12881): regular room of USDC/USDT now $0
- day 29.88: **cap squatting** (filler wallet w985f17 pledges $4084): regular room of USDC/USDT now $0
- day 29.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.96: **cap squatting** (filler wallet w985f18 pledges $1426): regular room of USDC/USDT now $0
- day 30.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.21: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 33.45: **cap squatting** (filler wallet w985f19 pledges $2086): regular room of USDC/USDT now $0
- day 33.70: **cap squatting** (filler wallet w985f20 pledges $4283): regular room of USDC/USDT now $0
- day 33.95: **cap squatting** (filler wallet w985f21 pledges $1476): regular room of USDC/USDT now $0
- day 34.03: **cap squatting** (filler wallet w985f22 pledges $192): regular room of USDC/USDT now $0
- day 35.03: **cap squatting** (filler wallet w985f23 pledges $3783): regular room of USDC/USDT now $0
- day 35.16: **cap squatting** (filler wallet w985f24 pledges $1591): regular room of USDC/USDT now $0
- day 35.33: **cap squatting** (filler wallet w985f25 pledges $2539): regular room of USDC/USDT now $0
- day 36.37: **cap squatting** (filler wallet w985f26 pledges $6453): regular room of USDC/USDT now $0
- day 37.20: **cap squatting** (filler wallet w985f27 pledges $23443): regular room of USDC/USDT now $0
- day 37.41: **cap squatting** (filler wallet w985f28 pledges $3881): regular room of USDC/USDT now $0
- day 37.83: **cap squatting** (filler wallet w985f29 pledges $6523): regular room of USDC/USDT now $0
- day 39.66: **cap squatting** (filler wallet w985f30 pledges $1843): regular room of USDC/USDT now $0
- day 39.74: **cap squatting** (filler wallet w985f31 pledges $3214): regular room of USDC/USDT now $0
- day 41.12: **cap squatting** (filler wallet w985f32 pledges $74755): regular room of USDC/USDT now $0
- day 41.87: **cap squatting** (filler wallet w985f33 pledges $15008): regular room of USDC/USDT now $0
- day 41.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.38: **cap squatting** (filler wallet w985f34 pledges $3935): regular room of USDC/USDT now $0
- day 42.71: **cap squatting** (filler wallet w985f35 pledges $2265): regular room of USDC/USDT now $0
- day 42.92: **cap squatting** (filler wallet w985f36 pledges $1777): regular room of USDC/USDT now $0
- day 43.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.77: **cap squatting** (filler wallet w985f37 pledges $2358): regular room of USDC/USDT now $0
- day 44.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 45.90: **cap squatting** (filler wallet w985f38 pledges $14659): regular room of USDC/USDT now $0
- day 46.15: **cap squatting** (filler wallet w985f39 pledges $12357): regular room of USDC/USDT now $0
- day 46.40: **cap squatting** (filler wallet w985f40 pledges $50893): regular room of USDC/USDT now $0
- day 46.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 46.61: **cap squatting** (filler wallet w985f41 pledges $4443): regular room of USDC/USDT now $0
- day 46.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $695181
- day 47.03: **cap squatting** (filler wallet w985f42 pledges $5950): regular room of USDC/USDT now $0
- day 47.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.29: **cap squatting** (filler wallet w985f43 pledges $2463): regular room of USDC/USDT now $0
- day 48.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.96: **cap squatting** (filler wallet w985f44 pledges $24464): regular room of USDC/USDT now $0
- day 49.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.21: **cap squatting** (filler wallet w985f45 pledges $7828): regular room of USDC/USDT now $0
- day 49.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.34: **cap squatting** (filler wallet w985f46 pledges $1144): regular room of USDC/USDT now $0
- day 49.51: **cap squatting** (filler wallet w985f47 pledges $2859): regular room of USDC/USDT now $0
- day 49.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.36: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.20: **cap squatting** (filler wallet w985f48 pledges $16117): regular room of USDC/USDT now $0
- day 51.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.28: **cap squatting** (filler wallet w985f49 pledges $1586): regular room of USDC/USDT now $0
- day 51.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.58: **cap squatting** (filler wallet w985f50 pledges $63079): regular room of USDC/USDT now $0
- day 51.95: **cap squatting** (filler wallet w985f51 pledges $4089): regular room of USDC/USDT now $0
- day 52.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.38: **cap squatting** (filler wallet w985f52 pledges $1132): regular room of USDC/USDT now $0
- day 52.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.18: **cap squatting** (filler wallet w985f53 pledges $17050): regular room of USDC/USDT now $0
- day 54.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.53: **cap squatting** (filler wallet w985f54 pledges $1410): regular room of USDC/USDT now $0
- day 55.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.13: **cap squatting** (filler wallet w985f55 pledges $4127): regular room of USDC/USDT now $0
- day 57.47: **cap squatting** (filler wallet w985f56 pledges $1244): regular room of USDC/USDT now $0
- day 57.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.27: **cap squatting** (filler wallet w985f57 pledges $1882): regular room of USDC/USDT now $0
- day 58.81: **cap squatting** (filler wallet w985f58 pledges $1198): regular room of USDC/USDT now $0
- day 58.85: **cap squatting** (filler wallet w985f59 pledges $27837): regular room of USDC/USDT now $0
- day 58.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.45: **cap squatting** (filler wallet w985f60 pledges $878): regular room of USDC/USDT now $0
- day 59.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.42: **cap squatting** (filler wallet w985f61 pledges $8480): regular room of USDC/USDT now $0
- day 60.79: **cap squatting** (filler wallet w985f62 pledges $15854): regular room of USDC/USDT now $0
- day 60.83: **cap squatting** (filler wallet w985f63 pledges $16730): regular room of USDC/USDT now $0
- day 61.04: **cap squatting** (filler wallet w985f64 pledges $97): regular room of USDC/USDT now $0
- day 61.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.38: **cap squatting** (filler wallet w985f65 pledges $2642): regular room of USDC/USDT now $0
- day 61.50: **cap squatting** (filler wallet w985f66 pledges $7931): regular room of USDC/USDT now $0
- day 61.55: **cap squatting** (filler wallet w985f67 pledges $137): regular room of USDC/USDT now $0
- day 61.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.77: **cap squatting** (filler wallet w985f68 pledges $5540): regular room of USDC/USDT now $0
- day 62.10: **cap squatting** (filler wallet w985f69 pledges $47148): regular room of USDC/USDT now $0
- day 62.52: **cap squatting** (filler wallet w985f70 pledges $3327): regular room of USDC/USDT now $0
- day 62.64: **cap squatting** (filler wallet w985f71 pledges $9429): regular room of USDC/USDT now $0
- day 62.77: **cap squatting** (filler wallet w985f72 pledges $968): regular room of USDC/USDT now $0
- day 62.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.23: **cap squatting** (filler wallet w985f73 pledges $1261): regular room of USDC/USDT now $0
- day 63.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.57: **cap squatting** (filler wallet w985f74 pledges $23326): regular room of USDC/USDT now $0
- day 63.83: **cap squatting** (filler wallet w985f75 pledges $13459): regular room of USDC/USDT now $0
- day 64.08: **cap squatting** (filler wallet w985f76 pledges $6386): regular room of USDC/USDT now $0
- day 64.12: **cap squatting** (filler wallet w985f77 pledges $7118): regular room of USDC/USDT now $0
- day 64.25: **cap squatting** (filler wallet w985f78 pledges $1110): regular room of USDC/USDT now $0
- day 64.33: **cap squatting** (filler wallet w985f79 pledges $1737): regular room of USDC/USDT now $0
- day 64.38: **cap squatting** (filler wallet w985f80 pledges $13772): regular room of USDC/USDT now $0
- day 64.58: **cap squatting** (filler wallet w985f81 pledges $9075): regular room of USDC/USDT now $0
- day 64.62: **cap squatting** (filler wallet w985f82 pledges $5893): regular room of USDC/USDT now $0
- day 64.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.28: **cap squatting** (filler wallet w985f83 pledges $502): regular room of USDC/USDT now $0
- day 66.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.33: **cap squatting** (filler wallet w985f84 pledges $3738): regular room of USDC/USDT now $0
- day 67.58: **cap squatting** (filler wallet w985f85 pledges $7004): regular room of USDC/USDT now $0
- day 67.83: **cap squatting** (filler wallet w985f86 pledges $2914): regular room of USDC/USDT now $0
- day 67.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.09: **cap squatting** (filler wallet w985f87 pledges $727): regular room of USDC/USDT now $0
- day 68.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.17: **cap squatting** (filler wallet w985f88 pledges $2584): regular room of USDC/USDT now $0
- day 68.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.51: **cap squatting** (filler wallet w985f89 pledges $5847): regular room of USDC/USDT now $0
- day 68.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.35: **cap squatting** (filler wallet w985f90 pledges $12129): regular room of USDC/USDT now $0
- day 70.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.50: **cap squatting** (filler wallet w985f91 pledges $6460): regular room of USDC/USDT now $0
- day 70.66: **cap squatting** (filler wallet w985f92 pledges $19194): regular room of USDC/USDT now $0
- day 70.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.92: **cap squatting** (filler wallet w985f93 pledges $34405): regular room of USDC/USDT now $0
- day 70.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.18: **cap squatting** (filler wallet w985f94 pledges $15044): regular room of USDC/USDT now $0
- day 71.39: **cap squatting** (filler wallet w985f95 pledges $5041): regular room of USDC/USDT now $0
- day 71.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.03: **cap squatting** (filler wallet w985f96 pledges $9240): regular room of USDC/USDT now $0
- day 72.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.44: **cap squatting** (filler wallet w985f97 pledges $16394): regular room of USDC/USDT now $0
- day 74.48: **cap squatting** (filler wallet w985f98 pledges $3274): regular room of USDC/USDT now $0
- day 74.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.27: **cap squatting** (filler wallet w985f108 pledges $6996): regular room of USDC/USDT now $0
- day 77.94: **cap squatting** (filler wallet w985f109 pledges $5050): regular room of USDC/USDT now $0
- day 78.40: **cap squatting** (filler wallet w985f110 pledges $4732): regular room of USDC/USDT now $0
- day 78.65: **cap squatting** (filler wallet w985f111 pledges $8862): regular room of USDC/USDT now $0
- day 78.90: **cap squatting** (filler wallet w985f112 pledges $3835): regular room of USDC/USDT now $0
- day 79.56: **cap squatting** (filler wallet w985f113 pledges $1818): regular room of USDC/USDT now $0
- day 79.60: **cap squatting** (filler wallet w985f114 pledges $2254): regular room of USDC/USDT now $0
- day 81.27: **cap squatting** (filler wallet w985f115 pledges $610): regular room of USDC/USDT now $0
- day 81.85: **cap squatting** (filler wallet w985f116 pledges $9784): regular room of USDC/USDT now $0
- day 82.52: **cap squatting** (filler wallet w985f117 pledges $2768): regular room of USDC/USDT now $0
- day 83.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.48: **cap squatting** (filler wallet w985f118 pledges $77470): regular room of USDC/USDT now $0
- day 83.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.98: **cap squatting** (filler wallet w985f119 pledges $155): regular room of USDC/USDT now $0
- day 84.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.45: **cap squatting** (filler wallet w985f120 pledges $3897): regular room of USDC/USDT now $0
- day 84.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.34: **cap squatting** (filler wallet w985f121 pledges $22826): regular room of USDC/USDT now $0
- day 85.59: **cap squatting** (filler wallet w985f122 pledges $48146): regular room of USDC/USDT now $0
- day 85.84: **cap squatting** (filler wallet w985f123 pledges $19223): regular room of USDC/USDT now $0
- day 85.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.05: **cap squatting** (filler wallet w985f124 pledges $3476): regular room of USDC/USDT now $0
- day 86.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.14: **cap squatting** (filler wallet w985f125 pledges $1381): regular room of USDC/USDT now $0
- day 86.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.41: **cap squatting** (filler wallet w985f126 pledges $17968): regular room of USDC/USDT now $0
- day 87.70: **cap squatting** (filler wallet w985f127 pledges $8589): regular room of USDC/USDT now $0
- day 87.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.22: **cap squatting** (filler wallet w985f128 pledges $296): regular room of USDC/USDT now $0
- day 89.47: **cap squatting** (filler wallet w985f129 pledges $6352): regular room of USDC/USDT now $0
