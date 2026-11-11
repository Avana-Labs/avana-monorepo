### Personas (seed 20261113, feed profile `spec`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 152 | 118 | 77 | 0 | $7,936 | $37 | $1 | $78 | $0 | 0.98% | 72% | 41 / 40 / 0 |
| active_lp | 120 | 54 | 66 | 31 | 0 | $13,848 | $57 | $12 | $270 | $0 | 1.88% | 93% | 20 / 20 / 0 |
| leveraged | 100 | 55 | 45 | 55 | 9 | $16,805 | $149 | $52 | $385 | $65 | 2.58% | 82% | 30 / 30 / 0 |
| small | 120 | 46 | 74 | 32 | 0 | $154 | $1 | $0 | $91 | $0 | 61.74% | 100% | 13 / 13 / 0 |
| whale | 20 | 14 | 4 | 10 | 0 | $675,029 | $3,256 | $1,165 | $210 | $0 | 0.04% | 0% | 3 / 4 / 0 |
| multi_market | 85 | 61 | 22 | 58 | 1 | $16,313 | $81 | $28 | $152 | $2 | 0.85% | 72% | 13 / 14 / 0 |
| mobile | 110 | 74 | 36 | 51 | 5 | $3,327 | $20 | $6 | $90 | $35 | 2.18% | 84% | 23 / 23 / 0 |
| forgetful | 90 | 48 | 42 | 43 | 4 | $4,832 | $26 | $15 | $72 | $55 | 1.77% | 79% | 0 / 0 / 0 |
| usdc_borrower | 70 | 41 | 29 | 41 | 1 | $17,808 | $87 | $39 | $122 | $70 | 0.79% | 66% | 17 / 17 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 129 |
| accounts | 60 |
| bonus_paid | $230 |
| debt_repaid | $8,114 |
| deficit | $0 |
| budget_draws | $16 |
| keeper_reimbursement | $97,008 |
| keeper_pnl | $-97,008 |
| searcher_profit | $0 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $89,697 |
| max_gas_usd | $904 |
| dust calls (repay < $100) | 114 |
| by episode | USDe crash 127, pause + USDe aftershock 2 |
| by caller/mode | keeper/gho 124, keeper/in_kind 5 |
| by debt asset | GHO 105, USDC 24 |
| by market | USDe/USDT 129 |
| liquidation blocked (account-hours by reason) | RecoveryBelowFloor 73.8 h (12 accounts), StalePrice(disagree_pause) 4.8 h (6 accounts), StalePrice(disagree_expired) 0.8 h (5 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| borrow | `HealthFactorTooLow` | 20 | 10 | $152 |
| borrow | `PriceTooOld` | 15 | 14 | $123 |
| borrow | `DeadlineExpired` | 12 | 12 | $106 |
| pledge | `DeadlineExpired` | 11 | 10 | $248 |
| borrow | `BadNonce` | 7 | 7 | $48 |
| repayAllAndWithdraw | `DeadlineExpired` | 5 | 4 | $62 |
| pledge | `Dropped(not mined)` | 4 | 4 | $0 |
| borrow | `Dropped(not mined)` | 4 | 3 | $0 |
| collectFees | `DeadlineExpired` | 4 | 4 | $16 |
| withdraw | `Dropped(not mined)` | 2 | 2 | $0 |
| repay | `DeadlineExpired` | 2 | 2 | $45 |
| borrow | `DebtPriceTooOld` | 1 | 1 | $9 |
| repayAllAndWithdraw | `Dropped(not mined)` | 1 | 1 | $0 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| borrow | `PriceNotLive(Drifting:band)` | 2109 | 20 |
| pledge | `CapExceeded(market)` | 1319 | 341 |
| pledge | `NotFullRange` | 401 | 386 |
| pledge | `SliceNotAvailable` | 106 | 21 |
| pledge | `ApplicationPaused` | 85 | 6 |
| withdraw(rebalance) | `HealthFactorTooLow` | 70 | 30 |
| pledge | `PriceNotAccepted(Drifting)` | 68 | 18 |
| borrow | `ApplicationPaused` | 61 | 19 |
| top-up | `PoolShareExceeded` | 33 | 5 |
| pledge | `PriceNotAccepted(Cached/Expired)` | 25 | 21 |
| pledge | `PoolShareExceeded` | 22 | 13 |
| borrow | `ApplicationFrozen` | 17 | 17 |
| borrow | `PriceTooOld` | 16 | 15 |
| withdraw(rebalance) | `PriceTooOld` | 9 | 8 |
| pledge | `CapExceeded(depositor)` | 6 | 6 |
| pledge | `BelowMinPledge` | 3 | 3 |
| borrow | `HealthFactorTooLow` | 3 | 1 |
| withdraw(rebalance) | `PriceNotLive(Drifting:band)` | 3 | 3 |
| pledge | `ApplicationFrozen` | 3 | 1 |
| pledge(loop) | `SliceNotAvailable` | 1 | 1 |
| withdraw(rebalance) | `PriceNotLive(Cached/Expired)` | 1 | 1 |
| top-up | `SliceNotAvailable` | 1 | 1 |
| borrow | `DebtPriceTooOld` | 1 | 1 |
| borrow | `PriceNotLive(Drifting:mixed)` | 1 | 1 |
| withdraw(rebalance) | `ApplicationPaused` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | concentrated_rejected | 386 | 401 | app (now), contracts (later) |
| 2 | cap_full | 361 | 1426 | app + governance |
| 3 | low_ltv | 260 | 260 | app + risk |
| 4 | fees_manual | 112 | 182 | app (contracts optional) |
| 5 | gas_exceeds_value | 88 | 88 | app + parameter |
| 6 | whole_nft_withdraw | 52 | 131 | contracts |
| 7 | borrow_blocked_price | 44 | 2143 | spec parameter + app |
| 8 | deadline_expired | 29 | 34 | app |
| 9 | exit_needs_external_funds | 23 | 23 | contracts |
| 10 | liquidated | 21 | 129 | app |
| 11 | donation_not_credited | 17 | 19 | contracts + app |
| 12 | no_alerts | 14 | 89 | app/services |
| 13 | max_borrow_reverted | 10 | 20 | app (+ spec note) |
| 14 | tx_dropped | 10 | 11 | app |
| 15 | bad_nonce | 7 | 7 | app |
| 16 | depositor_cap_split | 6 | 6 | governance |
| 17 | topup_refused_pool_share | 5 | 33 | contracts/spec |
| 18 | below_min | 3 | 3 | app |
| 19 | liquidated_unable_to_act | 1 | 8 | contracts/spec + app |
| 20 | borrow_blocked_other_market | 1 | 2 | contracts + app |
| 21 | topup_refused_slice | 1 | 1 | spec parameter + app |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| donated liquidity sitting uncredited in pledged NFTs (USD) | $61,314 | 7 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 40 |
| uncollected fees in the vault (claimable at any time) | $17,813 | 381 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age |
|---|---|---|---|
| USDC/USDT | 94.5% | 1.1% | 4.4% |
| GHO/USDC | 93.7% | 2.0% | 4.3% |
| DAI/USDC | 95.7% | 0.0% | 4.3% |
| USDe/USDT | 62.7% | 34.4% | 2.8% |
| USDC debt feed | 97.7% | 0.0% | 2.3% |

### Invariants

400859 checks over 15 kinds; violations: none

| Invariant | Checks |
|---|---|
| HF >= 1.10 after every borrow (BOR-POST-003) | 515 |
| HF >= 1.10 after withdraw-with-debt | 2 |
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1022 |
| backing: supply == credited + pending | 364 |
| credited == sum of records | 364 |
| custody iff open record | 62041 |
| debt conservation per account | 102674 |
| fee conservation per NFT | 108648 |
| liquidation GHO conservation | 129 |
| market regular counter <= cap | 364 |
| probe: state gates match the 3.6 emergency matrix | 108 |
| record live liquidity >= credited | 62041 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 62041 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $525, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $41,681 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $3,688,443, DAI/USDC $2,876,976, USDe/USDT $2,558,717 |
| third-party repay service | {} |

### Rule probes vs the 3.6 emergency matrix (observed / expected)

| State (market, day) | new | topup | borrow | repay | collect | wd_free | wd_debt | repay_all_wd | liq |
|---|---|---|---|---|---|---|---|---|---|
| Live (USDC/USDT, 5.00) | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| Drifting (USD band breach) (GHO/USDC, 9.00) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | Y | Y |
| Live on frozen alternate, then Drifting (TWAP) (USDC/USDT, 18.75) | N (PriceNotAccepted(Drifting)) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:twap)) | Y | Y | Y | N (PriceNotLive(Drifting:twap)) | Y | Y |
| Live on frozen alternate, then Drifting (TWAP) (USDC/USDT, 18.90) | N (PriceNotAccepted(Drifting)) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:twap)) | Y | Y | Y | N (PriceNotLive(Drifting:twap)) | Y | Y |
| Live on frozen alternate, then Drifting (TWAP) (USDC/USDT, 19.20) | N (PriceNotAccepted(Drifting)) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:twap)) | Y | Y | Y | N (PriceNotLive(Drifting:twap)) | Y | Y |
| Grace after recovery (USDC/USDT, 19.61) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | Y | Y | Y | Y | Y | Y | N (GraceHealthFactor) |
| Drifting (feed disagreement) (USDe/USDT, 60.21) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | Y | N (StalePrice(disagree_pause)) |
| Disagreement beyond disagreementPauseMax (USDe/USDT, 60.25) | N (PriceNotAccepted(Drifting)) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:disagree)) | Y | Y | Y | N (PriceNotLive(Drifting:disagree)) | Y | N (StalePrice(disagree_expired)) |
| Drifting (USD band breach) (USDe/USDT, 66.00) | *N (PoolShareExceeded)* (state allows; refused by a cap) | *N (PoolShareExceeded)* (state allows; refused by a cap) | N (PriceNotLive(Drifting:band)) | Y | Y | Y | N (PriceNotLive(Drifting:band)) | Y | Y |
| Application Frozen (USDC/USDT, 75.10) | N (ApplicationFrozen) | Y | N (ApplicationFrozen) | Y | Y | Y | Y | Y | Y |
| Application Paused (USDC/USDT, 76.00) | N (ApplicationPaused) | N (ApplicationPaused) | N (ApplicationPaused) | Y | Y | Y | N (ApplicationPaused) | Y | Y |
| USDC debt feed stale (collateral Live on alternate) (USDC/USDT, 85.10) | *N (CapExceeded(market))* (state allows; refused by a cap) | *N (SliceNotAvailable)* (state allows; refused by a cap) | N (PriceTooOld) | Y | Y | Y | N (PriceTooOld) | Y | N (DebtPriceStale) |

### Governance and attacks

- day 60.26: governance schedules enableInKind(USDe/USDT) after 1.8 h of RecoveryBelowFloor
- day 60.76: enableInKind(USDe/USDT) executed after the 12 h short delay
- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 40 opened; gas paid $2946
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 13.25: **cap squatting** (filler wallet w985f1 pledges $990000): regular room of USDC/USDT now $507629
- day 13.30: **cap squatting** (filler wallet w985f2 pledges $407203): regular room of USDC/USDT now $0
- day 13.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 13.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.54: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 14.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 15.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 16.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 17.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.03: **cap squatting** (filler wallet w985f3 pledges $14966): regular room of USDC/USDT now $0
- day 18.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 18.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 19.60: **slice re-leverage** (top-up): refused: PriceNotAccepted(Cached/Expired)
- day 19.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 24.23: **cap squatting** (filler wallet w985f4 pledges $4510): regular room of USDC/USDT now $0
- day 25.27: **cap squatting** (filler wallet w985f5 pledges $15796): regular room of USDC/USDT now $0
- day 26.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 26.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 26.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 27.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 28.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 29.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.19: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.23: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.27: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.31: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.35: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.40: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.44: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.48: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.52: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.56: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.60: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.65: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.69: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.73: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.77: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.81: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.85: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.90: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.94: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 30.98: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.02: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.06: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.10: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.15: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.19: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.23: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.27: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.31: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.35: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.40: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.44: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.48: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.52: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.56: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.60: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.65: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.69: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.73: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.77: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.81: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.85: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.90: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.94: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 31.98: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.02: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.06: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.10: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.15: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.19: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.23: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.27: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.31: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.35: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.40: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.44: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.48: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.52: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.56: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.60: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.65: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.69: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.73: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.77: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.81: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.85: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.90: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.94: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 32.98: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.02: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.06: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.10: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.15: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.19: **slice re-leverage** (top-up): refused: PoolShareExceeded
- day 33.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 34.57: **cap squatting** (filler wallet w985f6 pledges $183): regular room of USDC/USDT now $0
- day 36.11: **cap squatting** (filler wallet w985f7 pledges $6945): regular room of USDC/USDT now $0
- day 36.90: **cap squatting** (filler wallet w985f8 pledges $13668): regular room of USDC/USDT now $0
- day 37.15: **cap squatting** (filler wallet w985f9 pledges $2120): regular room of USDC/USDT now $0
- day 39.27: **cap squatting** (filler wallet w985f10 pledges $12160): regular room of USDC/USDT now $0
- day 39.90: **cap squatting** (filler wallet w985f11 pledges $20956): regular room of USDC/USDT now $0
- day 41.32: **cap squatting** (filler wallet w985f12 pledges $3741): regular room of USDC/USDT now $0
- day 41.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.33: **cap squatting** (filler wallet w985f13 pledges $97170): regular room of USDC/USDT now $0
- day 42.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.45: **cap squatting** (filler wallet w985f14 pledges $85): regular room of USDC/USDT now $0
- day 42.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.00: **cap squatting** (filler wallet w985f15 pledges $996): regular room of USDC/USDT now $0
- day 44.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.93: **cap squatting** (filler wallet w985f16 pledges $74868): regular room of USDC/USDT now $0
- day 45.85: **cap squatting** (filler wallet w985f17 pledges $3555): regular room of USDC/USDT now $0
- day 46.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 46.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 46.27: **cap squatting** (filler wallet w985f18 pledges $2750): regular room of USDC/USDT now $0
- day 46.36: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $692931
- day 47.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.00: **cap squatting** (filler wallet w985f19 pledges $2960): regular room of USDC/USDT now $0
- day 48.25: **cap squatting** (filler wallet w985f20 pledges $2022): regular room of USDC/USDT now $0
- day 48.50: **cap squatting** (filler wallet w985f21 pledges $416): regular room of USDC/USDT now $0
- day 49.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.06: **cap squatting** (filler wallet w985f22 pledges $13298): regular room of USDC/USDT now $0
- day 50.10: **cap squatting** (filler wallet w985f23 pledges $12002): regular room of USDC/USDT now $0
- day 50.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.15: **cap squatting** (filler wallet w985f24 pledges $10531): regular room of USDC/USDT now $0
- day 55.52: **cap squatting** (filler wallet w985f25 pledges $5095): regular room of USDC/USDT now $0
- day 56.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.96: **cap squatting** (filler wallet w985f26 pledges $858081): regular room of USDC/USDT now $0
- day 58.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.39: **cap squatting** (filler wallet w985f34 pledges $3969): regular room of USDC/USDT now $0
- day 59.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.93: **cap squatting** (filler wallet w985f35 pledges $30196): regular room of USDC/USDT now $0
- day 59.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.02: **cap squatting** (filler wallet w985f36 pledges $9506): regular room of USDC/USDT now $0
- day 60.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.19: **cap squatting** (filler wallet w985f37 pledges $8071): regular room of USDC/USDT now $0
- day 60.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.36: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.66: **cap squatting** (filler wallet w985f38 pledges $15705): regular room of USDC/USDT now $0
- day 60.91: **cap squatting** (filler wallet w985f39 pledges $4506): regular room of USDC/USDT now $0
- day 61.16: **cap squatting** (filler wallet w985f40 pledges $1392): regular room of USDC/USDT now $0
- day 61.21: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.59: **cap squatting** (filler wallet w985f41 pledges $139225): regular room of USDC/USDT now $0
- day 61.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.85: **cap squatting** (filler wallet w985f42 pledges $11525): regular room of USDC/USDT now $0
- day 61.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.40: **cap squatting** (filler wallet w985f43 pledges $2296): regular room of USDC/USDT now $0
- day 62.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.57: **cap squatting** (filler wallet w985f44 pledges $2696): regular room of USDC/USDT now $0
- day 64.33: **cap squatting** (filler wallet w985f45 pledges $8604): regular room of USDC/USDT now $0
- day 64.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.20: **cap squatting** (filler wallet w985f46 pledges $491): regular room of USDC/USDT now $0
- day 65.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.76: **cap squatting** (filler wallet w985f47 pledges $2831): regular room of USDC/USDT now $0
- day 65.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.10: **cap squatting** (filler wallet w985f48 pledges $49416): regular room of USDC/USDT now $0
- day 66.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.27: **cap squatting** (filler wallet w985f49 pledges $5654): regular room of USDC/USDT now $0
- day 67.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.54: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.01: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.41: **cap squatting** (filler wallet w985f50 pledges $12374): regular room of USDC/USDT now $0
- day 71.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.75: **cap squatting** (filler wallet w985f51 pledges $61078): regular room of USDC/USDT now $0
- day 72.20: **cap squatting** (filler wallet w985f52 pledges $2183): regular room of USDC/USDT now $0
- day 72.45: **cap squatting** (filler wallet w985f53 pledges $1323): regular room of USDC/USDT now $0
- day 72.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.83: **cap squatting** (filler wallet w985f54 pledges $21862): regular room of USDC/USDT now $0
- day 73.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.48: **cap squatting** (filler wallet w985f55 pledges $2885): regular room of USDC/USDT now $0
- day 74.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.28: **cap squatting** (filler wallet w985f110 pledges $22552): regular room of USDC/USDT now $0
- day 77.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.53: **cap squatting** (filler wallet w985f111 pledges $7500): regular room of USDC/USDT now $0
- day 78.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.99: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.08: **cap squatting** (filler wallet w985f112 pledges $18508): regular room of USDC/USDT now $0
- day 81.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.33: **cap squatting** (filler wallet w985f113 pledges $1606): regular room of USDC/USDT now $0
- day 81.54: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.66: **cap squatting** (filler wallet w985f114 pledges $23118): regular room of USDC/USDT now $0
- day 81.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.88: **cap squatting** (filler wallet w985f115 pledges $11773): regular room of USDC/USDT now $0
- day 83.26: **cap squatting** (filler wallet w985f116 pledges $4114): regular room of USDC/USDT now $0
- day 83.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.39: **cap squatting** (filler wallet w985f117 pledges $3268): regular room of USDC/USDT now $0
- day 83.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.69: **cap squatting** (filler wallet w985f118 pledges $16289): regular room of USDC/USDT now $0
- day 84.86: **cap squatting** (filler wallet w985f119 pledges $6920): regular room of USDC/USDT now $0
- day 84.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.04: **cap squatting** (filler wallet w985f120 pledges $7691): regular room of USDC/USDT now $0
- day 86.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.78: **cap squatting** (filler wallet w985f121 pledges $3653): regular room of USDC/USDT now $0
- day 88.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
