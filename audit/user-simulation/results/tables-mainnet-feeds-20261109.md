### Personas (seed 20261109, feed profile `mainnet`, repay quote `deadline`)

| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| passive_lp | 270 | 180 | 90 | 14 | 0 | $8,037 | $49 | $0 | $67 | $0 | 0.81% | 61% | 42 / 42 / 0 |
| active_lp | 120 | 72 | 48 | 15 | 0 | $13,354 | $48 | $0 | $200 | $0 | 1.15% | 78% | 35 / 35 / 0 |
| leveraged | 100 | 72 | 28 | 50 | 0 | $18,201 | $143 | $29 | $154 | $0 | 0.88% | 54% | 35 / 35 / 0 |
| small | 120 | 39 | 81 | 3 | 0 | $191 | $1 | $0 | $68 | $0 | 38.69% | 100% | 11 / 11 / 0 |
| whale | 20 | 16 | 3 | 7 | 0 | $479,896 | $2,245 | $0 | $195 | $0 | 0.03% | 0% | 4 / 4 / 0 |
| multi_market | 85 | 70 | 11 | 5 | 0 | $18,592 | $93 | $0 | $103 | $0 | 0.60% | 56% | 16 / 17 / 0 |
| mobile | 110 | 71 | 39 | 8 | 0 | $4,684 | $27 | $0 | $69 | $0 | 1.27% | 73% | 22 / 22 / 0 |
| forgetful | 90 | 72 | 18 | 3 | 0 | $9,485 | $46 | $0 | $54 | $0 | 0.63% | 54% | 0 / 0 / 0 |
| usdc_borrower | 70 | 48 | 22 | 12 | 0 | $13,498 | $70 | $0 | $72 | $0 | 0.47% | 58% | 17 / 17 / 0 |

### Liquidations

| Measure | Value |
|---|---|
| calls | 0 |
| accounts | 0 |
| bonus_paid | $0 |
| debt_repaid | $0 |
| deficit | $0 |
| budget_draws | $0 |
| keeper_reimbursement | $0 |
| keeper_pnl | $0 |
| searcher_profit | $0 |
| sandwich_extracted | $0 |
| dust_keeper_loss | $0 |
| max_gas_usd | $0 |
| dust calls (repay < $100) | 0 |
| by episode |  |
| by caller/mode |  |
| by debt asset |  |
| by market |  |
| liquidation blocked (account-hours by reason) | RecoveryBelowFloor 0.7 h (1 accounts), StalePrice(disagree_pause) 0.2 h (1 accounts) |

### Failed transactions on-chain (reverted, gas paid)

| Action | Error | Count | Users | Gas lost |
|---|---|---|---|---|
| pledge | `DeadlineExpired` | 15 | 14 | $331 |
| borrow | `HealthFactorTooLow` | 10 | 5 | $77 |
| pledge | `Dropped(not mined)` | 8 | 8 | $0 |
| borrow | `PriceTooOld` | 6 | 6 | $47 |
| withdraw | `DeadlineExpired` | 6 | 6 | $91 |
| borrow | `DeadlineExpired` | 4 | 4 | $33 |
| pledge | `CapExceeded(market)` | 4 | 4 | $76 |
| withdraw | `Dropped(not mined)` | 3 | 2 | $0 |
| collectFees | `DeadlineExpired` | 3 | 3 | $10 |
| borrow | `Dropped(not mined)` | 2 | 2 | $0 |
| collectFees | `Dropped(not mined)` | 2 | 2 | $0 |
| borrow | `BadNonce` | 1 | 1 | $5 |

### Refused by the app pre-check (no gas)

| Action | Reason | Count | Users |
|---|---|---|---|
| borrow | `PriceTooOld` | 75746 | 455 |
| borrow | `PriceNotLive(Drifting:band)` | 9272 | 110 |
| borrow | `PriceNotLive(Cached/Expired)` | 1208 | 140 |
| pledge | `CapExceeded(market)` | 929 | 253 |
| borrow | `PriceNotLive(Drifting:twap)` | 664 | 109 |
| borrow | `ApplicationPaused` | 533 | 207 |
| pledge | `NotFullRange` | 385 | 377 |
| pledge | `PoolShareExceeded` | 97 | 67 |
| borrow | `PriceNotLive(Drifting:mixed)` | 82 | 20 |
| borrow | `ApplicationFrozen` | 82 | 82 |
| pledge | `ApplicationPaused` | 70 | 4 |
| pledge | `PriceNotAccepted(Cached/Expired)` | 57 | 12 |
| borrow | `PriceNotLive(Drifting:disagree)` | 48 | 29 |
| pledge | `SliceNotAvailable` | 33 | 8 |
| borrow | `DebtPriceTooOld` | 31 | 8 |
| withdraw(rebalance) | `PriceTooOld` | 28 | 13 |
| pledge(loop) | `SliceNotAvailable` | 25 | 25 |
| pledge | `PriceNotAccepted(Drifting)` | 9 | 4 |
| pledge(loop) | `PoolShareExceeded` | 5 | 5 |
| top-up | `PoolShareExceeded` | 5 | 3 |
| pledge | `CapExceeded(depositor)` | 3 | 3 |
| pledge | `BelowMinPledge` | 3 | 3 |
| top-up | `SliceNotAvailable` | 3 | 3 |
| withdraw(rebalance) | `ApplicationPaused` | 2 | 2 |
| withdraw(rebalance) | `HealthFactorTooLow` | 1 | 1 |
| top-up | `ApplicationPaused` | 1 | 1 |
| withdraw(rebalance) | `PriceNotLive(Drifting:band)` | 1 | 1 |

### Frustrations (unique users)

| # | Code | Users | Events | Where the fix belongs |
|---|---|---|---|---|
| 1 | borrow_blocked_price | 455 | 86544 | spec parameter + app |
| 2 | concentrated_rejected | 377 | 385 | app (now), contracts (later) |
| 3 | low_ltv | 321 | 321 | app + risk |
| 4 | cap_full | 286 | 991 | app + governance |
| 5 | gas_exceeds_value | 81 | 81 | app + parameter |
| 6 | band_blocked_gho_premium | 49 | 491 | contracts/spec |
| 7 | whole_nft_withdraw | 46 | 95 | contracts |
| 8 | fees_manual | 41 | 70 | app (contracts optional) |
| 9 | deadline_expired | 25 | 28 | app |
| 10 | borrow_blocked_other_market | 20 | 69 | contracts + app |
| 11 | donation_not_credited | 14 | 17 | contracts + app |
| 12 | tx_dropped | 14 | 15 | app |
| 13 | twap_griefed | 11 | 22 | risk ops + app |
| 14 | max_borrow_reverted | 5 | 10 | app (+ spec note) |
| 15 | topup_refused_pool_share | 3 | 5 | contracts/spec |
| 16 | depositor_cap_split | 3 | 3 | governance |
| 17 | below_min | 3 | 3 | app |
| 18 | topup_refused_slice | 3 | 3 | spec parameter + app |
| 19 | exit_needs_external_funds | 2 | 2 | contracts |
| 20 | bad_nonce | 1 | 1 | app |
| 21 | topup_refused_paused | 1 | 1 | contracts/spec + app |

### Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| donated liquidity sitting uncredited in pledged NFTs (USD) | $63,377 | 5 |
| forgetful accounts still open with debt (not stuck, idle) | $0 | 3 |
| uncollected fees in the vault (claimable at any time) | $47,529 | 449 |

### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)

| Market / feed | Allowed | Blocked by state | Blocked by price age |
|---|---|---|---|
| USDC/USDT | 0.1% | 1.1% | 98.8% |
| GHO/USDC | 0.0% | 2.0% | 97.9% |
| DAI/USDC | 4.0% | 0.0% | 96.0% |
| USDe/USDT | 0.1% | 34.4% | 65.5% |
| USDC debt feed | 4.1% | 0.0% | 95.9% |

### Invariants

423318 checks over 12 kinds; violations: none

| Invariant | Checks |
|---|---|
| HF >= 1.10 after every borrow (BOR-POST-003) | 130 |
| Hub drawn == sum of account debt | 182 |
| LP liquidity conservation per NFT | 1186 |
| backing: supply == credited + pending | 364 |
| credited == sum of records | 364 |
| custody iff open record | 64281 |
| debt conservation per account | 118772 |
| fee conservation per NFT | 108749 |
| market regular counter <= cap | 364 |
| record live liquidity >= credited | 64281 |
| slice counter <= slice cap | 364 |
| vault holds only NFTs with an open record | 64281 |

### Protocol state at the end

| Measure | Value |
|---|---|
| deficit (bad debt) | {'GHO': 0.0, 'USDC': 0.0} |
| slice used per market (USD) | USDC/USDT $467, GHO/USDC $0, DAI/USDC $0, USDe/USDT $0 |
| slice used by the re-leverage attacker | $24,846 |
| regular cap used | USDC/USDT $8,000,000, GHO/USDC $3,235,499, DAI/USDC $3,312,411, USDe/USDT $2,474,626 |
| third-party repay service | {'repaid': 1, 'repaid_in_None': 1, 'usd': 303.42872422680216} |

### Rule probes vs the 3.6 emergency matrix (observed / expected)

| State (market, day) | new | topup | borrow | repay | collect | wd_free | wd_debt | repay_all_wd | liq |
|---|---|---|---|---|---|---|---|---|---|
| Live (skipped: probe account could not borrow) (USDC/USDT, 5.00) | - | - | - | - | - | - | - | - | - |
| Drifting (USD band, GHO premium) (skipped: probe account could not borrow) (GHO/USDC, 9.00) | - | - | - | - | - | - | - | - | - |
| Live on frozen alternate, then Drifting (TWAP) (skipped: probe account could not borrow) (USDC/USDT, 18.75) | - | - | - | - | - | - | - | - | - |
| Cached (skipped: probe account could not borrow) (USDC/USDT, 18.90) | - | - | - | - | - | - | - | - | - |
| Expired (skipped: probe account could not borrow) (USDC/USDT, 19.20) | - | - | - | - | - | - | - | - | - |
| Grace after recovery (skipped: probe account could not borrow) (USDC/USDT, 19.61) | - | - | - | - | - | - | - | - | - |
| Drifting (feed disagreement) (skipped: probe account could not borrow) (USDe/USDT, 60.21) | - | - | - | - | - | - | - | - | - |
| Disagreement beyond disagreementPauseMax (skipped: probe account could not borrow) (USDe/USDT, 60.25) | - | - | - | - | - | - | - | - | - |
| Drifting (USD band breach) (skipped: probe account could not borrow) (USDe/USDT, 66.00) | - | - | - | - | - | - | - | - | - |
| Application Frozen (skipped: probe account could not borrow) (USDC/USDT, 75.10) | - | - | - | - | - | - | - | - | - |
| Application Paused (skipped: probe account could not borrow) (USDC/USDT, 76.00) | - | - | - | - | - | - | - | - | - |
| USDC debt feed stale (collateral Live on alternate) (skipped: probe account could not borrow) (USDC/USDT, 85.10) | - | - | - | - | - | - | - | - | - |

### Governance and attacks

- day 75.00: pause state -> Frozen
- day 75.25: pause state -> Paused
- day 77.25: pause state -> None
- day 3.00: **dust accounts** (open 40 x $10.60 USDe/USDT accounts at HF 1.10): 0 opened; gas paid $5296
- day 5.00: **flash-loan pledge-borrow-exit** (flash-mint $5M of LP, pledge, borrow max, withdraw in one tx): reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss
- day 12.00: **direct Spoke.liquidationCall** (call liquidationCall on an account): Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER
- day 16.46: **cap squatting** (filler wallet w985f1 pledges $990000): regular room of USDC/USDT now $466278
- day 16.50: **cap squatting** (filler wallet w985f2 pledges $466278): regular room of USDC/USDT now $0
- day 17.00: **cap squatting** (filler wallet w985f3 pledges $9596): regular room of USDC/USDT now $0
- day 17.30: **cap squatting** (filler wallet w985f4 pledges $25735): regular room of USDC/USDT now $0
- day 18.00: **cap squatting** (filler wallet w985f5 pledges $43213): regular room of USDC/USDT now $0
- day 19.63: **cap squatting** (filler wallet w985f23 pledges $5579): regular room of USDC/USDT now $0
- day 20.00: **donate liquidity to a victim NFT** (NFPM.increaseLiquidity on a pledged tokenId): no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT
- day 21.67: **cap squatting** (filler wallet w985f24 pledges $17269): regular room of USDC/USDT now $0
- day 22.00: **cap squatting** (filler wallet w985f25 pledges $2461): regular room of USDC/USDT now $0
- day 23.88: **cap squatting** (filler wallet w985f26 pledges $12355): regular room of USDC/USDT now $0
- day 25.71: **cap squatting** (filler wallet w985f27 pledges $2030): regular room of USDC/USDT now $0
- day 28.09: **cap squatting** (filler wallet w985f28 pledges $21745): regular room of USDC/USDT now $0
- day 30.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.10: **pledge while pool is pushed off peg** (move USDC/USDT pool 2% then pledge): refused: PriceNotAccepted(Drifting)
- day 30.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 30.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
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
- day 33.19: **cap squatting** (filler wallet w985f80 pledges $56880): regular room of USDC/USDT now $0
- day 33.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 33.28: **cap squatting** (filler wallet w985f81 pledges $14201): regular room of USDC/USDT now $0
- day 33.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 33.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 33.62: **cap squatting** (filler wallet w985f82 pledges $13682): regular room of USDC/USDT now $0
- day 33.87: **cap squatting** (filler wallet w985f83 pledges $16974): regular room of USDC/USDT now $0
- day 35.16: **cap squatting** (filler wallet w985f84 pledges $7101): regular room of USDC/USDT now $0
- day 36.45: **cap squatting** (filler wallet w985f85 pledges $23443): regular room of USDC/USDT now $0
- day 38.95: **cap squatting** (filler wallet w985f86 pledges $13150): regular room of USDC/USDT now $0
- day 40.20: **cap squatting** (filler wallet w985f87 pledges $5154): regular room of USDC/USDT now $0
- day 40.28: **cap squatting** (filler wallet w985f88 pledges $34354): regular room of USDC/USDT now $0
- day 41.33: **cap squatting** (filler wallet w985f89 pledges $2371): regular room of USDC/USDT now $0
- day 41.41: **cap squatting** (filler wallet w985f90 pledges $7847): regular room of USDC/USDT now $0
- day 41.91: **cap squatting** (filler wallet w985f91 pledges $68599): regular room of USDC/USDT now $0
- day 42.74: **cap squatting** (filler wallet w985f92 pledges $2571): regular room of USDC/USDT now $0
- day 43.41: **cap squatting** (filler wallet w985f93 pledges $10588): regular room of USDC/USDT now $0
- day 43.87: **cap squatting** (filler wallet w985f94 pledges $16042): regular room of USDC/USDT now $0
- day 44.37: **cap squatting** (filler wallet w985f95 pledges $4492): regular room of USDC/USDT now $0
- day 46.16: **cap squatting** (filler wallet w985f96 pledges $50893): regular room of USDC/USDT now $0
- day 46.20: **cap squatting** (filler wallet w985f97 pledges $1232): regular room of USDC/USDT now $0
- day 47.00: **TWAP griefing in drained GHO/USDC pool** (hold pool 0.7% off Chainlink for 2.4 h): market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $695181
- day 48.58: **cap squatting** (filler wallet w985f98 pledges $24524): regular room of USDC/USDT now $0
- day 49.16: **cap squatting** (filler wallet w985f99 pledges $6494): regular room of USDC/USDT now $0
- day 49.41: **cap squatting** (filler wallet w985f100 pledges $6159): regular room of USDC/USDT now $0
- day 49.87: **cap squatting** (filler wallet w985f101 pledges $1214): regular room of USDC/USDT now $0
- day 50.78: **cap squatting** (filler wallet w985f102 pledges $16445): regular room of USDC/USDT now $0
- day 50.95: **cap squatting** (filler wallet w985f103 pledges $1249): regular room of USDC/USDT now $0
- day 51.12: **cap squatting** (filler wallet w985f104 pledges $17896): regular room of USDC/USDT now $0
- day 52.74: **cap squatting** (filler wallet w985f105 pledges $4089): regular room of USDC/USDT now $0
- day 52.99: **cap squatting** (filler wallet w985f106 pledges $17225): regular room of USDC/USDT now $0
- day 53.87: **cap squatting** (filler wallet w985f107 pledges $13853): regular room of USDC/USDT now $0
- day 55.20: **cap squatting** (filler wallet w985f108 pledges $1146): regular room of USDC/USDT now $0
- day 56.78: **cap squatting** (filler wallet w985f109 pledges $4438): regular room of USDC/USDT now $0
- day 57.08: **cap squatting** (filler wallet w985f110 pledges $6475): regular room of USDC/USDT now $0
- day 57.53: **cap squatting** (filler wallet w985f111 pledges $1198): regular room of USDC/USDT now $0
- day 58.53: **cap squatting** (filler wallet w985f112 pledges $64694): regular room of USDC/USDT now $0
- day 58.74: **cap squatting** (filler wallet w985f113 pledges $27900): regular room of USDC/USDT now $0
- day 59.66: **cap squatting** (filler wallet w985f114 pledges $8652): regular room of USDC/USDT now $0
- day 59.95: **cap squatting** (filler wallet w985f115 pledges $289): regular room of USDC/USDT now $0
- day 60.28: **cap squatting** (filler wallet w985f116 pledges $32313): regular room of USDC/USDT now $0
- day 60.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.54: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.67: **cap squatting** (filler wallet w985f117 pledges $16696): regular room of USDC/USDT now $0
- day 60.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.80: **cap squatting** (filler wallet w985f118 pledges $15830): regular room of USDC/USDT now $0
- day 60.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 60.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.87: **cap squatting** (filler wallet w985f119 pledges $5728): regular room of USDC/USDT now $0
- day 61.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 61.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.22: **cap squatting** (filler wallet w985f120 pledges $10626): regular room of USDC/USDT now $0
- day 62.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.40: **cap squatting** (filler wallet w985f121 pledges $7890): regular room of USDC/USDT now $0
- day 62.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.48: **cap squatting** (filler wallet w985f122 pledges $15381): regular room of USDC/USDT now $0
- day 62.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.66: **cap squatting** (filler wallet w985f123 pledges $23620): regular room of USDC/USDT now $0
- day 62.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.79: **cap squatting** (filler wallet w985f124 pledges $9412): regular room of USDC/USDT now $0
- day 62.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 62.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.14: **cap squatting** (filler wallet w985f125 pledges $20748): regular room of USDC/USDT now $0
- day 63.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.40: **cap squatting** (filler wallet w985f126 pledges $23090): regular room of USDC/USDT now $0
- day 63.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 63.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.01: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.39: **cap squatting** (filler wallet w985f127 pledges $2763): regular room of USDC/USDT now $0
- day 64.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 64.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 65.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.26: **cap squatting** (filler wallet w985f128 pledges $10833): regular room of USDC/USDT now $0
- day 66.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 66.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.01: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.36: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 67.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.02: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.28: **cap squatting** (filler wallet w985f129 pledges $11655): regular room of USDC/USDT now $0
- day 68.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.54: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 68.89: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.31: **cap squatting** (filler wallet w985f130 pledges $4615): regular room of USDC/USDT now $0
- day 69.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.60: **cap squatting** (filler wallet w985f131 pledges $6615): regular room of USDC/USDT now $0
- day 69.65: **cap squatting** (filler wallet w985f132 pledges $53625): regular room of USDC/USDT now $0
- day 69.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 69.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.87: **cap squatting** (filler wallet w985f133 pledges $8860): regular room of USDC/USDT now $0
- day 70.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 70.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.85: **cap squatting** (filler wallet w985f134 pledges $2039): regular room of USDC/USDT now $0
- day 71.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 71.99: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.21: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.51: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.60: **cap squatting** (filler wallet w985f135 pledges $9166): regular room of USDC/USDT now $0
- day 72.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 72.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.21: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 73.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.26: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.61: **cap squatting** (filler wallet w985f136 pledges $2819): regular room of USDC/USDT now $0
- day 74.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 74.88: **cap squatting** (filler wallet w985f137 pledges $16757): regular room of USDC/USDT now $0
- day 74.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 75.26: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.30: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.35: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.39: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.43: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.47: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.51: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.55: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.60: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.64: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.68: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.72: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.76: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.80: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.85: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.89: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.93: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 75.97: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.01: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.05: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.10: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.14: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.18: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.22: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.26: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.30: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.35: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 76.39: **slice re-leverage** (top-up): refused: ApplicationPaused
- day 77.26: **cap squatting** (filler wallet w985f158 pledges $12239): regular room of USDC/USDT now $0
- day 77.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.39: **cap squatting** (filler wallet w985f159 pledges $13232): regular room of USDC/USDT now $0
- day 77.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.61: **cap squatting** (filler wallet w985f160 pledges $15413): regular room of USDC/USDT now $0
- day 77.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 77.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.13: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.39: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.48: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.57: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.61: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.74: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.83: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 78.96: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.00: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.05: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.09: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.14: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.18: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.22: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.27: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.31: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.35: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.40: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.44: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.49: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.53: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.66: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.70: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.79: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 79.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.01: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.54: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 80.89: **cap squatting** (filler wallet w985f161 pledges $1427): regular room of USDC/USDT now $0
- day 80.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.35: **cap squatting** (filler wallet w985f162 pledges $9760): regular room of USDC/USDT now $0
- day 81.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 81.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.03: **cap squatting** (filler wallet w985f163 pledges $2718): regular room of USDC/USDT now $0
- day 82.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.51: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 82.99: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.21: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.88: **cap squatting** (filler wallet w985f164 pledges $579432): regular room of USDC/USDT now $0
- day 83.92: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 83.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.01: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.06: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.10: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.15: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.19: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.23: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.28: **cap squatting** (filler wallet w985f165 pledges $70993): regular room of USDC/USDT now $0
- day 84.32: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.36: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.41: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.45: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.54: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.58: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.76: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 84.89: **cap squatting** (filler wallet w985f166 pledges $77306): regular room of USDC/USDT now $0
- day 84.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 85.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.11: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.29: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.51: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.64: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.81: **cap squatting** (filler wallet w985f167 pledges $13643): regular room of USDC/USDT now $0
- day 86.86: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.95: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 86.99: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.04: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.08: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.17: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.21: **cap squatting** (filler wallet w985f168 pledges $8455): regular room of USDC/USDT now $0
- day 87.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.30: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.34: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.38: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.43: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.47: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.52: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.56: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.60: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.65: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.69: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.73: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.78: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.82: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.87: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 87.91: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.24: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.28: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.33: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.37: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.42: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.46: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.50: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.55: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.59: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.63: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.68: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.72: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.77: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.81: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.85: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.90: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.94: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 88.98: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.03: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.07: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.12: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.16: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.20: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.25: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.62: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.67: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.71: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.75: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.80: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.84: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.88: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.93: **slice re-leverage** (top-up): refused: SliceNotAvailable
- day 89.97: **slice re-leverage** (top-up): refused: SliceNotAvailable
