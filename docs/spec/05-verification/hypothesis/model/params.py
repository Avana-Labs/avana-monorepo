# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Parameter values used by the model: launch values from 1.5 Parameters (Q-196, Q-210, Q-230, Q-241, Q-251,
Q-262, Q-267, Q-274) where set, Aave values from the listing ceiling (Q-185, Q-186), and the per-market values
set with the Aave risk service providers (Q-197) chosen here within their bounds."""
from dataclasses import dataclass, field
from .mathlib import WAD, RAY

DAY = 86400
HOUR = 3600
USD = 10 ** 8


@dataclass
class Params:
    # Health (Q-398): no on-chain opening floor. The Lens recommends borrowing to HF 1.10 beside the maximum at
    # Aave's HF 1.00; an optional per-market hard floor is off (0) by default.
    recommended_hf: int = 110 * WAD // 100
    hard_floor_hf: int = 0
    # Aave Spoke configuration (Q-185, Q-186): target HF 1.10, CF 31.2%, max bonus 5%, factor 50%
    target_hf: int = 110 * WAD // 100
    hf_for_max_bonus: int = 90 * WAD // 100
    lb_factor: int = 5000
    cf_bps: int = 3120
    max_lb_bps: int = 10500
    collateral_risk_bps: int = 500
    max_user_reserves: int = 16                  # Spoke per-account reserve limit (Q-193)
    # Kinked utilization curves set by the Aave DAO (SPEC-HUB-007, Q-408), in bps:
    # (baseDrawnRate, rateGrowthBeforeOptimal, rateGrowthAfterOptimal, optimalUsageRatio). GHO keeps a 5.50 % base
    # as its floor; the USDC curve has no floor.
    gho_curve: tuple = (550, 360, 5000, 9000)
    usdc_curve: tuple = (0, 650, 4000, 9200)
    # Exposure caps (Q-055, Q-174, Q-175, Q-197, SPEC-CAP-002): USD with 8 decimals
    cap_market_usd: int = 3_000_000 * USD
    topup_slice_usd: int = 300_000 * USD
    cap_token_usd: int = 5_000_000 * USD
    cap_depositor_usd: int = 1_500_000 * USD
    pool_share_bps: int = 1000                   # poolShareMaxBps (SPEC-CAP-005)
    stress_floor_usd8: int = USD                 # $1.00 per whole vault token
    min_pledge_usd: int = 10 * USD               # Q-230, Q-277
    rescue_min_pledge_usd: int = 10 * USD        # RESCUE_MIN_PLEDGE_USD (Q-252)
    keeper_floor: int = 1                        # Avana's own keeper (Q-400); borrowing halts only at 0
    max_keepers: int = 32
    # Oracle (Q-182, Q-183, Q-184, Q-195, Q-196, Q-274): primary heartbeat 1 h, alternate 24 h
    heartbeat: int = HOUR
    alt_heartbeat: int = DAY
    age_margin: int = 600                        # feedMaxAge = liquidationPriceMaxAge = heartbeat + 600
    borrow_age_cap: int = 4200                   # borrowPriceMaxAge = min(heartbeat + 600, 4,200)
    cached_window: int = HOUR
    disagreement_pause_max: int = HOUR
    alt_tol_bps: int = 150                       # feedAgreementToleranceBps
    twap_tol_bps: int = 50
    band_low: int = 90_000_000                   # usdBandLow, usdBandHigh (SPEC-ORC-011)
    band_high: int = 102_000_000
    stable_ceiling: int = USD
    min_answer: int = 5 * 10 ** 6
    max_answer: int = 10 ** 9
    grace_period: int = 30 * 60
    grace_hf: int = 95 * WAD // 100
    debt_stress_rise_bps: int = 500              # debtStressRiseBps (USDC)
    # Settlement (Q-159, Q-190, Q-198, Q-235, Q-250, Q-251, Q-256, Q-261)
    slippage_bps: int = 100
    slippage_min_bps: int = 40
    floor_rounding_allowance: int = WAD          # floorRoundingAllowanceGho = 1 GHO
    avana_fee_share_bps: int = 2000
    flash_fee_bps: int = 5                       # Aave V3 FLASHLOAN_PREMIUM_TOTAL
    max_flash_fee_bps: int = 10                  # maxFlashFeeBps (Q-317)
    max_shortfall_bps: int = 1000
    flash_capacity: int = 5_000_000 * WAD        # Aave V3 Pool idle liquidity per debt asset (about $5M)
    dex_slippage_bps: int = 30
    # Circuit breakers (Q-399): oracle/band, pool-share concentration (merged with poolShareMaxBps) and the
    # deficit freeze trip on-chain; price drop, seizure surge and route failures are monitoring alerts only.
    breaker_deficit_max: dict = field(default_factory=lambda: {"GHO": 10_000 * WAD, "USDC": 10_000 * 10 ** 6})
    freeze_rate_limit: int = 20                  # freezeAddress per guardian in 24 one-hour buckets (Q-242); the model counts a continuous 24 h window
    # Funding (Q-233, Q-236, Q-407): the credit line is the borrow side (the CDP Spokes' drawCap); lending is public, so
    # the Lend Spoke addCap is a separate supply cap (whole tokens) on the DAO's bootstrap supply plus public supply
    credit_line: dict = field(default_factory=lambda: {"GHO": 2_000_000 * WAD, "USDC": 1_000_000 * 10 ** 6})
    bootstrap_supply: dict = field(default_factory=lambda: {"GHO": 2_000_000 * WAD, "USDC": 1_000_000 * 10 ** 6})
    lend_supply_cap: dict = field(default_factory=lambda: {"GHO": 10_000_000, "USDC": 5_000_000})
    first_loss: dict = field(default_factory=lambda: {"GHO": 400_000 * WAD, "USDC": 50_000 * 10 ** 6})
    first_loss_min: dict = field(default_factory=lambda: {"GHO": 400_000 * WAD, "USDC": 50_000 * 10 ** 6})
    # Faulty upgradeable RiskModule (only Aave's own checks bind, SPEC-CF-003)
    faulty_risk_module: bool = False

    def feed_max_age(self, hb):
        return hb + self.age_margin

    def borrow_max_age(self, hb):
        return min(hb + self.age_margin, self.borrow_age_cap)
