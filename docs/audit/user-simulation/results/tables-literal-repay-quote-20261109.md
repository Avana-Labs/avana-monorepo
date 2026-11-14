### Personas (seed 20261109, feed profile `spec`, repay quote `literal`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 171 | 99 | 88 | 0 | $7,445 | $44 | $2 | $84 | $0 | 1.08% | 72% | 37 / 37 / 0 |
| active_lp | 120 | 63 | 58 | 33 | 1 | $13,917 | $54 | $8 | $271 | $6 | 1.94% | 92% | 21 / 21 / 0 |
| leveraged | 100 | 71 | 29 | 70 | 5 | $16,309 | $171 | $49 | $378 | $24 | 2.08% | 80% | 34 / 34 / 0 |
| small | 120 | 49 | 71 | 24 | 2 | $185 | $1 | $0 | $81 | $0 | 47.51% | 100% | 12 / 12 / 0 |
| whale | 20 | 18 | 1 | 15 | 0 | $479,896 | $2,700 | $874 | $247 | $0 | 0.05% | 0% | 3 / 3 / 0 |
| multi_market | 85 | 79 | 6 | 66 | 1 | $18,682 | $83 | $22 | $152 | $4 | 0.77% | 71% | 19 / 18 / 0 |
| mobile | 110 | 66 | 44 | 42 | 2 | $4,641 | $32 | $8 | $87 | $27 | 1.69% | 80% | 16 / 16 / 0 |
| forgetful | 90 | 58 | 32 | 53 | 15 | $9,522 | $57 | $28 | $67 | $233 | 0.76% | 57% | 0 / 0 / 0 |
| usdc_borrower | 70 | 47 | 23 | 47 | 3 | $14,285 | $90 | $34 | $152 | $17 | 0.99% | 72% | 19 / 19 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 161 |
| accounts | 69 |
| bonus_paid | $314 |
| debt_repaid | $12,966 |
| deficit | $0 |
| budget_draws | $28 |
| keeper_reimbursement | $111,089 |
| keeper_pnl | $-111,089 |
| searcher_profit | $0 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $108,836 |
| max_gas_usd | $904 |
| dust calls (repay < $100) | 145 |
| by episode | USDe crash 152, pause + USDe aftershock 9 |
| by caller/mode | keeper/gho 154, keeper/in_kind 7 |
| by debt asset | GHO 117, USDC 44 |
| by market | USDe/USDT 161 |
| liquidation blocked (account-hours by reason) | RecoveryBelowFloor 74.2 h (14 accounts), StalePrice(disagree_pause) 3.7 h (6 accounts), StalePrice(disagree_expired) 0.8 h (5 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| repayAllAndWithdraw | `RepayAllAboveCap` | 226 | 113 | $3,764 |
| borrow | `HealthFactorTooLow` | 36 | 18 | $284 |
| borrow | `PriceTooOld` | 18 | 17 | $153 |
| collectFees | `DeadlineExpired` | 12 | 11 | $40 |
| borrow | `DeadlineExpired` | 10 | 10 | $78 |
| pledge | `DeadlineExpired` | 6 | 6 | $151 |
| repayAllAndWithdraw | `DeadlineExpired` | 6 | 4 | $83 |
| pledge | `Dropped(not mined)` | 4 | 4 | $0 |
| borrow | `BadNonce` | 3 | 3 | $28 |
| borrow | `Dropped(not mined)` | 2 | 2 | $0 |
| repayAllAndWithdraw | `Dropped(not mined)` | 2 | 2 | $0 |
| pledge | `CapExceeded(market)` | 1 | 1 | $17 |
| repay | `DeadlineExpired` | 1 | 1 | $38 |
| withdraw | `DeadlineExpired` | 1 | 1 | $11 |
| withdraw | `Dropped(not mined)` | 1 | 1 | $0 |
| collectFees | `Dropped(not mined)` | 1 | 1 | $0 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| borrow | `PriceNotLive(Drifting:band)` | 2653 | 25 |
| pledge | `CapExceeded(market)` | 1054 | 279 |
| pledge | `NotFullRange` | 385 | 377 |
| pledge | `PriceNotAccepted(Cached/Expired)` | 111 | 21 |
| pledge | `ApplicationPaused` | 100 | 5 |
| pledge | `SliceNotAvailable` | 95 | 21 |
| pledge | `PoolShareExceeded` | 90 | 54 |
| borrow | `DrawCapExceeded` | 89 | 46 |
| withdraw(rebalance) | `HealthFactorTooLow` | 67 | 28 |
| borrow | `ApplicationPaused` | 52 | 19 |
| borrow | `PriceTooOld` | 32 | 32 |
| borrow | `ApplicationFrozen` | 15 | 15 |
| pledge | `PriceNotAccepted(Drifting)` | 11 | 6 |
| withdraw(rebalance) | `PriceNotLive(Drifting:band)` | 6 | 6 |
| borrow | `PriceNotLive(Cached/Expired)` | 5 | 2 |
| withdraw(rebalance) | `PriceTooOld` | 4 | 4 |
| pledge | `CapExceeded(depositor)` | 3 | 3 |
| borrow | `HealthFactorTooLow` | 3 | 2 |
| pledge(loop) | `SliceNotAvailable` | 3 | 3 |
| withdraw(rebalance) | `ApplicationPaused` | 3 | 3 |
| top-up | `PoolShareExceeded` | 2 | 2 |
| withdraw(rebalance) | `PriceNotLive(Cached/Expired)` | 1 | 1 |
| borrow | `DebtPriceTooOld` | 1 | 1 |
| top-up | `SliceNotAvailable` | 1 | 1 |
| pledge | `BelowMinPledge` | 1 | 1 |
| top-up | `ApplicationPaused` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | concentrated_rejected | 377 | 385 | app (now), contracts (later) |
| 2 | low_ltv | 307 | 307 | app + risk |
| 3 | cap_full | 302 | 1153 | app + governance |
| 4 | fees_manual | 131 | 244 | app (contracts optional) |
| 5 | repay_short_interest | 113 | 226 | app + spec |
| 6 | gas_exceeds_value | 82 | 82 | app + parameter |
| 7 | borrow_blocked_price | 61 | 2706 | spec parameter + app |
| 8 | whole_nft_withdraw | 61 | 152 | contracts |
| 9 | drawcap_exhausted | 46 | 89 | app + Aave governance |
| 10 | liquidated | 30 | 161 | app |
| 11 | deadline_expired | 29 | 36 | app |
| 12 | donation_not_credited | 29 | 36 | contracts + app |
| 13 | exit_needs_external_funds | 26 | 26 | contracts |
| 14 | max_borrow_reverted | 18 | 36 | app (+ spec note) |
| 15 | no_alerts | 10 | 78 | app/services |
| 16 | tx_dropped | 10 | 10 | app |
| 17 | borrow_blocked_other_market | 6 | 10 | contracts + app |
| 18 | depositor_cap_split | 3 | 3 | governance |
| 19 | bad_nonce | 3 | 3 | app |
| 20 | band_blocked_gho_premium | 2 | 2 | contracts/spec |
| 21 | topup_refused_pool_share | 2 | 2 | contracts/spec |
| 22 | topup_refused_slice | 1 | 1 | spec parameter + app |
| 23 | below_min | 1 | 1 | app |
| 24 | topup_refused_paused | 1 | 1 | contracts/spec + app |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| donated liquidity sitting uncredited in pledged NFTs (USD) | $120,423 | 15 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 48 |
| uncollected fees in the vault (claimable at any time) | $22,106 | 453 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age |
|---|---|---|---|
| USDC/USDT | 94.1% | 1.1% | 4.8% |
| GHO/USDC | 93.6% | 2.0% | 4.3% |
| DAI/USDC | 95.3% | 0.0% | 4.7% |
| USDe/USDT | 62.7% | 34.4% | 2.9% |
| USDC debt feed | 97.5% | 0.0% | 2.5% |

### Invariants

437404 checks over 15 kinds; violations: none

| Invariant | Checks |
|---|---|
| HF >= 1.10 after every borrow (BOR-POST-003) | 569 |
| HF >= 1.10 after withdraw-with-debt | 5 |
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1124 |
| backing: supply == credited + pending | 364 |
| credited == sum of records | 364 |
| custody iff open record | 69264 |
| debt conservation per account | 114736 |
| fee conservation per NFT | 111271 |
| liquidation GHO conservation | 161 |
| market regular counter <= cap | 364 |
| probe: state gates match the 3.6 emergency matrix | 108 |
| record live liquidity >= credited | 69264 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 69264 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $378, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $35,898 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $3,508,445, DAI/USDC $3,390,108, USDe/USDT $2,373,743 |
| third-party repay service | {'repaid': 1, 'repaid_in_None': 1, 'usd': 310.0881791288698} |

### Rule probes vs the 3.6 emergency matrix (observed / expected)

| State (market, day) | new | topup | borrow | repay | collect | wd_free | wd_debt | repay_all_wd | liq |
|---|---|---|---|---|---|---|---|---|---|
| Live (USDC/USDT, 5.00) | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Drifting (USD band breach) (GHO/USDC, 9.00) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | Y | Y |
| Live on frozen alternate, then Drifting (TWAP) (USDC/USDT, 18.75) | N (PriceNotAccepted(Drifting)) | Y | N (PriceNotLive(Drifting:twap)) | Y | Y | Y | N (PriceNotLive(Drifting:twap)) | Y | Y |
| Cached (USDC/USDT, 18.90) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Expired (USDC/USDT, 19.20) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotAccepted(Cached/Expired)) | N (PriceNotLive(Cached/Expired)) | Y | Y | Y | N (PriceNotLive(Cached/Expired)) | Y | N (StalePrice(Cached/Expired)) |
| Grace after recovery (USDC/USDT, 19.61) | Y | Y | Y | Y | Y | Y | Y | Y | N (GraceHealthFactor) |
| Drifting (feed disagreement) (USDe/USDT, 60.21) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | Y | N (StalePrice(disagree_pause)) |
| Disagreement beyond disagreementPauseMax (USDe/USDT, 60.25) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | Y | N (StalePrice(disagree_expired)) |
| Drifting (USD band breach) (USDe/USDT, 66.00) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | Y | Y |
| Application Frozen (USDC/USDT, 75.10) | N (ApplicationFrozen) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (ApplicationFrozen) | Y | Y | Y | Y | Y | Y |
| Application Paused (USDC/USDT, 76.00) | N (ApplicationPaused) | N (ApplicationPaused) | N (ApplicationPaused) | Y | Y | Y | N (ApplicationPaused) | Y | Y |
| USDC debt feed stale (collateral Live on alternate) (USDC/USDT, 85.10) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | Y | N (DebtPriceStale) |

### Governance and attacks

- day 60.26: governance schedules enableInKind(USDe/USDT) after 2.0 h of RecoveryBelowFloor
- day 60.76: enableInKind(USDe/USDT) executed after the 12 h short delay
- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 40 opened; gas paid $2750
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 10.00: **cap squatting** (filler wallet w985f1 pledges $277): regular room of USDC/USDT now $0
- day 10.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 10.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 11.41: **cap squatting** (filler wallet w985f2 pledges $3062): regular room of USDC/USDT now $0
- day 11.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 12.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.42: **cap squatting** (filler wallet w985f3 pledges $10549): regular room of USDC/USDT now $0
- day 12.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 12.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.17: **cap squatting** (filler wallet w985f4 pledges $24851): regular room of USDC/USDT now $0
- day 17.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.05: **cap squatting** (filler wallet w985f5 pledges $12845): regular room of USDC/USDT now $0
- day 18.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.63: **cap squatting** (filler wallet w985f28 pledges $19283): regular room of USDC/USDT now $0
- day 19.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 27.18: **cap squatting** (filler wallet w985f29 pledges $428): regular room of USDC/USDT now $0
- day 27.80: **cap squatting** (filler wallet w985f30 pledges $30247): regular room of USDC/USDT now $0
- day 28.68: **cap squatting** (filler wallet w985f31 pledges $21745): regular room of USDC/USDT now $0
- day 30.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.15: **slice re-leverage** (top-up): refused: PoolShareExceeded
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
- day 31.82: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.86: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.90: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.94: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.98: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.02: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.07: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.11: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.15: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.19: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.23: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.27: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.32: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.36: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.40: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.44: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.48: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.52: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.57: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.61: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.65: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.69: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.73: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.77: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.82: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.86: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.90: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.94: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.98: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.02: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.07: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.11: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.15: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 34.11: **cap squatting** (filler wallet w985f32 pledges $1213): regular room of USDC/USDT now $0
- day 35.20: **cap squatting** (filler wallet w985f33 pledges $1519): regular room of USDC/USDT now $0
- day 35.49: **cap squatting** (filler wallet w985f34 pledges $15183): regular room of USDC/USDT now $0
- day 35.74: **cap squatting** (filler wallet w985f35 pledges $4304): regular room of USDC/USDT now $0
- day 35.99: **cap squatting** (filler wallet w985f36 pledges $1367): regular room of USDC/USDT now $0
- day 36.53: **cap squatting** (filler wallet w985f37 pledges $23443): regular room of USDC/USDT now $0
- day 36.90: **cap squatting** (filler wallet w985f38 pledges $2044): regular room of USDC/USDT now $0
- day 38.11: **cap squatting** (filler wallet w985f39 pledges $34354): regular room of USDC/USDT now $0
- day 40.49: **cap squatting** (filler wallet w985f40 pledges $17164): regular room of USDC/USDT now $0
- day 40.99: **cap squatting** (filler wallet w985f41 pledges $9279): regular room of USDC/USDT now $0
- day 41.53: **cap squatting** (filler wallet w985f42 pledges $4888): regular room of USDC/USDT now $0
- day 41.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.53: **cap squatting** (filler wallet w985f43 pledges $68537): regular room of USDC/USDT now $0
- day 42.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.51: **cap squatting** (filler wallet w985f44 pledges $10189): regular room of USDC/USDT now $0
- day 44.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 46.44: **cap squatting** (filler wallet w985f45 pledges $50503): regular room of USDC/USDT now $0
- day 46.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 46.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $695507
- day 47.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.45: **cap squatting** (filler wallet w985f46 pledges $4329): regular room of USDC/USDT now $0
- day 47.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.95: **cap squatting** (filler wallet w985f47 pledges $671): regular room of USDC/USDT now $0
- day 51.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.33: **cap squatting** (filler wallet w985f48 pledges $16385): regular room of USDC/USDT now $0
- day 51.37: **cap squatting** (filler wallet w985f49 pledges $847): regular room of USDC/USDT now $0
- day 51.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.12: **cap squatting** (filler wallet w985f50 pledges $991): regular room of USDC/USDT now $0
- day 52.55: **cap squatting** (filler wallet w985f51 pledges $4068): regular room of USDC/USDT now $0
- day 53.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.39: **cap squatting** (filler wallet w985f52 pledges $17075): regular room of USDC/USDT now $0
- day 54.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.86: **cap squatting** (filler wallet w985f53 pledges $874): regular room of USDC/USDT now $0
- day 55.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.70: **cap squatting** (filler wallet w985f54 pledges $4277): regular room of USDC/USDT now $0
- day 55.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.36: **cap squatting** (filler wallet w985f55 pledges $27127): regular room of USDC/USDT now $0
- day 59.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.71: **cap squatting** (filler wallet w985f56 pledges $32284): regular room of USDC/USDT now $0
- day 61.12: **cap squatting** (filler wallet w985f57 pledges $5885): regular room of USDC/USDT now $0
- day 61.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.21: **cap squatting** (filler wallet w985f58 pledges $16657): regular room of USDC/USDT now $0
- day 61.34: **cap squatting** (filler wallet w985f59 pledges $15854): regular room of USDC/USDT now $0
- day 61.46: **cap squatting** (filler wallet w985f60 pledges $289): regular room of USDC/USDT now $0
- day 61.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.14: **cap squatting** (filler wallet w985f61 pledges $7604): regular room of USDC/USDT now $0
- day 62.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.10: **cap squatting** (filler wallet w985f62 pledges $9345): regular room of USDC/USDT now $0
- day 63.23: **cap squatting** (filler wallet w985f63 pledges $4753): regular room of USDC/USDT now $0
- day 63.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.95: **cap squatting** (filler wallet w985f64 pledges $15172): regular room of USDC/USDT now $0
- day 64.29: **cap squatting** (filler wallet w985f65 pledges $23630): regular room of USDC/USDT now $0
- day 64.54: **cap squatting** (filler wallet w985f66 pledges $6411): regular room of USDC/USDT now $0
- day 64.79: **cap squatting** (filler wallet w985f67 pledges $1737): regular room of USDC/USDT now $0
- day 64.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.40: **cap squatting** (filler wallet w985f68 pledges $346): regular room of USDC/USDT now $0
- day 66.24: **cap squatting** (filler wallet w985f69 pledges $20781): regular room of USDC/USDT now $0
- day 66.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.50: **cap squatting** (filler wallet w985f70 pledges $5832): regular room of USDC/USDT now $0
- day 67.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.33: **cap squatting** (filler wallet w985f71 pledges $17117): regular room of USDC/USDT now $0
- day 67.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.05: **cap squatting** (filler wallet w985f72 pledges $10945): regular room of USDC/USDT now $0
- day 68.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.30: **cap squatting** (filler wallet w985f73 pledges $2901): regular room of USDC/USDT now $0
- day 68.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.55: **cap squatting** (filler wallet w985f74 pledges $587): regular room of USDC/USDT now $0
- day 68.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.18: **cap squatting** (filler wallet w985f75 pledges $8860): regular room of USDC/USDT now $0
- day 71.22: **cap squatting** (filler wallet w985f76 pledges $6631): regular room of USDC/USDT now $0
- day 71.35: **cap squatting** (filler wallet w985f77 pledges $53625): regular room of USDC/USDT now $0
- day 71.60: **cap squatting** (filler wallet w985f78 pledges $15126): regular room of USDC/USDT now $0
- day 71.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.85: **cap squatting** (filler wallet w985f79 pledges $4780): regular room of USDC/USDT now $0
- day 72.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.74: **cap squatting** (filler wallet w985f80 pledges $9194): regular room of USDC/USDT now $0
- day 72.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.35: **cap squatting** (filler wallet w985f81 pledges $16524): regular room of USDC/USDT now $0
- day 74.64: **cap squatting** (filler wallet w985f82 pledges $15455): regular room of USDC/USDT now $0
- day 74.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.28: **cap squatting** (filler wallet w985f134 pledges $5674): regular room of USDC/USDT now $0
- day 77.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.88: **cap squatting** (filler wallet w985f135 pledges $7858): regular room of USDC/USDT now $0
- day 78.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.09: **cap squatting** (filler wallet w985f136 pledges $2030): regular room of USDC/USDT now $0
- day 79.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.67: **cap squatting** (filler wallet w985f137 pledges $13436): regular room of USDC/USDT now $0
- day 79.92: **cap squatting** (filler wallet w985f138 pledges $3854): regular room of USDC/USDT now $0
- day 80.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.43: **cap squatting** (filler wallet w985f139 pledges $404): regular room of USDC/USDT now $0
- day 80.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.21: **cap squatting** (filler wallet w985f140 pledges $9323): regular room of USDC/USDT now $0
- day 82.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.80: **cap squatting** (filler wallet w985f141 pledges $2647): regular room of USDC/USDT now $0
- day 83.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.84: **cap squatting** (filler wallet w985f142 pledges $38062): regular room of USDC/USDT now $0
- day 85.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.05: **cap squatting** (filler wallet w985f143 pledges $71053): regular room of USDC/USDT now $0
- day 86.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.27: **cap squatting** (filler wallet w985f144 pledges $19193): regular room of USDC/USDT now $0
- day 86.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.16: **cap squatting** (filler wallet w985f145 pledges $13661): regular room of USDC/USDT now $0
- day 87.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.42: **cap squatting** (filler wallet w985f146 pledges $8380): regular room of USDC/USDT now $0
- day 88.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
