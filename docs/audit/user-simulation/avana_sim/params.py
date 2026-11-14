"""Protocol parameters (spec values) and modelling assumptions.

Every protocol value cites the spec page that fixes it. Every value marked
ASSUMPTION is a modelling input that the spec leaves to the listing payload,
to Aave, or to the outside world; the report lists them.
"""

MIN = 60
HOUR = 3600
DAY = 86400
YEAR = 365 * DAY

# ---------------------------------------------------------------- protocol (spec)
RECOMMENDED_HF = 1.10          # Lens recommendedBorrow target (Q-398); users borrow to it, rescue top-ups restore it
MIN_HF = 1.00                  # Aave V4 liquidation threshold; previewBorrowMax target (Q-398)
MARKET_HARD_FLOOR_HF = 0.0     # optional per-market hard floor (Q-398): off (0) by default
BORROW_AGE_MARGIN = 600        # 1.5 BORROW_AGE_MARGIN (Q-274)
BORROW_AGE_CAP = 4200          # 1.5 BORROW_AGE_CAP (Q-274)
MAX_PRIMARY_HEARTBEAT = 3600   # REQ-ORACLE-054: every primary (and standby) leg; a token without one is not listed
FEED_MAX_AGE_PAD = 600         # feedMaxAge = liquidationPriceMaxAge = heartbeat + 600 (1.5)


def borrow_max_age(hb):
    """borrowPriceMaxAge of a feed: min(heartbeat + 600, 4,200) seconds (Q-274, REQ-ORACLE-054)."""
    return min(hb + BORROW_AGE_MARGIN, BORROW_AGE_CAP)


def liq_max_age(hb):
    """liquidationPriceMaxAge (= feedMaxAge) of a feed: heartbeat + 600 seconds (1.5)."""
    return hb + FEED_MAX_AGE_PAD

CACHED_WINDOW = 3600           # 1.5 cachedWindow (Q-183)
DISAGREE_PAUSE_MAX = 3600      # 1.5 disagreementPauseMax (Q-208)
AGREEMENT_MARGIN = 0.0050      # 1.5 feedAgreementMarginBps = 50
TWAP_WINDOW = 1800             # 1.5 twapWindow
TWAP_TOL_TICKS = 50            # 1.5 twapToleranceTicks
USD_BAND = (0.90, 1.02)        # 1.5 usdBandLow (uncapped q) / usdBandHigh (capped v) (Q-195, Q-275)
STABLE_CEILING = 1.00          # 1.5 stableCeilingUsd (Q-177)
GRACE_DURATION = 1800          # 1.5 graceDuration
GRACE_HF = 0.95                # 1.5 graceHealthFactor
MIN_PLEDGE_USD = 10.0          # 1.5 minPledgeUsd (Q-230, Q-277)
RESCUE_MIN_PLEDGE_USD = 10.0   # 1.5 RESCUE_MIN_PLEDGE_USD (Q-252)
STRESS_FLOOR_PER_VT = 1.00     # 1.5 stressFloorUsd per whole vault token
POOL_SHARE_MAX = 0.10          # 1.5 poolShareMaxBps = 1,000, also the concentration gate (Q-399)
TOPUP_SLICE_FRACTION = 0.10    # 1.5 topUpSliceUsd = 10% of marketUsdCap
SLIPPAGE_ALLOWANCE = 0.01      # 1.5 slippageAllowanceBps = 100
FLOOR_ROUNDING_GHO = 1.0       # 1.5 floorRoundingAllowanceGho
AVANA_FEE_SHARE = 0.20         # 1.5 avanaFeeShareBps (Q-231), on oracle value (Q-256)
# No SettlementBudget (Q-397): the keeper funds debtToCover, the flash principal and premium up front;
# a rounding gap at final settlement is paid by the caller through the shortfall top-up.
MAX_SHORTFALL_BPS = 0.10       # 1.5 maxShortfallBps = 1,000 (Q-251)
SHORTFALL_GAP = HOUR           # REQ-SWAP-103: a gap over one hour starts a new run
# Breakers (Q-399). Price drop, seizure surge and route failures are monitoring alerts, not on-chain trips.
ALERT_PRICE_DROP = 0.03        # alert: 3% in 2 hours
ALERT_SEIZURE = 0.20           # alert: seized above 20% of a market in 1 hour
ALERT_ROUTE_FAILURES = 3       # alert: 3 swap-route failures in 1 hour
ALERT_WINDOW = HOUR
BREAKER_DEFICIT_MAX = 10_000.0  # 1.5 breakerDeficitMax: 10,000 GHO per CDP Spoke (same units for USDC, set at listing)
BREAKER_RECOVERY = 30 * MIN    # 30 min of healthy observations clear a temporary gate (provisional)
CHECKPOINT_INTERVAL = HOUR     # REQ-ORACLE-088 hourly price checkpoint
MAX_ADDRESS_FREEZES_PER_DAY = 20  # 1.5 (Q-242)
BORROW_MAX_MARGIN = 1.005      # 1.5 BORROW_MAX_MARGIN_BPS = 50 (Q-268)
REPAY_ALL_MARGIN = 1.001       # 1.5 REPAY_ALL_MARGIN_BPS = 10 (Q-269)
PAUSE_REASON = 'General'       # the scenario's governance pause carries reason General (Q-252)
KEEPER_FLOOR = 1               # 1.5 keeperFloor (Q-400): new borrowing halts only at 0 active keepers
MAX_KEEPERS = 32
NORMAL_DELAY = 5 * DAY         # 1.5 timelockNormalDelay (restorePriceRoute waits it)
CREDIT_LINE = {'GHO': 2_000_000.0, 'USDC': 1_000_000.0}  # GHO from 1.5 (Q-006); USDC: ASSUMPTION (set at listing)

# Aave V4 Borrow Spoke liquidation configuration (2.1, 3.5 LIQ-068)
TARGET_HF = 1.10               # aaveTargetHealthFactor (Q-185)
MAX_LB = 1.05                  # maxLiquidationBonus 10,500
LB_FACTOR = 0.40               # liquidationBonusFactor 4,000 -> min bonus 2%
HF_FOR_MAX_BONUS = 0.90
DUST_USD = 1000.0              # Aave V4 DUST_LIQUIDATION_THRESHOLD ($1,000)

# Debt reserves: GHO fixed $1 (Q-100); USDC via its Chainlink feed (Q-238).
DEBT_ASSETS = ('GHO', 'USDC')
# Settlement in the debt asset that was repaid (3.5, Q-358): no buy leg. A pool token that is the
# debt asset needs no swap; a GHO leg sold for USDC pays the GSM fee below (ASSUMPTION).
GHO_TO_USDC_COST = 0.002
# Flash source (IFlashSource, Aave V3 Pool flashLoan; 3.5 LIQ-030, REP-018)
FLASH_PREMIUM = 0.0005         # live Aave V3 FLASHLOAN_PREMIUM_TOTAL = 5 bps (Q-279)
MAX_FLASH_FEE = 0.0010         # 1.5 maxFlashFeeBps = 10 on Ethereum (Q-335)
# Idle Aave V3 Pool balance of each debt asset (ASSUMPTION, Ethereum); a larger repay takes the
# caller-funded path (Kf = D, no premium)
FLASH_LIQUIDITY = {'GHO': 20_000_000.0, 'USDC': 300_000_000.0}
# No minimum debt on any chain (Q-381): a borrower may borrow any amount; Avana's own keepers liquidate and pay the gas.
DEBT_STRESS_RISE = {'USDC': 0.05}        # 1.5 debtStressRiseBps (500 for USDC) (Q-247, Q-248)

# ---------------------------------------------------------------- markets
# CF = min(CF0, CF1) x poolRiskFactor (2.7); caps set in the listing payload.
# Caps, CFs, fee APRs and pool composition are ASSUMPTIONS sized like the
# worked examples in 3.1 and 3.5.
MARKETS = {
    'USDC/USDT': dict(tokens=('USDC', 'USDT'), cf=0.312, cap=8_000_000.0, fee_apr=0.015,
                      conc_fee_mult=12.0,
                      pool=dict(full_range=8_000_000.0, buckets=[(0.0005, 120_000_000.0), (0.005, 30_000_000.0), (0.05, 3_000_000.0)])),
    'GHO/USDC': dict(tokens=('GHO', 'USDC'), cf=0.300, cap=5_000_000.0, fee_apr=0.040,
                     conc_fee_mult=8.0,
                     pool=dict(full_range=6_000_000.0, buckets=[(0.002, 20_000_000.0), (0.02, 10_000_000.0)])),
    'DAI/USDC': dict(tokens=('DAI', 'USDC'), cf=0.300, cap=4_000_000.0, fee_apr=0.010,
                     conc_fee_mult=12.0,
                     pool=dict(full_range=5_000_000.0, buckets=[(0.0005, 80_000_000.0), (0.005, 15_000_000.0)])),
    'USDe/USDT': dict(tokens=('USDe', 'USDT'), cf=0.252, cap=3_000_000.0, fee_apr=0.060,
                      conc_fee_mult=6.0,
                      pool=dict(full_range=4_000_000.0, buckets=[(0.005, 15_000_000.0), (0.05, 5_000_000.0)])),
}
MARKET_IDS = list(MARKETS)
TOKEN_USD_CAP = 20_000_000.0    # tokenUsdCap per token (3.1 worked example)
DEPOSITOR_USD_CAP = 1_000_000.0  # depositorUsdCap (3.1 worked example)

# ---------------------------------------------------------------- feeds (ASSUMPTION)
# Primary route per token: Chainlink TOKEN/USD. 'spec' profile: every primary leg
# has a 1-hour heartbeat, which REQ-ORACLE-054 requires for listing. 'mainnet'
# profile: 24-hour heartbeat on the USDC, USDT, GHO and USDe primaries. The listing
# check of REQ-ORACLE-054 refuses such a primary, so this profile is a counterfactual
# that measures what the listing rule prevents.
# Alternate route: a TOKEN/ETH x ETH/USD composite, 24-hour heartbeat, 1% deviation.
# Standby route (Q-248): a third, independent 1-hour feed per token, listed with the
# primary's checks, which keeps publishing through the scenario's feed outages.
FEED_PROFILES = {
    'spec': {t: (0.0025, 3600) for t in ('USDC', 'USDT', 'DAI', 'GHO', 'USDe')},
    'mainnet': {'USDC': (0.0025, 86400), 'USDT': (0.0025, 86400), 'DAI': (0.0025, 3600),
                'GHO': (0.005, 86400), 'USDe': (0.005, 86400)},
}
ALT_FEED = (0.010, 86400)
STANDBY_FEED = (0.0025, 3600)
# Monitoring pages on a leg's age at 90% of its feedMaxAge and on a debt feed's age at
# 90% of liquidationPriceMaxAge (Q-244, M-03/M-04); the guardian confirms on-chain and
# calls useStandbyRoute this long after the page (Q-243 triage, 3-of-5 Safe). ASSUMPTION.
PAGE_AGE_FRACTION = 0.90
GUARDIAN_REACTION = 45 * MIN
DISAGREEMENT_PAGE = 30 * MIN     # M-02 pages 30 minutes before disagreementPauseMax ends
FEED_DELAY = (12, 75)            # seconds from trigger to on-chain round, calm (ASSUMPTION)
FEED_DELAY_CONGESTED = (30, 420)  # during gas spikes (ASSUMPTION)

# ---------------------------------------------------------------- costs (ASSUMPTION)
# Etherscan gas tracker, 2026-11-10 16:19 UTC: base fee and Standard 0.939 gwei, Rapid 1.139 gwei; a
# 21,000-gas transfer at $0.041 implies ETH at about $2,080.
ETH_USD = 2080.0
# Gas price path, gwei. Calm minutes follow base_lo + (base_hi - base_lo) x sin^2(2 pi x day fraction),
# times exp(N(0, noise_sigma)). Stress windows raise the price to at least the listed floor: 5-10 gwei
# on shock days, 30 gwei on the worst crash day.
GAS_PRICE = {
    'base_lo': 0.1, 'base_hi': 1.2, 'noise_sigma': 0.25,
    'scenario_shock': 5.0, 'scenario_shock_eth_drop': 8.0,   # SHOCK_DAY, first 12 h
    'usdt_depeg': 5.0,                                        # day 30.0-30.5
    'usde_crash_peak': 30.0, 'usde_crash_tail': 10.0,         # day 60.0-60.5, 60.5-61.0
    'late_spike': 4.0,                                        # day 75.25-75.5, below congestion
}
# A minute is congested (Chainlink rounds land with FEED_DELAY_CONGESTED, transactions take longer to
# be included) when the gas price exceeds this multiple of base_hi: 4 x 1.2 = 4.8 gwei. Calm noise
# would need a 5.5-sigma draw at the daily peak to reach it.
GAS_CONGESTION_MULT = 4.0
GAS_CONGESTION_GWEI = GAS_CONGESTION_MULT * GAS_PRICE['base_hi']
GAS = {  # gas units, estimated from comparable Aave V3 / Uniswap v3 calls plus Avana's checks
    'nft_approve': 50_000, 'erc20_approve': 46_000,
    'pledge_first': 900_000, 'pledge': 480_000,
    'borrow': 330_000, 'borrow_per_extra_market': 70_000,
    'repay': 190_000, 'withdraw': 320_000, 'repay_all_withdraw': 460_000,
    'collect': 140_000, 'release_zero': 160_000,
    'mint_nft': 520_000, 'decrease_collect': 230_000, 'swap': 150_000,
    # SPEC-CHAIN-001 gas units model: G(n) = 1,310,000 + 240,000 x n for an account with n records, flash loan
    # included (G(1) = 1,550,000; G(16) = 5,150,000 <= 16,777,216, the per-transaction gas limit)
    'liquidate': 1_310_000, 'liquidate_per_record': 240_000,
    'repay_with_collateral': 1_100_000, 'remove_liquidity': 380_000, 'recredit': 420_000,
    'revert_fraction': 0.45,
}
SWAP_COST = 0.0005        # stable swap cost when a user buys the debt asset (ASSUMPTION)
RATES = {'GHO': 0.065 + 0.010, 'USDC': 0.055 + 0.010}  # borrow APR incl. Aave risk premium (ASSUMPTION)
USDC_STRESS_RATE = 0.11   # USDC rate days 60-70 (utilisation spike, ASSUMPTION)
APP_DEADLINE = 15 * MIN   # app default deadline (ASSUMPTION; the spec leaves it to the app)
APP_REPAY_BUFFER = 0.0    # app approves exactly Lens.quoteRepayAll (webapp/README.md, Q-269)

# ---------------------------------------------------------------- deployment topologies (design review)
# Used only when the simulation runs with a topology (Sim(topology=...)); the base runs keep the
# four markets above. Three stable markets: one USDC/USDT and one DAI/USDC pool on AMM protocol A
# (chain A), and one USDC/USDT pool on AMM protocol B on a second chain (chain B). T3 adds a
# WETH/USDC market on a Volatile-Hub Spoke. Caps, CFs and pool depths are ASSUMPTIONS sized like
# the markets above; the WETH/USDC CF is min(CF_WETH 0.80, CF_USDC 0.78) x poolRiskFactor 0.50.
BASE_MARKETS = dict(MARKETS)
TOPO_MARKETS = {
    'USDC/USDT': dict(MARKETS['USDC/USDT'], chain='A'),
    'DAI/USDC': dict(MARKETS['DAI/USDC'], cap=5_000_000.0, chain='A'),
    'USDC/USDT-B': dict(tokens=('USDC', 'USDT'), cf=0.312, cap=4_000_000.0, fee_apr=0.020, conc_fee_mult=10.0, chain='B',
                        pool=dict(full_range=3_000_000.0, buckets=[(0.0005, 25_000_000.0), (0.005, 6_000_000.0)])),
    'WETH/USDC': dict(tokens=('WETH', 'USDC'), cf=0.390, cap=5_000_000.0, fee_apr=0.12, conc_fee_mult=4.0, chain='A',
                      volatile=True, breaker_drop=0.15,
                      pool=dict(full_range=40_000_000.0, buckets=[(0.10, 60_000_000.0)])),
}
STABLE_TOPO_MARKETS = ('USDC/USDT', 'DAI/USDC', 'USDC/USDT-B')
# Spoke of each market per topology. A Spoke lives on one chain, so the chain-B market has its own
# Spoke in every topology. T3 = T2 plus a Volatile-Hub Spoke that borrows USDC from the Stable Hub.
TOPOLOGIES = {
    'T1': {'USDC/USDT': 'A:USDC/USDT', 'DAI/USDC': 'A:DAI/USDC', 'USDC/USDT-B': 'B:USDC/USDT'},
    'T2': {'USDC/USDT': 'A:Stable', 'DAI/USDC': 'A:Stable', 'USDC/USDT-B': 'B:Stable'},
    'T3': {'USDC/USDT': 'A:Stable', 'DAI/USDC': 'A:Stable', 'USDC/USDT-B': 'B:Stable', 'WETH/USDC': 'V:Volatile'},
}
# Per-Spoke drawCap on each debt reserve of the Stable Hub (SPEC-HUB-003: the sum over Spokes equals
# the credit line), split in proportion to each Spoke's expected demand (ASSUMPTION). The Volatile
# Spoke borrows USDC only; its line is carved out of the Stable Hub's USDC credit line.
TOPO_DRAW_CAPS = {
    'T1': {'A:USDC/USDT': {'GHO': 900_000.0, 'USDC': 450_000.0}, 'A:DAI/USDC': {'GHO': 600_000.0, 'USDC': 300_000.0},
           'B:USDC/USDT': {'GHO': 500_000.0, 'USDC': 250_000.0}},
    'T2': {'A:Stable': {'GHO': 1_500_000.0, 'USDC': 750_000.0}, 'B:Stable': {'GHO': 500_000.0, 'USDC': 250_000.0}},
    'T3': {'A:Stable': {'GHO': 1_500_000.0, 'USDC': 600_000.0}, 'B:Stable': {'GHO': 500_000.0, 'USDC': 200_000.0},
           'V:Volatile': {'GHO': 0.0, 'USDC': 200_000.0}},
}
FIRST_LOSS_RESERVE = {'GHO': 100_000.0, 'USDC': 50_000.0}   # firstLossReserveMinimum: GHO from 1.5; USDC ASSUMPTION
WETH_DAILY_VOL = 0.035          # ASSUMPTION: WETH/USD daily volatility on the calm path
WETH_FEED = (0.005, 3600)       # Chainlink ETH/USD: 0.5% deviation, 1-hour heartbeat


def use_markets(markets):
    """Swap the market set in place (MARKETS and MARKET_IDS are read at call time everywhere)."""
    MARKETS.clear()
    MARKETS.update(markets)
    MARKET_IDS[:] = list(markets)
