### Personas (seed 20261112, feed profile `spec`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 157 | 113 | 74 | 0 | $7,982 | $33 | $0 | $71 | $0 | 0.85% | 73% | 36 / 35 / 0 |
| active_lp | 120 | 55 | 65 | 26 | 0 | $15,105 | $34 | $0 | $231 | $0 | 2.17% | 100% | 26 / 26 / 0 |
| leveraged | 100 | 48 | 52 | 48 | 3 | $20,879 | $120 | $73 | $252 | $5 | 1.24% | 73% | 25 / 25 / 0 |
| small | 120 | 37 | 83 | 24 | 2 | $223 | $1 | $0 | $90 | $2 | 42.33% | 100% | 10 / 9 / 0 |
| whale | 20 | 14 | 6 | 12 | 0 | $696,880 | $3,175 | $1,298 | $256 | $0 | 0.04% | 0% | 4 / 4 / 0 |
| multi_market | 85 | 78 | 5 | 71 | 0 | $19,533 | $47 | $23 | $128 | $0 | 0.74% | 82% | 18 / 18 / 0 |
| mobile | 110 | 63 | 47 | 53 | 0 | $4,782 | $16 | $9 | $86 | $0 | 2.24% | 86% | 22 / 22 / 0 |
| forgetful | 90 | 57 | 33 | 50 | 2 | $8,021 | $30 | $27 | $72 | $37 | 1.04% | 77% | 0 / 0 / 0 |
| usdc_borrower | 70 | 43 | 27 | 43 | 0 | $15,328 | $82 | $32 | $98 | $0 | 0.76% | 58% | 16 / 16 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 33 |
| accounts | 31 |
| bonus_paid | $45 |
| debt_repaid | $1,620 |
| deficit | $0 |
| budget_draws | $1 |
| keeper_reimbursement | $24,576 |
| keeper_pnl | $-24,576 |
| searcher_profit | $0 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $24,191 |
| max_gas_usd | $904 |
| dust calls (repay < $100) | 31 |
| by episode | USDe crash 33 |
| by caller/mode | keeper/gho 31, keeper/in_kind 2 |
| by debt asset | GHO 33 |
| by market | USDe/USDT 33 |
| liquidation blocked (account-hours by reason) | RecoveryBelowFloor 21.5 h (5 accounts), StalePrice(disagree_pause) 1.3 h (4 accounts), StalePrice(disagree_expired) 0.7 h (4 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| borrow | `PriceTooOld` | 15 | 14 | $136 |
| borrow | `DeadlineExpired` | 14 | 13 | $131 |
| borrow | `HealthFactorTooLow` | 14 | 7 | $114 |
| pledge | `DeadlineExpired` | 12 | 10 | $241 |
| borrow | `BadNonce` | 9 | 9 | $78 |
| collectFees | `DeadlineExpired` | 8 | 8 | $24 |
| borrow | `Dropped(not mined)` | 5 | 5 | $0 |
| pledge | `Dropped(not mined)` | 5 | 4 | $0 |
| withdraw | `Dropped(not mined)` | 4 | 3 | $0 |
| repay | `DeadlineExpired` | 2 | 1 | $85 |
| pledge | `CapExceeded(market)` | 1 | 1 | $11 |
| collectFees | `Dropped(not mined)` | 1 | 1 | $0 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| pledge | `CapExceeded(market)` | 1220 | 315 |
| borrow | `PriceNotLive(Drifting:band)` | 815 | 11 |
| pledge | `NotFullRange` | 393 | 378 |
| pledge | `PriceNotAccepted(Cached/Expired)` | 103 | 25 |
| pledge | `PoolShareExceeded` | 75 | 67 |
| withdraw(rebalance) | `HealthFactorTooLow` | 63 | 22 |
| pledge | `SliceNotAvailable` | 51 | 9 |
| pledge | `PriceNotAccepted(Drifting)` | 41 | 16 |
| top-up | `PoolShareExceeded` | 27 | 4 |
| borrow | `PriceTooOld` | 21 | 19 |
| borrow | `ApplicationPaused` | 19 | 7 |
| withdraw(rebalance) | `PriceTooOld` | 7 | 7 |
| borrow | `ApplicationFrozen` | 5 | 5 |
| pledge | `ApplicationPaused` | 4 | 1 |
| top-up | `SliceNotAvailable` | 2 | 2 |
| withdraw(rebalance) | `ApplicationPaused` | 2 | 2 |
| pledge | `BelowMinPledge` | 1 | 1 |
| pledge(loop) | `SliceNotAvailable` | 1 | 1 |
| pledge | `CapExceeded(depositor)` | 1 | 1 |
| withdraw(rebalance) | `PriceNotLive(Cached/Expired)` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | concentrated_rejected | 378 | 393 | app (now), contracts (later) |
| 2 | cap_full | 325 | 1273 | app + governance |
| 3 | low_ltv | 255 | 255 | app + risk |
| 4 | fees_manual | 86 | 152 | app (contracts optional) |
| 5 | gas_exceeds_value | 76 | 76 | app + parameter |
| 6 | whole_nft_withdraw | 52 | 134 | contracts |
| 7 | borrow_blocked_price | 41 | 847 | spec parameter + app |
| 8 | deadline_expired | 30 | 36 | app |
| 9 | exit_needs_external_funds | 15 | 15 | contracts |
| 10 | donation_not_credited | 13 | 18 | contracts + app |
| 11 | tx_dropped | 13 | 15 | app |
| 12 | bad_nonce | 9 | 9 | app |
| 13 | liquidated | 8 | 33 | app |
| 14 | max_borrow_reverted | 7 | 14 | app (+ spec note) |
| 15 | no_alerts | 6 | 31 | app/services |
| 16 | borrow_blocked_other_market | 5 | 6 | contracts + app |
| 17 | topup_refused_pool_share | 4 | 27 | contracts/spec |
| 18 | topup_refused_slice | 2 | 2 | spec parameter + app |
| 19 | band_blocked_gho_premium | 1 | 2 | contracts/spec |
| 20 | below_min | 1 | 1 | app |
| 21 | depositor_cap_split | 1 | 1 | governance |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| donated liquidity sitting uncredited in pledged NFTs (USD) | $68,544 | 4 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 48 |
| uncollected fees in the vault (claimable at any time) | $14,721 | 391 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age |
|---|---|---|---|
| USDC/USDT | 94.5% | 1.1% | 4.4% |
| GHO/USDC | 93.8% | 2.0% | 4.2% |
| DAI/USDC | 95.8% | 0.0% | 4.2% |
| USDe/USDT | 62.7% | 34.4% | 2.9% |
| USDC debt feed | 97.8% | 0.0% | 2.2% |

### Invariants

395878 checks over 15 kinds; violations: none

| Invariant | Checks |
|---|---|
| HF >= 1.10 after every borrow (BOR-POST-003) | 488 |
| HF >= 1.10 after withdraw-with-debt | 9 |
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1029 |
| backing: supply == credited + pending | 364 |
| credited == sum of records | 364 |
| custody iff open record | 60819 |
| debt conservation per account | 101326 |
| fee conservation per NFT | 108790 |
| liquidation GHO conservation | 33 |
| market regular counter <= cap | 364 |
| probe: state gates match the 3.6 emergency matrix | 108 |
| record live liquidity >= credited | 60819 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 60819 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $0, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $40,639 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $1,901,673, DAI/USDC $3,598,865, USDe/USDT $2,777,057 |
| third-party repay service | {} |

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

- day 60.26: governance schedules enableInKind(USDe/USDT) after 1.8 h of RecoveryBelowFloor
- day 60.76: enableInKind(USDe/USDT) executed after the 12 h short delay
- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (dust24): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust25): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust26): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust27): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust28): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust29): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust30): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust31): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust32): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust33): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust34): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust35): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust36): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust37): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust38): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (dust39): pledge refused: CapExceeded(market)
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 24 opened; gas paid $1502
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 10.00: **cap squatting** (filler wallet w985f1 pledges $1447): regular room of USDC/USDT now $0
- day 10.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 11.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 12.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.70: **cap squatting** (filler wallet w985f2 pledges $88963): regular room of USDC/USDT now $0
- day 13.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.01: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.56: **cap squatting** (filler wallet w985f3 pledges $583): regular room of USDC/USDT now $0
- day 15.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.31: **cap squatting** (filler wallet w985f4 pledges $311): regular room of USDC/USDT now $0
- day 15.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.68: **cap squatting** (filler wallet w985f5 pledges $912): regular room of USDC/USDT now $0
- day 17.81: **cap squatting** (filler wallet w985f6 pledges $4935): regular room of USDC/USDT now $0
- day 18.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.60: **cap squatting** (filler wallet w985f7 pledges $5817): regular room of USDC/USDT now $0
- day 19.19: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.23: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.27: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.31: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.35: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.40: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.44: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.48: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.52: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.56: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 22.65: **cap squatting** (filler wallet w985f8 pledges $23586): regular room of USDC/USDT now $0
- day 25.77: **cap squatting** (filler wallet w985f9 pledges $2099): regular room of USDC/USDT now $0
- day 25.86: **cap squatting** (filler wallet w985f10 pledges $5402): regular room of USDC/USDT now $0
- day 26.44: **cap squatting** (filler wallet w985f11 pledges $2721): regular room of USDC/USDT now $0
- day 26.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.03: **cap squatting** (filler wallet w985f12 pledges $2782): regular room of USDC/USDT now $0
- day 27.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.00: **cap squatting** (filler wallet w985f13 pledges $31242): regular room of USDC/USDT now $0
- day 28.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.46: **cap squatting** (filler wallet w985f14 pledges $602): regular room of USDC/USDT now $0
- day 28.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.52: **cap squatting** (filler wallet w985f15 pledges $833): regular room of USDC/USDT now $0
- day 29.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.16: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.20: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.25: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.29: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.33: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.37: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.41: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.45: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.50: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.54: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.58: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.25: **cap squatting** (filler wallet w985f79 pledges $87113): regular room of USDC/USDT now $0
- day 33.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 34.25: **cap squatting** (filler wallet w985f80 pledges $12066): regular room of USDC/USDT now $0
- day 34.50: **cap squatting** (filler wallet w985f81 pledges $33034): regular room of USDC/USDT now $0
- day 34.62: **cap squatting** (filler wallet w985f82 pledges $22044): regular room of USDC/USDT now $0
- day 35.12: **cap squatting** (filler wallet w985f83 pledges $9540): regular room of USDC/USDT now $0
- day 35.38: **cap squatting** (filler wallet w985f84 pledges $1472): regular room of USDC/USDT now $0
- day 35.50: **cap squatting** (filler wallet w985f85 pledges $6097): regular room of USDC/USDT now $0
- day 36.25: **cap squatting** (filler wallet w985f86 pledges $734997): regular room of USDC/USDT now $0
- day 36.83: **cap squatting** (filler wallet w985f87 pledges $4814): regular room of USDC/USDT now $0
- day 38.17: **cap squatting** (filler wallet w985f88 pledges $2471): regular room of USDC/USDT now $0
- day 38.25: **cap squatting** (filler wallet w985f89 pledges $7378): regular room of USDC/USDT now $0
- day 38.54: **cap squatting** (filler wallet w985f90 pledges $826): regular room of USDC/USDT now $0
- day 39.12: **cap squatting** (filler wallet w985f91 pledges $4897): regular room of USDC/USDT now $0
- day 39.54: **cap squatting** (filler wallet w985f92 pledges $274): regular room of USDC/USDT now $0
- day 39.79: **cap squatting** (filler wallet w985f93 pledges $30588): regular room of USDC/USDT now $0
- day 40.04: **cap squatting** (filler wallet w985f94 pledges $2920): regular room of USDC/USDT now $0
- day 40.29: **cap squatting** (filler wallet w985f95 pledges $2530): regular room of USDC/USDT now $0
- day 42.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.76: **cap squatting** (filler wallet w985f96 pledges $1095): regular room of USDC/USDT now $0
- day 43.26: **cap squatting** (filler wallet w985f97 pledges $7568): regular room of USDC/USDT now $0
- day 43.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.94: **cap squatting** (filler wallet w985f98 pledges $1829): regular room of USDC/USDT now $0
- day 44.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.36: **cap squatting** (filler wallet w985f99 pledges $9294): regular room of USDC/USDT now $0
- day 44.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 45.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 45.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 46.04: **cap squatting** (filler wallet w985f100 pledges $113099): regular room of USDC/USDT now $0
- day 46.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $689395
- day 47.05: **cap squatting** (filler wallet w985f101 pledges $11030): regular room of USDC/USDT now $0
- day 47.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.70: **cap squatting** (filler wallet w985f102 pledges $4974): regular room of USDC/USDT now $0
- day 48.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.21: **cap squatting** (filler wallet w985f103 pledges $3264): regular room of USDC/USDT now $0
- day 50.30: **cap squatting** (filler wallet w985f104 pledges $152): regular room of USDC/USDT now $0
- day 50.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.93: **cap squatting** (filler wallet w985f105 pledges $51527): regular room of USDC/USDT now $0
- day 51.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.69: **cap squatting** (filler wallet w985f106 pledges $1276): regular room of USDC/USDT now $0
- day 51.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.57: **cap squatting** (filler wallet w985f107 pledges $94): regular room of USDC/USDT now $0
- day 52.86: **cap squatting** (filler wallet w985f108 pledges $2779): regular room of USDC/USDT now $0
- day 53.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.66: **cap squatting** (filler wallet w985f109 pledges $1214): regular room of USDC/USDT now $0
- day 53.75: **cap squatting** (filler wallet w985f110 pledges $14145): regular room of USDC/USDT now $0
- day 53.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.56: **cap squatting** (filler wallet w985f111 pledges $4165): regular room of USDC/USDT now $0
- day 55.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.33: **cap squatting** (filler wallet w985f112 pledges $2502): regular room of USDC/USDT now $0
- day 57.62: **cap squatting** (filler wallet w985f113 pledges $9697): regular room of USDC/USDT now $0
- day 57.74: **cap squatting** (filler wallet w985f114 pledges $6561): regular room of USDC/USDT now $0
- day 57.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.88: **cap squatting** (filler wallet w985f115 pledges $4056): regular room of USDC/USDT now $0
- day 57.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.99: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.66: **cap squatting** (filler wallet w985f116 pledges $9280): regular room of USDC/USDT now $0
- day 63.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.37: **cap squatting** (filler wallet w985f117 pledges $3609): regular room of USDC/USDT now $0
- day 64.54: **cap squatting** (filler wallet w985f118 pledges $5409): regular room of USDC/USDT now $0
- day 64.58: **cap squatting** (filler wallet w985f119 pledges $6461): regular room of USDC/USDT now $0
- day 64.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.67: **cap squatting** (filler wallet w985f120 pledges $1647): regular room of USDC/USDT now $0
- day 66.22: **cap squatting** (filler wallet w985f121 pledges $1959): regular room of USDC/USDT now $0
- day 66.51: **cap squatting** (filler wallet w985f122 pledges $8667): regular room of USDC/USDT now $0
- day 66.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.05: **cap squatting** (filler wallet w985f123 pledges $313840): regular room of USDC/USDT now $0
- day 67.10: **cap squatting** (filler wallet w985f124 pledges $112401): regular room of USDC/USDT now $0
- day 67.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.36: **cap squatting** (filler wallet w985f125 pledges $30132): regular room of USDC/USDT now $0
- day 67.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.61: **cap squatting** (filler wallet w985f126 pledges $8010): regular room of USDC/USDT now $0
- day 67.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.80: **cap squatting** (filler wallet w985f127 pledges $6815): regular room of USDC/USDT now $0
- day 69.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.04: **cap squatting** (filler wallet w985f128 pledges $20933): regular room of USDC/USDT now $0
- day 71.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.63: **cap squatting** (filler wallet w985f129 pledges $16309): regular room of USDC/USDT now $0
- day 71.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.01: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.28: **cap squatting** (filler wallet w985f130 pledges $6897): regular room of USDC/USDT now $0
- day 74.36: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.33: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.37: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.41: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.45: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.49: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.53: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.58: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.62: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.66: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.70: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.74: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.78: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.83: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.87: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.91: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.95: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.99: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.03: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.08: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.12: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.16: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.20: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 77.28: **cap squatting** (filler wallet w985f156 pledges $56224): regular room of USDC/USDT now $0
- day 77.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.80: **cap squatting** (filler wallet w985f157 pledges $979300): regular room of USDC/USDT now $0
- day 79.05: **cap squatting** (filler wallet w985f158 pledges $13019): regular room of USDC/USDT now $0
- day 79.09: **cap squatting** (filler wallet w985f159 pledges $18944): regular room of USDC/USDT now $0
- day 79.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.60: **cap squatting** (filler wallet w985f160 pledges $105): regular room of USDC/USDT now $0
- day 79.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.36: **cap squatting** (filler wallet w985f161 pledges $16791): regular room of USDC/USDT now $0
- day 81.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.01: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.07: **cap squatting** (filler wallet w985f162 pledges $79252): regular room of USDC/USDT now $0
- day 86.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.66: **cap squatting** (filler wallet w985f163 pledges $6640): regular room of USDC/USDT now $0
- day 87.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.42: **cap squatting** (filler wallet w985f164 pledges $3446): regular room of USDC/USDT now $0
- day 88.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.68: **cap squatting** (filler wallet w985f165 pledges $5146): regular room of USDC/USDT now $0
