# SPDX-License-Identifier: LicenseRef-BUSL
# Copyright (c) 2026 Avana Labs
# Contains a port of Aave V4 code (aave/aave-v4 commit a3ef63e, (c) Aave Labs), used only in test environments under
# the Aave V4 license in LICENSES/LicenseRef-BUSL-AaveV4.md; see THIRD_PARTY_LICENSES.md.
"""Integer math used by the Avana reference model.

Mirrors, with the same rounding directions:
  Aave V4 @ a3ef63ea6415d25237a9775bf66e76e9993561c2
    src/libraries/math/WadRayMath.sol, PercentageMath.sol, MathUtils.sol
    src/hub/libraries/SharesMath.sol (VIRTUAL_ASSETS = VIRTUAL_SHARES = 1e6)
    src/spoke/libraries/SpokeUtils.sol (toValue)
  OpenZeppelin Math.mulDiv / Math.sqrt (floor unless stated).
Every helper checks the Solidity bit width it stands for, so an overflow in the
model raises instead of silently growing like a Python int.
"""

WAD = 10 ** 18
RAY = 10 ** 27
BPS = 10 ** 4                       # PercentageMath.PERCENTAGE_FACTOR
VIRTUAL = 10 ** 6                   # SharesMath VIRTUAL_ASSETS / VIRTUAL_SHARES
SECONDS_PER_YEAR = 365 * 24 * 3600  # MathUtils.SECONDS_PER_YEAR

U40 = 2 ** 40 - 1
U96 = 2 ** 96 - 1
U120 = 2 ** 120 - 1
U128 = 2 ** 128 - 1
U160 = 2 ** 160 - 1
U200 = 2 ** 200 - 1
U256 = 2 ** 256 - 1

HF_LIQ = 10 ** 18                   # HEALTH_FACTOR_LIQUIDATION_THRESHOLD
DUST_VALUE = 1000 * 10 ** 26        # DUST_LIQUIDATION_THRESHOLD = 1000e26 (USD, 8-dec price x 1e18)


class Overflow(Exception):
    """A value exceeded the Solidity type it models (the real contract reverts)."""


def chk(x, bound=U256, what="uint256"):
    if x < 0 or x > bound:
        raise Overflow(f"{what} out of range: {x}")
    return x


def cdiv(a, b):
    """Ceil division for non-negative a, positive b."""
    return -(-a // b)


def mul_div(a, b, c, up=False):
    """OpenZeppelin Math.mulDiv with Floor/Ceil rounding (512-bit intermediate, result must fit 256)."""
    chk(a), chk(b)
    if c == 0:
        raise ZeroDivisionError("mulDiv by zero")
    r = cdiv(a * b, c) if up else (a * b) // c
    return chk(r)


def isqrt(x):
    """OpenZeppelin Math.sqrt (floor)."""
    chk(x)
    if x == 0:
        return 0
    r = 1 << ((x.bit_length() + 1) // 2)
    while True:
        y = (r + x // r) // 2
        if y >= r:
            return r
        r = y


# --- WadRayMath --------------------------------------------------------------

def ray_mul_up(a, b):
    return chk(cdiv(chk(a * b), RAY))


def ray_mul_down(a, b):
    return chk(a * b) // RAY


def ray_div_up(a, b):
    return chk(cdiv(chk(a * RAY), b))


def ray_div_down(a, b):
    return chk(a * RAY) // b


def to_ray(a):
    return chk(a * RAY)


def from_ray_up(a):
    return cdiv(a, RAY)


def round_ray_up(a):
    return chk(cdiv(a, RAY) * RAY)


def bps_to_wad(a):
    return chk(a * (WAD // BPS))


def div_up(a, b):
    """MathUtils.divUp."""
    return cdiv(a, b)


# --- PercentageMath ----------------------------------------------------------

def percent_mul_down(v, p):
    return chk(v * p) // BPS


def percent_mul_up(v, p):
    return cdiv(chk(v * p), BPS)


# --- SharesMath (Hub added shares, virtual offset 1e6) ------------------------

def to_shares_down(assets, total_assets, total_shares):
    return mul_div(assets, total_shares + VIRTUAL, total_assets + VIRTUAL)


def to_shares_up(assets, total_assets, total_shares):
    return mul_div(assets, total_shares + VIRTUAL, total_assets + VIRTUAL, up=True)


def to_assets_down(shares, total_assets, total_shares):
    return mul_div(shares, total_assets + VIRTUAL, total_shares + VIRTUAL)


def to_assets_up(shares, total_assets, total_shares):
    return mul_div(shares, total_assets + VIRTUAL, total_shares + VIRTUAL, up=True)


# --- SpokeUtils ----------------------------------------------------------------

def to_value(amount, decimals, price):
    """SpokeUtils.toValue: amount * price * 10^(18 - decimals) (USD x 1e26 for an 8-dec price)."""
    return chk(amount * price * 10 ** (18 - decimals))


def linear_interest(rate_ray, dt):
    """MathUtils.calculateLinearInterest: RAY + rate * dt / SECONDS_PER_YEAR (rate is uint96 RAY)."""
    chk(rate_ray, U96, "uint96 rate")
    return rate_ray * dt // SECONDS_PER_YEAR + RAY
