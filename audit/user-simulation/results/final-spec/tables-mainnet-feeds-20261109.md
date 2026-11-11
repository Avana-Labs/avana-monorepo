### Personas (seed 20261109, feed profile `mainnet`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 177 | 93 | 29 | 0 | $7,931 | $49 | $0 | $69 | $0 | 0.84% | 62% | 43 / 43 / 0 |
| active_lp | 120 | 65 | 55 | 24 | 0 | $14,503 | $86 | $0 | $243 | $0 | 1.42% | 77% | 26 / 26 / 0 |
| leveraged | 100 | 69 | 31 | 54 | 3 | $18,120 | $131 | $38 | $176 | $64 | 1.03% | 64% | 32 / 32 / 0 |
| small | 120 | 55 | 65 | 7 | 0 | $185 | $1 | $0 | $81 | $0 | 42.68% | 100% | 17 / 17 / 0 |
| whale | 20 | 18 | 2 | 13 | 0 | $490,687 | $2,565 | $444 | $263 | $0 | 0.04% | 0% | 4 / 4 / 0 |
| multi_market | 85 | 71 | 12 | 16 | 1 | $16,978 | $66 | $0 | $108 | $171 | 0.66% | 66% | 18 / 18 / 0 |
| mobile | 110 | 66 | 44 | 22 | 0 | $4,451 | $32 | $0 | $71 | $0 | 1.39% | 71% | 17 / 17 / 0 |
| forgetful | 90 | 65 | 25 | 3 | 0 | $8,700 | $47 | $0 | $53 | $0 | 0.68% | 54% | 0 / 0 / 0 |
| usdc_borrower | 70 | 44 | 26 | 24 | 0 | $14,135 | $79 | $5 | $73 | $0 | 0.50% | 55% | 19 / 19 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 4 |
| accounts | 4 |
| bonus_paid | $235 |
| debt_repaid | $6,480 |
| deficit | $0 |
| budget_draws | $0 |
| keeper_reimbursement | $2,353 |
| keeper_pnl | $-2,353 |
| searcher_profit | $96 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $0 |
| max_gas_usd | $776 |
| dust calls (repay < $100) | 0 |
| calls on the dust attacker's accounts / on other accounts | 0 / 4 |
| other accounts: calls repaying under $100 / gas / debt repaid / reimbursed / most calls on one account | 0 / $2,362 / $6,480 / $2,353 / 1 |
| liquidations seizing a fresh market while another market of the account was Cached, Expired or disagreeing (Q-247) | 1 |
| by episode | USDe crash 3, GHO/USDC drain 1 |
| by caller/mode | permissionless/gho 1, keeper/gho 3 |
| by debt asset | USDC 1, GHO 3 |
| by market | USDC/USDT 1, USDe/USDT 3 |
| liquidation blocked (account-hours by reason) | StalePrice(Cached/Expired) 263.5 h (48 accounts), StalePrice(disagree_pause) 1.2 h (2 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| pledge | `DeadlineExpired` | 10 | 9 | $239 |
| pledge | `Dropped(not mined)` | 6 | 6 | $0 |
| borrow | `PriceTooOld` | 5 | 5 | $32 |
| withdraw | `DeadlineExpired` | 4 | 4 | $31 |
| collectFees | `DeadlineExpired` | 4 | 4 | $13 |
| removeLiquidity | `DeadlineExpired` | 2 | 2 | $24 |
| borrow | `Dropped(not mined)` | 2 | 1 | $0 |
| borrow | `BadNonce` | 2 | 2 | $8 |
| repayAllAndWithdraw | `Dropped(not mined)` | 2 | 2 | $0 |
| borrow | `DeadlineExpired` | 2 | 2 | $12 |
| repayAllAndWithdraw | `DeadlineExpired` | 2 | 2 | $23 |
| pledge | `CapExceeded(market)` | 1 | 1 | $18 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| borrow | `PriceTooOld` | 53059 | 420 |
| borrow | `PriceNotLive(Drifting:band)` | 6954 | 64 |
| pledge | `CapExceeded(market)` | 1074 | 283 |
| borrow | `PriceNotLive(Drifting:twap)` | 391 | 103 |
| pledge | `NotFullRange` | 385 | 377 |
| borrow | `ApplicationPaused` | 342 | 153 |
| borrow | `DebtPriceTooOld` | 77 | 13 |
| borrow | `PriceNotLive(Drifting:mixed)` | 59 | 14 |
| removeLiquidity(rebalance) | `PriceTooOld` | 48 | 23 |
| pledge | `SliceNotAvailable` | 46 | 10 |
| borrow | `ApplicationFrozen` | 45 | 45 |
| pledge | `PoolShareExceeded` | 43 | 32 |
| recredit | `CapExceeded(market)` | 43 | 10 |
| borrow | `BreakerTripped(POOL_SHARE)` | 36 | 20 |
| repayWithCollateral | `StalePrice(Cached/Expired)` | 28 | 9 |
| borrow | `PriceNotLive(Cached/Expired)` | 26 | 25 |
| borrow | `PriceNotLive(Drifting:disagree)` | 26 | 13 |
| pledge(loop) | `SliceNotAvailable` | 23 | 23 |
| top-up | `PriceNotAccepted(Cached/Expired)` | 22 | 6 |
| pledge | `PriceNotAccepted(Drifting)` | 18 | 8 |
| recredit | `SliceNotAvailable` | 14 | 3 |
| pledge | `PriceNotAccepted(Cached/Expired)` | 5 | 5 |
| recredit | `PoolShareExceeded` | 5 | 1 |
| pledge | `CapExceeded(depositor)` | 3 | 3 |
| borrow | `BreakerTripped(MANUAL)` | 3 | 3 |
| top-up | `SliceNotAvailable` | 2 | 2 |
| top-up | `PoolShareExceeded` | 2 | 2 |
| pledge | `NotRescueTopUp` | 2 | 2 |
| pledge | `BelowMinPledge` | 1 | 1 |
| removeLiquidity(rebalance) | `ApplicationPaused` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | borrow_blocked_price | 420 | 60564 | spec parameter + app |
| 2 | concentrated_rejected | 377 | 385 | app (now), contracts (later) |
| 3 | low_ltv | 317 | 317 | app + risk |
| 4 | cap_full | 316 | 1144 | app + governance |
| 5 | gas_exceeds_value | 80 | 80 | app + parameter |
| 6 | fees_manual | 66 | 121 | app (contracts optional) |
| 7 | used_partial_removal | 29 | 69 | outcome |
| 8 | borrow_blocked_other_market | 25 | 78 | contracts + app |
| 9 | partial_removal_refused | 23 | 49 | app |
| 10 | borrow_blocked_breaker | 23 | 39 | app |
| 11 | deadline_expired | 20 | 24 | app |
| 12 | twap_griefed | 19 | 33 | risk ops + app |
| 13 | recredit_refused | 14 | 62 | app |
| 14 | deleverage_refused | 9 | 28 | app |
| 15 | tx_dropped | 9 | 10 | app |
| 16 | used_repay_with_collateral | 7 | 9 | outcome |
| 17 | exit_via_repay_with_collateral | 7 | 7 | outcome |
| 18 | topup_refused_stale | 6 | 22 | app |
| 19 | liquidated | 4 | 4 | app |
| 20 | no_alerts | 4 | 4 | app/services |
| 21 | depositor_cap_split | 3 | 3 | governance |
| 22 | bad_nonce | 2 | 2 | app |
| 23 | topup_refused_slice | 2 | 2 | spec parameter + app |
| 24 | topup_refused_pool_share | 2 | 2 | contracts/spec |
| 25 | below_min | 1 | 1 | app |
| 26 | rescued_by_topup_exemption | 1 | 1 | outcome |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| added liquidity sitting uncredited in pledged NFTs (USD) | $101,202 | 8 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 3 |
| uncollected fees in the vault (claimable at any time) | $32,383 | 455 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age | Blocked by a market breaker |
|---|---|---|---|---|
| USDC/USDT | 0.3% | 0.4% | 99.2% | 0.1% |
| GHO/USDC | 1.6% | 0.1% | 98.3% | 0.0% |
| DAI/USDC | 4.7% | 0.9% | 94.4% | 0.0% |
| USDe/USDT | 0.3% | 33.8% | 65.8% | 0.1% |
| USDC debt price | 4.8% | 0.0% | 95.2% | 0.0% |

### Invariants

474442 checks over 20 kinds; violations: none

| Invariant | Checks |
|---|---|
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1006 |
| address freeze gates match EMG-070 | 5 |
| backing: supply <= credited + pending, equal with a conforming LPVaultSwap (Q-257) | 364 |
| credited == sum of records | 364 |
| custody iff open record | 63267 |
| debt conservation per account | 117016 |
| fee conservation per NFT | 100202 |
| liquidation GHO conservation | 4 |
| market regular counter <= cap | 364 |
| re-credit: record credited == live liquidity | 15 |
| record live liquidity >= credited | 63267 |
| record live liquidity >= credited after removal | 69 |
| repay with collateral: conversion covers the flash loan (SPEC-LIQ-020) | 9 |
| repay-all leaves no allowance (refund of the unused pull, REP-009) | 230 |
| rescue units <= credited per record | 64214 |
| rescue-excluded HF >= 1.10 after every borrow (REQ-RISK-068) | 229 |
| routed liquidation meets the recovery floor (R + shortfall >= minGho) | 4 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 63267 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $0, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $38,118 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $3,477,157, DAI/USDC $3,389,996, USDe/USDT $2,581,413 |
| third-party repay service | {'repaid': 5, 'repaid_in_None': 5, 'usd': 142618.0141173772} |

### Rule probes vs the 3.6 emergency matrix (observed / expected)

| State (market, day) | new | topup | rescue | borrow | repay | collect | wd_free | wd_debt | remove_debt | rwc | repay_all_wd | liq |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Live (skipped: probe account could not borrow) (USDC/USDT, 5.00) | - | - | - | - | - | - | - | - | - | - | - | - |
| GHO premium (skipped: probe account could not borrow) (GHO/USDC, 9.00) | - | - | - | - | - | - | - | - | - | - | - | - |
| USDT routes stalled (skipped: probe account could not borrow) (USDC/USDT, 18.53) | - | - | - | - | - | - | - | - | - | - | - | - |
| USDT routes stalled, standby serving (skipped: probe account could not borrow) (USDC/USDT, 18.75) | - | - | - | - | - | - | - | - | - | - | - | - |
| USDT routes stalled, later (skipped: probe account could not borrow) (USDC/USDT, 19.20) | - | - | - | - | - | - | - | - | - | - | - | - |
| After USDT recovery (skipped: probe account could not borrow) (USDC/USDT, 19.61) | - | - | - | - | - | - | - | - | - | - | - | - |
| DAI routes stalled (skipped: probe account could not borrow) (DAI/USDC, 52.05) | - | - | - | - | - | - | - | - | - | - | - | - |
| DAI Cached (skipped: probe account could not borrow) (DAI/USDC, 52.98) | - | - | - | - | - | - | - | - | - | - | - | - |
| DAI Expired (skipped: probe account could not borrow) (DAI/USDC, 53.03) | - | - | - | - | - | - | - | - | - | - | - | - |
| DAI grace after recovery (skipped: probe account could not borrow) (DAI/USDC, 53.25) | - | - | - | - | - | - | - | - | - | - | - | - |
| Drifting (feed disagreement) (skipped: probe account could not borrow) (USDe/USDT, 60.21) | - | - | - | - | - | - | - | - | - | - | - | - |
| Disagreement beyond disagreementPauseMax (skipped: probe account could not borrow) (USDe/USDT, 60.25) | - | - | - | - | - | - | - | - | - | - | - | - |
| Drifting (USD band breach) (skipped: probe account could not borrow) (USDe/USDT, 66.00) | - | - | - | - | - | - | - | - | - | - | - | - |
| Application Frozen (skipped: probe account could not borrow) (USDC/USDT, 75.10) | - | - | - | - | - | - | - | - | - | - | - | - |
| Application Paused (General) (skipped: probe account could not borrow) (USDC/USDT, 76.00) | - | - | - | - | - | - | - | - | - | - | - | - |
| USDC primary stalled (skipped: probe account could not borrow) (USDC/USDT, 85.06) | - | - | - | - | - | - | - | - | - | - | - | - |
| USDC primary stalled, standby serving (skipped: probe account could not borrow) (USDC/USDT, 85.10) | - | - | - | - | - | - | - | - | - | - | - | - |

### Final-spec features

| Measure | Value |
|---|---|
| standby switches (day, token, slot, call) | 19.02 USDT primary useStandbyRoute; 24.60 USDT primary restorePriceRoute; 52.07 DAI DAI/USDC tripMarketBreaker; 53.96 DAI DAI/USDC resetMarketBreaker |
| tokens listable (every primary leg heartbeat <= 3,600 s) | USDC False, USDT False, DAI True, GHO False, USDe False |
| GHO/USDC Drifting(USD band) during the GHO premium | 0.0 h |
| USDT stall: minutes a USDT market was seizable on a leg older than borrowPriceMaxAge | 709 |
| USDC primary stall: USDC debt borrow gate / repayment gate closed | 360 / 0 min |
| USDC/USDT oracle minutes | drifting_band_min 0, drifting_twap_min 427, disagree_min 63, cached_min 35, expired_min 0, alt_past_borrow_age_min 0 |
| GHO/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 131, disagree_min 0, cached_min 0, expired_min 0, alt_past_borrow_age_min 0 |
| DAI/USDC oracle minutes | drifting_band_min 0, drifting_twap_min 756, disagree_min 0, cached_min 60, expired_min 333, alt_past_borrow_age_min 1340 |
| USDe/USDT oracle minutes | drifting_band_min 43077, drifting_twap_min 1071, disagree_min 137, cached_min 35, expired_min 0, alt_past_borrow_age_min 0 |
| latched breakers (day, market, reason) | none |
| borrowing blocked by a market breaker (hours, from 10-minute samples) | DAI/USDC MANUAL 1.0; GHO/USDC POOL_SHARE 1.0; GHO/USDC during gho_premium 1.0; USDC/USDT POOL_SHARE 1.5; USDC/USDT during usdt_depeg 1.5; USDe/USDT POOL_SHARE 2.0; USDe/USDT during usdt_depeg 2.0 |
| caller shortfall top-ups: calls / GHO | 3 / $42 |
| shortfall reports / automatic in-kind openings | 0 / none |
| Avana fee (oracle value) | $46 |
| rescue: attacker_borrowed_after_first_slice | 0.0 |
| rescue: attacker_slice_used | 38117.664930169 |
| rescue: borrowed_after_slice_all | 0 |
| rescue: rescue_excluded_borrow_refusals | 1 |
| rescue: rescue_excluded_refusals_attacker | 1 |
| rescue: rescue_units_booked | 19563.73108921179 |
| rescue: stats | {'refused:PriceNotAccepted': 22, 'sized_to_restore': 1, 'sized_to_restore_below_accepted': 1, 'planned:pool_share+breaker': 1, 'rescue_topups_done': 1, 'rescue_topups_done:pool_share': 1, 'rescue_topups_done:breaker': 1} |
| deleverage | conversion_loss_usd 18.58, done 9, refused:StalePrice 28, repaid_usd 36064.3 |
| recredit | done 15, liquidity_added 30, refused:CapExceeded 43, refused:PoolShareExceeded 5, refused:SliceNotAvailable 14, units 59813.15 |
| removal | done 69, reverted:DeadlineExpired 2 |
| exits | repay_all_first_attempt 42 |
| address freeze gates (EMG-070) | new account from a frozen wallet: N (AddressIsFrozen); non-rescue top-up: N (NotRescueTopUp); rescue top-up: - (the probe account has no debt to restore); non-rescue top-up (probe account): N (BelowMinPledge); borrow: N (AddressIsFrozen); repay: Y; debt-dependent rows: - (the frozen dust wallet has no debt in this run) |

### Governance and attacks

- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused(General)
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 0 opened; gas paid $5296
- day 3.50: **address freeze of the dust wallets** (40 freezeAddress calls by two guardians): 40 frozen; a 21st freeze by the same guardian within 24 h refused: FreezeRateLimited
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 10.00: **cap squatting** (filler wallet w985f1 pledges $1022): regular room of USDC/USDT now $0
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 12.05: **cap squatting** (filler wallet w985f2 pledges $4014): regular room of USDC/USDT now $0
- day 16.21: **cap squatting** (filler wallet w985f3 pledges $2784): regular room of USDC/USDT now $0
- day 16.88: **cap squatting** (filler wallet w985f4 pledges $7720): regular room of USDC/USDT now $0
- day 17.67: **cap squatting** (filler wallet w985f5 pledges $3762): regular room of USDC/USDT now $0
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 20.75: **cap squatting** (filler wallet w985f6 pledges $3236): regular room of USDC/USDT now $0
- day 22.21: **cap squatting** (filler wallet w985f7 pledges $2879): regular room of USDC/USDT now $0
- day 23.71: **cap squatting** (filler wallet w985f8 pledges $17653): regular room of USDC/USDT now $0
- day 24.38: **cap squatting** (filler wallet w985f9 pledges $13483): regular room of USDC/USDT now $0
- day 27.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.21: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.51: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.99: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.36: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.54: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 31.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 31.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 31.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 31.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 34.07: **cap squatting** (filler wallet w985f10 pledges $13398): regular room of USDC/USDT now $0
- day 35.02: **cap squatting** (filler wallet w985f11 pledges $3626): regular room of USDC/USDT now $0
- day 36.11: **cap squatting** (filler wallet w985f12 pledges $2015): regular room of USDC/USDT now $0
- day 36.98: **cap squatting** (filler wallet w985f13 pledges $23443): regular room of USDC/USDT now $0
- day 37.44: **cap squatting** (filler wallet w985f14 pledges $9438): regular room of USDC/USDT now $0
- day 38.52: **cap squatting** (filler wallet w985f15 pledges $6523): regular room of USDC/USDT now $0
- day 38.57: **cap squatting** (filler wallet w985f16 pledges $9225): regular room of USDC/USDT now $0
- day 38.65: **cap squatting** (filler wallet w985f17 pledges $13150): regular room of USDC/USDT now $0
- day 39.15: **cap squatting** (filler wallet w985f18 pledges $2265): regular room of USDC/USDT now $0
- day 39.19: **cap squatting** (filler wallet w985f19 pledges $12357): regular room of USDC/USDT now $0
- day 40.02: **cap squatting** (filler wallet w985f20 pledges $22022): regular room of USDC/USDT now $0
- day 40.44: **cap squatting** (filler wallet w985f21 pledges $31288): regular room of USDC/USDT now $0
- day 41.44: **cap squatting** (filler wallet w985f22 pledges $15221): regular room of USDC/USDT now $0
- day 41.73: **cap squatting** (filler wallet w985f23 pledges $1967): regular room of USDC/USDT now $0
- day 41.77: **cap squatting** (filler wallet w985f24 pledges $4217): regular room of USDC/USDT now $0
- day 43.32: **cap squatting** (filler wallet w985f25 pledges $74755): regular room of USDC/USDT now $0
- day 43.73: **cap squatting** (filler wallet w985f26 pledges $10588): regular room of USDC/USDT now $0
- day 45.15: **cap squatting** (filler wallet w985f27 pledges $4492): regular room of USDC/USDT now $0
- day 45.73: **cap squatting** (filler wallet w985f28 pledges $13417): regular room of USDC/USDT now $0
- day 46.07: **cap squatting** (filler wallet w985f29 pledges $1232): regular room of USDC/USDT now $0
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $695814
- day 47.82: **cap squatting** (filler wallet w985f30 pledges $9075): regular room of USDC/USDT now $0
- day 48.36: **cap squatting** (filler wallet w985f31 pledges $5358): regular room of USDC/USDT now $0
- day 49.36: **cap squatting** (filler wallet w985f32 pledges $1214): regular room of USDC/USDT now $0
- day 49.48: **cap squatting** (filler wallet w985f33 pledges $6495): regular room of USDC/USDT now $0
- day 50.19: **cap squatting** (filler wallet w985f34 pledges $1249): regular room of USDC/USDT now $0
- day 51.52: **cap squatting** (filler wallet w985f35 pledges $16445): regular room of USDC/USDT now $0
- day 52.48: **cap squatting** (filler wallet w985f36 pledges $4089): regular room of USDC/USDT now $0
- day 53.07: **cap squatting** (filler wallet w985f37 pledges $3596): regular room of USDC/USDT now $0
- day 53.32: **cap squatting** (filler wallet w985f38 pledges $8650): regular room of USDC/USDT now $0
- day 53.94: **cap squatting** (filler wallet w985f39 pledges $17225): regular room of USDC/USDT now $0
- day 54.19: **cap squatting** (filler wallet w985f40 pledges $1146): regular room of USDC/USDT now $0
- day 55.19: **cap squatting** (filler wallet w985f41 pledges $2952): regular room of USDC/USDT now $0
- day 56.61: **cap squatting** (filler wallet w985f42 pledges $4438): regular room of USDC/USDT now $0
- day 57.48: **cap squatting** (filler wallet w985f43 pledges $2539): regular room of USDC/USDT now $0
- day 57.61: **cap squatting** (filler wallet w985f44 pledges $145): regular room of USDC/USDT now $0
- day 58.44: **cap squatting** (filler wallet w985f45 pledges $1198): regular room of USDC/USDT now $0
- day 58.94: **cap squatting** (filler wallet w985f46 pledges $27900): regular room of USDC/USDT now $0
- day 60.27: **cap squatting** (filler wallet w985f47 pledges $32313): regular room of USDC/USDT now $0
- day 60.65: **cap squatting** (filler wallet w985f48 pledges $17019): regular room of USDC/USDT now $0
- day 60.82: **cap squatting** (filler wallet w985f49 pledges $15854): regular room of USDC/USDT now $0
- day 61.40: **cap squatting** (filler wallet w985f50 pledges $137): regular room of USDC/USDT now $0
- day 62.36: **cap squatting** (filler wallet w985f51 pledges $5875): regular room of USDC/USDT now $0
- day 62.65: **cap squatting** (filler wallet w985f52 pledges $23654): regular room of USDC/USDT now $0
- day 62.82: **cap squatting** (filler wallet w985f53 pledges $9429): regular room of USDC/USDT now $0
- day 62.90: **cap squatting** (filler wallet w985f54 pledges $7931): regular room of USDC/USDT now $0
- day 63.07: **cap squatting** (filler wallet w985f55 pledges $15397): regular room of USDC/USDT now $0
- day 63.19: **cap squatting** (filler wallet w985f56 pledges $20889): regular room of USDC/USDT now $0
- day 63.94: **cap squatting** (filler wallet w985f57 pledges $6055): regular room of USDC/USDT now $0
- day 64.11: **cap squatting** (filler wallet w985f58 pledges $11): regular room of USDC/USDT now $0
- day 65.44: **cap squatting** (filler wallet w985f59 pledges $5404): regular room of USDC/USDT now $0
- day 66.40: **cap squatting** (filler wallet w985f60 pledges $10990): regular room of USDC/USDT now $0
- day 67.03: **cap squatting** (filler wallet w985f61 pledges $6887): regular room of USDC/USDT now $0
- day 68.03: **cap squatting** (filler wallet w985f62 pledges $6352): regular room of USDC/USDT now $0
- day 68.32: **cap squatting** (filler wallet w985f63 pledges $12161): regular room of USDC/USDT now $0
- day 69.36: **cap squatting** (filler wallet w985f64 pledges $50): regular room of USDC/USDT now $0
- day 69.61: **cap squatting** (filler wallet w985f65 pledges $53625): regular room of USDC/USDT now $0
- day 70.69: **cap squatting** (filler wallet w985f66 pledges $9180): regular room of USDC/USDT now $0
- day 70.82: **cap squatting** (filler wallet w985f67 pledges $6631): regular room of USDC/USDT now $0
- day 70.94: **cap squatting** (filler wallet w985f68 pledges $2735): regular room of USDC/USDT now $0
- day 72.19: **cap squatting** (filler wallet w985f69 pledges $1586): regular room of USDC/USDT now $0
- day 72.32: **cap squatting** (filler wallet w985f70 pledges $9309): regular room of USDC/USDT now $0
- day 73.73: **cap squatting** (filler wallet w985f71 pledges $4238): regular room of USDC/USDT now $0
- day 74.53: **cap squatting** (filler wallet w985f72 pledges $16806): regular room of USDC/USDT now $0
- day 77.28: **cap squatting** (filler wallet w985f122 pledges $11569): regular room of USDC/USDT now $0
- day 77.32: **cap squatting** (filler wallet w985f123 pledges $8462): regular room of USDC/USDT now $0
- day 77.40: **cap squatting** (filler wallet w985f124 pledges $13594): regular room of USDC/USDT now $0
- day 79.32: **cap squatting** (filler wallet w985f125 pledges $2254): regular room of USDC/USDT now $0
- day 80.07: **cap squatting** (filler wallet w985f126 pledges $37476): regular room of USDC/USDT now $0
- day 81.23: **cap squatting** (filler wallet w985f127 pledges $2768): regular room of USDC/USDT now $0
- day 81.36: **cap squatting** (filler wallet w985f128 pledges $9784): regular room of USDC/USDT now $0
- day 83.86: **cap squatting** (filler wallet w985f129 pledges $579728): regular room of USDC/USDT now $0
- day 84.19: **cap squatting** (filler wallet w985f130 pledges $3113): regular room of USDC/USDT now $0
- day 84.36: **cap squatting** (filler wallet w985f131 pledges $71158): regular room of USDC/USDT now $0
- day 84.40: **cap squatting** (filler wallet w985f132 pledges $10306): regular room of USDC/USDT now $0
- day 84.78: **cap squatting** (filler wallet w985f133 pledges $77486): regular room of USDC/USDT now $0
- day 85.32: **cap squatting** (filler wallet w985f134 pledges $38526): regular room of USDC/USDT now $0
- day 85.73: **cap squatting** (filler wallet w985f135 pledges $5923): regular room of USDC/USDT now $0
- day 85.82: **cap squatting** (filler wallet w985f136 pledges $2633): regular room of USDC/USDT now $0
- day 86.61: **cap squatting** (filler wallet w985f137 pledges $13835): regular room of USDC/USDT now $0
- day 87.32: **cap squatting** (filler wallet w985f138 pledges $8589): regular room of USDC/USDT now $0
- day 88.40: **cap squatting** (filler wallet w985f139 pledges $3783): regular room of USDC/USDT now $0
