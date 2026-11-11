### Personas (seed 20261112, feed profile `spec`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 160 | 110 | 76 | 0 | $7,647 | $33 | $0 | $72 | $0 | 0.99% | 75% | 37 / 35 / 0 |
| active_lp | 120 | 57 | 63 | 26 | 1 | $15,105 | $36 | $0 | $242 | $7 | 2.04% | 98% | 29 / 29 / 0 |
| leveraged | 100 | 44 | 56 | 44 | 4 | $21,274 | $121 | $79 | $285 | $126 | 1.36% | 68% | 22 / 22 / 0 |
| small | 120 | 39 | 81 | 22 | 3 | $196 | $1 | $0 | $93 | $2 | 49.45% | 100% | 13 / 13 / 0 |
| whale | 20 | 13 | 6 | 11 | 0 | $659,337 | $2,929 | $1,205 | $229 | $0 | 0.05% | 0% | 4 / 5 / 0 |
| multi_market | 85 | 78 | 7 | 72 | 20 | $18,438 | $43 | $20 | $136 | $2,103 | 0.93% | 83% | 17 / 17 / 0 |
| mobile | 110 | 64 | 46 | 55 | 0 | $4,698 | $15 | $8 | $95 | $0 | 2.35% | 86% | 23 / 22 / 0 |
| forgetful | 90 | 58 | 32 | 51 | 2 | $8,071 | $30 | $28 | $72 | $29 | 0.97% | 78% | 0 / 0 / 0 |
| usdc_borrower | 70 | 43 | 27 | 43 | 0 | $15,328 | $82 | $32 | $106 | $0 | 0.79% | 65% | 16 / 16 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 70 |
| accounts | 70 |
| bonus_paid | $2,269 |
| debt_repaid | $49,697 |
| deficit | $0 |
| budget_draws | $1 |
| keeper_reimbursement | $39,511 |
| keeper_pnl | $-38,768 |
| searcher_profit | $291 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $33,379 |
| max_gas_usd | $904 |
| dust calls (repay < $100) | 43 |
| calls on the dust attacker's accounts / on other accounts | 40 / 30 |
| other accounts: calls repaying under $100 / gas / debt repaid / reimbursed / most calls on one account | 3 / $9,032 / $49,598 / $8,461 / 1 |
| liquidations seizing a fresh market while another market of the account was Cached, Expired or disagreeing (Q-247) | 19 |
| by episode | USDe crash 51, GHO/USDC drain 19 |
| by caller/mode | keeper/gho 64, permissionless/gho 6 |
| by debt asset | GHO 64, USDC 6 |
| by market | USDC/USDT 10, GHO/USDC 8, USDe/USDT 52 |
| liquidation blocked (account-hours by reason) | StalePrice(Cached/Expired) 1834.5 h (101 accounts), StalePrice(disagree_pause) 1.0 h (3 accounts), StalePrice(disagree_expired) 0.5 h (3 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| borrow | `DeadlineExpired` | 11 | 9 | $84 |
| pledge | `DeadlineExpired` | 9 | 9 | $218 |
| borrow | `Dropped(not mined)` | 6 | 6 | $0 |
| borrow | `BadNonce` | 5 | 5 | $44 |
| pledge | `Dropped(not mined)` | 4 | 3 | $0 |
| repay | `DeadlineExpired` | 4 | 4 | $24 |
| collectFees | `DeadlineExpired` | 2 | 2 | $6 |
| withdraw | `DeadlineExpired` | 2 | 2 | $16 |
| pledge | `CapExceeded(market)` | 1 | 1 | $22 |
| repayAllAndWithdraw | `DeadlineExpired` | 1 | 1 | $18 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| pledge | `CapExceeded(market)` | 1227 | 315 |
| borrow | `PriceNotLive(Drifting:band)` | 924 | 10 |
| pledge | `NotFullRange` | 393 | 378 |
| repayWithCollateral | `StalePrice(Cached/Expired)` | 220 | 14 |
| top-up | `PriceNotAccepted(Cached/Expired)` | 137 | 15 |
| pledge | `PoolShareExceeded` | 61 | 55 |
| pledge | `SliceNotAvailable` | 42 | 8 |
| removeLiquidity(rebalance) | `HealthFactorTooLow` | 34 | 12 |
| borrow | `ApplicationPaused` | 22 | 7 |
| recredit | `CapExceeded(market)` | 21 | 6 |
| borrow | `BreakerTripped(POOL_SHARE,MANUAL)` | 11 | 11 |
| borrow | `PriceNotLive(Cached/Expired)` | 5 | 5 |
| top-up | `SliceNotAvailable` | 4 | 4 |
| borrow | `ApplicationFrozen` | 4 | 4 |
| borrow | `PriceNotLive(Drifting:mixed)` | 3 | 1 |
| pledge | `NotRescueTopUp` | 3 | 3 |
| borrow | `BreakerTripped(POOL_SHARE)` | 2 | 2 |
| pledge(loop) | `SliceNotAvailable` | 1 | 1 |
| pledge | `CapExceeded(depositor)` | 1 | 1 |
| pledge | `PriceNotAccepted(Drifting)` | 1 | 1 |
| recredit | `PoolShareExceeded` | 1 | 1 |
| recredit | `BreakerTripped(MANUAL)` | 1 | 1 |
| repayWithCollateral | `StalePrice(disagree_pause)` | 1 | 1 |
| top-up | `PoolShareExceeded` | 1 | 1 |
| removeLiquidity(rebalance) | `PriceNotLive(Drifting:band)` | 1 | 1 |
| removeLiquidity(rebalance) | `ApplicationPaused` | 1 | 1 |
| repayWithCollateral | `ApplicationPaused` | 1 | 1 |
| borrow | `PriceTooOld` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | concentrated_rejected | 378 | 393 | app (now), contracts (later) |
| 2 | cap_full | 324 | 1271 | app + governance |
| 3 | low_ltv | 253 | 253 | app + risk |
| 4 | fees_manual | 95 | 158 | app (contracts optional) |
| 5 | gas_exceeds_value | 74 | 74 | app + parameter |
| 6 | used_partial_removal | 42 | 121 | outcome |
| 7 | liquidated | 31 | 70 | app |
| 8 | no_alerts | 28 | 67 | app/services |
| 9 | deadline_expired | 25 | 29 | app |
| 10 | borrow_blocked_price | 16 | 933 | spec parameter + app |
| 11 | deleverage_refused | 15 | 222 | app |
| 12 | topup_refused_stale | 15 | 137 | app |
| 13 | used_repay_with_collateral | 14 | 14 | outcome |
| 14 | partial_removal_refused | 13 | 36 | app |
| 15 | borrow_blocked_breaker | 12 | 13 | app |
| 16 | exit_via_repay_with_collateral | 11 | 11 | outcome |
| 17 | tx_dropped | 9 | 10 | app |
| 18 | recredit_refused | 7 | 23 | app |
| 19 | bad_nonce | 5 | 5 | app |
| 20 | borrow_blocked_other_market | 5 | 5 | contracts + app |
| 21 | topup_refused_slice | 4 | 4 | spec parameter + app |
| 22 | rescued_by_topup_exemption | 2 | 7 | outcome |
| 23 | depositor_cap_split | 1 | 1 | governance |
| 24 | topup_refused_pool_share | 1 | 1 | contracts/spec |
| 25 | exit_needs_external_funds | 1 | 1 | contracts |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| added liquidity sitting uncredited in pledged NFTs (USD) | $8,988 | 3 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 49 |
| uncollected fees in the vault (claimable at any time) | $13,873 | 396 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age | Blocked by a market breaker |
|---|---|---|---|---|
| USDC/USDT | 96.5% | 0.0% | 0.1% | 3.4% |
| GHO/USDC | 97.8% | 0.1% | 0.0% | 2.0% |
| DAI/USDC | 98.5% | 1.0% | 0.4% | 0.1% |
| USDe/USDT | 63.2% | 33.4% | 0.0% | 3.4% |
| USDC debt price | 100.0% | 0.0% | 0.0% | 0.0% |

### Invariants

455373 checks over 23 kinds; violations: {'rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026)': 3}

| Invariant | Checks |
|---|---|
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 958 |
| address freeze gates match EMG-070 | 9 |
| backing: supply <= credited + pending, equal with a conforming LPVaultSwap (Q-257) | 364 |
| credited == sum of records | 364 |
| custody iff open record | 60760 |
| debt conservation per account | 106184 |
| fee conservation per NFT | 101263 |
| liquidation GHO conservation | 70 |
| market regular counter <= cap | 364 |
| probe: state gates match the 3.6 emergency matrix | 189 |
| re-credit: record credited == live liquidity | 14 |
| record live liquidity >= credited | 60760 |
| record live liquidity >= credited after removal | 121 |
| repay with collateral: conversion covers the flash loan (SPEC-LIQ-020) | 14 |
| repay-all leaves no allowance (refund of the unused pull, REP-009) | 306 |
| rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026) | 15 |
| rescue units <= credited per record | 61675 |
| rescue-excluded HF >= 1.10 after every borrow (REQ-RISK-068) | 516 |
| rescue-excluded HF >= 1.10 after partial removal with debt | 51 |
| routed liquidation meets the recovery floor (R + shortfall >= minGho) | 70 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 60760 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $0, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $42,132 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $1,699,267, DAI/USDC $2,598,846, USDe/USDT $2,776,905 |
| third-party repay service | {'repaid': 4, 'repaid_in_None': 4, 'usd': 9586.226346325286} |

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
| Cached (DAI/USDC, 52.41) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | N (StalePrice(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Expired (DAI/USDC, 52.46) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | N (StalePrice(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Grace after recovery, manual breaker still tripped (DAI/USDC, 53.25) | N (PoolShareExceeded) | N (PoolShareExceeded) | Y | N (BreakerTripped(POOL_SHARE,MANUAL)) | Y | Y | Y | N (BreakerTripped(POOL_SHARE,MANUAL)) | N (BreakerTripped(POOL_SHARE,MANUAL)) | Y | Y | N (GraceHealthFactor) |
| Drifting (feed disagreement) (USDe/USDT, 60.21) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_pause)) | Y | N (StalePrice(disagree_pause)) |
| Disagreement beyond disagreementPauseMax (USDe/USDT, 60.25) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | N (PriceNotLive(Drifting:disagree)) | N (StalePrice(disagree_expired)) | Y | N (StalePrice(disagree_expired)) |
| Market breaker tripped (USDe/USDT, 66.00) | N (PoolShareExceeded) | N (PoolShareExceeded) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | N (PriceNotLive(Drifting:band)) | Y | Y | Y |
| Application Frozen (USDC/USDT, 75.10) | N (ApplicationFrozen) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | N (ApplicationFrozen) | Y | Y | Y | Y | Y | Y | Y | Y |
| Application Paused (General) (USDC/USDT, 76.00) | N (NotRescueTopUp) | N (NotRescueTopUp) | Y | N (ApplicationPaused) | Y | Y | Y | N (ApplicationPaused) | N (ApplicationPaused) | N (ApplicationPaused) | Y | Y |
| Live (USDC/USDT, 85.06) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Live (USDC/USDT, 85.10) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y |

### Final-spec features

| Measure | Value |
|---|---|
| standby switches (day, token, slot, call) | 85.05 USDC primary useStandbyRoute; 18.56 USDT primary useStandbyRoute; 24.60 USDT primary restorePriceRoute; 53.25 DAI primary useStandbyRoute; 58.25 DAI primary restorePriceRoute; 52.07 DAI DAI/USDC tripMarketBreaker; 53.29 DAI DAI/USDC resetMarketBreaker |
| tokens listable (every primary leg heartbeat <= 3,600 s) | USDC True, USDT True, DAI True, GHO True, USDe True |
| GHO/USDC Drifting(USD band) during the GHO premium | 0.0 h |
| USDT stall: minutes a USDT market was seizable on a leg older than borrowPriceMaxAge | 0 |
| USDC primary stall: USDC debt borrow gate / repayment gate closed | 38 / 38 min |
| USDC/USDT oracle minutes | drifting_band_min 0, drifting_twap_min 1, disagree_min 63, cached_min 0, expired_min 0, alt_past_borrow_age_min 76 |
| GHO/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 130, disagree_min 0, cached_min 0, expired_min 0, alt_past_borrow_age_min 38 |
| DAI/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 22, disagree_min 0, cached_min 60, expired_min 1154, alt_past_borrow_age_min 556 |
| USDe/USDT oracle minutes | drifting_band_min 43075, drifting_twap_min 690, disagree_min 145, cached_min 0, expired_min 0, alt_past_borrow_age_min 38 |
| latched breakers (day, market, reason) | none |
| borrowing blocked by a market breaker (hours, from 10-minute samples) | DAI/USDC POOL_SHARE 1.5; DAI/USDC POOL_SHARE,MANUAL 1.0; GHO/USDC POOL_SHARE 44.2; GHO/USDC during gho_premium 44.2; USDC/USDT POOL_SHARE 73.8; USDC/USDT during usdt_depeg 73.8; USDe/USDT POOL_SHARE 73.2; USDe/USDT during usdt_depeg 73.2 |
| caller shortfall top-ups: calls / GHO | 8 / $83 |
| shortfall reports / automatic in-kind openings | 0 / none |
| Avana fee (oracle value) | $448 |
| rescue: attacker_borrowed_after_first_slice | 0.0 |
| rescue: attacker_slice_used | 42131.884661540724 |
| rescue: borrowed_after_slice_all | 0 |
| rescue: rescue_excluded_borrow_refusals | 1552 |
| rescue: rescue_excluded_refusals_attacker | 1552 |
| rescue: rescue_units_booked | 22551.904013684285 |
| rescue: stats | {'refused:PriceNotAccepted': 137, 'sized_to_restore': 7, 'sized_to_restore_below_accepted': 7, 'planned:pool_share+breaker': 7, 'rescue_topups_done': 7, 'rescue_topups_done:pool_share': 7, 'rescue_topups_done:breaker': 7} |
| deleverage | conversion_loss_usd 65.16, done 14, refused:ApplicationPaused 1, refused:StalePrice 221, repaid_usd 151693.92 |
| recredit | done 14, liquidity_added 20, refused:BreakerTripped 1, refused:CapExceeded 21, refused:PoolShareExceeded 1, units 64009.42 |
| removal | done 121 |
| exits | repay_all_first_attempt 102 |
| address freeze gates (EMG-070) | new account from a frozen wallet: N (AddressIsFrozen); non-rescue top-up: N (NotRescueTopUp); rescue top-up: Y; non-rescue top-up (probe account): N (NotRescueTopUp); borrow: N (AddressIsFrozen); repay: Y; partial removal with debt: N (AddressIsFrozen); repay with collateral: N (AddressIsFrozen); liquidation of its positions (gate): Y |

### Governance and attacks

- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused(General)
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 40 opened; gas paid $2504
- day 3.50: **address freeze of the dust wallets** (40 freezeAddress calls by two guardians): 40 frozen; a 21st freeze by the same guardian within 24 h refused: FreezeRateLimited
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 10.00: **cap squatting** (filler wallet w985f1 pledges $617273): regular room of USDC/USDT now $0
- day 10.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.09: **cap squatting** (filler wallet w985f2 pledges $1656): regular room of USDC/USDT now $0
- day 10.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 11.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 11.94: **cap squatting** (filler wallet w985f3 pledges $8551): regular room of USDC/USDT now $0
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 12.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.74: **cap squatting** (filler wallet w985f4 pledges $26913): regular room of USDC/USDT now $0
- day 13.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.22: **cap squatting** (filler wallet w985f5 pledges $4162): regular room of USDC/USDT now $0
- day 15.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.70: **cap squatting** (filler wallet w985f6 pledges $7359): regular room of USDC/USDT now $0
- day 15.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.56: **cap squatting** (filler wallet w985f7 pledges $2088): regular room of USDC/USDT now $0
- day 18.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 23.00: **cap squatting** (filler wallet w985f8 pledges $2122): regular room of USDC/USDT now $0
- day 23.25: **cap squatting** (filler wallet w985f9 pledges $1829): regular room of USDC/USDT now $0
- day 23.83: **cap squatting** (filler wallet w985f10 pledges $2873): regular room of USDC/USDT now $0
- day 26.42: **cap squatting** (filler wallet w985f11 pledges $1804): regular room of USDC/USDT now $0
- day 26.50: **cap squatting** (filler wallet w985f12 pledges $6368): regular room of USDC/USDT now $0
- day 29.33: **cap squatting** (filler wallet w985f13 pledges $3224): regular room of USDC/USDT now $0
- day 30.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 33.25: **cap squatting** (filler wallet w985f53 pledges $51055): regular room of USDC/USDT now $0
- day 34.33: **cap squatting** (filler wallet w985f54 pledges $4458): regular room of USDC/USDT now $0
- day 34.41: **cap squatting** (filler wallet w985f55 pledges $3786): regular room of USDC/USDT now $0
- day 34.79: **cap squatting** (filler wallet w985f56 pledges $7302): regular room of USDC/USDT now $0
- day 34.83: **cap squatting** (filler wallet w985f57 pledges $1263): regular room of USDC/USDT now $0
- day 35.04: **cap squatting** (filler wallet w985f58 pledges $13519): regular room of USDC/USDT now $0
- day 35.20: **cap squatting** (filler wallet w985f59 pledges $1620): regular room of USDC/USDT now $0
- day 35.29: **cap squatting** (filler wallet w985f60 pledges $5873): regular room of USDC/USDT now $0
- day 35.33: **cap squatting** (filler wallet w985f61 pledges $1576): regular room of USDC/USDT now $0
- day 35.37: **cap squatting** (filler wallet w985f62 pledges $2345): regular room of USDC/USDT now $0
- day 35.95: **cap squatting** (filler wallet w985f63 pledges $17280): regular room of USDC/USDT now $0
- day 36.20: **cap squatting** (filler wallet w985f64 pledges $1217): regular room of USDC/USDT now $0
- day 36.41: **cap squatting** (filler wallet w985f65 pledges $724865): regular room of USDC/USDT now $0
- day 36.83: **cap squatting** (filler wallet w985f66 pledges $3781): regular room of USDC/USDT now $0
- day 37.41: **cap squatting** (filler wallet w985f67 pledges $4439): regular room of USDC/USDT now $0
- day 38.04: **cap squatting** (filler wallet w985f68 pledges $19150): regular room of USDC/USDT now $0
- day 38.16: **cap squatting** (filler wallet w985f69 pledges $2011): regular room of USDC/USDT now $0
- day 38.41: **cap squatting** (filler wallet w985f70 pledges $1955): regular room of USDC/USDT now $0
- day 38.45: **cap squatting** (filler wallet w985f71 pledges $30): regular room of USDC/USDT now $0
- day 38.66: **cap squatting** (filler wallet w985f72 pledges $5628): regular room of USDC/USDT now $0
- day 39.12: **cap squatting** (filler wallet w985f73 pledges $826): regular room of USDC/USDT now $0
- day 39.95: **cap squatting** (filler wallet w985f74 pledges $18931): regular room of USDC/USDT now $0
- day 40.00: **cap squatting** (filler wallet w985f75 pledges $274): regular room of USDC/USDT now $0
- day 40.62: **cap squatting** (filler wallet w985f76 pledges $9444): regular room of USDC/USDT now $0
- day 40.87: **cap squatting** (filler wallet w985f77 pledges $3974): regular room of USDC/USDT now $0
- day 41.70: **cap squatting** (filler wallet w985f78 pledges $3516): regular room of USDC/USDT now $0
- day 41.87: **cap squatting** (filler wallet w985f79 pledges $7568): regular room of USDC/USDT now $0
- day 43.37: **cap squatting** (filler wallet w985f80 pledges $884): regular room of USDC/USDT now $0
- day 44.04: **cap squatting** (filler wallet w985f81 pledges $547): regular room of USDC/USDT now $0
- day 45.04: **cap squatting** (filler wallet w985f82 pledges $9305): regular room of USDC/USDT now $0
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $688755
- day 47.58: **cap squatting** (filler wallet w985f83 pledges $4115): regular room of USDC/USDT now $0
- day 47.79: **cap squatting** (filler wallet w985f84 pledges $1567): regular room of USDC/USDT now $0
- day 48.08: **cap squatting** (filler wallet w985f85 pledges $113445): regular room of USDC/USDT now $0
- day 48.58: **cap squatting** (filler wallet w985f86 pledges $1469): regular room of USDC/USDT now $0
- day 48.66: **cap squatting** (filler wallet w985f87 pledges $3120): regular room of USDC/USDT now $0
- day 48.79: **cap squatting** (filler wallet w985f88 pledges $3657): regular room of USDC/USDT now $0
- day 49.25: **cap squatting** (filler wallet w985f89 pledges $3370): regular room of USDC/USDT now $0
- day 49.83: **cap squatting** (filler wallet w985f90 pledges $3525): regular room of USDC/USDT now $0
- day 50.83: **cap squatting** (filler wallet w985f91 pledges $297): regular room of USDC/USDT now $0
- day 50.95: **cap squatting** (filler wallet w985f92 pledges $51766): regular room of USDC/USDT now $0
- day 51.58: **cap squatting** (filler wallet w985f93 pledges $7862): regular room of USDC/USDT now $0
- day 52.45: **cap squatting** (filler wallet w985f94 pledges $10359): regular room of USDC/USDT now $0
- day 52.50: **cap squatting** (filler wallet w985f95 pledges $12880): regular room of USDC/USDT now $0
- day 52.54: **cap squatting** (filler wallet w985f96 pledges $2779): regular room of USDC/USDT now $0
- day 53.25: **cap squatting** (filler wallet w985f97 pledges $2461): regular room of USDC/USDT now $0
- day 53.70: **cap squatting** (filler wallet w985f98 pledges $8490): regular room of USDC/USDT now $0
- day 53.87: **cap squatting** (filler wallet w985f99 pledges $1269): regular room of USDC/USDT now $0
- day 54.45: **cap squatting** (filler wallet w985f100 pledges $302): regular room of USDC/USDT now $0
- day 54.87: **cap squatting** (filler wallet w985f101 pledges $4607): regular room of USDC/USDT now $0
- day 55.12: **cap squatting** (filler wallet w985f102 pledges $619): regular room of USDC/USDT now $0
- day 55.50: **cap squatting** (filler wallet w985f103 pledges $5002): regular room of USDC/USDT now $0
- day 55.66: **cap squatting** (filler wallet w985f104 pledges $6009): regular room of USDC/USDT now $0
- day 56.12: **cap squatting** (filler wallet w985f105 pledges $9697): regular room of USDC/USDT now $0
- day 60.70: **cap squatting** (filler wallet w985f106 pledges $2184): regular room of USDC/USDT now $0
- day 63.08: **cap squatting** (filler wallet w985f107 pledges $10442): regular room of USDC/USDT now $0
- day 64.33: **cap squatting** (filler wallet w985f108 pledges $5409): regular room of USDC/USDT now $0
- day 64.50: **cap squatting** (filler wallet w985f109 pledges $1408): regular room of USDC/USDT now $0
- day 65.04: **cap squatting** (filler wallet w985f110 pledges $3783): regular room of USDC/USDT now $0
- day 65.62: **cap squatting** (filler wallet w985f111 pledges $6611): regular room of USDC/USDT now $0
- day 65.66: **cap squatting** (filler wallet w985f112 pledges $1933): regular room of USDC/USDT now $0
- day 66.25: **cap squatting** (filler wallet w985f113 pledges $1959): regular room of USDC/USDT now $0
- day 66.58: **cap squatting** (filler wallet w985f114 pledges $38071): regular room of USDC/USDT now $0
- day 66.83: **cap squatting** (filler wallet w985f115 pledges $74396): regular room of USDC/USDT now $0
- day 67.00: **cap squatting** (filler wallet w985f116 pledges $313908): regular room of USDC/USDT now $0
- day 67.08: **cap squatting** (filler wallet w985f117 pledges $30232): regular room of USDC/USDT now $0
- day 67.33: **cap squatting** (filler wallet w985f118 pledges $8132): regular room of USDC/USDT now $0
- day 67.45: **cap squatting** (filler wallet w985f119 pledges $6018): regular room of USDC/USDT now $0
- day 68.08: **cap squatting** (filler wallet w985f120 pledges $140): regular room of USDC/USDT now $0
- day 68.66: **cap squatting** (filler wallet w985f121 pledges $7009): regular room of USDC/USDT now $0
- day 69.20: **cap squatting** (filler wallet w985f122 pledges $433): regular room of USDC/USDT now $0
- day 70.25: **cap squatting** (filler wallet w985f123 pledges $21394): regular room of USDC/USDT now $0
- day 72.45: **cap squatting** (filler wallet w985f124 pledges $397206): regular room of USDC/USDT now $0
- day 74.16: **cap squatting** (filler wallet w985f125 pledges $7393): regular room of USDC/USDT now $0
- day 77.29: **cap squatting** (filler wallet w985f171 pledges $38885): regular room of USDC/USDT now $0
- day 78.50: **cap squatting** (filler wallet w985f172 pledges $13019): regular room of USDC/USDT now $0
- day 79.12: **cap squatting** (filler wallet w985f173 pledges $149): regular room of USDC/USDT now $0
- day 79.16: **cap squatting** (filler wallet w985f174 pledges $267): regular room of USDC/USDT now $0
- day 79.33: **cap squatting** (filler wallet w985f175 pledges $16936): regular room of USDC/USDT now $0
- day 79.75: **cap squatting** (filler wallet w985f176 pledges $13252): regular room of USDC/USDT now $0
- day 79.83: **cap squatting** (filler wallet w985f177 pledges $4628): regular room of USDC/USDT now $0
- day 82.16: **cap squatting** (filler wallet w985f178 pledges $1028): regular room of USDC/USDT now $0
- day 83.58: **cap squatting** (filler wallet w985f179 pledges $840): regular room of USDC/USDT now $0
- day 85.83: **cap squatting** (filler wallet w985f180 pledges $242): regular room of USDC/USDT now $0
- day 86.12: **cap squatting** (filler wallet w985f181 pledges $80325): regular room of USDC/USDT now $0
- day 86.50: **cap squatting** (filler wallet w985f182 pledges $6640): regular room of USDC/USDT now $0
- day 86.91: **cap squatting** (filler wallet w985f183 pledges $1580): regular room of USDC/USDT now $0
- day 87.20: **cap squatting** (filler wallet w985f184 pledges $3239): regular room of USDC/USDT now $0
- day 87.45: **cap squatting** (filler wallet w985f185 pledges $1723): regular room of USDC/USDT now $0
- day 88.12: **cap squatting** (filler wallet w985f186 pledges $2203): regular room of USDC/USDT now $0
- day 88.87: **cap squatting** (filler wallet w985f187 pledges $6384): regular room of USDC/USDT now $0
