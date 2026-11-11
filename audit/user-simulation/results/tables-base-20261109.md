### Personas (seed 20261109, feed profile `spec`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 174 | 96 | 89 | 0 | $7,618 | $46 | $2 | $83 | $0 | 1.11% | 70% | 38 / 38 / 0 |
| active_lp | 120 | 65 | 55 | 34 | 2 | $13,041 | $44 | $8 | $282 | $6 | 2.06% | 91% | 23 / 23 / 0 |
| leveraged | 100 | 71 | 29 | 70 | 5 | $16,309 | $170 | $49 | $339 | $26 | 1.93% | 77% | 34 / 34 / 0 |
| small | 120 | 51 | 69 | 24 | 1 | $171 | $1 | $0 | $81 | $0 | 46.44% | 100% | 13 / 13 / 0 |
| whale | 20 | 18 | 1 | 15 | 0 | $479,896 | $2,700 | $867 | $250 | $0 | 0.05% | 0% | 3 / 3 / 0 |
| multi_market | 85 | 80 | 5 | 67 | 2 | $18,715 | $81 | $21 | $133 | $24 | 0.82% | 75% | 19 / 19 / 0 |
| mobile | 110 | 67 | 43 | 44 | 3 | $5,327 | $33 | $8 | $96 | $27 | 1.50% | 81% | 17 / 17 / 0 |
| forgetful | 90 | 57 | 33 | 52 | 14 | $9,384 | $55 | $28 | $66 | $220 | 0.84% | 58% | 0 / 0 / 0 |
| usdc_borrower | 70 | 48 | 22 | 48 | 1 | $13,276 | $87 | $34 | $124 | $5 | 0.98% | 73% | 20 / 20 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 151 |
| accounts | 68 |
| bonus_paid | $310 |
| debt_repaid | $12,842 |
| deficit | $0 |
| budget_draws | $25 |
| keeper_reimbursement | $104,733 |
| keeper_pnl | $-104,733 |
| searcher_profit | $0 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $102,168 |
| max_gas_usd | $904 |
| dust calls (repay < $100) | 135 |
| by episode | USDe crash 143, pause + USDe aftershock 8 |
| by caller/mode | keeper/gho 143, keeper/in_kind 8 |
| by debt asset | GHO 115, USDC 36 |
| by market | USDe/USDT 151 |
| liquidation blocked (account-hours by reason) | RecoveryBelowFloor 81.2 h (13 accounts), StalePrice(disagree_pause) 3.5 h (7 accounts), StalePrice(disagree_expired) 1.0 h (6 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| borrow | `HealthFactorTooLow` | 36 | 18 | $284 |
| borrow | `PriceTooOld` | 17 | 16 | $153 |
| borrow | `DeadlineExpired` | 13 | 13 | $106 |
| pledge | `DeadlineExpired` | 9 | 7 | $231 |
| collectFees | `Dropped(not mined)` | 5 | 5 | $0 |
| collectFees | `DeadlineExpired` | 5 | 5 | $19 |
| pledge | `Dropped(not mined)` | 4 | 4 | $0 |
| borrow | `BadNonce` | 4 | 4 | $37 |
| borrow | `Dropped(not mined)` | 3 | 3 | $0 |
| pledge | `CapExceeded(market)` | 2 | 2 | $42 |
| repayAllAndWithdraw | `Dropped(not mined)` | 2 | 2 | $0 |
| repay | `Dropped(not mined)` | 2 | 2 | $0 |
| withdraw | `DeadlineExpired` | 1 | 1 | $12 |
| pledge | `SliceNotAvailable` | 1 | 1 | $11 |
| repay | `DeadlineExpired` | 1 | 1 | $80 |
| repayAllAndWithdraw | `DeadlineExpired` | 1 | 1 | $10 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| borrow | `PriceNotLive(Drifting:band)` | 2295 | 23 |
| pledge | `CapExceeded(market)` | 1001 | 272 |
| pledge | `NotFullRange` | 385 | 377 |
| pledge | `PoolShareExceeded` | 116 | 69 |
| pledge | `PriceNotAccepted(Cached/Expired)` | 111 | 21 |
| pledge | `SliceNotAvailable` | 90 | 21 |
| borrow | `DrawCapExceeded` | 89 | 46 |
| withdraw(rebalance) | `HealthFactorTooLow` | 71 | 28 |
| borrow | `ApplicationPaused` | 51 | 17 |
| pledge | `ApplicationPaused` | 41 | 3 |
| borrow | `PriceTooOld` | 33 | 33 |
| borrow | `ApplicationFrozen` | 15 | 15 |
| withdraw(rebalance) | `PriceNotLive(Drifting:band)` | 12 | 7 |
| pledge | `PriceNotAccepted(Drifting)` | 11 | 6 |
| top-up | `PoolShareExceeded` | 8 | 7 |
| borrow | `PriceNotLive(Cached/Expired)` | 5 | 2 |
| pledge | `CapExceeded(depositor)` | 3 | 3 |
| borrow | `HealthFactorTooLow` | 3 | 2 |
| pledge(loop) | `SliceNotAvailable` | 2 | 2 |
| pledge | `BelowMinPledge` | 2 | 2 |
| withdraw(rebalance) | `PriceNotLive(Cached/Expired)` | 1 | 1 |
| borrow | `DebtPriceTooOld` | 1 | 1 |
| top-up | `SliceNotAvailable` | 1 | 1 |
| withdraw(rebalance) | `PriceTooOld` | 1 | 1 |
| withdraw(rebalance) | `ApplicationPaused` | 1 | 1 |
| top-up | `ApplicationPaused` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | concentrated_rejected | 377 | 385 | app (now), contracts (later) |
| 2 | low_ltv | 310 | 310 | app + risk |
| 3 | cap_full | 294 | 1095 | app + governance |
| 4 | fees_manual | 141 | 250 | app (contracts optional) |
| 5 | gas_exceeds_value | 81 | 81 | app + parameter |
| 6 | whole_nft_withdraw | 63 | 164 | contracts |
| 7 | borrow_blocked_price | 61 | 2349 | spec parameter + app |
| 8 | drawcap_exhausted | 46 | 89 | app + Aave governance |
| 9 | liquidated | 29 | 151 | app |
| 10 | exit_needs_external_funds | 26 | 26 | contracts |
| 11 | donation_not_credited | 25 | 31 | contracts + app |
| 12 | deadline_expired | 24 | 30 | app |
| 13 | max_borrow_reverted | 18 | 36 | app (+ spec note) |
| 14 | tx_dropped | 15 | 16 | app |
| 15 | no_alerts | 11 | 71 | app/services |
| 16 | borrow_blocked_other_market | 7 | 10 | contracts + app |
| 17 | topup_refused_pool_share | 7 | 8 | contracts/spec |
| 18 | bad_nonce | 4 | 4 | app |
| 19 | depositor_cap_split | 3 | 3 | governance |
| 20 | band_blocked_gho_premium | 2 | 2 | contracts/spec |
| 21 | below_min | 2 | 2 | app |
| 22 | topup_refused_slice | 1 | 1 | spec parameter + app |
| 23 | topup_refused_paused | 1 | 1 | contracts/spec + app |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| donated liquidity sitting uncredited in pledged NFTs (USD) | $45,052 | 11 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 47 |
| uncollected fees in the vault (claimable at any time) | $21,670 | 455 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age |
|---|---|---|---|
| USDC/USDT | 94.4% | 1.1% | 4.6% |
| GHO/USDC | 94.0% | 2.0% | 4.0% |
| DAI/USDC | 95.6% | 0.0% | 4.4% |
| USDe/USDT | 62.7% | 34.4% | 2.9% |
| USDC debt feed | 97.7% | 0.0% | 2.3% |

### Invariants

440947 checks over 15 kinds; violations: none

| Invariant | Checks |
|---|---|
| HF >= 1.10 after every borrow (BOR-POST-003) | 575 |
| HF >= 1.10 after withdraw-with-debt | 8 |
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1133 |
| backing: supply == credited + pending | 364 |
| credited == sum of records | 364 |
| custody iff open record | 69845 |
| debt conservation per account | 116132 |
| fee conservation per NFT | 111667 |
| liquidation GHO conservation | 151 |
| market regular counter <= cap | 364 |
| probe: state gates match the 3.6 emergency matrix | 108 |
| record live liquidity >= credited | 69845 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 69845 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $497, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $35,454 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $3,439,753, DAI/USDC $3,358,990, USDe/USDT $2,286,045 |
| third-party repay service | {'repaid': 1, 'repaid_in_None': 1, 'usd': 303.87343203657906} |

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

- day 60.26: governance schedules enableInKind(USDe/USDT) after 1.8 h of RecoveryBelowFloor
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
- day 33.19: **cap squatting** (filler wallet w985f70 pledges $7082): regular room of USDC/USDT now $0
- day 33.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 33.57: **cap squatting** (filler wallet w985f71 pledges $5683): regular room of USDC/USDT now $0
- day 34.20: **cap squatting** (filler wallet w985f72 pledges $14110): regular room of USDC/USDT now $0
- day 35.90: **cap squatting** (filler wallet w985f73 pledges $15183): regular room of USDC/USDT now $0
- day 36.40: **cap squatting** (filler wallet w985f74 pledges $4304): regular room of USDC/USDT now $0
- day 36.65: **cap squatting** (filler wallet w985f75 pledges $1367): regular room of USDC/USDT now $0
- day 37.32: **cap squatting** (filler wallet w985f76 pledges $23443): regular room of USDC/USDT now $0
- day 37.70: **cap squatting** (filler wallet w985f77 pledges $2043): regular room of USDC/USDT now $0
- day 38.57: **cap squatting** (filler wallet w985f78 pledges $2871): regular room of USDC/USDT now $0
- day 39.95: **cap squatting** (filler wallet w985f79 pledges $25187): regular room of USDC/USDT now $0
- day 41.24: **cap squatting** (filler wallet w985f80 pledges $1312): regular room of USDC/USDT now $0
- day 41.95: **cap squatting** (filler wallet w985f81 pledges $4888): regular room of USDC/USDT now $0
- day 42.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 42.70: **cap squatting** (filler wallet w985f82 pledges $66028): regular room of USDC/USDT now $0
- day 42.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 43.37: **cap squatting** (filler wallet w985f83 pledges $10465): regular room of USDC/USDT now $0
- day 43.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 44.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 45.27: **cap squatting** (filler wallet w985f84 pledges $3828): regular room of USDC/USDT now $0
- day 45.94: **cap squatting** (filler wallet w985f85 pledges $50893): regular room of USDC/USDT now $0
- day 46.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 46.82: **cap squatting** (filler wallet w985f86 pledges $48): regular room of USDC/USDT now $0
- day 46.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $695694
- day 47.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 47.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 48.12: **cap squatting** (filler wallet w985f87 pledges $10003): regular room of USDC/USDT now $0
- day 48.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.13: **cap squatting** (filler wallet w985f88 pledges $7897): regular room of USDC/USDT now $0
- day 49.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 49.73: **cap squatting** (filler wallet w985f89 pledges $997): regular room of USDC/USDT now $0
- day 50.36: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 50.86: **cap squatting** (filler wallet w985f90 pledges $16289): regular room of USDC/USDT now $0
- day 50.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.08: **cap squatting** (filler wallet w985f91 pledges $1234): regular room of USDC/USDT now $0
- day 51.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 51.37: **cap squatting** (filler wallet w985f92 pledges $4029): regular room of USDC/USDT now $0
- day 51.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 52.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 53.65: **cap squatting** (filler wallet w985f93 pledges $16700): regular room of USDC/USDT now $0
- day 53.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 54.58: **cap squatting** (filler wallet w985f94 pledges $5924): regular room of USDC/USDT now $0
- day 54.74: **cap squatting** (filler wallet w985f95 pledges $1146): regular room of USDC/USDT now $0
- day 55.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 55.62: **cap squatting** (filler wallet w985f96 pledges $4277): regular room of USDC/USDT now $0
- day 55.92: **cap squatting** (filler wallet w985f97 pledges $5969): regular room of USDC/USDT now $0
- day 55.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.21: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 56.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 57.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 58.98: **cap squatting** (filler wallet w985f98 pledges $27648): regular room of USDC/USDT now $0
- day 59.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 59.83: **cap squatting** (filler wallet w985f99 pledges $23765): regular room of USDC/USDT now $0
- day 60.04: **cap squatting** (filler wallet w985f100 pledges $137): regular room of USDC/USDT now $0
- day 60.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.21: **cap squatting** (filler wallet w985f101 pledges $32236): regular room of USDC/USDT now $0
- day 60.84: **cap squatting** (filler wallet w985f102 pledges $15826): regular room of USDC/USDT now $0
- day 60.88: **cap squatting** (filler wallet w985f103 pledges $16730): regular room of USDC/USDT now $0
- day 61.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.35: **cap squatting** (filler wallet w985f104 pledges $15009): regular room of USDC/USDT now $0
- day 62.65: **cap squatting** (filler wallet w985f105 pledges $4753): regular room of USDC/USDT now $0
- day 62.73: **cap squatting** (filler wallet w985f106 pledges $9429): regular room of USDC/USDT now $0
- day 62.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.02: **cap squatting** (filler wallet w985f107 pledges $7847): regular room of USDC/USDT now $0
- day 63.07: **cap squatting** (filler wallet w985f108 pledges $5875): regular room of USDC/USDT now $0
- day 63.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.05: **cap squatting** (filler wallet w985f109 pledges $23412): regular room of USDC/USDT now $0
- day 64.30: **cap squatting** (filler wallet w985f110 pledges $6411): regular room of USDC/USDT now $0
- day 64.46: **cap squatting** (filler wallet w985f111 pledges $13432): regular room of USDC/USDT now $0
- day 64.55: **cap squatting** (filler wallet w985f112 pledges $1737): regular room of USDC/USDT now $0
- day 64.71: **cap squatting** (filler wallet w985f113 pledges $5922): regular room of USDC/USDT now $0
- day 64.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.30: **cap squatting** (filler wallet w985f114 pledges $10111): regular room of USDC/USDT now $0
- day 68.55: **cap squatting** (filler wallet w985f115 pledges $2914): regular room of USDC/USDT now $0
- day 68.80: **cap squatting** (filler wallet w985f116 pledges $686): regular room of USDC/USDT now $0
- day 69.35: **cap squatting** (filler wallet w985f117 pledges $50): regular room of USDC/USDT now $0
- day 69.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.53: **cap squatting** (filler wallet w985f118 pledges $6470): regular room of USDC/USDT now $0
- day 70.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.87: **cap squatting** (filler wallet w985f119 pledges $53600): regular room of USDC/USDT now $0
- day 70.91: **cap squatting** (filler wallet w985f120 pledges $9180): regular room of USDC/USDT now $0
- day 70.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.13: **cap squatting** (filler wallet w985f121 pledges $15121): regular room of USDC/USDT now $0
- day 71.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.38: **cap squatting** (filler wallet w985f122 pledges $4793): regular room of USDC/USDT now $0
- day 71.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.18: **cap squatting** (filler wallet w985f123 pledges $9219): regular room of USDC/USDT now $0
- day 72.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.63: **cap squatting** (filler wallet w985f124 pledges $2875): regular room of USDC/USDT now $0
- day 74.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.72: **cap squatting** (filler wallet w985f125 pledges $16784): regular room of USDC/USDT now $0
- day 74.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.28: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.36: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.40: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.44: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.48: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 77.28: **cap squatting** (filler wallet w985f168 pledges $20992): regular room of USDC/USDT now $0
- day 77.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.17: **cap squatting** (filler wallet w985f169 pledges $3127): regular room of USDC/USDT now $0
- day 79.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.42: **cap squatting** (filler wallet w985f170 pledges $13594): regular room of USDC/USDT now $0
- day 79.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.59: **cap squatting** (filler wallet w985f171 pledges $2096): regular room of USDC/USDT now $0
- day 79.67: **cap squatting** (filler wallet w985f172 pledges $3854): regular room of USDC/USDT now $0
- day 80.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.82: **cap squatting** (filler wallet w985f173 pledges $2563): regular room of USDC/USDT now $0
- day 81.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.36: **cap squatting** (filler wallet w985f174 pledges $9772): regular room of USDC/USDT now $0
- day 81.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.30: **cap squatting** (filler wallet w985f175 pledges $37686): regular room of USDC/USDT now $0
- day 85.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.31: **cap squatting** (filler wallet w985f176 pledges $71012): regular room of USDC/USDT now $0
- day 86.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.56: **cap squatting** (filler wallet w985f177 pledges $19206): regular room of USDC/USDT now $0
- day 86.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.78: **cap squatting** (filler wallet w985f178 pledges $13769): regular room of USDC/USDT now $0
- day 87.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.00: **cap squatting** (filler wallet w985f179 pledges $8400): regular room of USDC/USDT now $0
- day 88.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
