# AMM LP pricing models (AMM-A, AMM-B, AMM-C)

Z3 models and exact-integer runs of fair-composition LP pricing for three AMM types, with the Hypothesis search in [`../../hypothesis/test_hyp_amm_pricing.py`](../../hypothesis/test_hyp_amm_pricing.py). Fair composition values an LP position at the token amounts it would hold at the oracle-implied price, never at the pool's spot reserves.

Run from `spec/05-verification/`:

```bash
.venv/bin/python z3/amm-pricing/ap01_concentrated_liquidity.py     # ~3 s
.venv/bin/python z3/amm-pricing/ap02_constant_product.py           # < 1 s
.venv/bin/python z3/amm-pricing/ap03_stable_and_weighted.py        # < 1 s
.venv/bin/python -m pytest -q hypothesis/test_hyp_amm_pricing.py   # ~4 s (AVANA_HYP_SCALE=20: ~70 s)
```

Result words follow [`../units-oracle`](../units-oracle/README.md): `PROVED`, `COUNTEREXAMPLE`, `COMPUTED`, `TIMEOUT`; a script exits 1 only when a result differs from the `expect` value beside the check. `COUNTEREXAMPLE (deliberate)` marks an unsafe quote shown to be manipulable. `run_all.sh` runs every `z3/**/*.py` and every `hypothesis/test_*.py` on its quick path, so these files run there too; all pass.

These are the pricing proofs (`PRICE`) and manipulation tests (`MANIP`) that an AMM integration carries before listing (`trace.py`, `amm-integrations.json`). Each group of checks has one ID of the form `MATH-AMM-<P>-PRICE-NN` or `HYP-AMM-<P>-<METHOD>-NN` and a `verifies:` tag naming the rules it checks on the integration pages ([2.19](../../../02-contracts/19-amm-integration-interface.md)–[2.22](../../../02-contracts/22-amm-integration-readiness.md)) and the design-review findings it closes. Uniswap v3 and Aerodrome Slipstream share the tick and amount math, so every concentrated-liquidity group carries a `V3` and a `SLIP` ID.

| Check ID | Checks | Verifies |
|---|---|---|
| `MATH-AMM-V3-PRICE-01`, `MATH-AMM-SLIP-PRICE-01` | A1a–A1c | `SPEC-AMM-CORE-001`, `REQ-AMM-CORE-012`, `SPEC-AMM-V3-001`, `REQ-AMM-V3-005`, `REQ-AMM-SLIP-012`, `INV-078` |
| `MATH-AMM-V3-PRICE-02`, `MATH-AMM-SLIP-PRICE-02` | A2a, A2b | `SPEC-AMM-V3-001`, `REQ-AMM-SLIP-012` |
| `MATH-AMM-V3-PRICE-03`, `MATH-AMM-SLIP-PRICE-03` | A3a–A3g | `SPEC-AMM-CORE-001`, `SPEC-AMM-V3-001`, `REQ-AMM-V3-005`, `REQ-AMM-SLIP-012`, `INV-078` |
| `MATH-AMM-V3-PRICE-04`, `MATH-AMM-SLIP-PRICE-04` | A4a–A4h | `SPEC-AMM-V3-001`, `REQ-AMM-V3-005`, `REQ-AMM-V3-006`, `REQ-AMM-SLIP-012`, `INV-078`, AMMN-RT-02 |
| `MATH-AMM-V3-PRICE-05`, `MATH-AMM-SLIP-PRICE-05` | A5a–A5e | `REQ-AMM-V3-002`, `REQ-AMM-V3-007`, `REQ-AMM-V3-008`, `REQ-AMM-SLIP-008`, `REQ-AMM-SLIP-014`, `REQ-AMM-SLIP-017`, `INV-005`, AMMN-RT-01 |
| `MATH-AMM-V3-PRICE-06`, `MATH-AMM-SLIP-PRICE-06` | A6a–A6c | `REQ-AMM-CORE-006`, `REQ-AMM-CORE-016`, `REQ-AMM-SLIP-018`, AMMN-RT-01 |
| `MATH-AMM-V2-PRICE-01` … `06` | B1; B2; B3; B4; B5; B6–B11 | `SPEC-AMM-CORE-001`, `SPEC-AMM-V2-001`, `REQ-AMM-V2-001` … `005`, `REQ-AMM-CORE-014`, `INV-078`, AMMN-RT-07 |
| `MATH-AMM-BAL-PRICE-01`, `02` | C1; C6 | `SPEC-AMM-CORE-001`, `SPEC-AMM-BAL-001`, `REQ-AMM-BAL-005`, `REQ-AMM-CORE-014`, `INV-078`, AMMN-RT-07 |
| `MATH-AMM-CURVE-PRICE-01`, `02` | C2; C3–C5 | `SPEC-AMM-CORE-001`, `SPEC-AMM-CURVE-001`, `REQ-AMM-CURVE-001`, `REQ-AMM-CURVE-006`, `REQ-AMM-CORE-014`, `INV-078`, AMMN-RT-07 |

## Models

| File | Pool type | Arithmetic |
|---|---|---|
| `_common.py` | shared | solver wrappers and TickMath port from `../units-oracle/_common.py`; integer ports of `LiquidityAmounts.getAmountsForLiquidity`, a v2-style pair (`swap` with the 0.3% K check, `mint`, `burn`, `sync`, `skim`, `_mintFee`, `MINIMUM_LIQUIDITY = 1000`), StableSwap NG `get_D`, `get_y`, dynamic fee and 50% admin share |
| `ap01_concentrated_liquidity.py` | concentrated liquidity (v3 ticks; tickSpacing-keyed AMM protocols use the same tick and amount math) | reals for proofs, Q64.96 integers for rounding, int24 bit-vectors for the range check |
| `ap02_constant_product.py` | constant product, `k = r0·r1` | reals with `q² = k·p0·p1`; exact integers for attack runs |
| `ap03_stable_and_weighted.py` | StableSwap (n = 2, 3) and weighted (80/20, 50/50, 1/3 each) | polynomial encodings of fractional powers; integer StableSwap; 80-digit weighted pool |

## Formulas

| Pool | Quote | Redeemable value used as the safety bound |
|---|---|---|
| Concentrated | `(a0, a1) = getAmountsForLiquidity(sO, sa, sb, L)`, `value = mulDiv(a0, p0, 10^d0) + mulDiv(a1, p1, 10^d1)`, `sO = isqrt(mulDiv(num, 2^192, den))` from the feeds | — (the quote is the minimum over spot prices, AMM-A1a) |
| Constant product | `2·√(r0·r1·p0·p1) / (totalSupply + pendingFeeLiquidity)` with `getReserves()` | `(r0·p0 + r1·p1) / supply` |
| Weighted | `k·∏(p_i/w_i)^w_i / supply`, `k = ∏ b_i^w_i` | `Σ b_i·p_i / supply` |
| StableSwap | `min_i(p_i) · D / supply` (= `min p · virtual_price`) | `Σ x_i·p_i / supply` |

## Checks and results

### AMM-A — concentrated liquidity (`ap01`)

| ID | Statement | Result |
|---|---|---|
| A1a | For every spot price, spot amounts valued at the oracle price ≥ fair quote: fair composition is the minimum, so moving `slot0` cannot lower it and the fair quote reads no `slot0` input | PROVED |
| A1b | In range, the excess of a spot-composition quote is exactly `L·(sSpot − sO)²/sSpot` | PROVED |
| A1c | A spot-composition quote is inflatable: spot at 4× the oracle price on a ±100× range raises it ≥ 12.5% | COUNTEREXAMPLE (deliberate) |
| A2a, A2b | Quote is non-decreasing in `L`: exact reals; integer floor step `floor(la·c/d) ≤ floor(lb·c/d)` for `la ≤ lb` | PROVED |
| A3a–d | Floored amounts (in range, below, above) and the floored USD value never exceed exact math at the same sqrt price | PROVED |
| A3e | The oracle sqrt price is itself floored (`S' ≤ S* < S' + 1`); amounts read at `S'` are worth at most `L/(S'·2^96)` raw token1 more than the exact fair value at the true price | PROVED (bound) |
| A3f | Floor, then subtract 1 raw token1 unit: never above the exact fair value for `L ≤ 2^128`, `S' ≥ 2^32` | PROVED |
| A3g | Exact-integer search: at `L ≈ 2^127` and prices near `1e-38`, the floored quote beat the exact fair value by 0.269 raw token1. At `L ≤ maxLiquidityPerTick` no excess was found (best −0.00067). At launch-pair prices the bound is < 1e-13 raw units | COMPUTED (strict "never overvalues" fails at extreme L and price) |
| A4a–e | Oracle below the range: all token0, `a0 = L(sb − sa)/(sa·sb)`. Above: all token1, `a1 = L(sb − sa)`. Continuous at both ends; still the minimum over spot prices (A1a). Integer port agrees | PROVED / COMPUTED |
| A4f | Without the clamp, above the range: `x = L(1/sO − 1/sb)` is negative and floored at 0 while `y = L(sO − sa)` keeps growing, so the unclamped quote exceeds the clamped one by exactly `L·(sO − sb)` token1, unbounded in the oracle ratio | PROVED |
| A4g | The clamped quote never exceeds the unclamped one at any oracle price, so the clamp is the conservative branch | PROVED |
| A4h | Range `[0.99, 1.01]`, token1 depegged to $0.952 (oracle ratio 1.05), `L = 1,000,000`: clamped 10,000.125 token1 = $9,523.93; unclamped `y = 29,707.64`, `x = −19,137 → 0`, ×2.971 | COMPUTED (deliberate) |
| A5a [1, 10, 50, 100, 200, 2000] | int24 `tick % s == 0` ⇔ `tick = k·s`, negative ticks included | PROVED |
| A5b [same] | Accepted ranges lie in the usable ticks `[⌈MIN_TICK/s⌉·s, ⌊MAX_TICK/s⌋·s]` | PROVED |
| A5c [same] | A check on `uint24(tick) % s` disagrees with alignment (accepts tick −516 for s = 10); same for 50, 100, 200, 2000; correct for s = 1 | COUNTEREXAMPLE (deliberate) ×5, PROVED for s = 1 |
| A5d | `maxLiquidityPerTick` from 1.9e32 (s = 1) to 3.8e35 (s = 2000) | COMPUTED |
| A5e | Every spacing `s` in `[1, 16,384]` has `maxLiquidityPerTick(s) ≤ 2^120 − 1` exactly when `s ≤ 6,931` (1.324e36 at 6,931, 1.334e36 at 6,932, 1.540e36 at 8,000), the Slipstream listing bound of `REQ-AMM-SLIP-008` that keeps `REQ-AMM-SLIP-014` | COMPUTED (asserted) |
| A6a | A range nested in the market's range is worth at most the market's range per unit of `L`, at every oracle price, so crediting a narrower NFT at the market's value per unit can only overstate it | PROVED |
| A6b | With a check that the ticks lie inside the market range, a strictly narrower range is quoted above its own fair value | COUNTEREXAMPLE (deliberate) |
| A6c | Market `[0.90, 1.10]` (ticks −1054, 953), NFT on ticks `[−1, 1]`, price 1: value per unit of `L` 0.097863 against 0.00009999 raw units; a $10,000 NFT is quoted ×979 ($9.79M). An exact match of both ticks refuses it | COMPUTED (deliberate) |

### AMM-B — constant product (`ap02`)

| ID | Statement | Result |
|---|---|---|
| B1a, B1b | `2√(k·p0·p1) ≤ r0·p0 + r1·p1` for all reserves; equality only at the oracle price | PROVED |
| B2a, B2b | A swap never lowers `k` and raises it by less than `1/γ` (`γ = 0.997`): fair quote +0.1503% at most per swap | PROVED |
| B2c | From a pool at the oracle price, the fair-value gain of one swap ≤ the swapper's loss at oracle prices | PROVED |
| B2d, B3d | After any swap or donation the quote ≤ redeemable value | PROVED |
| B3a | Pool at the oracle price: a synced donation raises `V` by at most its own value | PROVED |
| B3b | Pool off the oracle price (`r1·p1 = 4·r0·p0`): a 1-unit donation raises `V` by 1.657 | COUNTEREXAMPLE (deliberate) |
| B3c | Pool within 1% of the oracle price: donation gain ≤ 1.005 × donation value | PROVED |
| B4a, B4b | Mint and burn rounding never lower value per LP (rounding cannot be farmed) | PROVED |
| B5a, B5b | `kLast`/`feeTo`: a `totalSupply` quote overstates by `(√k − √kLast)/(5√k + √kLast) ≤ (√(k/kLast) − 1)/6`; with `supply + pending` it is ≤ redeemable | PROVED |
| B6 | Naive spot reserves × price, 1M USDC / 500 WETH pool: a flash-funded 9M USDC swap makes it ×5.05 ($2.0M → $10.1M), fair moves +0.135%; round trip costs 5,421 USDC; at 31% LTV ≈ $2.5M of excess borrowing | COMPUTED (deliberate) |
| B7 | Quote from `balanceOf`: donate 100%, read ×2.0, `skim` it all back at no cost. `getReserves` quote unchanged | COMPUTED (deliberate) |
| B8 | Transfer + `sync`: per-LP +donation/supply (10% → ×1.100), donation locked (`skim` returns 0) | COMPUTED |
| B9 | Low supply (1,000 locked + 1): one LP unit worth donation/1001; a later depositor of 1.9 LP units' worth gets 1 LP and loses 47.3% to rounding | COMPUTED |
| B10 | `feeTo` on, 20 round trips of 5M: `k` ×1.104, `totalSupply` quote overstates by 0.814% (bound 0.848%) | COMPUTED |
| B11 | One swap of 1e3 … 1e12 USDC: +0.00015% … +0.15034% (bound 0.15034%) | COMPUTED |

### AMM-C — StableSwap and weighted (`ap03`)

| ID | Statement | Result |
|---|---|---|
| C1a, C1b | Weighted fair value ≤ redeemable (80/20, three tokens at 1/3) | PROVED |
| C1c | One swap into token i grows `k` by ≤ `(1 − fee)^(−w_i)` | PROVED |
| C1d | Weighted 50/50 at the oracle price: donation gain ≤ donation value | PROVED |
| C2a, C2b | n = 2 StableSwap: `2√(xy) ≤ D ≤ x + y` for every A | PROVED |
| C2c | `min(p)·D ≤ Σ x_i·p_i` for every A and imbalance | PROVED |
| C2d | `max(p)·D` (or a mean price) can exceed the redeemable value | COUNTEREXAMPLE (deliberate) |
| C3 | One imbalancing swap into 1M/1M (A = 200, 4 bps, off-peg ×2): virtual price ×1.000001 … ×1.27 (5M in); the quote gain ($531k) is far below the swapper's loss ($4.0M) | COMPUTED |
| C4 | After imbalancing swaps with coin 0 at 0.95/0.99/1.00: max quote/redeemable = 0.99997 | COMPUTED |
| C5 | Donation of 10% of one coin: virtual price ×1.05 | COMPUTED |
| C6 | Weighted 80/20, 0.3% fee: per-swap gain ≤ +0.2407% (token0 in) / +0.0601% (token1 in); max fair/redeemable 0.999997 | COMPUTED |

### Hypothesis (`test_hyp_amm_pricing.py`)

Each test keeps the ID the spec pages cite and carries the listing-method IDs `HYP-AMM-<P>-…` in brackets.

| ID | Property | Budget | Result |
|---|---|---|---|
| HYP-AMM-01 (`V3-MANIP-01`, `SLIP-MANIP-01`) | CL: spot composition ≥ fair (integer, 2-floor slack), random spacing, range, L ≤ maxLiquidityPerTick, decimals 6/8/18, prices $0.01–$10,000 | 400 | pass |
| HYP-AMM-02 (`V3-PRICE-01`, `SLIP-PRICE-01`) | CL: quote monotone in L | 300 | pass |
| HYP-AMM-03 (`V3-PRICE-02`, `SLIP-PRICE-02`) | CL: integer amounts and value ≤ exact rationals at the same sqrt price | 300 | pass |
| HYP-AMM-04 (`V3-PRICE-03`, `SLIP-PRICE-03`) | CL: all token0 below the range, all token1 above | 200 | pass |
| HYP-AMM-05 (`V3-PRICE-04`, `SLIP-PRICE-04`) | int24 `%` alignment for the six spacings; the `uint24` cast misfires | 500 | pass |
| HYP-AMM-06 (`V2-MANIP-01`) | v2: one block of ≤ 12 swaps, donations (sync or skim), mints and burns, `feeTo` on or off: quote ≤ redeemable after every step; fair value gain ≤ attacker's net inflow at oracle prices | 300 | pass |
| HYP-AMM-07 (`V2-MANIP-02`) | v2: one swap of any size: `k` ratio ≤ 1000/997 plus < 1 raw output unit of rounding; per-LP ≤ +0.15035% | 300 | pass |
| HYP-AMM-08 (`V2-PRICE-01`) | v2: `feeTo` overstatement ≤ `(√(k/kLast) − 1)/6` | 200 | pass |
| HYP-AMM-09 (`V2-MANIP-03`) | v2 (deliberate): naive spot quote +8.3% … ×10 from one swap; `balanceOf` quote ×2 free with `skim` | 150 | pass (attack confirmed) |
| HYP-AMM-10 (`CURVE-MANIP-01`) | StableSwap n = 2, 3, A 10…2000, coins at 0.90–1.00: `min(p)·D` ≤ redeemable after swaps and donations; swaps never lower D | 200 | pass |
| HYP-AMM-11 (`BAL-MANIP-01`) | Weighted 50/50, 80/20, 20/80, 1/3 each: fair ≤ redeemable; per-swap `k` growth ≤ `(1 − fee)^(−w_i)` | 200 | pass |

Also run at `AVANA_HYP_SCALE=20` (≈ 70 s): all pass. At extreme imbalance (about 1e5:1, A = 10) the StableSwap integer `get_D` does not converge within 255 rounds. The pool reverts there, so the oracle must treat a reverting `get_virtual_price` / `D` read as a price failure.

## Guards each pool type needs before listing

**Concentrated liquidity**
- Read amounts at the oracle sqrt price only; never read `slot0` amounts (A1). A TWAP or spot deviation check may gate the quote but must not feed it.
- Floor every step, then subtract one raw unit of value (A3f). Also bound `L/(S'·2^96)` at listing.
- Check range alignment with signed int24 `tick % tickSpacing == 0`, never on a `uint24` cast (A5c). Read `tickSpacing()` from the pool.
- Exclude uncollected fees (`tokensOwed`, fee growth) from the quote. A wash trader can raise them in one transaction.
- Out of range, the position is one token. Haircut it as that token alone; there is no IL dampening.

**Constant product**
- Use `getReserves()`, never `balanceOf` (B7).
- Use `totalSupply + pending _mintFee liquidity` when `feeTo` is set (B5, B10).
- Require the pool's spot price within a tolerance of the oracle price (for example 1%), so donation gain stays ≤ 1.005× its cost (B3b, B3c).
- Set a minimum `totalSupply` (for example ≥ 10^6 × MINIMUM_LIQUIDITY) and a minimum pool value (B9).
- Cap the per-block change of the per-LP quote at a few × 0.15% per swap of headroom (for example 1%). Larger moves read as Cached (B2b, B8).

**StableSwap and weighted**
- StableSwap: quote `min(p_i)·virtual_price`, never a mean or max price (C2d).
- Weighted: use the invariant formula, and the BPT supply that includes pending protocol-fee BPT (`getActualSupply`-style).
- Treat a reverting `get_D` / virtual-price read as a failure.
- Cap the per-block quote change; imbalancing swaps can move virtual price +27% (C3), though the attacker pays more than the gain.
- Read-only reentrancy (not modelled): virtual price and weighted-pool rates read inside the pool's own callback (ETH or token hooks mid-`remove_liquidity`, or a vault mid-join/exit) are wrong. Before every read, call a state-changing, reentrancy-locked pool function: StableSwap `withdraw_admin_fees` or `remove_liquidity(0, [0…])`, depending on version. For a weighted vault, use the vault reentrancy check (`ensureNotInVaultContext`). Fail closed if the lock is held.
