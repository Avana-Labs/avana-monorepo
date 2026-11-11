// -*- mode: Bluespec; -*-
//
// Avana v1 — cross-contract state machine (spec stage).
//
// Models the final design (spec/04-security/04-design-decisions.md, Q-001 … Q-278).
// Property IDs (QNT-…), bounds and readings are listed in quint/README.md.
// Scenario tests: avana_tests.qnt.
//
// One state variable `s` holds every contract's storage; `la` records the
// last action so traces read as a story.
//
// Step relations (pick with `quint run --step=…`):
//   step                reviewed Avana components, attacker EOA, guardians, the
//                       AvanaTimelock (schedule / execute / cancel), Aave governance
//   stepHostilePolicy   step + a hostile RiskModule implementation (Q-229)
//   stepHostileSwap     step + a hostile LPVaultSwap implementation (Q-224, Q-257)
//   stepAll             step + both of the above
//   stepHostileAdapter  step + a hostile AaveAdapter implementation (Q-223 blast radius)
//
// Abstractions (README "Bounds and assumptions"):
//   * one vault-token unit = one unit of credited liquidity (Q-066); its GHO
//     value is the LPOracle price (integer GHO per unit); CF is one flat percentage;
//     Hub shares == assets unless a market is flagged, so share and unit checks coincide;
//   * debt values are kept in GHO cents (GHO = 100 per unit, USDT at its DebtOracle price);
//   * Aave V4 liquidation follows LiquidationLogic (dust rule, collateral cap,
//     MustNotLeaveDust, deficit reporting) with a flat bonus and no target-HF limit;
//   * time is an integer `now` (one tick ≈ one hour, values scaled).
module avana {

  // ---------------------------------------------------------------- types

  type PS = Live | Drifting | Cached | Expired

  type Nft = { owner: str, liquidity: int, fees: int, pool: str }

  type BRec = {
    tokenId: int, depositor: str, proxy: str, market: str,
    credited: int, rescue: int, open: bool
  }

  // timelock operation (AvanaTimelock, Q-228, Q-262, Q-263)
  type OpT = { calls: Set[str], tgt: str, arg: int }
  type Op = {
    calls: Set[str], tgt: str, arg: int, proposer: str,
    schedAt: int, readyAt: int, status: str, by: str
  }

  // Design variants. DESIGN_FINAL is the current design; the tests build
  // superseded variants to replay the problems they removed.
  type Design = {
    debitCheck: str,                 // "DELTA" (Q-160 snapshot) or "LEDGER" (Σ credited == supply)
    principalCappedCollect: bool,    // Q-061
    latch: str,                      // "TIMESTAMP" (Q-154) or "READ" (Q-129 as first written)
    backingCheck: str,               // "ONE_SIDED" (Q-257) or "EQUALITY" (Q-224 as first written)
  }

  // liquidation call parameters (LiquidationParams; route outcome chosen by the environment)
  type LiqP = {
    d: int,                          // debtToCover
    s0: int, s1: int,                // realised slippage of the two sell legs, percent
    k: int,                          // maxShortfallGho (Q-251)
    b: int,                          // realised buy slippage, percent (non-GHO debt)
    over: int,                       // debt asset bought above what Aave pulls (sold back, Q-256)
    dl: int, minPay: int,            // deadline and minimum payout (Q-216)
  }

  type Ghost = {
    seizers: Set[str],               // liquidators whose liquidationCall moved vault tokens
    deficitReporters: Set[str],      // liquidators whose liquidationCall reported a deficit
    borrowStale: bool,               // borrow / debt-keeping exit with a Cached/Expired market or failing debt price
    borrowDegraded: bool,            // borrow / debt-keeping exit outside the reviewed gates
    borrowBelowFloor: bool,          // rescue-excluded HF below max(openHf, 1.00) after a borrow / debt-keeping exit
    borrowOverCap: bool,             // borrow beyond drawCap or Hub liquidity
    borrowBelowAave: bool,           // Aave HF below 1 after a borrow or withdrawal
    nonOwnerAction: bool,            // a borrower action changed a proxy its caller does not own
    liqStale: bool,                  // seizure of a stale market or repayment of a stale debt reserve
    liqHealthy: bool,                // seizure of an account with HF >= 1
    liqGraceBreach: bool,            // seizure inside the real recovery grace without deep HF
    debitMismatch: bool,             // records debited != Spoke supply decrease != burned
    largestFirstBreach: bool,        // a smaller record debited while a larger one had credit
    floorBreach: bool,               // settlement below the recovery floor
    conservationBreach: bool,        // GHO waterfall does not balance
    gapOnZeroSeize: bool,            // a caller gap charged on a liquidation that seized nothing
    feesMisdirected: int,            // fee value paid to anyone but the depositor of record
    rescueOfRecorded: bool,          // stray-NFT return touched an NFT with an open record
    topUpStateBreach: bool,          // pledge outside the state rules of Q-132, Q-227, Q-241, Q-242, Q-252
    borrowFrozen: bool,              // borrow while an account vault-token reserve is frozen on Aave
    exitNotReconciled: bool,         // an exit or settlement left Spoke supply != credited units
    pendingSettled: int,             // pending-settlement units burned by an honest LPVaultSwap
    avanaFunded: bool,               // an Avana balance (fee recipient) paid toward a liquidation (Q-397)
    payoutLost: bool,                // a refused payout neither paid nor escrowed (Q-401)
    repayOverspend: bool,            // a repay spent more than the debt it removed
    // added for Q-222 … Q-278
    mintWhileSuspect: bool,          // a vault-token mint by a pledge path under Paused(MintPathSuspect)
    pauseRoleBreach: bool,           // pause state moved toward None by a key without the pause role
    breakerBypass: bool,             // new activity through a tripped breaker
    frozenActed: bool,               // a frozen address made a call the freeze blocks
    freezeRateBreach: bool,          // a guardian froze more addresses per window than allowed
    rescueBreach: bool,              // a rescue top-up outside the rescue rule
    gapChanged: bool,                // an Adapter call changed a market's backing gap
    removalBreach: bool,             // partial removal broke its record rules
    recreditBreach: bool,            // re-credit broke its record rules
    rwcBreach: bool,                 // repay with collateral lowered HF or took a fee
    crossAccount: bool,              // a liquidation changed another account
    tlFast: bool,                    // a non-short-eligible operation executed before MIN_NORMAL_DELAY
    tlLate: bool,                    // an operation executed after its grace window
    standbyBreach: bool,             // a standby switch made by someone without the role
    reportGateChange: bool,          // a shortfall report changed a market gate (reports are alerts, Q-399)
    feeBreach: bool,                 // Avana fee not min(oracle-value share, surplus)
    legBreach: bool,                 // a sell leg below its oracle-derived minimum, or legs passed but the floor failed
    sellbackBreach: bool,            // sell-back of unspent debt asset below its floor
    spendBreach: bool,               // GHO spent on the buy leg above the oracle bound
    shortfallBreach: bool,           // floor shortfall above the caller's cap
    topUpSplitBreach: bool,          // caller top-up != floor shortfall + settlement gap (Q-397)
    nftMisdirected: bool,            // an NFT left the LPVault to someone other than its depositor of record
    shortfallPaid: int,              // caller shortfall top-ups, GHO cents
  }

  type St = {
    now: int,
    design: Design,
    // Uniswap v3 NFPM
    nfts: int -> Nft,
    strayProven: int -> str,         // address proven for a stray NFT (Q-104)
    // Collateralization (immutable): backing records, pending settlement
    recs: int -> BRec,
    nextRec: int,
    pending: str -> int,             // liquidity behind unsettled vault tokens (Q-201)
    orphan: str -> int,              // ghost: units burned by burnSeized and never settled (Q-257)
    // ProxyManager and the Adapter binding (Q-225). Avana deploys one immutable, logic-free
    // PositionProxy per wallet x CDP Spoke x market by CREATE2 (no implementation, upgrade or migration);
    // the model keys a proxy by (wallet, Spoke), so a wallet's markets on one Spoke share one proxy.
    proxyWallet: str -> str,
    bindHistory: Set[(str, str)],
    validProxy: Set[(str, str)],     // (market, proxy) registry inside each vault token (Q-224)
    nonce: str -> int,
    borrowCount: str -> int,
    // vault tokens: (market, holder) -> balance
    bal: (str, str) -> int,
    hubDonated: str -> int,          // vault tokens sent to the Hub outside supply
    // Borrow Spokes
    supplied: (str, str) -> int,     // (proxy, market) -> supplied units
    enabled: Set[(str, str)],
    debt: (str, str) -> int,         // (proxy, asset) -> debt units
    // Hubs (one liquidity pool per debt asset)
    liq: str -> int,
    drawn: (str, str) -> int,        // (spoke, asset)
    drawCap: (str, str) -> int,
    deficit: str -> int,
    deficitEver: str -> int,
    accrued: str -> int,
    // Coverage Spokes (First-Loss Reserve per asset, Q-236)
    reserve: str -> int,
    reserveFundedEver: str -> int,
    coveredEver: str -> int,
    // balances: (holder, asset)
    cash: (str, str) -> int,         // GHO cents; USDT in hundredths
    feeRecipient: int,
    // LPOracle per market. Stored state Live/Drifting/Cached; Expired is computed.
    price: str -> int,
    pst: str -> PS,
    cachedSince: str -> int,
    disagreeSince: str -> int,
    disagreeSeen: str -> int,
    lowPx: str -> int,               // LP price from the lower route answers (Q-247)
    sawExpired: str -> bool,         // READ latch only
    recoveredAt: str -> int,
    trueRecoveredAt: str -> int,
    feedsDown: Set[str],             // primary and alternate routes both failing
    standbyActive: Set[str],         // standby route switched in (Q-248)
    standbyStale: Set[str],
    cp: str -> int,                  // hourly price checkpoint (SPEC-BRK-001)
    cpAt: str -> int,
    // DebtOracle for USDT (Q-248); GHO has Aave's fixed source
    dpx: int,                        // accepted price, GHO cents per unit
    dpst: PS,
    dCachedSince: int,
    dDisagree: bool,
    dHigh: int,                      // higher route answer during a disagreement
    dFeedsDown: bool,
    dStandby: bool,
    // Aave flags
    vaultPaused: Set[str],
    vaultFrozen: Set[str],
    debtPaused: Set[(str, str)],
    debtFrozen: Set[(str, str)],
    hubHalted: Set[str],
    sharesNeq: Set[str],
    configDrift: bool,
    // MarketRegistry: application pause state, breakers, freeze (Q-227, Q-241, Q-242)
    app: str,                        // "None" | "Frozen" | "Paused"
    reason: str,                     // "" | "General" | "MintPathSuspect"
    offboarding: Set[str],
    manualMkt: Set[str],
    seizeWinStart: str -> int,          // monitoring alert counters only (Q-399), never a gate
    seizeWin: str -> int,
    rfWinStart: str -> int,
    rfWin: str -> int,
    manualDebt: Set[(str, str)],
    issuerMkt: Set[str],
    issuerAsset: Set[str],
    poolThin: Set[str],              // pool-share cap exceeded and pool-share breaker tripped
    frozen: Set[str],
    freezeWinStart: str -> int,
    freezeWinCount: str -> int,
    // LPVaultSwap keeper list
    keepers: Set[str],
    // ParameterStore
    openHf: int,
    lastLoosen: int,
    // routes and payout escrow
    routeFailing: Set[str],          // both sell routes fail at run time
    routeDisabled: Set[str],         // both sell-route records disabled
    primaryDown: Set[str],           // primary route fails, backup used
    buyFailing: bool,                // USDT buy routes fail at run time
    buyDisabled: bool,               // USDT buy-route records disabled
    payoutBlocked: Set[str],         // holders whose payout transfer the debt token refuses (Q-401)
    failFirst: str -> int,           // shortfall-report alert evidence (Q-251, Q-399)
    failLast: str -> int,
    reportTimes: str -> Set[int],    // ghost: report times since the last routed liquidation
    escrowHeld: str -> int,
    escrowCredited: str -> int,
    escrowClaimed: str -> int,
    escrowBal: int,
    tokVal: str -> int,              // pool-token value received (GHO-equivalent)
    // upgradeable components
    riskHostile: bool,
    swapHostile: bool,
    adapterHostile: bool,
    // rolling 24-hour window start (freeze rate); there is no settlement budget (Q-397)
    winStart: int,
    // AvanaTimelock
    ops: int -> Op,
    nextOp: int,
    normalDelay: int,
    shortEnabled: Set[str],
    admins: Set[str],
    multisigLive: bool,
    g: Ghost,
  }

  type Last = { act: str, who: str, tgt: str, n: int }

  // ------------------------------------------------------------ constants

  pure val WALLETS = Set("alice", "bob", "eve")          // eve = attacker EOA
  pure val SPOKES = Set("S1", "S2")
  pure val PROXY: (str, str) -> str = Map(
    ("alice", "S1") -> "P_alice_S1", ("alice", "S2") -> "P_alice_S2",
    ("bob", "S1") -> "P_bob_S1", ("bob", "S2") -> "P_bob_S2",
    ("eve", "S1") -> "P_eve_S1", ("eve", "S2") -> "P_eve_S2")
  pure val PROXIES = Set("P_alice_S1", "P_alice_S2", "P_bob_S1", "P_bob_S2", "P_eve_S1", "P_eve_S2")
  pure val P_SPOKE = Map("P_alice_S1" -> "S1", "P_alice_S2" -> "S2", "P_bob_S1" -> "S1",
                         "P_bob_S2" -> "S2", "P_eve_S1" -> "S1", "P_eve_S2" -> "S2")
  pure val P_WALLET = Map("P_alice_S1" -> "alice", "P_alice_S2" -> "alice", "P_bob_S1" -> "bob",
                          "P_bob_S2" -> "bob", "P_eve_S1" -> "eve", "P_eve_S2" -> "eve")
  pure val ROGUE = "X_rogue"                              // attacker contract
  pure val KEEPERS0 = Set("k1", "k2", "kS")               // approved at launch (Q-082)
  pure val KEEPERS_ALL = Set("k1", "k2", "kS", "k4")      // k4 can be added through the timelock
  pure val KEEPER_FLOOR = 1                               // keeperFloor (Q-139, Q-228, Q-400): Avana's keeper
  pure val GUARDIANS = Set("EG", "APG")                   // PAUSE_GUARDIAN + FREEZE_GUARDIAN (Q-227)
  pure val FREEZE_KEY = "FK"                              // a key holding only the freeze role
  pure val FREEZERS = Set("EG", "APG", "FK")
  pure val PROPOSERS = Set("MULTISIG", "AAVE_EXEC")       // Q-228, Q-245
  pure val CANCELLERS = Set("MULTISIG", "EG", "APG", "AAVE_EXEC")
  pure val DAO_CANCELLER = "AAVE_EXEC"
  pure val SYSTEM = Set("HUB", "ADAPTER", "LPVAULTSWAP", "LPVAULT", "COLL")
  pure val HOLDERS = WALLETS.union(PROXIES).union(KEEPERS_ALL).union(SYSTEM).union(Set(ROGUE))
  pure val PROTECTED = SYSTEM.union(PROXIES).union(Set("TIMELOCK", "AAVE_EXEC"))  // Q-242
  pure val FREEZE_TARGETS = WALLETS.union(KEEPERS_ALL).union(Set(ROGUE, "LPVAULTSWAP", "P_alice_S1"))

  pure val MARKETS = Set("mA", "mB", "mC")
  pure val SPOKE_OF = Map("mA" -> "S1", "mB" -> "S1", "mC" -> "S2")
  pure val ASSETS = Set("GHO", "USDT")
  pure val DEBT_RES = Map("S1" -> Set("GHO", "USDT"), "S2" -> Set("GHO"))   // approved debt sets (Q-237)
  pure val KEYS = Set(("S1", "GHO"), ("S1", "USDT"), ("S2", "GHO"))
  pure val TOKEN_IDS = Set(42, 7, 9, 8, 13, 21, 66, 5)

  pure val CF = 80                 // collateral factor, percent
  pure val BONUS = 5               // liquidation bonus, percent
  pure val OPEN_HF0 = 0            // optional per-market hard floor (Q-398), percent; 0 = off (default)
  pure val OPEN_HF_MIN = 105       // lowest value when switched on
  pure val OPEN_HF_MAX = 125
  pure val REC_HF = 110            // Lens recommended borrow HF (Q-398), percent; rescue target
  pure val LOOSEN_STEP = 3         // at most 0.03 per loosening (Q-246)
  pure val HARD_FLOOR = 100        // Aave's HF 1.00: the only floor always applied (Q-398)
  pure val DEEP_HF = 90            // graceHealthFactor (Q-088), percent
  pure val DUST = 1000             // Aave V4 DUST_LIQUIDATION_THRESHOLD ($1,000)
  pure val ALLOW = 3               // slippageAllowanceBps, percent
  pure val BUY_ALLOW = 2           // buySlippageAllowanceBps, percent (Q-235)
  pure val FEE_SHARE = 20          // avanaFeeShareBps, percent
  pure val DISAGREE_MAX = 2        // disagreementPauseMax
  pure val ROUND_ALLOW = 2         // floorRoundingAllowanceGho; ⌊2 / 2⌋ = 1 per leg (Q-250)
  pure val MAX_SH_PCT = 10         // maxShortfallBps, percent (Q-251)
  pure val CACHED_WINDOW = 2
  pure val GRACE = 3
  pure val DAY = 24                // rolling 24-hour windows (freeze rate)
  pure val LINE = Map("GHO" -> 5000, "USDT" -> 2000)
  pure val RESERVE0 = 500
  pure val RESERVE_MIN = 300       // firstLossReserveMinimum
  pure val DEF_MAX = 10000         // breakerDeficitMax 10,000 GHO (Q-399)
  pure val CAP0: (str, str) -> int = Map(("S1", "GHO") -> 4000, ("S1", "USDT") -> 2000, ("S2", "GHO") -> 1000)
  pure val ADD_CAP = 5000          // Hub addCap per vault-token asset
  pure val MIN_PLEDGE = 300        // minPledgeUsd (scaled)
  pure val RESCUE_MIN = 10         // RESCUE_MIN_PLEDGE_USD
  pure val DPX0 = 100              // USDT accepted price, GHO cents
  pure val DSTRESS = 25            // debtStressRiseBps, percent
  pure val BRK_WIN = 2             // alert counting window (monitoring, Q-399)
  pure val SURGE_PCT = 20          // seizure alert threshold, percent (alert only)
  pure val ROUTE_FAIL_N = 3        // route-failure alert count (alert only)
  pure val DROP_PCT = 3            // price-drop alert threshold, percent (alert only)
  pure val CP_MAX_AGE = 2          // checkpoint compared only while recent
  pure val FREEZE_LIMIT = 2        // address freezes per guardian per window
  pure val SHORT_DELAY = 1
  pure val NORMAL0 = 5
  pure val MIN_NORMAL = 4          // MIN_NORMAL_DELAY (Q-262)
  pure val MAX_DELAY = 5
  pure val OP_GRACE = 14           // execution window after ready
  pure val REPORT_GAP = 1          // largest gap between reports
  pure val BIG = 1000000           // "max" amount
  pure val NO_DEADLINE = 1000000000
  pure val BORROW_AMTS = Set(300, 1000, 1500)
  pure val REPAY_AMTS = Set(1, 300, BIG)
  pure val COVER_AMTS = Set(1, 100, BIG)
  pure val LIQ_AMTS = Set(1, 300, 800, BIG)
  pure val SLIPS = Set(0, 2, 10)
  pure val PRICES = Set(1, 2, 3)

  pure val SHORT_ELIGIBLE = Set("tightenOpenHf", "disableRoute", "restoreRoute", "removeKeeper",
    "setMarketOffboarding", "freezeAddress", "pause", "freeze",
    "tripMarketBreaker", "useStandbyRoute")
  pure val RESTORING = Set("restoreRoute", "useStandbyRoute", "addKeeper", "unfreezeAddress")
  pure val ROLE_CALLS = Set("grantAdmin")
  pure val UPGRADE_CALLS = Set("upgradeAdapter", "upgradeSwap")

  pure val OP_TEMPLATES: Set[OpT] = Set(
    { calls: Set("upgradeAdapter"), tgt: "ADAPTER", arg: 0 },
    { calls: Set("upgradeSwap"), tgt: "LPVAULTSWAP", arg: 0 },
    { calls: Set("loosenOpenHf"), tgt: "", arg: 0 },
    { calls: Set("tightenOpenHf"), tgt: "", arg: 0 },
    { calls: Set("disableRoute"), tgt: "mA", arg: 0 },
    { calls: Set("restoreRoute"), tgt: "mA", arg: 0 },
    { calls: Set("addKeeper"), tgt: "k4", arg: 0 },
    { calls: Set("removeKeeper"), tgt: "k1", arg: 0 },
    { calls: Set("removeKeeper"), tgt: "k4", arg: 0 },
    { calls: Set("freezeAddress"), tgt: "eve", arg: 0 },
    { calls: Set("freezeAddress"), tgt: "k2", arg: 0 },
    { calls: Set("unfreezeAddress"), tgt: "eve", arg: 0 },
    { calls: Set("pause"), tgt: "General", arg: 0 },
    { calls: Set("freeze"), tgt: "", arg: 0 },
    { calls: Set("unpause"), tgt: "", arg: 0 },
    { calls: Set("unfreeze"), tgt: "", arg: 0 },
    { calls: Set("grantAdmin"), tgt: "eve", arg: 0 },
    { calls: Set("grantAdmin"), tgt: "TIMELOCK", arg: 0 },
    { calls: Set("setNormalDelay"), tgt: "", arg: 3 },
    { calls: Set("setNormalDelay"), tgt: "", arg: 4 },
    { calls: Set("setNormalDelay"), tgt: "", arg: 6 },
    { calls: Set("setShortDelaySelector"), tgt: "upgradeAdapter", arg: 1 },
    { calls: Set("setShortDelaySelector"), tgt: "tightenOpenHf", arg: 0 },
    { calls: Set("setShortDelaySelector"), tgt: "tightenOpenHf", arg: 1 },
    { calls: Set("restoreRoute", "loosenOpenHf"), tgt: "mA", arg: 0 },
    { calls: Set("useStandbyRoute"), tgt: "mA", arg: 0 },
    { calls: Set("restorePriceRoute"), tgt: "mA", arg: 0 },
    { calls: Set("tripMarketBreaker"), tgt: "mA", arg: 0 },
    { calls: Set("resetMarketBreaker"), tgt: "mA", arg: 0 },
    { calls: Set("setMarketOffboarding"), tgt: "mB", arg: 0 },
  )

  pure val NFT_INIT: int -> Nft = Map(
    42 -> { owner: "alice", liquidity: 1000, fees: 0, pool: "mA" },
    7  -> { owner: "alice", liquidity: 800,  fees: 0, pool: "mA" },
    9  -> { owner: "alice", liquidity: 600,  fees: 0, pool: "mB" },
    21 -> { owner: "alice", liquidity: 1000, fees: 0, pool: "mC" },
    5  -> { owner: "alice", liquidity: 100,  fees: 0, pool: "mA" },
    8  -> { owner: "bob",   liquidity: 700,  fees: 0, pool: "mA" },
    13 -> { owner: "bob",   liquidity: 1000, fees: 0, pool: "mC" },
    66 -> { owner: "eve",   liquidity: 600,  fees: 0, pool: "mA" }
  )

  pure val DESIGN_FINAL: Design = {
    debitCheck: "DELTA", principalCappedCollect: true, latch: "TIMESTAMP", backingCheck: "ONE_SIDED",
  }

  // ------------------------------------------------------------- helpers

  pure def imin(a: int, b: int): int = if (a < b) a else b
  pure def imax(a: int, b: int): int = if (a > b) a else b
  pure def ceilDiv(a: int, b: int): int = (a + b - 1) / b

  pure def gho(st: St, h: str): int = st.cash.get((h, "GHO"))
  pure def addCash(c: (str, str) -> int, h: str, a: str, d: int): (str, str) -> int =
    c.set((h, a), c.get((h, a)) + d)

  // price state as the LPOracle computes it on a read
  pure def ps(st: St, m: str): PS =
    if (st.pst.get(m) == Cached and st.now >= st.cachedSince.get(m) + CACHED_WINDOW) Expired
    else st.pst.get(m)

  pure def isStale(st: St, m: str): bool = ps(st, m) == Cached or ps(st, m) == Expired

  // Q-162, Q-199, Q-208: liquidation of the market waits from the first stored
  // observation; after disagreementPauseMax it is treated as Expired until the routes agree.
  pure def disagreeBlocks(st: St, m: str): bool = st.disagreeSince.get(m) >= 0
  pure def disagreeExpiredForLiq(st: St, m: str): bool =
    st.disagreeSeen.get(m) >= 0 and st.now >= st.disagreeSeen.get(m) + DISAGREE_MAX

  // Q-247: only the seized market's own price gates its seizure
  pure def mktFreshForLiq(st: St, m: str): bool = not(isStale(st, m)) and not(disagreeBlocks(st, m))

  // the price Aave reads for valuation (Q-247): Expired -> worthless, disagreement -> lower route
  pure def aavePx(st: St, m: str): int =
    if (ps(st, m) == Expired) 0 else if (disagreeBlocks(st, m)) st.lowPx.get(m) else st.price.get(m)

  // serving routes fresh (Q-248): the standby replaces the failed route when switched in
  pure def servingFresh(st: St, m: str): bool =
    if (st.standbyActive.contains(m)) not(st.standbyStale.contains(m)) else not(st.feedsDown.contains(m))

  pure def dps(st: St): PS =
    if (st.dpst == Cached and st.now >= st.dCachedSince + CACHED_WINDOW) Expired else st.dpst

  pure def debtFresh(st: St, a: str): bool = a == "GHO" or (dps(st) == Live and not(st.dDisagree))

  // the debt price Aave reads (Q-247, Q-248): Expired -> stress price, disagreement -> higher route
  pure def aaveDpx(st: St, a: str): int =
    if (a == "GHO") 100
    else if (dps(st) == Expired) st.dpx * (100 + DSTRESS) / 100
    else if (st.dDisagree) st.dHigh
    else st.dpx

  pure def openRecs(st: St): Set[int] = st.recs.keys().filter(i => st.recs.get(i).open)

  pure def recsOf(st: St, p: str, m: str): Set[int] =
    openRecs(st).filter(i => st.recs.get(i).proxy == p and st.recs.get(i).market == m)

  pure def creditedOf(st: St, p: str, m: str): int =
    recsOf(st, p, m).fold(0, (a, i) => a + st.recs.get(i).credited)

  pure def rescueOf(st: St, p: str, m: str): int =
    recsOf(st, p, m).fold(0, (a, i) => a + st.recs.get(i).rescue)

  pure def creditedMarket(st: St, m: str): int =
    openRecs(st).filter(i => st.recs.get(i).market == m).fold(0, (a, i) => a + st.recs.get(i).credited)

  pure def supplyOf(st: St, m: str): int = HOLDERS.fold(0, (a, h) => a + st.bal.get((m, h)))

  // backing gap of a market (Q-257): totalCredited + pending - totalSupply
  pure def gapOf(st: St, m: str): int = creditedMarket(st, m) + st.pending.get(m) - supplyOf(st, m)

  pure def spOf(p: str): str = P_SPOKE.get(p)

  pure def acctMarkets(st: St, p: str): Set[str] =
    MARKETS.filter(m => SPOKE_OF.get(m) == spOf(p) and st.enabled.contains((p, m)))

  pure def proxyMarkets(st: St, p: str): Set[str] = acctMarkets(st, p)

  pure def acctDebts(st: St, p: str): Set[str] = DEBT_RES.get(spOf(p)).filter(a => st.debt.get((p, a)) > 0)

  pure def hasDebt(st: St, p: str): bool = acctDebts(st, p).size() > 0

  // risk-adjusted collateral × 100 at Aave prices; debt value × 100 (GHO cents)
  pure def adjAave(st: St, p: str): int =
    acctMarkets(st, p).fold(0, (a, m) => a + st.supplied.get((p, m)) * aavePx(st, m) * CF)

  // rescue units valued at zero (Q-253)
  pure def adjEx(st: St, p: str): int =
    acctMarkets(st, p).fold(0, (a, m) =>
      a + imax(0, st.supplied.get((p, m)) - rescueOf(st, p, m)) * aavePx(st, m) * CF)

  pure def debtVal(st: St, p: str): int =
    DEBT_RES.get(spOf(p)).fold(0, (a, x) => a + st.debt.get((p, x)) * aaveDpx(st, x))

  // HF < 1 <=> adj < debtVal ; HF >= x% <=> adj × 100 >= debtVal × x
  pure def liquidatable(st: St, p: str): bool = hasDebt(st, p) and adjAave(st, p) < debtVal(st, p)

  pure def isCreated(st: St, p: str): bool = st.proxyWallet.get(p) != ""

  // addresses that may hold a market's vault tokens; the Adapter is never one (REQ-VTOKEN-006, REQ-VTOKEN-041)
  pure def allowedRecipient(st: St, m: str, rcpt: str): bool =
    Set("HUB", "LPVAULTSWAP").contains(rcpt) or st.validProxy.contains((m, rcpt))

  // the token's (from, to) path rule for transfer and transferFrom (REQ-VTOKEN-006, REQ-VTOKEN-041):
  // registered proxy -> Hub, Hub -> registered proxy, Hub -> LPVaultSwap; every other path reverts
  pure def allowedTransfer(st: St, m: str, src: str, dst: str): bool = or {
    st.validProxy.contains((m, src)) and dst == "HUB",
    src == "HUB" and (st.validProxy.contains((m, dst)) or dst == "LPVAULTSWAP"),
  }

  pure def addBal(b: (str, str) -> int, m: str, h: str, d: int): (str, str) -> int =
    b.set((m, h), b.get((m, h)) + d)

  pure def activeKeepers(st: St): Set[str] = st.keepers.exclude(st.frozen)

  pure def inGrace(st: St, acct: Set[str]): bool = acct.exists(y => st.now < st.recoveredAt.get(y) + GRACE)

  // circuit breakers (Q-241, Q-399, REQ-RISK-065). Oracle failure is the price gates themselves.
  // The price drop is a monitoring alert only; it never gates.
  pure def priceDrop(st: St, m: str): bool =
    st.now - st.cpAt.get(m) <= CP_MAX_AGE and st.price.get(m) * 100 < st.cp.get(m) * (100 - DROP_PCT)

  pure def marketBreaker(st: St, m: str): bool = or {
    st.manualMkt.contains(m), st.issuerMkt.contains(m), st.poolThin.contains(m),
  }

  pure def debtBreaker(st: St, sp: str, a: str): bool = or {
    st.manualDebt.contains((sp, a)), st.reserve.get(a) < RESERVE_MIN, st.deficit.get(a) > DEF_MAX,
    st.issuerAsset.contains(a),
  }

  // liquidation halts that stop new borrowing (REQ-ADAPTER-010, REQ-RISK-062, EMG-047)
  pure def liqHaltedMkt(st: St, m: str): bool = or {
    activeKeepers(st).size() == 0,
    st.routeDisabled.contains(m),
    st.sharesNeq.contains(m), st.vaultPaused.contains(m), not(mktFreshForLiq(st, m)),
  }
  pure def liqHaltedDebt(st: St, sp: str, a: str): bool =
    (a == "USDT" and st.buyDisabled) or not(debtFresh(st, a)) or st.debtPaused.contains((sp, a))

  // A successful poke() or Avana call that reads markets `ms` stores the first observation
  // of a route disagreement (Q-199). READ latch only (Q-129 as first written): flags Expired.
  pure def latchRead(st: St, ms: Set[str]): St = {
    val st1 = ms.fold(st, (acc, m) =>
      if (acc.disagreeSince.get(m) >= 0 and acc.disagreeSeen.get(m) < 0)
        { ...acc, disagreeSeen: acc.disagreeSeen.set(m, acc.now) }
      else acc)
    if (st1.design.latch != "READ") st1
    else ms.fold(st1, (acc, m) =>
      if (ps(acc, m) == Expired) { ...acc, sawExpired: acc.sawExpired.set(m, true) }
      else if (acc.sawExpired.get(m))
        { ...acc, sawExpired: acc.sawExpired.set(m, false), recoveredAt: acc.recoveredAt.set(m, acc.now) }
      else acc)
  }

  // Every Avana restriction of new activity cleared (pause state, breakers, address freeze
  // except `keep`, offboarding). Used by QNT-32 and QNT-33.
  pure def clearRestrictions(st: St, keep: Set[str]): St = { ...st,
    app: "None", reason: "", manualMkt: Set(), manualDebt: Set(),
    issuerMkt: Set(), issuerAsset: Set(), poolThin: Set(),
    frozen: st.frozen.intersect(keep), offboarding: Set(),
  }

  // ---------------------------------------------------------------- init

  pure val GHOST0: Ghost = {
    seizers: Set(), deficitReporters: Set(),
    borrowStale: false, borrowDegraded: false, borrowBelowFloor: false, borrowOverCap: false,
    borrowBelowAave: false, nonOwnerAction: false, liqStale: false, liqHealthy: false,
    liqGraceBreach: false, debitMismatch: false, largestFirstBreach: false, floorBreach: false,
    conservationBreach: false, gapOnZeroSeize: false, feesMisdirected: 0, rescueOfRecorded: false,
    topUpStateBreach: false, borrowFrozen: false, exitNotReconciled: false, pendingSettled: 0,
    avanaFunded: false, payoutLost: false, repayOverspend: false,
    mintWhileSuspect: false, pauseRoleBreach: false, breakerBypass: false,
    frozenActed: false, freezeRateBreach: false, rescueBreach: false, gapChanged: false,
    removalBreach: false, recreditBreach: false, rwcBreach: false, crossAccount: false,
    tlFast: false, tlLate: false, standbyBreach: false, reportGateChange: false, feeBreach: false,
    legBreach: false, sellbackBreach: false, spendBreach: false, shortfallBreach: false,
    topUpSplitBreach: false, nftMisdirected: false, shortfallPaid: 0,
  }

  pure def initState(d: Design): St = {
    now: 0,
    design: d,
    nfts: NFT_INIT,
    strayProven: TOKEN_IDS.mapBy(t => ""),
    recs: Map(),
    nextRec: 1,
    pending: MARKETS.mapBy(m => 0),
    orphan: MARKETS.mapBy(m => 0),
    proxyWallet: PROXIES.mapBy(p => ""),
    bindHistory: Set(),
    validProxy: Set(),
    nonce: PROXIES.mapBy(p => 0),
    borrowCount: PROXIES.mapBy(p => 0),
    bal: tuples(MARKETS, HOLDERS).mapBy(k => 0),
    hubDonated: MARKETS.mapBy(m => 0),
    supplied: tuples(PROXIES, MARKETS).mapBy(k => 0),
    enabled: Set(),
    debt: tuples(PROXIES, ASSETS).mapBy(k => 0),
    liq: LINE.keys().mapBy(a => LINE.get(a) + RESERVE0),
    drawn: KEYS.mapBy(k => 0),
    drawCap: CAP0,
    deficit: ASSETS.mapBy(a => 0),
    deficitEver: ASSETS.mapBy(a => 0),
    accrued: ASSETS.mapBy(a => 0),
    reserve: ASSETS.mapBy(a => RESERVE0),
    reserveFundedEver: ASSETS.mapBy(a => RESERVE0),
    coveredEver: ASSETS.mapBy(a => 0),
    cash: tuples(HOLDERS, ASSETS).mapBy(k =>
      if (k._2 == "GHO") (if (k._1 == "eve" or k._1 == ROGUE) 500000 else if (WALLETS.contains(k._1) or KEEPERS_ALL.contains(k._1)) 300000 else 0)
      else (if (WALLETS.contains(k._1)) 100000 else 0)),
    feeRecipient: 0,
    price: MARKETS.mapBy(m => 2),
    pst: MARKETS.mapBy(m => Live),
    cachedSince: MARKETS.mapBy(m => 0),
    disagreeSince: MARKETS.mapBy(m => -1),
    disagreeSeen: MARKETS.mapBy(m => -1),
    lowPx: MARKETS.mapBy(m => 2),
    sawExpired: MARKETS.mapBy(m => false),
    recoveredAt: MARKETS.mapBy(m => -100),
    trueRecoveredAt: MARKETS.mapBy(m => -100),
    feedsDown: Set(),
    standbyActive: Set(),
    standbyStale: Set(),
    cp: MARKETS.mapBy(m => 2),
    cpAt: MARKETS.mapBy(m => 0),
    dpx: DPX0,
    dpst: Live,
    dCachedSince: 0,
    dDisagree: false,
    dHigh: DPX0,
    dFeedsDown: false,
    dStandby: false,
    vaultPaused: Set(),
    vaultFrozen: Set(),
    debtPaused: Set(),
    debtFrozen: Set(),
    hubHalted: Set(),
    sharesNeq: Set(),
    configDrift: false,
    app: "None",
    reason: "",
    offboarding: Set(),
    manualMkt: Set(),
    seizeWinStart: MARKETS.mapBy(m => -100),
    seizeWin: MARKETS.mapBy(m => 0),
    rfWinStart: MARKETS.mapBy(m => -100),
    rfWin: MARKETS.mapBy(m => 0),
    manualDebt: Set(),
    issuerMkt: Set(),
    issuerAsset: Set(),
    poolThin: Set(),
    frozen: Set(),
    freezeWinStart: FREEZERS.mapBy(x => -100),
    freezeWinCount: FREEZERS.mapBy(x => 0),
    keepers: KEEPERS0,
    openHf: OPEN_HF0,
    lastLoosen: -100,
    routeFailing: Set(),
    routeDisabled: Set(),
    primaryDown: Set(),
    buyFailing: false,
    buyDisabled: false,
    payoutBlocked: Set(),
    failFirst: MARKETS.mapBy(m => -1),
    failLast: MARKETS.mapBy(m => -100),
    reportTimes: MARKETS.mapBy(m => Set()),
    escrowHeld: HOLDERS.mapBy(h => 0),
    escrowCredited: HOLDERS.mapBy(h => 0),
    escrowClaimed: HOLDERS.mapBy(h => 0),
    escrowBal: 0,
    tokVal: HOLDERS.mapBy(h => 0),
    riskHostile: false,
    swapHostile: false,
    adapterHostile: false,
    winStart: 0,
    ops: Map(),
    nextOp: 1,
    normalDelay: NORMAL0,
    shortEnabled: SHORT_ELIGIBLE,
    admins: Set("TIMELOCK"),
    multisigLive: true,
    g: GHOST0,
  }

  var s: St
  var la: Last

  action go(nx: St, a: str, who: str, tgt: str, n: int): bool = all {
    s' = nx, la' = { act: a, who: who, tgt: tgt, n: n },
  }

  // ============================================================== RECORDS
  // Collateralization (immutable): largest-credited-first debit, ties to the lowest
  // record ID (Q-194); removes exactly the debited liquidity; principal-capped
  // collect (Q-061); rescue units never exceed credited units (Q-253).

  type DebitAcc = { recs: int -> BRec, nfts: int -> Nft, left: int, principal: int, fees: int, ordered: bool }

  pure def debitLargestFirst(st: St, p: str, m: str, units: int): DebitAcc = {
    val ids = recsOf(st, p, m)
    ids.fold(
      { recs: st.recs, nfts: st.nfts, left: units, principal: 0, fees: 0, ordered: true },
      (acc, i0) => {
        val cand = ids.filter(i => acc.recs.get(i).credited > 0)
        if (acc.left == 0 or cand.size() == 0) acc else {
          val best = cand.fold(-1, (b, i) =>
            if (b == -1) i
            else if (acc.recs.get(i).credited > acc.recs.get(b).credited or
                     (acc.recs.get(i).credited == acc.recs.get(b).credited and i < b)) i
            else b)
          val r = acc.recs.get(best)
          val take = imin(acc.left, r.credited)
          val n = acc.nfts.get(r.tokenId)
          val feeTaken = if (st.design.principalCappedCollect) 0 else n.fees
          {
            recs: acc.recs.set(best, { ...r, credited: r.credited - take, rescue: imin(r.rescue, r.credited - take) }),
            nfts: acc.nfts.set(r.tokenId, { ...n, liquidity: n.liquidity - take, fees: n.fees - feeTaken }),
            left: acc.left - take,
            principal: acc.principal + take,
            fees: acc.fees + feeTaken,
            ordered: acc.ordered and not(cand.exists(i => acc.recs.get(i).credited > r.credited)),
          }
        }
      })
  }

  // Q-201 reconcile on exit: units missing from the proxy's Spoke supply (a seizure
  // never settled) are debited from its records largest-first; their liquidity moves
  // to the pending-settlement balance, which keeps the outstanding vault tokens backed.
  pure def reconcile(st: St, p: str, m: str): St = {
    val gap = creditedOf(st, p, m) - st.supplied.get((p, m))
    if (gap <= 0) st else {
      val db = debitLargestFirst(st, p, m, gap)
      { ...st,
        recs: db.recs, nfts: db.nfts,
        pending: st.pending.set(m, st.pending.get(m) + db.principal),
        g: { ...st.g,
          feesMisdirected: st.g.feesMisdirected + db.fees,
          largestFirstBreach: st.g.largestFirstBreach or not(db.ordered),
          debitMismatch: st.g.debitMismatch or db.left != 0,
        },
      }
    }
  }

  // The Adapter's backing check (Q-257): one-sided form keeps the market's backing gap;
  // the equality form of Q-224 as first written requires totalSupply == credited + pending.
  // Every reviewed Adapter call keeps the gap (checked by the ghost `gapChanged`), so
  // the check passes exactly when this holds before the call.
  pure def backingGuard(st: St, m: str): bool =
    if (st.design.backingCheck == "ONE_SIDED") gapOf(st, m) >= 0 else gapOf(st, m) == 0

  pure def gapGhost(st0: St, st1: St, m: str): bool = gapOf(st0, m) != gapOf(st1, m) or gapOf(st1, m) < 0

  // ============================================================== PLEDGE
  // wallet -> AaveAdapter.pledge -> ProxyManager creates the (wallet, Spoke) proxy on first
  // pledge -> Collateralization.pledge (custody, RiskModule.checkPledge) -> the Adapter mints
  // exactly the credited units to the proxy -> proxy supplies them (Q-223, Q-224, Q-225).

  type PledgeClass = { ok: bool, rescue: bool }

  // Aave's own supply checks: reserve not frozen or paused, Hub not halted, Hub addCap
  pure def aaveSupplyOk(st: St, m: str, L: int): bool = and {
    not(st.vaultFrozen.contains(m)), not(st.vaultPaused.contains(m)),
    not(st.hubHalted.contains(SPOKE_OF.get(m))), st.bal.get((m, "HUB")) + L <= ADD_CAP,
  }

  // rescue-top-up eligibility (Q-252, REQ-RISK-066): indebted, HF below the opening HF,
  // and the charge no more than what restores it
  pure def rescueEligible(st: St, p: str, m: str, L: int): bool = and {
    hasDebt(st, p),
    adjAave(st, p) * 100 < debtVal(st, p) * REC_HF,
    L * st.price.get(m) * CF * 100 <= debtVal(st, p) * REC_HF - adjAave(st, p) * 100,
  }

  // RiskModule.checkPledge on `L` units into market m for proxy p
  pure def checkPledge(st: St, p: str, m: str, L: int, requireRescue: bool): PledgeClass = {
    val newAcct = not(hasDebt(st, p))
    val value = L * st.price.get(m)
    val stateOk = if (newAcct) ps(st, m) == Live else (ps(st, m) == Live or ps(st, m) == Drifting)
    val needsEx = requireRescue or marketBreaker(st, m) or value < MIN_PLEDGE
    val common = and {
      L > 0, stateOk, not(st.offboarding.contains(m)), aaveSupplyOk(st, m, L),
      newAcct implies (not(st.configDrift) and not(st.sharesNeq.contains(m))),
    }
    if (needsEx) { ok: common and value >= RESCUE_MIN and rescueEligible(st, p, m, L), rescue: true }
    else { ok: common and value >= MIN_PLEDGE, rescue: false }
  }

  pure def pledgeRequireRescue(st: St, w: str): bool =
    (st.app == "Paused" and st.reason == "General") or st.frozen.contains(w)

  // a hostile RiskModule approves anything; Aave still refuses supply it cannot take
  pure def pledgeCheck(st: St, w: str, p: str, m: str, L: int): PledgeClass =
    if (st.riskHostile) { ok: aaveSupplyOk(st, m, L), rescue: false }
    else checkPledge(st, p, m, L, pledgeRequireRescue(st, w))

  // the pledge rows of the emergency matrix (EMG-POST-006), stated independently
  pure def pledgeRuleOk(st: St, w: str, p: str, m: str, L: int, rescue: bool): bool =
    if (not(hasDebt(st, p)))
      and { st.app == "None", ps(st, m) == Live, not(marketBreaker(st, m)), not(st.frozen.contains(w)), not(rescue) }
    else if (rescue)
      and { st.app != "Paused" or st.reason == "General", ps(st, m) == Live or ps(st, m) == Drifting,
            rescueEligible(st, p, m, L), L * st.price.get(m) >= RESCUE_MIN }
    else
      and { st.app == "None" or st.app == "Frozen", ps(st, m) == Live or ps(st, m) == Drifting,
            not(marketBreaker(st, m)), not(st.frozen.contains(w)), L * st.price.get(m) >= MIN_PLEDGE }

  pure def pledgeOk(st: St, w: str, t: int, m: str): bool = {
    val n = st.nfts.get(t)
    val sp = SPOKE_OF.get(m)
    val p = PROXY.get((w, sp))
    and {
      WALLETS.contains(w),
      not(st.app == "Paused" and st.reason == "MintPathSuspect"),       // Adapter (Q-252)
      isCreated(st, p) or not(st.frozen.contains(w)),                   // ProxyManager refuses a frozen wallet
      not(st.app == "Frozen" and not(hasDebt(st, p))),                  // Adapter (Q-227)
      n.owner == w, n.pool == m,                                        // LPVault: owner; pool; stray NFTs refused (Q-258)
      backingGuard(st, m),
      pledgeCheck(st, w, p, m, n.liquidity).ok,
    }
  }

  pure def pledgeNext(st: St, w: str, t: int, m: str): St = {
    val n = st.nfts.get(t)
    val sp = SPOKE_OF.get(m)
    val p = PROXY.get((w, sp))
    val L = n.liquidity
    val pc = pledgeCheck(st, w, p, m, L)
    val st1 = latchRead(st, Set(m))
    val nx = { ...st1,
      proxyWallet: st.proxyWallet.set(p, w),                   // created and bound once (Q-225)
      bindHistory: st.bindHistory.union(Set((p, w))),
      validProxy: st.validProxy.union(Set((m, p))),            // addValidProxy at the first pledge into m
      nfts: st.nfts.set(t, { ...n, owner: "LPVAULT" }),
      recs: st.recs.put(st.nextRec, { tokenId: t, depositor: w, proxy: p, market: m, credited: L,
                                      rescue: if (pc.rescue) L else 0, open: true }),
      nextRec: st.nextRec + 1,
      bal: addBal(st.bal, m, "HUB", L),                       // mint L to the proxy; the proxy supplies L
      supplied: st.supplied.set((p, m), st.supplied.get((p, m)) + L),
      enabled: st.enabled.union(Set((p, m))),
    }
    { ...nx,
      g: { ...nx.g,
        topUpStateBreach: nx.g.topUpStateBreach or (not(st.riskHostile) and not(pledgeRuleOk(st, w, p, m, L, pc.rescue))),
        mintWhileSuspect: nx.g.mintWhileSuspect or (st.app == "Paused" and st.reason == "MintPathSuspect"),
        rescueBreach: nx.g.rescueBreach or (pc.rescue and not(rescueEligible(st, p, m, L))),
        frozenActed: nx.g.frozenActed or (st.frozen.contains(w) and not(pc.rescue) and not(st.riskHostile)),
        breakerBypass: nx.g.breakerBypass or (marketBreaker(st, m) and not(pc.rescue) and not(st.riskHostile)),
        gapChanged: nx.g.gapChanged or gapGhost(st, nx, m),
      },
    }
  }

  action pledge(w: str, t: int, m: str): bool = all {
    pledgeOk(s, w, t, m), go(pledgeNext(s, w, t, m), "pledge", w, m, t),
  }

  // ======================================================= RISKMODULE GATES
  // preBorrowCheck / preWithdrawCheck / postHealthCheck (Q-229, Q-234, Q-241, Q-247, Q-253)

  pure def preBorrowOk(st: St, p: str, r: str): bool = {
    val sp = spOf(p)
    val acct = acctMarkets(st, p)
    val dScope = acctDebts(st, p).union(Set(r))
    and {
      acct.forall(m => ps(st, m) == Live),
      dScope.forall(a => debtFresh(st, a) and not(st.debtPaused.contains((sp, a)))),
      acct.forall(m => not(st.vaultPaused.contains(m))),
      acct.forall(m => not(st.offboarding.contains(m)) and not(st.vaultFrozen.contains(m))),
      not(st.configDrift), not(st.hubHalted.contains(sp)),
      acct.forall(m => not(st.sharesNeq.contains(m))),
      acct.forall(m => not(liqHaltedMkt(st, m))),
      dScope.forall(a => not(liqHaltedDebt(st, sp, a))),
      acct.forall(m => not(marketBreaker(st, m))),
      not(debtBreaker(st, sp, r)),
    }
  }

  pure def preWithdrawOk(st: St, p: str, m0: str): bool = {
    val sp = spOf(p)
    val acct = acctMarkets(st, p).union(Set(m0))
    val dScope = acctDebts(st, p)
    and {
      acct.forall(m => ps(st, m) == Live),
      dScope.forall(a => debtFresh(st, a) and not(st.debtPaused.contains((sp, a)))),
      acct.forall(m => not(st.vaultPaused.contains(m))),
      not(st.configDrift), not(st.hubHalted.contains(sp)),
      acct.forall(m => not(st.sharesNeq.contains(m))),
      acct.forall(m => not(liqHaltedMkt(st, m))),
      dScope.forall(a => not(liqHaltedDebt(st, sp, a))),
      acct.forall(m => not(marketBreaker(st, m))),
      dScope.forall(a => not(debtBreaker(st, sp, a))),
    }
  }

  // rescue-excluded HF >= max(optional hard floor, 1.00) (Q-229, Q-253, Q-398)
  pure def postHealthOk(st: St, p: str): bool =
    not(hasDebt(st, p)) or adjEx(st, p) * 100 >= debtVal(st, p) * imax(st.openHf, HARD_FLOOR)

  // Aave's own health-factor check (HF >= 1)
  pure def aaveHealthy(st: St, p: str): bool = not(hasDebt(st, p)) or adjAave(st, p) >= debtVal(st, p)

  // stale price anywhere in the account (collateral or held debt)
  pure def acctStale(st: St, p: str, extra: Set[str]): bool =
    acctMarkets(st, p).union(extra).exists(m => isStale(st, m)) or acctDebts(st, p).exists(a => not(debtFresh(st, a)))

  // ============================================================== BORROW
  // wallet -> AaveAdapter.borrow (proxy resolved from msg.sender and the Spoke, nonce,
  // pause state, freeze) -> RiskModule pre-check -> proxy borrows -> RiskModule post-check

  pure def borrowEffect(st: St, c: str, p: str, r: str, amt: int): St = {
    val sp = spOf(p)
    { ...st,
      debt: st.debt.set((p, r), st.debt.get((p, r)) + amt),
      drawn: st.drawn.set((sp, r), st.drawn.get((sp, r)) + amt),
      liq: st.liq.set(r, st.liq.get(r) - amt),
      cash: addCash(st.cash, c, r, amt * 100),
      nonce: st.nonce.set(p, st.nonce.get(p) + 1),
      borrowCount: st.borrowCount.set(p, st.borrowCount.get(p) + 1),
    }
  }

  pure def borrowOk(st: St, c: str, sp: str, r: str, amt: int, nn: int): bool = {
    val p = PROXY.get((c, sp))
    val nx = borrowEffect(st, c, p, r, amt)
    and {
      WALLETS.contains(c), isCreated(st, p), DEBT_RES.get(sp).contains(r),
      st.app == "None", not(st.frozen.contains(c)),                  // Adapter; receiver = caller
      nn == st.nonce.get(p), amt > 0, acctMarkets(st, p).size() > 0,
      not(st.debtPaused.contains((sp, r))), not(st.debtFrozen.contains((sp, r))), not(st.hubHalted.contains(sp)),
      amt <= st.liq.get(r), st.drawn.get((sp, r)) + amt <= st.drawCap.get((sp, r)),
      aaveHealthy(nx, p),
      st.riskHostile or (preBorrowOk(st, p, r) and postHealthOk(nx, p)),
    }
  }

  pure def borrowNext(st: St, c: str, sp: str, r: str, amt: int): St = {
    val p = PROXY.get((c, sp))
    val acct = acctMarkets(st, p)
    val nx = borrowEffect(latchRead(st, acct), c, p, r, amt)
    { ...nx,
      g: { ...nx.g,
        borrowStale: nx.g.borrowStale or acctStale(st, p, Set()) or not(debtFresh(st, r)),
        borrowFrozen: nx.g.borrowFrozen or acct.exists(m => st.vaultFrozen.contains(m)),
        borrowDegraded: nx.g.borrowDegraded or not(and {
          st.app == "None", not(st.frozen.contains(c)), preBorrowOk(st, p, r), postHealthOk(nx, p) }),
        borrowBelowFloor: nx.g.borrowBelowFloor or not(postHealthOk(nx, p)),
        borrowOverCap: nx.g.borrowOverCap or st.drawn.get((sp, r)) + amt > st.drawCap.get((sp, r)) or amt > st.liq.get(r),
        borrowBelowAave: nx.g.borrowBelowAave or not(aaveHealthy(nx, p)),
        breakerBypass: nx.g.breakerBypass or (not(st.riskHostile) and
          (acct.exists(m => marketBreaker(st, m)) or debtBreaker(st, sp, r))),
        frozenActed: nx.g.frozenActed or st.frozen.contains(c),
        nonOwnerAction: nx.g.nonOwnerAction or P_WALLET.get(p) != c,
      },
    }
  }

  action borrow(c: str, sp: str, r: str, amt: int, nn: int): bool = all {
    borrowOk(s, c, sp, r, amt, nn), go(borrowNext(s, c, sp, r, amt), "borrow", c, r, amt),
  }

  // =============================================================== REPAY
  // any payer -> AaveAdapter.repay(borrower, spoke, reserve, …) -> proxy repays. Reads no
  // pause state, breaker, freeze or registry state (Q-260); any partial amount (Q-153); at
  // zero debt it returns 0 (Q-180); repay-all pulls the cap and refunds the rest (Q-269).

  pure def repayAmt(st: St, p: str, a: str, maxSpend: int, isAll: bool): int =
    if (isAll) st.debt.get((p, a)) else imin(maxSpend, st.debt.get((p, a)))

  pure def repayOkM(st: St, c: str, p: str, a: str, maxSpend: int, isAll: bool, checkFunds: bool): bool = {
    val d = st.debt.get((p, a))
    val amt = repayAmt(st, p, a, maxSpend, isAll)
    val sp = spOf(p)
    and {
      isCreated(st, p), WALLETS.union(KEEPERS_ALL).contains(c), maxSpend > 0, DEBT_RES.get(sp).contains(a),
      d == 0 or and {
        not(isAll) or d <= maxSpend,
        not(st.debtPaused.contains((sp, a))), not(st.hubHalted.contains(sp)),   // Aave itself
        not(checkFunds) or st.cash.get((c, a)) >= amt * 100,
      },
    }
  }

  pure def repayOk(st: St, c: str, p: str, a: str, maxSpend: int, checkFunds: bool): bool =
    st.debt.get((p, a)) > 0 and repayOkM(st, c, p, a, maxSpend, false, checkFunds)

  pure def repayNext(st: St, c: str, p: str, a: str, maxSpend: int, isAll: bool): St = {
    val d = st.debt.get((p, a))
    val amt = repayAmt(st, p, a, maxSpend, isAll)
    val sp = spOf(p)
    { ...st,
      debt: st.debt.set((p, a), d - amt),
      drawn: st.drawn.set((sp, a), st.drawn.get((sp, a)) - amt),
      liq: st.liq.set(a, st.liq.get(a) + amt),
      cash: addCash(st.cash, c, a, -amt * 100),
      g: { ...st.g, repayOverspend: st.g.repayOverspend or amt > d or amt < 0 },
    }
  }

  action repay(c: str, p: str, a: str, maxSpend: int): bool = all {
    repayOkM(s, c, p, a, maxSpend, false, true), go(repayNext(s, c, p, a, maxSpend, false), "repay", c, p, maxSpend),
  }

  action repayAll(c: str, p: str, a: str, cap: int): bool = all {
    repayOkM(s, c, p, a, cap, true, true), go(repayNext(s, c, p, a, cap, true), "repayAll", c, p, cap),
  }

  // ============================================================ WITHDRAW
  // wallet -> AaveAdapter.withdraw -> Collateralization reconciles -> proxy withdraws to
  // itself -> the Adapter burns the released units -> Collateralization debits -> the LPVault
  // returns the NFT. Debt-free exits read no pause state, breaker, freeze or registry state
  // (Q-227, Q-241, Q-242, Q-260); one that leaves debt runs every withdraw-side gate.

  pure def debtExitOk(st: St, c: str, p: str, m: str, nx: St): bool = and {
    st.app != "Paused", not(st.frozen.contains(c)),               // Adapter
    aaveHealthy(nx, p),                                           // Aave
    st.riskHostile or (preWithdrawOk(st, p, m) and postHealthOk(nx, p)),
  }

  pure def debtExitGhosts(st: St, c: str, p: str, m: str, nx: St, withDebt: bool, g: Ghost): Ghost = { ...g,
    borrowStale: g.borrowStale or (withDebt and acctStale(st, p, Set(m))),
    borrowBelowFloor: g.borrowBelowFloor or (withDebt and not(postHealthOk(nx, p))),
    borrowBelowAave: g.borrowBelowAave or (withDebt and not(aaveHealthy(nx, p))),
    borrowDegraded: g.borrowDegraded or (withDebt and not(and {
      st.app != "Paused", not(st.frozen.contains(c)), preWithdrawOk(st, p, m), postHealthOk(nx, p) })),
    breakerBypass: g.breakerBypass or (withDebt and not(st.riskHostile) and
      (acctMarkets(st, p).union(Set(m)).exists(x => marketBreaker(st, x)) or
       acctDebts(st, p).exists(a => debtBreaker(st, spOf(p), a)))),
    frozenActed: g.frozenActed or (withDebt and st.frozen.contains(c)),
    nonOwnerAction: g.nonOwnerAction or P_WALLET.get(p) != c,
  }

  pure def withdrawEffect(st: St, rid: int): St = {
    val r = st.recs.get(rid)
    val p = r.proxy
    val m = r.market
    val u = r.credited
    val left = st.supplied.get((p, m)) - u
    val n = st.nfts.get(r.tokenId)
    { ...st,
      supplied: st.supplied.set((p, m), left),
      bal: addBal(st.bal, m, "HUB", -u),                       // Hub -> proxy -> burned by the Adapter
      enabled: if (left == 0) st.enabled.exclude(Set((p, m))) else st.enabled,
      recs: st.recs.set(rid, { ...r, credited: 0, rescue: 0, open: false }),
      nfts: st.nfts.set(r.tokenId, { ...n, owner: r.depositor }),  // rest of the NFT and its fees (Q-061)
    }
  }

  pure def withdrawOk(st: St, c: str, rid: int): bool =
    st.recs.keys().contains(rid) and {
      val r0 = st.recs.get(rid)
      val p = r0.proxy
      val m = r0.market
      val sp = SPOKE_OF.get(m)
      val st0 = reconcile(st, p, m)
      val r = st0.recs.get(rid)
      and {
        r0.open, r0.credited > 0, c == r0.depositor, PROXY.get((c, sp)) == p,
        backingGuard(st, m),
        r.credited == 0 or and {                                // fully reconciled: NFT released, no Spoke call
          st0.supplied.get((p, m)) >= r.credited,
          not(st.vaultPaused.contains(m)), not(st.hubHalted.contains(sp)),
          not(hasDebt(st0, p)) or debtExitOk(st0, c, p, m, withdrawEffect(st0, rid)),
        },
      }
    }

  pure def withdrawNext(st: St, c: str, rid: int): St = {
    val r0 = st.recs.get(rid)
    val p = r0.proxy
    val m = r0.market
    val st0 = reconcile(st, p, m)
    val withDebt = st0.recs.get(rid).credited > 0 and hasDebt(st0, p)
    val st1 = if (withDebt) latchRead(st0, acctMarkets(st0, p)) else st0
    val nx = withdrawEffect(st1, rid)
    { ...nx,
      g: { ...debtExitGhosts(st0, c, p, m, nx, withDebt, nx.g),
        exitNotReconciled: nx.g.exitNotReconciled or nx.supplied.get((p, m)) != creditedOf(nx, p, m),
        gapChanged: nx.g.gapChanged or gapGhost(st, nx, m),
      },
    }
  }

  action withdraw(c: str, rid: int): bool = all {
    withdrawOk(s, c, rid), go(withdrawNext(s, c, rid), "withdraw", c, "rec", rid),
  }

  // Collateralization.releaseZeroCredit: reconciles, and a record at 0 credited units
  // returns its NFT to the depositor with no Spoke call (Q-134). Never gated.
  pure def withdrawZeroOk(st: St, c: str, rid: int): bool =
    st.recs.keys().contains(rid) and {
      val r0 = st.recs.get(rid)
      val st0 = reconcile(st, r0.proxy, r0.market)
      and { r0.open, c == r0.depositor, st0.recs.get(rid).credited == 0 }
    }

  pure def withdrawZeroNext(st: St, rid: int): St = {
    val r0 = st.recs.get(rid)
    val st0 = reconcile(st, r0.proxy, r0.market)
    val r = st0.recs.get(rid)
    val n = st0.nfts.get(r.tokenId)
    { ...st0,
      recs: st0.recs.set(rid, { ...r, open: false }),
      nfts: st0.nfts.set(r.tokenId, { ...n, owner: r.depositor }),
    }
  }

  action withdrawZero(c: str, rid: int): bool = all {
    withdrawZeroOk(s, c, rid), go(withdrawZeroNext(s, rid), "releaseZeroCredit", c, "rec", rid),
  }

  // ======================================================= PARTIAL REMOVAL
  // AaveAdapter.removeLiquidity (Q-254): 0 < units < credited after reconcile; the proxy
  // withdraws, the Adapter burns, Collateralization debits, the LPVault decreases the NFT's
  // liquidity by exactly `units` and pays only that principal to the depositor; the NFT and
  // its fees stay in custody. With debt it is a withdraw-with-debt plus the remaining-record
  // minimum.

  pure def removeEffect(st: St, rid: int, u: int): St = {
    val r = st.recs.get(rid)
    val p = r.proxy
    val m = r.market
    val n = st.nfts.get(r.tokenId)
    { ...st,
      supplied: st.supplied.set((p, m), st.supplied.get((p, m)) - u),
      bal: addBal(st.bal, m, "HUB", -u),
      recs: st.recs.set(rid, { ...r, credited: r.credited - u, rescue: imin(r.rescue, r.credited - u) }),
      nfts: st.nfts.set(r.tokenId, { ...n, liquidity: n.liquidity - u }),
      tokVal: st.tokVal.set(r.depositor, st.tokVal.get(r.depositor) + u * st.price.get(m) * 100),
    }
  }

  pure def removeOk(st: St, c: str, rid: int, u: int): bool =
    st.recs.keys().contains(rid) and {
      val r0 = st.recs.get(rid)
      val p = r0.proxy
      val m = r0.market
      val sp = SPOKE_OF.get(m)
      val st0 = reconcile(st, p, m)
      val r = st0.recs.get(rid)
      and {
        r0.open, c == r0.depositor, PROXY.get((c, sp)) == p, backingGuard(st, m),
        u > 0, u < r.credited, st0.supplied.get((p, m)) >= u,
        not(st.vaultPaused.contains(m)), not(st.hubHalted.contains(sp)),
        not(hasDebt(st0, p)) or and {
          debtExitOk(st0, c, p, m, removeEffect(st0, rid, u)),
          st.riskHostile or (r.credited - u) * st.price.get(m) >= MIN_PLEDGE,    // checkRemainingRecord
        },
      }
    }

  pure def removeNext(st: St, c: str, rid: int, u: int): St = {
    val r0 = st.recs.get(rid)
    val p = r0.proxy
    val m = r0.market
    val st0 = reconcile(st, p, m)
    val withDebt = hasDebt(st0, p)
    val st1 = if (withDebt) latchRead(st0, acctMarkets(st0, p)) else st0
    val nx = removeEffect(st1, rid, u)
    val rA = nx.recs.get(rid)
    val nA = nx.nfts.get(rA.tokenId)
    { ...nx,
      g: { ...debtExitGhosts(st0, c, p, m, nx, withDebt, nx.g),
        exitNotReconciled: nx.g.exitNotReconciled or nx.supplied.get((p, m)) != creditedOf(nx, p, m),
        gapChanged: nx.g.gapChanged or gapGhost(st, nx, m),
        removalBreach: nx.g.removalBreach or not(and {
          rA.open, rA.credited > 0, nA.owner == "LPVAULT", nA.liquidity >= rA.credited,
          nA.fees == st0.nfts.get(rA.tokenId).fees, rA.rescue <= rA.credited,
          (withDebt and not(st.riskHostile)) implies rA.credited * st.price.get(m) >= MIN_PLEDGE,
        }),
      },
    }
  }

  action removeLiquidity(c: str, rid: int, u: int): bool = all {
    removeOk(s, c, rid, u), go(removeNext(s, c, rid, u), "removeLiquidity", c, "rec", rid),
  }

  // ============================================================ RE-CREDIT
  // AaveAdapter.recredit (Q-254): liquidity added to a pledged NFT through increaseLiquidity
  // is booked as a top-up of exactly `live - credited` with every top-up check (rescue rules
  // included), minted to the proxy and supplied.

  pure def recreditAdded(st: St, rid: int): int = {
    val r0 = st.recs.get(rid)
    val st0 = reconcile(st, r0.proxy, r0.market)
    val r = st0.recs.get(rid)
    st0.nfts.get(r.tokenId).liquidity - r.credited
  }

  pure def recreditOk(st: St, c: str, rid: int): bool =
    st.recs.keys().contains(rid) and {
      val r0 = st.recs.get(rid)
      val p = r0.proxy
      val m = r0.market
      val sp = SPOKE_OF.get(m)
      val st0 = reconcile(st, p, m)
      val r = st0.recs.get(rid)
      val added = st0.nfts.get(r.tokenId).liquidity - r.credited
      and {
        r0.open, c == r0.depositor, PROXY.get((c, sp)) == p, r.credited > 0, added > 0,
        not(st.app == "Paused" and st.reason == "MintPathSuspect"),
        not(st.app == "Frozen" and not(hasDebt(st0, p))),
        backingGuard(st, m),
        pledgeCheck(st0, c, p, m, added).ok,
      }
    }

  pure def recreditNext(st: St, c: str, rid: int): St = {
    val r0 = st.recs.get(rid)
    val p = r0.proxy
    val m = r0.market
    val st0 = latchRead(reconcile(st, p, m), Set(m))
    val r = st0.recs.get(rid)
    val added = st0.nfts.get(r.tokenId).liquidity - r.credited
    val pc = pledgeCheck(st0, c, p, m, added)
    val nx = { ...st0,
      recs: st0.recs.set(rid, { ...r, credited: r.credited + added, rescue: r.rescue + (if (pc.rescue) added else 0) }),
      bal: addBal(st0.bal, m, "HUB", added),
      supplied: st0.supplied.set((p, m), st0.supplied.get((p, m)) + added),
    }
    { ...nx,
      g: { ...nx.g,
        topUpStateBreach: nx.g.topUpStateBreach or (not(st.riskHostile) and not(pledgeRuleOk(st0, c, p, m, added, pc.rescue))),
        mintWhileSuspect: nx.g.mintWhileSuspect or (st.app == "Paused" and st.reason == "MintPathSuspect"),
        rescueBreach: nx.g.rescueBreach or (pc.rescue and not(rescueEligible(st0, p, m, added))),
        breakerBypass: nx.g.breakerBypass or (marketBreaker(st0, m) and not(pc.rescue) and not(st.riskHostile)),
        frozenActed: nx.g.frozenActed or (st.frozen.contains(c) and not(pc.rescue) and not(st.riskHostile)),
        gapChanged: nx.g.gapChanged or gapGhost(st, nx, m),
        recreditBreach: nx.g.recreditBreach or
          nx.recs.get(rid).credited != nx.nfts.get(r.tokenId).liquidity or nx.supplied.get((p, m)) > creditedOf(nx, p, m),
      },
    }
  }

  action recredit(c: str, rid: int): bool = all {
    recreditOk(s, c, rid), go(recreditNext(s, c, rid), "recredit", c, "rec", rid),
  }

  // ================================================================ FEES
  // depositor -> LPVault.collectFees -> NFPM.collect (Q-030, Q-051); never gated

  pure def collectOk(st: St, c: str, rid: int): bool =
    st.recs.keys().contains(rid) and { val r = st.recs.get(rid) and { r.open, c == r.depositor } }

  pure def collectNext(st: St, c: str, rid: int): St = {
    val r = st.recs.get(rid)
    val n = st.nfts.get(r.tokenId)
    { ...st,
      nfts: st.nfts.set(r.tokenId, { ...n, fees: 0 }),
      g: { ...st.g, feesMisdirected: st.g.feesMisdirected + (if (c != r.depositor) n.fees else 0) },
    }
  }

  action collectFees(c: str, rid: int): bool = all {
    collectOk(s, c, rid), go(collectNext(s, c, rid), "collectFees", c, "rec", rid),
  }

  // ===================================================== UNISWAP / MISC

  action accrueFees(t: int): bool = all {
    s.nfts.get(t).liquidity > 0,
    go({ ...s, nfts: s.nfts.set(t, { ...s.nfts.get(t), fees: s.nfts.get(t).fees + 10 }) }, "poolFees", "", "nft", t),
  }

  // NFPM.increaseLiquidity is callable by anyone (donation; the depositor may re-credit it)
  action donate(who: str, t: int, amt: int): bool =
    go({ ...s, nfts: s.nfts.set(t, { ...s.nfts.get(t), liquidity: s.nfts.get(t).liquidity + amt }) },
       "increaseLiquidity", who, "nft", t)

  action accrueInterest(p: str, a: str): bool = all {
    s.debt.get((p, a)) > 0,
    go({ ...s,
         debt: s.debt.set((p, a), s.debt.get((p, a)) + 50),
         drawn: s.drawn.set((spOf(p), a), s.drawn.get((spOf(p), a)) + 50),
         accrued: s.accrued.set(a, s.accrued.get(a) + 50) }, "accrueInterest", p, a, 50),
  }

  // NFT sent straight to the LPVault without a pledge (stray, Q-104, Q-258)
  action strayTransfer(w: str, t: int): bool = all {
    s.nfts.get(t).owner == w, WALLETS.contains(w),
    go({ ...s,
         nfts: s.nfts.set(t, { ...s.nfts.get(t), owner: "LPVAULT" }),
         strayProven: s.strayProven.set(t, w) }, "strayTransferToLPVault", w, "nft", t),
  }

  pure def hasOpenRecord(st: St, t: int): bool = openRecs(st).exists(i => st.recs.get(i).tokenId == t)

  // returnStrayNft through the timelock: only an NFT with no depositor of record
  pure def rescueOk(st: St, t: int): bool = and {
    st.nfts.get(t).owner == "LPVAULT", not(hasOpenRecord(st, t)), st.strayProven.get(t) != "",
  }

  action govRescue(t: int): bool = all {
    rescueOk(s, t),
    go({ ...s,
         nfts: s.nfts.set(t, { ...s.nfts.get(t), owner: s.strayProven.get(t) }),
         strayProven: s.strayProven.set(t, ""),
         g: { ...s.g, rescueOfRecorded: s.g.rescueOfRecorded or hasOpenRecord(s, t) } },
       "timelock.returnStrayNft", "TIMELOCK", "nft", t),
  }

  // ============================================================== ORACLES
  // LPOracle per market: TWAP drift, route disagreement with the lower-route price,
  // both routes failing (Cached, then Expired), recovery with the timestamp latch, the
  // standby route (Q-248) and poke().

  action priceMove(m: str, v: int): bool = all {
    s.pst.get(m) == Live or s.pst.get(m) == Drifting,
    go({ ...s, price: s.price.set(m, v), lowPx: s.lowPx.set(m, imax(1, v - 1)) }, "priceMove", "", m, v),
  }

  action drift(m: str): bool = all {
    s.pst.get(m) == Live, go({ ...s, pst: s.pst.set(m, Drifting) }, "toDrifting(TWAP)", "", m, 0),
  }

  action disagree(m: str): bool = all {
    s.pst.get(m) == Live or s.pst.get(m) == Drifting, s.disagreeSince.get(m) < 0,
    go({ ...s, pst: s.pst.set(m, Drifting), disagreeSince: s.disagreeSince.set(m, s.now),
         lowPx: s.lowPx.set(m, imax(1, s.price.get(m) - 1)) }, "routesDisagree", "", m, 0),
  }

  action undrift(m: str): bool = all {
    s.pst.get(m) == Drifting,
    go({ ...s, pst: s.pst.set(m, Live), disagreeSince: s.disagreeSince.set(m, -1),
         disagreeSeen: s.disagreeSeen.set(m, -1) }, "routesAgree->Live", "", m, 0),
  }

  pure def toCached(st: St, m: str): St =
    if (st.pst.get(m) == Cached) st
    else { ...st, pst: st.pst.set(m, Cached), cachedSince: st.cachedSince.set(m, st.now),
           disagreeSince: st.disagreeSince.set(m, -1), disagreeSeen: st.disagreeSeen.set(m, -1) }

  // first fresh price after an outage: Live, with the grace latch if the outage reached Expired
  pure def toLive(st: St, m: str, v: int): St = {
    val wasExpired = ps(st, m) == Expired
    { ...st,
      pst: st.pst.set(m, Live), price: st.price.set(m, v), lowPx: st.lowPx.set(m, imax(1, v - 1)),
      disagreeSince: st.disagreeSince.set(m, -1), disagreeSeen: st.disagreeSeen.set(m, -1),
      trueRecoveredAt: if (wasExpired) st.trueRecoveredAt.set(m, st.now) else st.trueRecoveredAt,
      recoveredAt: if (wasExpired and st.design.latch == "TIMESTAMP") st.recoveredAt.set(m, st.now) else st.recoveredAt }
  }

  action feedFail(m: str): bool = {
    val st1 = { ...s, feedsDown: s.feedsDown.union(Set(m)) }
    all { not(s.feedsDown.contains(m)), go(if (servingFresh(st1, m)) st1 else toCached(st1, m), "bothRoutesFail", "", m, 0) }
  }

  action recover(m: str, v: int): bool = {
    val st1 = { ...s, feedsDown: s.feedsDown.exclude(Set(m)) }
    all { s.feedsDown.contains(m), go(if (st1.pst.get(m) == Cached and servingFresh(st1, m)) toLive(st1, m, v) else st1, "routesRecover", "", m, v) }
  }

  action standbyGoesStale(m: str): bool = {
    val st1 = { ...s, standbyStale: s.standbyStale.union(Set(m)) }
    all { not(s.standbyStale.contains(m)), go(if (servingFresh(st1, m)) st1 else toCached(st1, m), "standbyStale", "", m, 0) }
  }

  // useStandbyRoute: the listed standby replaces the failed route at once; it never bypasses
  // freshness (a stale standby leaves the market Cached) and a disagreement ends only if the
  // standby agrees (Q-248)
  pure def standbyEffect(st: St, m: str): St = {
    val st1 = { ...st, standbyActive: st.standbyActive.union(Set(m)) }
    if (not(servingFresh(st1, m))) toCached(st1, m)
    else if (st1.pst.get(m) == Cached or st1.disagreeSince.get(m) >= 0) toLive(st1, m, st1.price.get(m))
    else st1
  }

  pure def unstandbyEffect(st: St, m: str): St = {
    val st1 = { ...st, standbyActive: st.standbyActive.exclude(Set(m)) }
    if (servingFresh(st1, m)) st1 else toCached(st1, m)
  }

  action useStandby(by: str, m: str): bool = all {
    GUARDIANS.contains(by), not(s.standbyActive.contains(m)),
    go({ ...standbyEffect(s, m), g: { ...s.g, standbyBreach: s.g.standbyBreach or not(GUARDIANS.contains(by)) } },
       "guardian.useStandbyRoute", by, m, 0),
  }

  // the Aave governance executor undoes a guardian's switch at once (cancelStandbySwitch)
  action cancelStandby(by: str, m: str): bool = all {
    by == "AAVE_EXEC", s.standbyActive.contains(m),
    go(unstandbyEffect(s, m), "aaveExecutor.cancelStandbySwitch", by, m, 0),
  }

  action poke(m: str): bool = go(latchRead(s, Set(m)), "poke", "", m, 0)

  // DebtOracle (USDT): primary and alternate with failover, agreement check, Cached/Expired,
  // standby; Aave reads the stress price once Expired and the higher route during a disagreement
  action debtPriceMove(v: int): bool = all {
    s.dpst == Live, not(s.dDisagree), go({ ...s, dpx: v, dHigh: v }, "debtPriceMove", "", "USDT", v),
  }
  action debtDisagree: bool = all {
    s.dpst == Live, not(s.dDisagree), go({ ...s, dDisagree: true, dHigh: s.dpx + 20 }, "debtRoutesDisagree", "", "USDT", 0),
  }
  action debtAgree: bool = all { s.dDisagree, go({ ...s, dDisagree: false, dHigh: s.dpx }, "debtRoutesAgree", "", "USDT", 0) }
  action debtFeedFail: bool = all {
    not(s.dFeedsDown),
    go({ ...s, dFeedsDown: true,
         dpst: if (s.dStandby) s.dpst else Cached,
         dCachedSince: if (s.dStandby or s.dpst == Cached) s.dCachedSince else s.now,
         dDisagree: if (s.dStandby) s.dDisagree else false }, "debtRoutesFail", "", "USDT", 0),
  }
  action debtRecover(v: int): bool = all {
    s.dFeedsDown,
    go({ ...s, dFeedsDown: false, dpst: Live, dpx: if (s.dpst == Cached) v else s.dpx, dHigh: if (s.dpst == Cached) v else s.dHigh },
       "debtRoutesRecover", "", "USDT", v),
  }
  action useStandbyDebt(by: str): bool = all {
    GUARDIANS.contains(by), not(s.dStandby),
    go({ ...s, dStandby: true, dpst: Live, dDisagree: false, dHigh: s.dpx }, "guardian.useStandbyRoute", by, "USDT", 0),
  }
  action cancelStandbyDebt(by: str): bool = all {
    by == "AAVE_EXEC", s.dStandby,
    go({ ...s, dStandby: false,
         dpst: if (s.dFeedsDown) Cached else s.dpst,
         dCachedSince: if (s.dFeedsDown and s.dpst != Cached) s.now else s.dCachedSince },
       "aaveExecutor.cancelStandbySwitch", by, "USDT", 0),
  }

  // ============================================================ LIQUIDATION

  type LiqRes = { ok: bool, repay: int, seized: int, noColl: bool, collLeft: int }

  // The liquidation-manager Borrow Spoke's liquidationCall(collateral, debtReserve, user,
  // debtToCover, false), canonical Aave V4 sizing at Aave's prices (Q-222, Q-247). A served
  // price of 0 stands for latestAnswer() = 1 (10^-8 USD per whole vault token): the whole
  // supply is seized for one debt unit.
  pure def aaveLiq(st: St, p: str, m: str, a: str, d: int): LiqRes = {
    val sp = SPOKE_OF.get(m)
    val debt = st.debt.get((p, a))
    val dp = aaveDpx(st, a)
    val sup = st.supplied.get((p, m))
    val pr = aavePx(st, m)
    val debt0 = imin(d, debt)
    val debtL = if (debt0 < debt and (debt - debt0) * dp < DUST * 100) debt else debt0   // debt dust -> all debt
    val seized0 = if (pr > 0) debtL * dp * (100 + BONUS) / (10000 * pr) else BIG
    val collDust = seized0 < sup and (sup - seized0) * pr < DUST
    val allColl = seized0 > sup or (collDust and debtL < debt)
    val repayAllColl = imin(imax(1, ceilDiv(sup * pr * 10000, (100 + BONUS) * dp)), debt)
    val repay = if (allColl) repayAllColl else debtL
    val seized = if (not(allColl)) seized0
                 else if (repayAllColl < debt) sup                                         // collateral binds
                 else if (pr > 0) imin(sup, debt * dp * (100 + BONUS) / (10000 * pr)) else sup   // debt binds
    val collAfter = sup - seized
    val otherColl = acctMarkets(st, p).exclude(Set(m)).fold(0, (acc, x) => acc + st.supplied.get((p, x)))
    {
      ok: and {
        liquidatable(st, p), st.enabled.contains((p, m)), sup > 0, repay > 0,
        d >= repay,                                                               // MustNotLeaveDust
        DEBT_RES.get(sp).contains(a),
        not(st.vaultPaused.contains(m)), not(st.debtPaused.contains((sp, a))), not(st.hubHalted.contains(sp)),
      },
      repay: repay, seized: seized, noColl: collAfter + otherColl == 0, collLeft: collAfter,
    }
  }

  // Aave-side effects; `dst` (msg.sender, the liquidation manager) receives the units. A
  // liquidation that leaves no collateral on the Spoke reports every remaining debt as deficit.
  pure def applyAaveLiq(st: St, p: str, m: str, a: str, lr: LiqRes, dst: str): St = {
    val sp = SPOKE_OF.get(m)
    val ds = DEBT_RES.get(sp)
    val debt2 = ds.fold(st.debt, (acc, x) =>
      acc.set((p, x), if (lr.noColl) 0 else if (x == a) st.debt.get((p, x)) - lr.repay else st.debt.get((p, x))))
    val defAdd = ASSETS.mapBy(x =>
      if (lr.noColl and ds.contains(x)) (if (x == a) st.debt.get((p, x)) - lr.repay else st.debt.get((p, x))) else 0)
    { ...st,
      debt: debt2,
      drawn: ds.fold(st.drawn, (acc, x) => acc.set((sp, x), acc.get((sp, x)) - (st.debt.get((p, x)) - debt2.get((p, x))))),
      liq: st.liq.set(a, st.liq.get(a) + lr.repay),
      deficit: ASSETS.mapBy(x => st.deficit.get(x) + defAdd.get(x)),
      deficitEver: ASSETS.mapBy(x => st.deficitEver.get(x) + defAdd.get(x)),
      supplied: st.supplied.set((p, m), lr.collLeft),
      enabled: if (lr.collLeft == 0) st.enabled.exclude(Set((p, m))) else st.enabled,
      bal: addBal(addBal(st.bal, m, "HUB", -lr.seized), m, dst, lr.seized),
      g: { ...st.g,
        seizers: if (lr.seized > 0) st.g.seizers.union(Set(dst)) else st.g.seizers,
        deficitReporters: if (ASSETS.exists(x => defAdd.get(x) > 0)) st.g.deficitReporters.union(Set(dst)) else st.g.deficitReporters,
        liqHealthy: st.g.liqHealthy or (lr.seized > 0 and not(liquidatable(st, p))),
      },
    }
  }

  // Collateralization.settleSeizure: the proxy's Spoke shares and the token's total supply
  // must each have fallen by exactly the debited units (Q-160, Q-224).
  // DELTA: Collateralization's own snapshot; LEDGER: Σ credited - units == supply after.
  pure def collSettleOk(st: St, q: str, m: str, units: int, qSupplyAfter: int, supplyDrop: int): bool =
    supplyDrop == units and (
      if (st.design.debitCheck == "DELTA") st.supplied.get((q, m)) - qSupplyAfter == units
      else creditedOf(st, q, m) - units == qSupplyAfter)

  // Two sell legs (one per pool token), each with an oracle-derived minimum (Q-250):
  // minOut = max(1, ⌈V_leg × (100 − sLeg) / 100⌉ − ⌊floorRoundingAllowance / 2⌋). Values in GHO cents.
  type Legs = { ok: bool, r: int }
  pure def legs(v: int, s0: int, s1: int, sLeg: int): Legs = {
    val v0 = v / 2
    val v1 = v - v0
    val min0 = imax(1, ceilDiv(v0 * (100 - sLeg), 100) - ROUND_ALLOW * 100 / 2)
    val min1 = imax(1, ceilDiv(v1 * (100 - sLeg), 100) - ROUND_ALLOW * 100 / 2)
    val r0 = v0 * (100 - s0) / 100
    val r1 = v1 * (100 - s1) / 100
    { ok: (v0 == 0 or r0 >= min0) and (v1 == 0 or r1 >= min1), r: r0 + r1 }
  }

  // effective sell slippage: the buy leg is inside the bound (1 + b)(1 − s) ≥ 1 + buyAllow (Q-235, Q-261)
  pure def sEff(a: str): int = imin(ALLOW, 100 - ceilDiv(100 * (100 + (if (a == "GHO") 0 else BUY_ALLOW)), 100 + BONUS))

  // Settlement waterfall in GHO cents (Q-085, Q-198, Q-235, Q-250, Q-251, Q-256)
  type Settle = {
    v: int, r: int, sx: int, legsOk: bool, minGho: int, sh: int, floorOk: bool,
    gcost: int, bound: int, ret: int, sbFloor: int, unspent: int, gnet: int,
    gap: int, shF: int, surplus: int, feeTarget: int, fee: int, callerGets: int,
  }

  pure def settleX(st: St, lr: LiqRes, m: str, a: str, q: LiqP): Settle = {
    val v = lr.seized * st.price.get(m) * 100                        // oracle value V
    val se = sEff(a)
    val sx = if (v > 0) imin(MAX_SH_PCT, q.k * 100 / v) else 0      // shortfall allowance per leg
    val lg = legs(v, q.s0, q.s1, se + sx)
    val minGho = imax(0, v * (100 - se) / 100 - ROUND_ALLOW * 100)  // aggregate recovery floor
    val shF = imax(0, minGho - lg.r)                                 // caller's floor top-up
    val dtc = lr.repay + (if (a == "GHO") 0 else q.over)
    val gcost = if (a == "GHO") lr.repay * 100 else ceilDiv(dtc * st.dpx * (100 + q.b), 100)
    val bound = if (a == "GHO") gcost else ceilDiv(dtc * st.dpx * (100 + BUY_ALLOW), 100)
    val unspent = dtc - lr.repay
    val ret = unspent * st.dpx * (100 - q.b) / 100                   // sell-back of unspent debt asset
    val sbFloor = (unspent * st.dpx) * (100 - BUY_ALLOW) / 100 - 1
    val gnet = gcost - ret
    val gap = imax(0, gnet - lg.r - shF)                             // settlement gap, caller-paid (Q-397)
    val sh = shF + gap
    val surplus = imax(0, lg.r + sh - gnet)
    val feeTarget = imax(0, v - gnet) * FEE_SHARE / 100              // from oracle value (Q-256)
    val fee = imin(feeTarget, surplus)
    {
      v: v, r: lg.r, sx: sx, legsOk: lg.ok, minGho: minGho, sh: sh, floorOk: shF <= q.k,
      gcost: gcost, bound: bound, ret: ret, sbFloor: sbFloor, unspent: unspent, gnet: gnet,
      gap: gap, shF: shF, surplus: surplus, feeTarget: feeTarget, fee: fee, callerGets: surplus - fee,
    }
  }

  // monitoring alert counters (Q-399): seizure surge and route failures are alerts only;
  // they never gate borrowing (a guardian acts on them)
  pure def noteSeizure(st: St, m: str, units: int): St = {
    val fresh = st.now >= st.seizeWinStart.get(m) + BRK_WIN
    val w = if (fresh) units else st.seizeWin.get(m) + units
    { ...st,
      seizeWinStart: if (fresh) st.seizeWinStart.set(m, st.now) else st.seizeWinStart,
      seizeWin: st.seizeWin.set(m, w),
    }
  }

  pure def noteRouteFail(st: St, m: str, failed: bool): St =
    if (not(failed)) st else {
      val fresh = st.now >= st.rfWinStart.get(m) + BRK_WIN
      val w = if (fresh) 1 else st.rfWin.get(m) + 1
      { ...st,
        rfWinStart: if (fresh) st.rfWinStart.set(m, st.now) else st.rfWinStart,
        rfWin: st.rfWin.set(m, w),
      }
    }

  // LPVaultSwap's own checks (Q-128, Q-189, Q-206, Q-213, Q-242, Q-247): never the pause
  // state, a breaker or the borrower's freeze; only the seized market's and the repaid
  // reserve's own prices; grace per account.
  pure def liqGate(st: St, c: str, p: str, m: str, a: str): bool = {
    val acct = acctMarkets(st, p)
    val deep = adjAave(st, p) * 100 < debtVal(st, p) * DEEP_HF
    and {
      not(st.swapHostile), not(st.frozen.contains(c)),                 // any caller that is not frozen (Q-404)
      not(st.sharesNeq.contains(m)),
      mktFreshForLiq(st, m), debtFresh(st, a),
      not(inGrace(latchRead(st, acct), acct)) or deep,
      not(st.routeFailing.contains(m)), not(st.routeDisabled.contains(m)),
      a == "GHO" or (not(st.buyFailing) and not(st.buyDisabled)),
    }
  }

  // Honest LPVaultSwap liquidation through the one entry point `liquidate` (Q-404): any caller
  // that is not frozen, registered as a committed operator or not; every caller funds its own
  // gap (Q-397). Deadline and minimum payout only make the call revert (Q-216).
  pure def swapLiqOk(st: St, c: str, p: str, m: str, a: str, q: LiqP): bool = {
    val lr = aaveLiq(st, p, m, a, q.d)
    val x = settleX(st, lr, m, a, q)
    and {
      st.now <= q.dl,
      liqGate(st, c, p, m, a),
      lr.ok, lr.seized > 0,                                              // NothingSeized
      x.legsOk, x.floorOk, x.gcost <= x.bound, x.unspent == 0 or x.ret >= x.sbFloor,
      gho(st, c) >= x.sh,
      collSettleOk(st, p, m, lr.seized, lr.collLeft, lr.seized),
      x.callerGets >= q.minPay,
    }
  }

  pure def q0(d: int): LiqP = { d: d, s0: 0, s1: 0, k: 0, b: 0, over: 0, dl: NO_DEADLINE, minPay: 0 }

  pure def otherAccountsSame(st0: St, st1: St, p: str): bool =
    PROXIES.exclude(Set(p)).forall(q =>
      MARKETS.forall(m => st0.supplied.get((q, m)) == st1.supplied.get((q, m))) and
      ASSETS.forall(a => st0.debt.get((q, a)) == st1.debt.get((q, a))))

  // Settlement: reconcile any earlier unsettled seizure (with the pre-seizure snapshot,
  // SPEC-BACK-011), Aave liquidation, burnSeized, debit largest first, unwind, convert,
  // waterfall.
  pure def swapLiqNext(st: St, c: str, p: str, m: str, a: str, q: LiqP): St = {
    val sp = SPOKE_OF.get(m)
    val acct = acctMarkets(st, p)
    val st1 = reconcile(latchRead(st, acct), p, m)
    val lr = aaveLiq(st, p, m, a, q.d)
    val x = settleX(st, lr, m, a, q)
    val deep = adjAave(st, p) * 100 < debtVal(st, p) * DEEP_HF
    val trueGrace = acct.exists(y => st.now < st.trueRecoveredAt.get(y) + GRACE)
    val st2 = applyAaveLiq(st1, p, m, a, lr, "LPVAULTSWAP")
    val db = debitLargestFirst(st2, p, m, lr.seized)
    val st3 = { ...st2, recs: db.recs, nfts: db.nfts, bal: addBal(st2.bal, m, "LPVAULTSWAP", -lr.seized) }
    val st4 = noteSeizure(noteRouteFail(st3, m, st.primaryDown.contains(m)), m, lr.seized)
    val blockedPay = st.payoutBlocked.contains(c) and x.callerGets > 0     // the token refuses the payout (Q-401)
    val st5 = { ...st4,
      feeRecipient: st4.feeRecipient + x.fee,
      cash: addCash(st4.cash, c, "GHO", (if (blockedPay) 0 else x.callerGets) - x.sh),
      escrowHeld: if (blockedPay) st4.escrowHeld.set(c, st4.escrowHeld.get(c) + x.callerGets) else st4.escrowHeld,
      escrowCredited: if (blockedPay) st4.escrowCredited.set(c, st4.escrowCredited.get(c) + x.callerGets) else st4.escrowCredited,
      escrowBal: if (blockedPay) st4.escrowBal + x.callerGets else st4.escrowBal,
      failFirst: st4.failFirst.set(m, -1),
      reportTimes: st4.reportTimes.set(m, Set()),
    }
    { ...st5,
      g: { ...st5.g,
        exitNotReconciled: st5.g.exitNotReconciled or st5.supplied.get((p, m)) != creditedOf(st5, p, m),
        liqStale: st5.g.liqStale or not(mktFreshForLiq(st, m)) or not(debtFresh(st, a)),
        liqGraceBreach: st5.g.liqGraceBreach or (trueGrace and not(deep)),
        debitMismatch: st5.g.debitMismatch or db.left != 0 or db.principal != lr.seized,
        largestFirstBreach: st5.g.largestFirstBreach or not(db.ordered),
        floorBreach: st5.g.floorBreach or x.r + x.sh < x.minGho,
        conservationBreach: st5.g.conservationBreach or (x.r + x.sh != x.gnet + x.fee + x.callerGets),
        gapOnZeroSeize: st5.g.gapOnZeroSeize or (lr.seized == 0 and x.gap > 0),
        avanaFunded: st5.g.avanaFunded or st5.feeRecipient < st.feeRecipient or x.r + x.sh < x.gnet,
        payoutLost: st5.g.payoutLost or (blockedPay and st5.escrowHeld.get(c) != st.escrowHeld.get(c) + x.callerGets),
        feesMisdirected: st5.g.feesMisdirected + db.fees,
        feeBreach: st5.g.feeBreach or x.fee > x.surplus or x.fee > imax(0, x.v - x.gnet) * FEE_SHARE / 100
                   or (x.surplus >= x.feeTarget and x.fee != x.feeTarget),
        legBreach: st5.g.legBreach or not(x.legsOk) or (x.sx == 0 and x.r < x.minGho),
        sellbackBreach: st5.g.sellbackBreach or (x.unspent > 0 and x.ret < x.sbFloor),
        spendBreach: st5.g.spendBreach or x.gcost > x.bound,
        shortfallBreach: st5.g.shortfallBreach or x.shF > q.k,
        topUpSplitBreach: st5.g.topUpSplitBreach or x.sh != x.shF + x.gap or x.gap != imax(0, x.gnet - x.r - x.shF),
        crossAccount: st5.g.crossAccount or not(otherAccountsSame(st, st5, p)),
        shortfallPaid: st5.g.shortfallPaid + x.sh,
      },
    }
  }

  action liquidate(c: str, p: str, m: str, a: str, q: LiqP): bool = all {
    swapLiqOk(s, c, p, m, a, q), go(swapLiqNext(s, c, p, m, a, q), "LPVaultSwap.liquidate", c, a, q.d),
  }

  // reportRecoveryShortfall (Q-251, Q-399, Q-401): an approved keeper runs the liquidation in a
  // call that reverts with its result; a floor failure is recorded as a monitoring alert only.
  // It never opens a settlement mode or changes a market gate.
  pure def reportOk(st: St, k: str, p: str, m: str, a: str, q: LiqP): bool = {
    val lr = aaveLiq(st, p, m, a, q.d)
    val x = settleX(st, lr, m, a, q)
    and { st.keepers.contains(k), liqGate(st, k, p, m, a), lr.ok, lr.seized > 0, x.legsOk, x.gcost <= x.bound, x.r < x.minGho }
  }

  pure def reportNext(st: St, m: str): St = {
    val first = if (st.failFirst.get(m) < 0 or st.now - st.failLast.get(m) > REPORT_GAP) st.now else st.failFirst.get(m)
    val times = st.reportTimes.get(m).union(Set(st.now))
    val st1 = noteRouteFail(st, m, st.primaryDown.contains(m))
    { ...st1,
      failFirst: st1.failFirst.set(m, first), failLast: st1.failLast.set(m, st.now),
      reportTimes: st1.reportTimes.set(m, times),
      g: { ...st1.g, reportGateChange: st1.g.reportGateChange or marketBreaker(st1, m) != marketBreaker(st, m)
                                       or liqHaltedMkt(st1, m) != liqHaltedMkt(st, m) },
    }
  }

  action reportShortfall(k: str, p: str, m: str, a: str, q: LiqP): bool = all {
    reportOk(s, k, p, m, a, q), go(reportNext(s, m), "LPVaultSwap.reportRecoveryShortfall", k, m, q.d),
  }

  // PayoutEscrow.claim (payout escrow, Q-401): only the credited holder, to a recipient it
  // chooses; never gated. It holds payouts a token refused (here the caller's GHO payout).
  pure def claimOk(st: St, c: str, w: str): bool = c == w and st.escrowHeld.get(w) > 0

  action claimEscrow(c: str, w: str, dst: str): bool = all {
    claimOk(s, c, w),
    go({ ...s,
         cash: addCash(s.cash, dst, "GHO", s.escrowHeld.get(w)),
         escrowClaimed: s.escrowClaimed.set(w, s.escrowClaimed.get(w) + s.escrowHeld.get(w)),
         escrowBal: s.escrowBal - s.escrowHeld.get(w),
         escrowHeld: s.escrowHeld.set(w, 0) },
       "PayoutEscrow.claim", c, dst, s.escrowHeld.get(w)),
  }

  // ================================================== REPAY WITH COLLATERAL
  // AaveAdapter.repayWithCollateral (Q-255): flash-funded; the proxy repays x, withdraws
  // `units`, the Adapter burns them, Collateralization debits, the LPVault unwinds to
  // LPVaultSwap, which converts with per-leg minimums at slippageAllowanceBps, repays the
  // flash loan and sends the rest to the wallet. No bonus or fee. Paused and the
  // caller's freeze refuse it; Frozen and breakers do not.

  type Rwc = { x: int, v: int, r: int, legsOk: bool, cost: int }

  pure def rwcCalc(st: St, p: str, m: str, a: str, u: int, slip: int, b: int): Rwc = {
    val v = u * st.price.get(m) * 100
    val lg = legs(v, slip, slip, ALLOW)
    val xMax = imax(0, v * (100 - ALLOW) / 100 - ROUND_ALLOW * 100) / aaveDpx(st, a)
    val x = imin(st.debt.get((p, a)), xMax)
    val cost = if (a == "GHO") x * 100 else ceilDiv(x * st.dpx * (100 + b), 100)
    { x: x, v: v, r: lg.r, legsOk: lg.ok, cost: cost }
  }

  pure def rwcEffect(st: St, rid: int, u: int, a: str, x: int, toWallet: int): St = {
    val r = st.recs.get(rid)
    val p = r.proxy
    val m = r.market
    val sp = SPOKE_OF.get(m)
    val n = st.nfts.get(r.tokenId)
    val whole = u == r.credited
    val left = st.supplied.get((p, m)) - u
    { ...st,
      debt: st.debt.set((p, a), st.debt.get((p, a)) - x),
      drawn: st.drawn.set((sp, a), st.drawn.get((sp, a)) - x),
      liq: st.liq.set(a, st.liq.get(a) + x),
      supplied: st.supplied.set((p, m), left),
      enabled: if (left == 0) st.enabled.exclude(Set((p, m))) else st.enabled,
      bal: addBal(st.bal, m, "HUB", -u),
      recs: st.recs.set(rid, { ...r, credited: r.credited - u, rescue: imin(r.rescue, r.credited - u), open: not(whole) }),
      nfts: st.nfts.set(r.tokenId, { ...n, liquidity: n.liquidity - u, owner: if (whole) r.depositor else n.owner }),
      cash: addCash(st.cash, r.depositor, "GHO", toWallet),
    }
  }

  pure def hfNotLower(st0: St, st1: St, p: str): bool =
    adjAave(st1, p) * debtVal(st0, p) >= adjAave(st0, p) * debtVal(st1, p)

  pure def rwcOk(st: St, c: str, rid: int, u: int, a: str, minRepaid: int, slip: int, b: int): bool =
    st.recs.keys().contains(rid) and {
      val r0 = st.recs.get(rid)
      val p = r0.proxy
      val m = r0.market
      val sp = SPOKE_OF.get(m)
      val st0 = reconcile(st, p, m)
      val r = st0.recs.get(rid)
      val z = rwcCalc(st0, p, m, a, u, slip, b)
      val nx = rwcEffect(st0, rid, u, a, z.x, z.r - z.cost)
      and {
        r0.open, c == r0.depositor, PROXY.get((c, sp)) == p,
        st.app != "Paused", not(st.frozen.contains(c)), not(st.swapHostile),
        backingGuard(st, m),
        mktFreshForLiq(st, m), debtFresh(st, a), not(st.sharesNeq.contains(m)),
        not(st.routeFailing.contains(m)), not(st.routeDisabled.contains(m)),
        a == "GHO" or (not(st.buyFailing) and not(st.buyDisabled) and b <= BUY_ALLOW),
        not(st.vaultPaused.contains(m)), not(st.hubHalted.contains(sp)), not(st.debtPaused.contains((sp, a))),
        u > 0, u <= r.credited, st0.supplied.get((p, m)) >= u,
        DEBT_RES.get(sp).contains(a), st0.debt.get((p, a)) > 0, z.x > 0, z.x >= minRepaid,
        z.legsOk, z.r >= z.cost,
        not(hasDebt(nx, p)) or (aaveHealthy(nx, p) and hfNotLower(st0, nx, p)),
      }
    }

  pure def rwcNext(st: St, c: str, rid: int, u: int, a: str, slip: int, b: int): St = {
    val r0 = st.recs.get(rid)
    val p = r0.proxy
    val m = r0.market
    val st0 = reconcile(st, p, m)
    val z = rwcCalc(st0, p, m, a, u, slip, b)
    val nx = rwcEffect(st0, rid, u, a, z.x, z.r - z.cost)
    { ...nx,
      g: { ...nx.g,
        exitNotReconciled: nx.g.exitNotReconciled or nx.supplied.get((p, m)) != creditedOf(nx, p, m),
        gapChanged: nx.g.gapChanged or gapGhost(st, nx, m),
        rwcBreach: nx.g.rwcBreach or z.r < z.cost or nx.feeRecipient != st.feeRecipient
                   or (hasDebt(nx, p) and not(hfNotLower(st0, nx, p))),
        frozenActed: nx.g.frozenActed or st.frozen.contains(c),
        nonOwnerAction: nx.g.nonOwnerAction or P_WALLET.get(p) != c,
      },
    }
  }

  action repayWithCollateral(c: str, rid: int, u: int, a: str, slip: int, b: int): bool = all {
    rwcOk(s, c, rid, u, a, 0, slip, b), go(rwcNext(s, c, rid, u, a, slip, b), "repayWithCollateral", c, a, rid),
  }

  // ===================================================== PENDING SETTLEMENT
  // LPVaultSwap.settlePending: open to anyone in every state; the Adapter burns the
  // unsettled vault tokens LPVaultSwap holds; Collateralization requires
  // totalSupply + x ≤ credited + pending (Q-257); proceeds fund the GHO Coverage Spoke (Q-236).
  pure def settlePendingX(st: St, m: str): int = imin(st.bal.get((m, "LPVAULTSWAP")), st.pending.get(m))

  pure def settlePendingOk(st: St, m: str): bool = {
    val x = settlePendingX(st, m)
    and { not(st.swapHostile), x > 0, supplyOf(st, m) <= creditedMarket(st, m) + st.pending.get(m) }
  }

  action settlePending(m: str): bool = {
    val x = settlePendingX(s, m)
    val proceeds = x * s.price.get(m)
    all {
      settlePendingOk(s, m),
      go({ ...s,
           bal: addBal(s.bal, m, "LPVAULTSWAP", -x),
           pending: s.pending.set(m, s.pending.get(m) - x),
           reserve: s.reserve.set("GHO", s.reserve.get("GHO") + proceeds),
           reserveFundedEver: s.reserveFundedEver.set("GHO", s.reserveFundedEver.get("GHO") + proceeds),
           liq: s.liq.set("GHO", s.liq.get("GHO") + proceeds),
           g: { ...s.g, pendingSettled: s.g.pendingSettled + x } },
         "LPVaultSwap.settlePending", "anyone", m, x),
    }
  }

  // The Spoke's liquidationCall reverts Unauthorized() for every caller other than its
  // LIQUIDATION_MANAGER (LPVaultSwap), including zero-collateral calls (Q-222).
  pure def directLiqOk(st: St, c: str, p: str, m: str, a: str, d: int): bool =
    c == "LPVAULTSWAP" and aaveLiq(st, p, m, a, d).ok

  // =========================================================== HOSTILE SWAP
  // A hostile LPVaultSwap implementation. It is the Spoke's liquidation manager and an
  // allowed recipient, so Aave pays it seized units; the immutable Collateralization and
  // escrow still apply their own checks when called.

  action upgradeSwapHostile: bool = all {
    not(s.swapHostile), go({ ...s, swapHostile: true }, "upgrade lands: LPVaultSwap -> hostile", "TIMELOCK", "", 0),
  }

  action restoreSwapHonest: bool = all {
    s.swapHostile, go({ ...s, swapHostile: false }, "upgrade lands: LPVaultSwap -> reviewed", "TIMELOCK", "", 0),
  }

  pure def hostileSeizeOk(st: St, p: str, m: str, a: str, d: int): bool = {
    val lr = aaveLiq(st, p, m, a, d)
    and { st.swapHostile, lr.ok, lr.seized > 0 }
  }

  pure def staleGhost(st: St, m: str, a: str, g: Ghost): Ghost =
    { ...g, liqStale: g.liqStale or not(mktFreshForLiq(st, m)) or not(debtFresh(st, a)) }

  // seize, then never settle
  action hostileSwapKeep(p: str, m: str, a: str, d: int): bool = {
    val st2 = applyAaveLiq(s, p, m, a, aaveLiq(s, p, m, a, d), "LPVAULTSWAP")
    all { hostileSeizeOk(s, p, m, a, d), go({ ...st2, g: staleGhost(s, m, a, st2.g) }, "hostileSwap.seizeAndKeep", "LPVAULTSWAP", p, d) }
  }

  // burnSeized of tokens it holds, never followed by a debit (orphan burn, Q-257)
  action hostileOrphanBurn(m: str): bool = {
    val x = s.bal.get((m, "LPVAULTSWAP"))
    all {
      s.swapHostile, x > 0,
      go({ ...s, bal: addBal(s.bal, m, "LPVAULTSWAP", -x), orphan: s.orphan.set(m, s.orphan.get(m) + x) },
         "hostileSwap.burnSeizedNoSettle", "LPVAULTSWAP", m, x),
    }
  }

  // seize from p, then ask Collateralization to settle proxy q, with or without burning
  pure def hostileReleaseOk(st: St, p: str, q: str, m: str, a: str, d: int, burn: bool): bool = {
    val lr = aaveLiq(st, p, m, a, d)
    val qAfter = if (q == p) lr.collLeft else st.supplied.get((q, m))
    and {
      hostileSeizeOk(st, p, m, a, d),
      collSettleOk(st, q, m, lr.seized, qAfter, if (burn) lr.seized else 0),    // immutable checks
      creditedOf(st, q, m) >= lr.seized,
    }
  }

  pure def hostileReleaseNext(st: St, p: str, q: str, m: str, a: str, d: int): St = {
    val lr = aaveLiq(st, p, m, a, d)
    val st2 = applyAaveLiq(reconcile(st, q, m), p, m, a, lr, "LPVAULTSWAP")
    val db = debitLargestFirst(st2, q, m, lr.seized)
    val st3 = { ...st2, recs: db.recs, nfts: db.nfts, bal: addBal(st2.bal, m, "LPVAULTSWAP", -lr.seized) }
    { ...st3,
      cash: addCash(st3.cash, "eve", "GHO", lr.seized * st.price.get(m) * 100),
      g: { ...staleGhost(st, m, a, st3.g),
        debitMismatch: st3.g.debitMismatch or q != p or db.left != 0,
        feesMisdirected: st3.g.feesMisdirected + db.fees,
      },
    }
  }

  action hostileSwapRelease(p: str, q: str, m: str, a: str, d: int, burn: bool): bool = all {
    hostileReleaseOk(s, p, q, m, a, d, burn), go(hostileReleaseNext(s, p, q, m, a, d), "hostileSwap.seizeAndSettle", p, q, d),
  }

  // move kept vault tokens: the token's path rule admits no transfer from LPVaultSwap
  // (REQ-VTOKEN-041, Q-300), so this move is never enabled and kept units leave LPVaultSwap
  // only by a burn (hostileOrphanBurn, hostileSwapRelease)
  action hostileSwapTransfer(m: str, dst: str): bool = {
    val x = s.bal.get((m, "LPVAULTSWAP"))
    all {
      s.swapHostile, x > 0, dst != "LPVAULTSWAP", allowedTransfer(s, m, "LPVAULTSWAP", dst),
      go({ ...s, bal: addBal(addBal(s.bal, m, "LPVAULTSWAP", -x), m, dst, x),
           hubDonated: if (dst == "HUB") s.hubDonated.set(m, s.hubDonated.get(m) + x) else s.hubDonated },
         "hostileSwap.transferVaultTokens", "LPVAULTSWAP", dst, x),
    }
  }

  // Collateralization.settlePending without a burn: allowed only inside the backing gap
  action hostileSettleNoBurn(m: str): bool = {
    val x = imin(s.pending.get(m), gapOf(s, m))
    all {
      s.swapHostile, x > 0,
      supplyOf(s, m) + x <= creditedMarket(s, m) + s.pending.get(m),
      go({ ...s, pending: s.pending.set(m, s.pending.get(m) - x), orphan: s.orphan.set(m, s.orphan.get(m) - x),
           cash: addCash(s.cash, "eve", "GHO", x * s.price.get(m) * 100) },
         "hostileSwap.settlePendingNoBurn", "LPVAULTSWAP", m, x),
    }
  }

  // ======================================================= HOSTILE RISKMODULE
  // approves every pledge, borrow and withdraw-with-debt (Q-229, REQ-RISK-007)

  action upgradeRiskHostile: bool = all {
    not(s.riskHostile), go({ ...s, riskHostile: true }, "upgrade lands: RiskModule -> hostile", "TIMELOCK", "", 0),
  }

  // ========================================================= HOSTILE ADAPTER
  // The Adapter's blast radius (Q-223): borrow against any proxy up to drawCap, withdraw any
  // proxy's supply (Hub -> proxy), mint to a registered proxy, burn from a registered proxy or
  // LPVaultSwap (never the Hub), register any address but a binding (REQ-VTOKEN-047). It cannot
  // send an NFT anywhere but to its depositor of record.

  action upgradeAdapterHostile: bool = all {
    not(s.adapterHostile), go({ ...s, adapterHostile: true }, "upgrade lands: AaveAdapter -> hostile", "TIMELOCK", "", 0),
  }

  action haMintSupply(p: str, m: str): bool = all {
    s.adapterHostile, s.validProxy.contains((m, p)), SPOKE_OF.get(m) == spOf(p), aaveSupplyOk(s, m, 100),
    go({ ...s, bal: addBal(s.bal, m, "HUB", 100), supplied: s.supplied.set((p, m), s.supplied.get((p, m)) + 100),
         enabled: s.enabled.union(Set((p, m))) }, "hostileAdapter.mintAndSupply", "ADAPTER", p, 100),
  }

  action haBurn(m: str, h: str): bool = {
    val x = imin(100, s.bal.get((m, h)))
    all { s.adapterHostile, x > 0, h == "LPVAULTSWAP" or s.validProxy.contains((m, h)),
          go({ ...s, bal: addBal(s.bal, m, h, -x) }, "hostileAdapter.burn", "ADAPTER", h, x) }
  }

  action haRegister(m: str, x: str): bool = all {
    s.adapterHostile, not(s.validProxy.contains((m, x))),
    go({ ...s, validProxy: s.validProxy.union(Set((m, x))) }, "hostileAdapter.addValidProxy", "ADAPTER", x, 0),
  }

  action haBorrowFor(p: str, a: str, amt: int): bool = {
    val sp = spOf(p)
    val nx = { ...s,
      debt: s.debt.set((p, a), s.debt.get((p, a)) + amt),
      drawn: s.drawn.set((sp, a), s.drawn.get((sp, a)) + amt),
      liq: s.liq.set(a, s.liq.get(a) - amt),
      cash: addCash(s.cash, "eve", a, amt * 100) }
    all {
      s.adapterHostile, isCreated(s, p), DEBT_RES.get(sp).contains(a),
      not(s.debtPaused.contains((sp, a))), not(s.debtFrozen.contains((sp, a))), not(s.hubHalted.contains(sp)),
      amt <= s.liq.get(a), s.drawn.get((sp, a)) + amt <= s.drawCap.get((sp, a)), aaveHealthy(nx, p),
      go({ ...nx, g: { ...nx.g,
             borrowOverCap: nx.g.borrowOverCap or s.drawn.get((sp, a)) + amt > s.drawCap.get((sp, a)),
             borrowBelowAave: nx.g.borrowBelowAave or not(aaveHealthy(nx, p)) } },
         "hostileAdapter.borrowFor", "ADAPTER", p, amt),
    }
  }

  action haWithdrawFrom(p: str, m: str): bool = {
    val u = imin(100, s.supplied.get((p, m)))
    val nx = { ...s, supplied: s.supplied.set((p, m), s.supplied.get((p, m)) - u),
               bal: addBal(addBal(s.bal, m, "HUB", -u), m, p, u) }
    all { s.adapterHostile, u > 0, not(s.vaultPaused.contains(m)), aaveHealthy(nx, p),
          go({ ...nx, g: { ...nx.g, borrowBelowAave: nx.g.borrowBelowAave or not(aaveHealthy(nx, p)) } },
             "hostileAdapter.withdrawFrom", "ADAPTER", p, u) }
  }

  // Collateralization.release for any record: the immutable LPVault sends the NFT only
  // to the depositor of record, whatever recipient the Adapter names
  action haReleaseNft(rid: int, named: str): bool = all {
    s.adapterHostile, s.recs.keys().contains(rid), s.recs.get(rid).open,
    {
      val r = s.recs.get(rid)
      val n = s.nfts.get(r.tokenId)
      val recipient = r.depositor
      go({ ...s,
           recs: s.recs.set(rid, { ...r, credited: 0, rescue: 0, open: false }),
           nfts: s.nfts.set(r.tokenId, { ...n, owner: recipient }),
           g: { ...s.g, nftMisdirected: s.g.nftMisdirected or recipient != r.depositor } },
         "hostileAdapter.releaseNft", "ADAPTER", named, rid)
    },
  }

  // ======================================================= APPLICATION STATE
  // MarketRegistry pause state (Q-227, Q-252): freeze() None -> Frozen by a freeze-role
  // holder; pause(reason) None/Frozen -> Paused by a pause guardian; unpause / unfreeze only
  // by a pause guardian (or the timelock); raising the reason to MintPathSuspect is immediate.

  action freezeApp(by: str): bool = all {
    FREEZERS.contains(by), s.app == "None", go({ ...s, app: "Frozen" }, "registry.freeze", by, "", 0),
  }

  action pauseApp(by: str, rs: str): bool = all {
    GUARDIANS.contains(by), s.app != "Paused", go({ ...s, app: "Paused", reason: rs }, "registry.pause", by, rs, 0),
  }

  action setPauseReason(by: str, rs: str): bool = all {
    GUARDIANS.contains(by), s.app == "Paused", s.reason != rs, go({ ...s, reason: rs }, "registry.setPauseReason", by, rs, 0),
  }

  // attempted by any freezer; only a pause guardian succeeds
  pure def liftOk(st: St, by: str, fromSt: str): bool = GUARDIANS.contains(by) and st.app == fromSt

  action liftApp(by: str, fromSt: str): bool = all {
    liftOk(s, by, fromSt),
    go({ ...s, app: "None", reason: "", g: { ...s.g, pauseRoleBreach: s.g.pauseRoleBreach or not(GUARDIANS.contains(by)) } },
       if (fromSt == "Paused") "registry.unpause" else "registry.unfreeze", by, "", 0),
  }

  // circuit breakers: manual trips by a freeze-role holder, resets by a pause guardian (Q-241)
  action tripMarket(by: str, m: str): bool = all {
    FREEZERS.contains(by), not(s.manualMkt.contains(m)),
    go({ ...s, manualMkt: s.manualMkt.union(Set(m)) }, "registry.tripMarketBreaker", by, m, 0),
  }
  action resetMarket(by: str, m: str): bool = all {
    GUARDIANS.contains(by), s.manualMkt.contains(m),
    go({ ...s, manualMkt: s.manualMkt.exclude(Set(m)),
         g: { ...s.g, pauseRoleBreach: s.g.pauseRoleBreach or not(GUARDIANS.contains(by)) } },
       "registry.resetMarketBreaker", by, m, 0),
  }
  action tripDebt(by: str, sp: str, a: str): bool = all {
    FREEZERS.contains(by), KEYS.contains((sp, a)), not(s.manualDebt.contains((sp, a))),
    go({ ...s, manualDebt: s.manualDebt.union(Set((sp, a))) }, "registry.tripDebtBreaker", by, a, 0),
  }
  action resetDebt(by: str, sp: str, a: str): bool = all {
    GUARDIANS.contains(by), s.manualDebt.contains((sp, a)),
    go({ ...s, manualDebt: s.manualDebt.exclude(Set((sp, a))) }, "registry.resetDebtBreaker", by, a, 0),
  }

  // address freeze (Q-242): immediate for a freeze-role holder, rate-limited per caller,
  // never for a protected address; no keeper floor (Q-400): freezing the last active keeper
  // succeeds and new borrowing then halts (liqHaltedMkt)
  pure def freezeTargetOk(st: St, a: str): bool = and {
    not(PROTECTED.contains(a)), not(st.frozen.contains(a)),
  }

  action freezeAddress(by: str, a: str): bool = {
    val fresh = s.now >= s.freezeWinStart.get(by) + DAY
    val cnt = if (fresh) 1 else s.freezeWinCount.get(by) + 1
    all {
      FREEZERS.contains(by), freezeTargetOk(s, a), cnt <= FREEZE_LIMIT,
      go({ ...s, frozen: s.frozen.union(Set(a)),
           freezeWinStart: if (fresh) s.freezeWinStart.set(by, s.now) else s.freezeWinStart,
           freezeWinCount: s.freezeWinCount.set(by, cnt),
           g: { ...s.g, freezeRateBreach: s.g.freezeRateBreach or cnt > FREEZE_LIMIT } },
         "registry.freezeAddress", by, a, 0),
    }
  }

  // ============================================================ AAVE SIDE
  // Aave Protocol Guardian (one-way pause and freeze) and the Aave DAO (lifts, halts, caps)

  action aavePauseVault(m: str): bool = go({ ...s, vaultPaused: s.vaultPaused.union(Set(m)) }, "aaveGuardian.pauseReserve(vault)", "APG", m, 0)
  action aaveFreezeVault(m: str): bool = go({ ...s, vaultFrozen: s.vaultFrozen.union(Set(m)) }, "aaveGuardian.freezeReserve(vault)", "APG", m, 0)
  action aavePauseDebt(sp: str, a: str): bool = all {
    KEYS.contains((sp, a)), go({ ...s, debtPaused: s.debtPaused.union(Set((sp, a))) }, "aaveGuardian.pauseReserve(debt)", "APG", a, 0),
  }
  action aaveFreezeDebt(sp: str, a: str): bool = all {
    KEYS.contains((sp, a)), go({ ...s, debtFrozen: s.debtFrozen.union(Set((sp, a))) }, "aaveGuardian.freezeReserve(debt)", "APG", a, 0),
  }
  action daoUnpauseAll: bool =
    go({ ...s, vaultPaused: Set(), vaultFrozen: Set(), debtPaused: Set(), debtFrozen: Set() }, "dao.unpauseAndUnfreezeReserves", "DAO", "", 0)
  action daoHalt(sp: str, on: bool): bool =
    go({ ...s, hubHalted: if (on) s.hubHalted.union(Set(sp)) else s.hubHalted.exclude(Set(sp)) },
       if (on) "dao.Hub.haltSpoke" else "dao.Hub.unhaltSpoke", "DAO", sp, 0)
  action daoSetDrawCap(sp: str, a: str, v: int): bool = all {
    KEYS.contains((sp, a)), go({ ...s, drawCap: s.drawCap.set((sp, a), v) }, "dao.setDrawCap", "DAO", a, v),
  }
  action sharesFlag(m: str, on: bool): bool =
    go({ ...s, sharesNeq: if (on) s.sharesNeq.union(Set(m)) else s.sharesNeq.exclude(Set(m)) }, "hub.sharesNeqAssets", "", m, if (on) 1 else 0)
  action configDriftFlag(on: bool): bool =
    go({ ...s, configDrift: on }, "aave.riskConfigurationDrift", "DAO", "", if (on) 1 else 0)

  // ========================================================== ENVIRONMENT

  action routeFail(m: str): bool = all { not(s.routeFailing.contains(m)), go({ ...s, routeFailing: s.routeFailing.union(Set(m)) }, "routesFailAtRunTime", "", m, 0) }
  action routeRestore(m: str): bool = all { s.routeFailing.contains(m), go({ ...s, routeFailing: s.routeFailing.exclude(Set(m)) }, "routesWorkAgain", "", m, 0) }
  action primaryToggle(m: str): bool =
    go({ ...s, primaryDown: if (s.primaryDown.contains(m)) s.primaryDown.exclude(Set(m)) else s.primaryDown.union(Set(m)) }, "primaryRouteToggle", "", m, 0)
  action buyToggle: bool = go({ ...s, buyFailing: not(s.buyFailing) }, "usdtBuyRoutesToggle", "", "USDT", 0)
  action issuerToggle(m: str): bool =
    go({ ...s, issuerMkt: if (s.issuerMkt.contains(m)) s.issuerMkt.exclude(Set(m)) else s.issuerMkt.union(Set(m)) }, "issuerProbeToggle", "", m, 0)
  action issuerAssetToggle(a: str): bool =
    go({ ...s, issuerAsset: if (s.issuerAsset.contains(a)) s.issuerAsset.exclude(Set(a)) else s.issuerAsset.union(Set(a)) }, "issuerProbeToggle", "", a, 0)
  action poolThinToggle(m: str): bool =
    go({ ...s, poolThin: if (s.poolThin.contains(m)) s.poolThin.exclude(Set(m)) else s.poolThin.union(Set(m)) }, "outsideLiquidityMoves", "", m, 0)

  // ============================================================ RESERVES

  action fundReserve(a: str, x: int): bool =
    go({ ...s, reserve: s.reserve.set(a, s.reserve.get(a) + x), reserveFundedEver: s.reserveFundedEver.set(a, s.reserveFundedEver.get(a) + x),
         liq: s.liq.set(a, s.liq.get(a) + x) }, "fundCoverageSpoke", "AVANA", a, x)

  // the Coverage Spoke of asset a covers a deficit recorded in a (Q-236)
  action coverDeficit(a: str, amt: int): bool = {
    val x = imin(amt, imin(s.deficit.get(a), s.reserve.get(a)))
    all {
      x > 0,
      go({ ...s, deficit: s.deficit.set(a, s.deficit.get(a) - x), reserve: s.reserve.set(a, s.reserve.get(a) - x),
           coveredEver: s.coveredEver.set(a, s.coveredEver.get(a) + x) }, "coverageSpoke.coverDeficit", "DAO", a, x),
    }
  }

  // a debt token starts or stops refusing transfers to a holder (payout escrow, Q-401)
  action payoutBlockToggle(h: str): bool =
    go({ ...s, payoutBlocked: if (s.payoutBlocked.contains(h)) s.payoutBlocked.exclude(Set(h)) else s.payoutBlocked.union(Set(h)) },
       "env.payoutRefusal", h, "", 0)

  // ============================================================== TIME

  pure def advance(st: St, k: int): St = {
    val n2 = st.now + k
    val reset = n2 >= st.winStart + DAY
    { ...st,
      now: n2,
      winStart: if (reset) n2 else st.winStart,
      cp: MARKETS.mapBy(m => st.price.get(m)),          // hourly checkpoint of the accepted price
      cpAt: MARKETS.mapBy(m => n2),
    }
  }

  action tick: bool = go(advance(s, 1), "tick", "", "", s.now + 1)
  action waitDelay: bool = go(advance(s, NORMAL0), "wait(normal delay)", "", "", s.now + NORMAL0)

  // ======================================================= AVANA TIMELOCK
  // TimelockController extension (Q-228, Q-245, Q-259, Q-262, Q-263): proposers are the
  // governance multisig and the Aave governance executor; the short delay applies only when
  // every call is on the enabled short list, itself inside the immutable SHORT_ELIGIBLE; the
  // normal delay stays in [MIN_NORMAL_DELAY, MAX_DELAY]; execution is public within OP_GRACE
  // of ready; restoring and role-change operations are cancellable only by the DAO.

  pure def reqDelay(st: St, calls: Set[str]): int = if (calls.subseteq(st.shortEnabled)) SHORT_DELAY else st.normalDelay
  pure def daoOnly(calls: Set[str]): bool = calls.subseteq(RESTORING) or calls.subseteq(ROLE_CALLS)

  pure def applyOneOk(st: St, call: str, tgt: str, arg: int): bool =
    if (call == "loosenOpenHf") st.openHf > 0 and st.now >= st.lastLoosen + st.normalDelay
    else if (call == "tightenOpenHf") imax(st.openHf + LOOSEN_STEP, OPEN_HF_MIN) <= OPEN_HF_MAX
    else if (call == "addKeeper") not(st.frozen.contains(tgt)) and not(st.keepers.contains(tgt))
    else if (call == "removeKeeper") st.keepers.contains(tgt) and activeKeepers(st).exclude(Set(tgt)).size() >= KEEPER_FLOOR
    else if (call == "freezeAddress") freezeTargetOk(st, tgt)
    else if (call == "unfreezeAddress") st.frozen.contains(tgt)
    else if (call == "pause") st.app != "Paused"
    else if (call == "freeze") st.app == "None"
    else if (call == "unpause") st.app == "Paused"
    else if (call == "unfreeze") st.app == "Frozen"
    else if (call == "grantAdmin") tgt == "TIMELOCK"                       // AdminRoleOnlyTimelock (Q-259)
    else if (call == "setNormalDelay") arg >= MIN_NORMAL and arg <= MAX_DELAY
    else if (call == "setShortDelaySelector") arg == 0 or SHORT_ELIGIBLE.contains(tgt)   // InvalidShortDelaySelector
    else if (call == "useStandbyRoute") not(st.standbyActive.contains(tgt))
    else if (call == "restorePriceRoute") st.standbyActive.contains(tgt)
    else true

  pure def applyOne(st: St, call: str, tgt: str, arg: int): St =
    if (call == "loosenOpenHf") { ...st, openHf: if (st.openHf - LOOSEN_STEP < OPEN_HF_MIN) 0 else st.openHf - LOOSEN_STEP, lastLoosen: st.now }
    else if (call == "tightenOpenHf") { ...st, openHf: imax(st.openHf + LOOSEN_STEP, OPEN_HF_MIN) }
    else if (call == "disableRoute") { ...st, routeDisabled: st.routeDisabled.union(Set(tgt)) }
    else if (call == "restoreRoute") { ...st, routeDisabled: st.routeDisabled.exclude(Set(tgt)) }
    else if (call == "addKeeper") { ...st, keepers: st.keepers.union(Set(tgt)) }
    else if (call == "removeKeeper") { ...st, keepers: st.keepers.exclude(Set(tgt)) }
    else if (call == "freezeAddress") { ...st, frozen: st.frozen.union(Set(tgt)) }
    else if (call == "unfreezeAddress") { ...st, frozen: st.frozen.exclude(Set(tgt)) }
    else if (call == "pause") { ...st, app: "Paused", reason: tgt }
    else if (call == "freeze") { ...st, app: "Frozen" }
    else if (call == "unpause" or call == "unfreeze") { ...st, app: "None", reason: "" }
    else if (call == "grantAdmin") { ...st, admins: st.admins.union(Set(tgt)) }
    else if (call == "setNormalDelay") { ...st, normalDelay: arg }
    else if (call == "setShortDelaySelector") { ...st, shortEnabled: if (arg == 1) st.shortEnabled.union(Set(tgt)) else st.shortEnabled.exclude(Set(tgt)) }
    else if (call == "useStandbyRoute") standbyEffect(st, tgt)
    else if (call == "restorePriceRoute") unstandbyEffect(st, tgt)
    else if (call == "tripMarketBreaker") { ...st, manualMkt: st.manualMkt.union(Set(tgt)) }
    else if (call == "resetMarketBreaker") { ...st, manualMkt: st.manualMkt.exclude(Set(tgt)) }
    else if (call == "setMarketOffboarding") { ...st, offboarding: st.offboarding.union(Set(tgt)) }
    else st                                                             // upgrades to reviewed implementations

  type OpRes = { ok: bool, st: St }
  pure def applyOp(st: St, op: Op): OpRes =
    op.calls.fold({ ok: true, st: st }, (acc, c) =>
      if (not(acc.ok)) acc
      else if (applyOneOk(acc.st, c, op.tgt, op.arg)) { ok: true, st: applyOne(acc.st, c, op.tgt, op.arg) }
      else { ok: false, st: acc.st })

  pure def scheduleOk(st: St, pr: str, t: OpT, short: bool): bool = and {
    PROPOSERS.contains(pr), pr != "MULTISIG" or st.multisigLive,
    (if (short) SHORT_DELAY else st.normalDelay) >= reqDelay(st, t.calls),
  }

  action schedule(pr: str, t: OpT, short: bool): bool = all {
    scheduleOk(s, pr, t, short),
    go({ ...s,
         ops: s.ops.put(s.nextOp, { calls: t.calls, tgt: t.tgt, arg: t.arg, proposer: pr, schedAt: s.now,
                                    readyAt: s.now + (if (short) SHORT_DELAY else s.normalDelay), status: "Pending", by: "" }),
         nextOp: s.nextOp + 1 }, "timelock.schedule", pr, t.tgt, s.nextOp),
  }

  pure def executeOk(st: St, id: int): bool =
    st.ops.keys().contains(id) and {
      val op = st.ops.get(id)
      and { op.status == "Pending", st.now >= op.readyAt, st.now < op.readyAt + OP_GRACE, applyOp(st, op).ok }
    }

  action execute(id: int): bool = {
    val op = s.ops.get(id)
    val st1 = applyOp(s, op).st
    all {
      executeOk(s, id),
      go({ ...st1,
           ops: s.ops.set(id, { ...op, status: "Done", by: "anyone" }),
           g: { ...st1.g,
             tlFast: st1.g.tlFast or (not(op.calls.subseteq(SHORT_ELIGIBLE)) and s.now - op.schedAt < MIN_NORMAL),
             tlLate: st1.g.tlLate or s.now >= op.readyAt + OP_GRACE } },
         "timelock.execute", "anyone", op.tgt, id),
    }
  }

  pure def cancelOk(st: St, c: str, id: int): bool =
    st.ops.keys().contains(id) and {
      val op = st.ops.get(id)
      and { op.status == "Pending", CANCELLERS.contains(c), not(daoOnly(op.calls)) or c == DAO_CANCELLER }
    }

  action cancel(c: str, id: int): bool = all {
    cancelOk(s, c, id),
    go({ ...s, ops: s.ops.set(id, { ...s.ops.get(id), status: "Cancelled", by: c }) }, "timelock.cancel", c, "", id),
  }

  action multisigLost: bool = all { s.multisigLive, go({ ...s, multisigLive: false }, "governanceSafe.quorumLost", "", "", 0) }

  // ================================================================ INIT

  action initWith(d: Design, label: str): bool = all {
    s' = initState(d), la' = { act: label, who: "", tgt: "", n: 0 },
  }
  action init = initWith(DESIGN_FINAL, "init")
  action initLedger = initWith({ ...DESIGN_FINAL, debitCheck: "LEDGER" }, "init(LEDGER debit check)")
  action initUncapped = initWith({ ...DESIGN_FINAL, principalCappedCollect: false }, "init(uncapped collect)")
  action initReadLatch = initWith({ ...DESIGN_FINAL, latch: "READ" }, "init(Q-129 read latch)")
  action initEquality = initWith({ ...DESIGN_FINAL, backingCheck: "EQUALITY" }, "init(absolute backing equality)")
  action initHostileSwap = all {
    s' = { ...initState(DESIGN_FINAL), swapHostile: true }, la' = { act: "init(LPVaultSwap hostile)", who: "", tgt: "", n: 0 },
  }

  // A reachable state with open positions, built with the normal transitions: alice NFTs 42
  // and 7 in mA with 2,500 GHO of debt; bob NFT 8 in mA with 600 GHO and 400 USDT of debt.
  pure val STRESSED: St = {
    val s1 = pledgeNext(initState(DESIGN_FINAL), "alice", 42, "mA")
    val s2 = pledgeNext(s1, "alice", 7, "mA")
    val s3 = pledgeNext(s2, "bob", 8, "mA")
    val s4 = borrowNext(s3, "alice", "S1", "GHO", 1500)
    val s5 = borrowNext(s4, "alice", "S1", "GHO", 1000)
    val s6 = borrowNext(s5, "bob", "S1", "GHO", 600)
    borrowNext(s6, "bob", "S1", "USDT", 400)
  }
  action initStressed = all { s' = STRESSED, la' = { act: "init(open positions)", who: "", tgt: "", n: 0 } }
  action initStressedHostileSwap = all {
    s' = { ...STRESSED, swapHostile: true }, la' = { act: "init(open positions, LPVaultSwap hostile)", who: "", tgt: "", n: 0 },
  }
  action initStressedHostileAdapter = all {
    s' = { ...STRESSED, adapterHostile: true }, la' = { act: "init(open positions, AaveAdapter hostile)", who: "", tgt: "", n: 0 },
  }
  // mA's routes fail at run time; eve's GHO payouts are refused (payout escrow, Q-401)
  action initRouteOutage = all {
    s' = { ...STRESSED, routeFailing: Set("mA"), payoutBlocked: Set("eve") },
    la' = { act: "init(open positions, mA routes failing, eve payout refused)", who: "", tgt: "", n: 0 },
  }
  // the routes of mA run 10 % below the oracle: liquidations fall below the floor
  action initCrash = all {
    s' = { ...STRESSED, price: STRESSED.price.set("mA", 1), lowPx: STRESSED.lowPx.set("mA", 1) },
    la' = { act: "init(open positions, mA price 1)", who: "", tgt: "", n: 0 },
  }

  // ================================================================= STEPS
  // The step first picks one action group (cheap) and only evaluates that group's branches.
  // Each group keeps `tick` as an always-enabled fallback.

  action doPledge = {
    nondet w = WALLETS.oneOf()
    nondet t = TOKEN_IDS.oneOf()
    nondet m = MARKETS.oneOf()
    val o = s.nfts.get(t).owner
    any {
      pledge(o, t, s.nfts.get(t).pool),                // owner pledges into its pool
      pledge(w, t, m),                                 // anyone, any market (mostly rejected)
      tick,
    }
  }

  action doBorrowRepay = {
    nondet w = WALLETS.oneOf()
    nondet c = WALLETS.oneOf()
    nondet p = PROXIES.oneOf()
    nondet sp = SPOKES.oneOf()
    nondet a = DEBT_RES.get(sp).oneOf()
    nondet ap = ASSETS.oneOf()
    nondet amt = BORROW_AMTS.oneOf()
    nondet r = REPAY_AMTS.oneOf()
    any {
      borrow(w, sp, a, amt, s.nonce.get(PROXY.get((w, sp)))),
      borrow(w, sp, a, amt, 0),                        // replayed nonce
      repay(w, PROXY.get((w, sp)), a, r),
      repay(c, p, ap, 300),                            // any payer (Q-212)
      repayAll(w, PROXY.get((w, sp)), a, BIG),
      tick,
    }
  }

  action doExit = {
    nondet c = WALLETS.oneOf()
    nondet rid = (if (openRecs(s).size() > 0) openRecs(s) else 1.to(12)).oneOf()
    nondet u = Set(100, 300).oneOf()
    nondet a = ASSETS.oneOf()
    nondet slip = Set(0, 2).oneOf()
    val dep = if (s.recs.keys().contains(rid)) s.recs.get(rid).depositor else c
    val cr = if (s.recs.keys().contains(rid)) s.recs.get(rid).credited else 0
    any {
      withdraw(dep, rid), withdrawZero(dep, rid), collectFees(dep, rid),
      removeLiquidity(dep, rid, u), recredit(dep, rid),
      repayWithCollateral(dep, rid, u, a, slip, 0), repayWithCollateral(dep, rid, cr, a, slip, 0),
      withdraw(c, rid), collectFees(c, rid), removeLiquidity(c, rid, u),     // anyone else
      tick,
    }
  }

  action doMisc = {
    nondet t = TOKEN_IDS.oneOf()
    nondet w = WALLETS.oneOf()
    nondet p = PROXIES.oneOf()
    nondet a = ASSETS.oneOf()
    nondet c = WALLETS.oneOf()
    any { accrueFees(t), donate(w, t, 100), accrueInterest(p, a), strayTransfer(w, t), govRescue(t),
          claimEscrow(w, w, c), claimEscrow(c, w, c), tick }
  }

  pure def usedMarkets(st: St): Set[str] = {
    val u = MARKETS.filter(m => PROXIES.exists(p => st.enabled.contains((p, m))))
    if (u.size() > 0) u else MARKETS
  }

  action doOracle = {
    nondet m = MARKETS.oneOf()
    nondet mu = usedMarkets(s).oneOf()
    nondet v = PRICES.oneOf()
    nondet g = GUARDIANS.oneOf()
    any {
      priceMove(mu, v), priceMove(mu, 1), priceMove(m, v),
      drift(m), disagree(mu), undrift(m), feedFail(mu), recover(m, v), poke(m),
      standbyGoesStale(m), useStandby(g, m), cancelStandby("AAVE_EXEC", m),
    }
  }

  action doDebtOracle = {
    nondet v = Set(100, 120).oneOf()
    nondet g = GUARDIANS.oneOf()
    any { debtPriceMove(v), debtDisagree, debtAgree, debtFeedFail, debtRecover(v), useStandbyDebt(g),
          cancelStandbyDebt("AAVE_EXEC"), tick }
  }

  // (proxy, market, debt asset) triples Aave would liquidate now
  pure def liqTargets(st: St): Set[(str, str, str)] = {
    val c = tuples(PROXIES, MARKETS, ASSETS).filter(t =>
      st.enabled.contains((t._1, t._2)) and st.debt.get((t._1, t._3)) > 0 and liquidatable(st, t._1))
    if (c.size() > 0) c else tuples(Set("P_alice_S1", "P_bob_S1"), Set("mA"), Set("GHO"))
  }

  action doCrash = {
    nondet mu = usedMarkets(s).oneOf()
    any { priceMove(mu, 1), debtPriceMove(120), tick }
  }

  action doLiquidate = {
    nondet t3 = liqTargets(s).oneOf()
    val p = t3._1
    val m = t3._2
    val a = t3._3
    nondet d = LIQ_AMTS.oneOf()
    nondet sl = SLIPS.oneOf()
    nondet kk = Set(0, 5000).oneOf()
    nondet b = Set(0, 3).oneOf()
    nondet over = Set(0, 10).oneOf()
    nondet k = KEEPERS_ALL.union(Set("eve")).oneOf()
    nondet c = Set("eve", "bob", "k1").oneOf()
    nondet dl = Set(s.now - 1, s.now + 2).oneOf()
    nondet mp = Set(0, 2000).oneOf()
    val q = { d: d, s0: sl, s1: sl, k: kk, b: b, over: over, dl: NO_DEADLINE, minPay: 0 }
    any {
      liquidate(k, p, m, a, q0(BIG)), liquidate(k, p, m, a, q),
      liquidate(c, p, m, a, { ...q, dl: dl, minPay: mp }), liquidate("bob", p, m, a, q0(BIG)),
      reportShortfall(k, p, m, a, { ...q0(BIG), s0: 10, s1: 10, k: 5000 }),
      settlePending(m), tick,
    }
  }

  action doGuardian = {
    nondet f = FREEZERS.oneOf()
    nondet g = GUARDIANS.oneOf()
    nondet rs = Set("General", "MintPathSuspect").oneOf()
    nondet m = MARKETS.oneOf()
    nondet key = KEYS.oneOf()
    nondet x = FREEZE_TARGETS.oneOf()
    nondet fromSt = Set("Paused", "Frozen").oneOf()
    any {
      freezeApp(f), pauseApp(g, rs), setPauseReason(g, rs), liftApp(f, fromSt),
      tripMarket(f, m), resetMarket(g, m), tripDebt(f, key._1, key._2), resetDebt(g, key._1, key._2),
      freezeAddress(f, x), tick,
    }
  }

  action doAave = {
    nondet m = MARKETS.oneOf()
    nondet sp = SPOKES.oneOf()
    nondet key = KEYS.oneOf()
    nondet on = Set(true, false).oneOf()
    any {
      aavePauseVault(m), aaveFreezeVault(m), aavePauseDebt(key._1, key._2), aaveFreezeDebt(key._1, key._2),
      daoUnpauseAll, daoHalt(sp, on), daoSetDrawCap(key._1, key._2, if (on) CAP0.get(key) else 0),
      sharesFlag(m, on), configDriftFlag(on),
    }
  }

  action doEnv = {
    nondet m = MARKETS.oneOf()
    nondet a = ASSETS.oneOf()
    any { routeFail(m), routeRestore(m), primaryToggle(m), buyToggle, issuerToggle(m), issuerAssetToggle(a),
          poolThinToggle(m), payoutBlockToggle("eve"), tick }
  }

  action doFunds = {
    nondet a = ASSETS.oneOf()
    nondet x = COVER_AMTS.oneOf()
    any { fundReserve(a, 200), coverDeficit(a, x), tick }
  }

  pure def readyOps(st: St): Set[int] =
    st.ops.keys().filter(i => st.ops.get(i).status == "Pending" and st.now >= st.ops.get(i).readyAt)

  action doTimelock = {
    nondet pr = PROPOSERS.oneOf()
    nondet t = OP_TEMPLATES.oneOf()
    nondet short = Set(true, false).oneOf()
    nondet c = CANCELLERS.oneOf()
    nondet id = (if (s.ops.keys().size() > 0) s.ops.keys() else Set(1)).oneOf()
    nondet rid = (if (readyOps(s).size() > 0) readyOps(s) else Set(1)).oneOf()
    any { schedule(pr, t, short), execute(rid), execute(id), cancel(c, id), waitDelay, multisigLost, tick }
  }

  // keeper floor-failure reports (monitoring alerts only, Q-399)
  action doReport = {
    nondet t3 = liqTargets(s).oneOf()
    nondet k = KEEPERS_ALL.oneOf()
    any { reportShortfall(k, t3._1, t3._2, t3._3, { ...q0(BIG), s0: 10, s1: 10, k: 5000 }), tick }
  }

  action doHostilePolicy = any { upgradeRiskHostile, tick }

  action doHostileSwap = {
    nondet t3 = liqTargets(s).oneOf()
    val p = t3._1
    val m = t3._2
    val a = t3._3
    nondet q = PROXIES.oneOf()
    nondet d = LIQ_AMTS.oneOf()
    nondet dst = HOLDERS.oneOf()
    nondet burn = Set(true, false).oneOf()
    any { upgradeSwapHostile, restoreSwapHonest, settlePending(m), hostileSwapKeep(p, m, a, d), hostileSwapKeep(p, m, a, BIG),
          hostileOrphanBurn(m), hostileSwapRelease(p, q, m, a, d, burn), hostileSwapRelease(p, p, m, a, BIG, true),
          hostileSwapTransfer(m, dst), hostileSettleNoBurn(m), tick }
  }

  action doHostileAdapter = {
    nondet p = PROXIES.oneOf()
    nondet m = MARKETS.oneOf()
    nondet a = ASSETS.oneOf()
    nondet h = HOLDERS.oneOf()
    nondet rid = (if (openRecs(s).size() > 0) openRecs(s) else 1.to(12)).oneOf()
    any { upgradeAdapterHostile, haMintSupply(p, m), haBurn(m, h), haRegister(m, ROGUE), haBorrowFor(p, a, 300),
          haWithdrawFrom(p, m), haReleaseNft(rid, "eve"), tick }
  }

  // Weighted choice among the action groups that can do something in this state.
  pure def weighted(name: str, w: int): Set[(str, int)] = 1.to(w).map(i => (name, i))

  pure def groups(st: St, hp: bool, hs: bool, ha: bool): Set[(str, int)] = {
    val gapNow = tuples(PROXIES, MARKETS).exists(pm => st.supplied.get(pm) < creditedOf(st, pm._1, pm._2))
    val liqNow = tuples(PROXIES, MARKETS).exists(pm => st.enabled.contains(pm) and liquidatable(st, pm._1))
    weighted("tick", 1).union(weighted("oracle", 2)).union(weighted("dOracle", 1)).union(weighted("misc", 1))
      .union(weighted("guard", 1)).union(weighted("aave", 1)).union(weighted("env", 1)).union(weighted("funds0", 1))
      .union(weighted("tl", if (readyOps(st).size() > 0) 3 else 1))
      .union(if (TOKEN_IDS.exists(t => WALLETS.contains(st.nfts.get(t).owner))) weighted("pledge", 3) else Set())
      .union(if (PROXIES.exists(p => isCreated(st, p))) weighted("borrow", 3) else Set())
      .union(if (openRecs(st).size() > 0) weighted("exit", 2) else Set())
      .union(if (gapNow) weighted("exit2", 3).union(weighted("borrow2", 2)) else Set())
      .union(if (liqNow) weighted("liq", 4) else weighted("liq", 1))
      .union(if (not(liqNow) and PROXIES.exists(p => hasDebt(st, p))) weighted("crash", 2) else Set())
      .union(if (ASSETS.exists(a => st.deficit.get(a) > 0)) weighted("funds", 3) else Set())
      .union(if (liqNow) weighted("rep", 2) else Set())
      .union(if (hp) weighted("hp", 1) else Set())
      .union(if (hs) weighted("hs", if (liqNow and st.swapHostile) 6 else if (liqNow or not(st.swapHostile)) 3 else 1) else Set())
      .union(if (ha) weighted("ha", 3) else Set())
  }

  action stepWith(hp: bool, hs: bool, ha: bool): bool = {
    nondet g = groups(s, hp, hs, ha).oneOf()
    val k = g._1
    if (k == "tick") tick
    else if (k == "pledge") doPledge
    else if (k == "borrow" or k == "borrow2") doBorrowRepay
    else if (k == "exit" or k == "exit2") doExit
    else if (k == "misc") doMisc
    else if (k == "oracle") doOracle
    else if (k == "dOracle") doDebtOracle
    else if (k == "liq") doLiquidate
    else if (k == "guard") doGuardian
    else if (k == "aave") doAave
    else if (k == "env") doEnv
    else if (k == "funds" or k == "funds0") doFunds
    else if (k == "tl") doTimelock
    else if (k == "crash") doCrash
    else if (k == "rep") doReport
    else if (k == "hp") doHostilePolicy
    else if (k == "ha") doHostileAdapter
    else doHostileSwap
  }

  action step = stepWith(false, false, false)
  action stepHostilePolicy = stepWith(true, false, false)
  action stepHostileSwap = stepWith(false, true, false)
  action stepAll = stepWith(true, true, false)
  action stepHostileAdapter = stepWith(false, false, true)

  // ============================================================ INVARIANTS
  // English statements, bounds and results: README.md.

  // QNT-01 verifies: Q-067, Q-193, Q-194, Q-224, Q-240, INV-005
  // One NFT backs at most one open record (NFT #42 cannot be registered twice).
  val qnt01_oneRecordPerNft = TOKEN_IDS.forall(t =>
    openRecs(s).filter(i => s.recs.get(i).tokenId == t).size() <= 1)

  // QNT-02 verifies: Q-067, Q-107, Q-223, Q-225, Q-240, INV-005
  // An open record's NFT is in LPVault custody, in the record's market, and its depositor
  // is the wallet bound to the record's proxy for that market's Spoke.
  val qnt02_recordCustody = openRecs(s).forall(i => {
    val r = s.recs.get(i)
    and {
      s.nfts.get(r.tokenId).owner == "LPVAULT",
      s.nfts.get(r.tokenId).pool == r.market,
      s.proxyWallet.get(r.proxy) == r.depositor,
      PROXY.get((r.depositor, SPOKE_OF.get(r.market))) == r.proxy,
    }
  })

  // QNT-03 verifies: Q-066, Q-201, Q-224, Q-257, INV-001, INV-080
  // Vault-token supply + units burned and never settled == Σ credited + pending, so the
  // supply never exceeds the backing, for any LPVaultSwap implementation.
  val qnt03_supplyEqualsBacking = MARKETS.forall(m =>
    supplyOf(s, m) + s.orphan.get(m) == creditedMarket(s, m) + s.pending.get(m) and s.orphan.get(m) >= 0)

  // QNT-04 verifies: Q-224, Q-300, INV-011
  // Vault tokens are held only by the Hub, LPVaultSwap or a registered proxy, never the Adapter.
  val qnt04_allowedHolders = MARKETS.forall(m => HOLDERS.forall(h =>
    s.bal.get((m, h)) > 0 implies allowedRecipient(s, m, h)))

  // QNT-05 verifies: Q-066, Q-067, Q-254
  val qnt05_liquidityCoversCredit = openRecs(s).forall(i =>
    s.nfts.get(s.recs.get(i).tokenId).liquidity >= s.recs.get(i).credited)

  // QNT-06 verifies: Q-066, Q-116, Q-224
  // Hub vault-token balance == Σ Spoke supplied units (+ tokens sent to the Hub outside supply).
  val qnt06_hubBalanceEqualsSupplied = MARKETS.forall(m =>
    s.bal.get((m, "HUB")) == PROXIES.fold(0, (a, h) => a + s.supplied.get((h, m))) + s.hubDonated.get(m))

  // QNT-07 verifies: Q-160, Q-201, Q-224, Q-254, Q-255, INV-008, INV-058
  // A proxy's Spoke supply never exceeds its credited units, and every exit or settlement
  // leaves them equal.
  val qnt07_perProxyLedger = not(s.g.exitNotReconciled) and PROXIES.forall(p => MARKETS.forall(m =>
    s.supplied.get((p, m)) <= creditedOf(s, p, m)))

  // QNT-08 verifies: Q-107, Q-224, Q-225, Q-276
  // One proxy per (wallet, Borrow Spoke), bound once and never rebound; each vault token
  // registers only proxies of its own Spoke that exist.
  val qnt08_proxyBinding = and {
    PROXIES.forall(p => s.proxyWallet.get(p) == "" or s.proxyWallet.get(p) == P_WALLET.get(p)),
    PROXIES.forall(p => s.bindHistory.filter(b => b._1 == p).size() <= 1),
    s.validProxy.forall(e => PROXIES.contains(e._2) and isCreated(s, e._2) and SPOKE_OF.get(e._1) == spOf(e._2)),
  }

  // QNT-09 verifies: Q-116, Q-144, Q-222, INV-013, INV-041
  // Only LPVaultSwap (the Spoke's liquidation manager) moves vault collateral out of a Spoke
  // position or reports a deficit; Spoke supply sits only with registered proxies.
  val qnt09_onlySwapSeizes = and {
    s.g.seizers.subseteq(Set("LPVAULTSWAP")),
    s.g.deficitReporters.subseteq(Set("LPVAULTSWAP")),
    tuples(PROXIES, MARKETS).forall(pm => s.supplied.get(pm) > 0 implies s.validProxy.contains((pm._2, pm._1))),
  }

  // QNT-10 verifies: Q-160, Q-194, Q-224, INV-014
  val qnt10_debitMatchesSeizure = not(s.g.debitMismatch) and not(s.g.largestFirstBreach)

  // QNT-11 verifies: Q-030, Q-061, Q-105, Q-254, Q-271
  val qnt11_feesToDepositor = s.g.feesMisdirected == 0

  // QNT-12 verifies: Q-104, Q-134, Q-258
  val qnt12_rescueOnlyUncredited = not(s.g.rescueOfRecorded)

  // QNT-13 verifies: Q-223, Q-226, Q-229, REQ-ADAPTER-040, REQ-RISK-007
  // Hostile components stay inside their blast radius: no borrow beyond drawCap or below
  // Aave HF 1, no NFT to anyone but its depositor of record, only LPVaultSwap seizes, the
  // Coverage Spokes move only by funding and DAO coverage, and no borrower action changes
  // another wallet's proxy except through the Adapter's own blast radius.
  val qnt13_hostileBounded = and {
    not(s.g.borrowOverCap), not(s.g.borrowBelowAave), not(s.g.nftMisdirected), not(s.g.nonOwnerAction),
    TOKEN_IDS.forall(t => WALLETS.union(Set("LPVAULT")).contains(s.nfts.get(t).owner)),
    s.g.seizers.subseteq(Set("LPVAULTSWAP")), s.g.deficitReporters.subseteq(Set("LPVAULTSWAP")),
    ASSETS.forall(a => s.reserve.get(a) == s.reserveFundedEver.get(a) - s.coveredEver.get(a)),
    MARKETS.forall(m => s.bal.get((m, "HUB")) <= ADD_CAP + s.hubDonated.get(m)),
  }

  // QNT-14 verifies: Q-051, Q-118, Q-180, Q-212, Q-227, Q-242, Q-260, Q-269
  // Repay of every debt reserve is open, for the borrower and any other payer, unless Aave
  // itself blocks it (debt reserve paused, Hub halt).
  val qnt14_repayAlwaysOpen = PROXIES.forall(p => DEBT_RES.get(spOf(p)).forall(a =>
    (isCreated(s, p) and s.debt.get((p, a)) > 0 and not(s.debtPaused.contains((spOf(p), a))) and not(s.hubHalted.contains(spOf(p))))
      implies (repayOk(s, P_WALLET.get(p), p, a, s.debt.get((p, a)), false) and repayOk(s, "eve", p, a, s.debt.get((p, a)), false))))

  // QNT-15 verifies: Q-051, Q-118, Q-134, Q-201, Q-227, Q-241, Q-242, Q-254, Q-257, Q-260
  // Debt-free withdrawal and partial removal are open unless Aave itself blocks them,
  // including after an unsettled seizure or an orphan burn.
  val qnt15_debtFreeWithdrawOpen = openRecs(s).forall(i => {
    val r = s.recs.get(i)
    val sp = SPOKE_OF.get(r.market)
    (not(hasDebt(s, r.proxy)) and not(s.vaultPaused.contains(r.market)) and not(s.hubHalted.contains(sp)))
      implies and {
        withdrawOk(s, r.depositor, i) or withdrawZeroOk(s, r.depositor, i),
        reconcile(s, r.proxy, r.market).recs.get(i).credited >= 2 implies removeOk(s, r.depositor, i, 1),
      }
  })

  // QNT-16 verifies: Q-030, Q-051, Q-140, Q-227
  val qnt16_feeCollectionOpen = openRecs(s).forall(i => collectOk(s, s.recs.get(i).depositor, i))

  // QNT-17 verifies: Q-153, Q-169
  // Any partial repay (1 unit) is accepted unless Aave blocks it.
  val qnt17_partialRepayOpen = PROXIES.forall(p => DEBT_RES.get(spOf(p)).forall(a =>
    (isCreated(s, p) and s.debt.get((p, a)) > 0 and not(s.debtPaused.contains((spOf(p), a))) and not(s.hubHalted.contains(spOf(p))))
      implies repayOk(s, P_WALLET.get(p), p, a, 1, false)))

  // QNT-18 verifies: Q-081, Q-128, Q-182, Q-229, Q-234, Q-238
  // With the reviewed RiskModule, no borrow or debt-keeping exit while any collateral price
  // of the account is Cached or Expired or any of its debt prices is failing.
  val qnt18_noBorrowOnStale = not(s.g.borrowStale)

  // QNT-19 verifies: Q-203, Q-229
  // With the reviewed RiskModule, no borrow while any of the account's vault-token reserves
  // is frozen on Aave.
  val qnt19_noBorrowWhenFrozen = not(s.g.borrowFrozen)

  // QNT-20 verifies: Q-095, Q-161, Q-229, Q-253, Q-398
  // Rescue-excluded HF >= max(1.00, optional hard floor) after every borrow and
  // debt-keeping exit (reviewed RiskModule); drawCap, Hub liquidity and Aave HF >= 1 always.
  val qnt20_borrowFloorAndCap = not(s.g.borrowBelowFloor) and not(s.g.borrowOverCap) and not(s.g.borrowBelowAave)

  // QNT-21 verifies: Q-106, Q-229
  val qnt21_nonceUnique = PROXIES.forall(p => s.borrowCount.get(p) == s.nonce.get(p))

  // QNT-22 verifies: Q-128, Q-162, Q-199, Q-208, Q-247
  // LPVaultSwap never seizes a market whose own price is Cached, Expired or in a
  // disagreement, and never repays a debt reserve whose own price is failing.
  val qnt22_noLiquidationOnStale = not(s.g.liqStale)

  // QNT-23 verifies: Q-116, Q-222
  val qnt23_noHealthySeizure = not(s.g.liqHealthy)

  // QNT-24 verifies: Q-088, Q-154, Q-206, Q-264
  val qnt24_graceRespected = not(s.g.liqGraceBreach)

  // QNT-25 verifies: Q-132, Q-227, Q-230, Q-241, Q-242, Q-252
  // Pledges follow the matrix: a new account only in None, Live, no breaker, unfrozen
  // caller; a non-rescue top-up in Live/Drifting under None or Frozen, no breaker, unfrozen
  // caller; otherwise only a rescue top-up; Paused(MintPathSuspect) none.
  val qnt25_topUpStates = not(s.g.topUpStateBreach) and not(s.g.mintWhileSuspect)

  // QNT-26 verifies: Q-097, Q-124, Q-235, Q-251, Q-256
  // The settlement waterfall balances (R + shortfall + draw = net GHO cost + fee + payout);
  // LPVaultSwap holds no vault tokens between calls.
  val qnt26_settlementConservation = not(s.g.conservationBreach) and
    MARKETS.forall(m => s.bal.get((m, "LPVAULTSWAP")) == 0 and s.bal.get((m, "LPVAULT")) == 0 and s.bal.get((m, "COLL")) == 0)

  // QNT-27 verifies: Q-085, Q-198, Q-251
  // Every settled liquidation meets the recovery floor with the caller's shortfall top-up.
  val qnt27_recoveryFloor = not(s.g.floorBreach)

  // QNT-28 verifies: Q-117, Q-127, Q-167, Q-236, Q-267, Q-397
  // The SettlementBudget is removed: every settlement is funded by recovery plus the caller,
  // and no Avana balance pays toward it.
  val qnt28_callerFundsGap = not(s.g.avanaFunded)

  // QNT-29 verifies: Q-127, Q-167, Q-198, Q-397
  // A caller gap is charged only on a liquidation that seized collateral.
  val qnt29_gapOnlyOnSeizure = not(s.g.gapOnZeroSeize)

  // QNT-30 verifies: Q-101, Q-142, Q-236
  // Per debt asset: coverage <= funded reserve and <= recorded deficit; reserve = funded - covered.
  val qnt30_deficitCoverage = ASSETS.forall(a => and {
    s.coveredEver.get(a) <= s.reserveFundedEver.get(a), s.coveredEver.get(a) <= s.deficitEver.get(a),
    s.reserve.get(a) >= 0, s.deficit.get(a) >= 0,
    s.reserve.get(a) == s.reserveFundedEver.get(a) - s.coveredEver.get(a),
  })

  // QNT-31 verifies: Q-070, Q-095, Q-101, Q-233
  // Per debt asset: Σ debt = drawn per Spoke; liquidity + drawn + deficit = line + interest + reserve.
  val qnt31_hubAccounting = and {
    KEYS.forall(k => s.drawn.get(k) == PROXIES.filter(p => spOf(p) == k._1).fold(0, (acc, p) => acc + s.debt.get((p, k._2)))),
    ASSETS.forall(a => s.liq.get(a) >= 0),
    ASSETS.forall(a => s.liq.get(a) + KEYS.filter(k => k._2 == a).fold(0, (acc, k) => acc + s.drawn.get(k)) + s.deficit.get(a)
                        == LINE.get(a) + s.accrued.get(a) + s.reserve.get(a)),
  }

  // QNT-32 verifies: Q-227, Q-241, Q-242, Q-247
  // Replaces the bounded Guardian liquidation halt: no Avana restriction (pause state and
  // reason, any breaker, an address freeze of anyone but the caller, offboarding) changes
  // whether a liquidation succeeds, for a committed operator or any other caller.
  val qnt32_avanaHaltBounded = liqTargets(s).forall(t => {
    val c = clearRestrictions(s, Set("k1", "bob"))
    and {
      swapLiqOk(s, "k1", t._1, t._2, t._3, q0(BIG)) == swapLiqOk(c, "k1", t._1, t._2, t._3, q0(BIG)),
      swapLiqOk(s, "bob", t._1, t._2, t._3, q0(BIG)) == swapLiqOk(c, "bob", t._1, t._2, t._3, q0(BIG)),
    }
  })

  // QNT-33 verifies: Q-227, Q-241, Q-242, Q-260
  // Replaces the incident-bounded Guardian restrictions: repay, debt-free withdrawal and
  // removal, zero-credit release, fee collection, pending settlement and escrow claims never
  // read the pause state, a breaker or the address freeze.
  val qnt33_avanaRestrictionsExpire = {
    val c = clearRestrictions(s, Set())
    and {
      openRecs(s).forall(i => {
        val r = s.recs.get(i)
        and {
          not(hasDebt(s, r.proxy)) implies (withdrawOk(s, r.depositor, i) == withdrawOk(c, r.depositor, i)),
          not(hasDebt(s, r.proxy)) implies (removeOk(s, r.depositor, i, 1) == removeOk(c, r.depositor, i, 1)),
          withdrawZeroOk(s, r.depositor, i) == withdrawZeroOk(c, r.depositor, i),
          collectOk(s, r.depositor, i) == collectOk(c, r.depositor, i),
        }
      }),
      PROXIES.forall(p => DEBT_RES.get(spOf(p)).forall(a =>
        repayOk(s, P_WALLET.get(p), p, a, BIG, false) == repayOk(c, P_WALLET.get(p), p, a, BIG, false))),
      MARKETS.forall(m => settlePendingOk(s, m) == settlePendingOk(c, m)),
      WALLETS.forall(w => claimOk(s, w, w) == claimOk(c, w, w)),
    }
  }

  // QNT-34 verifies: Q-139, Q-228, Q-242, Q-400, INV-048
  // Approved keepers never fall below keeperFloor (removeKeeper counts active keepers); only a guardian
  // freeze can leave 0 active keepers, and then every market counts as liquidation-halted for new borrowing.
  val qnt34_keeperFloor = and {
    s.keepers.size() >= KEEPER_FLOOR,
    activeKeepers(s).size() == 0 implies MARKETS.forall(m => liqHaltedMkt(s, m)),
  }

  // QNT-35 verifies: Q-067, Q-104, Q-105, Q-201, Q-255
  val qnt35_nftOwnership = TOKEN_IDS.forall(t => WALLETS.union(Set("LPVAULT")).contains(s.nfts.get(t).owner))

  // QNT-36 verifies: Q-098, Q-128, Q-139, Q-189, Q-198, Q-247, INV-046
  // Liquidation liveness: an account with HF < 1 whose seized market and repaid reserve
  // have fresh prices, with a working route, no Aave pause of either reserve and no Hub
  // halt, outside grace or below the grace HF, is liquidated by an approved keeper —
  // whatever the pause state, breakers, freezes or the account's other reserves.
  val qnt36_liquidationLive = PROXIES.forall(p => {
    val acct = acctMarkets(s, p)
    val sp = spOf(p)
    acct.forall(m => acctDebts(s, p).forall(a => {
      val free = and {
        liquidatable(s, p), not(s.swapHostile), not(s.sharesNeq.contains(m)),
        mktFreshForLiq(s, m), debtFresh(s, a),
        not(s.vaultPaused.contains(m)), not(s.debtPaused.contains((sp, a))), not(s.hubHalted.contains(sp)),
        not(s.routeFailing.contains(m)), not(s.routeDisabled.contains(m)),
        a == "GHO" or (not(s.buyFailing) and not(s.buyDisabled)),
        not(inGrace(latchRead(s, acct), acct)) or adjAave(s, p) * 100 < debtVal(s, p) * DEEP_HF,
        s.supplied.get((p, m)) > 0,
      }
      free implies activeKeepers(s).exists(k => LIQ_AMTS.exists(d => swapLiqOk(s, k, p, m, a, q0(d))))
    }))
  })

  // QNT-37 verifies: Q-201, Q-257, INV-058
  // The pending-settlement balance is never negative and backs only vault tokens outside
  // the Hub's supplied balance or units burned without settlement.
  val qnt37_pendingBacksTokens = MARKETS.forall(m =>
    s.pending.get(m) >= 0 and
    s.pending.get(m) <= supplyOf(s, m) - s.bal.get((m, "HUB")) + s.hubDonated.get(m) + s.orphan.get(m))

  // QNT-38 verifies: Q-189, Q-206, Q-227, Q-229, Q-241, Q-242
  // With the reviewed Adapter and RiskModule, a borrow or debt-keeping exit happens only
  // with every gate passing: pause state, freeze, prices, no liquidation halt for any
  // reserve held, breakers, HF.
  val qnt38_policyGates = not(s.g.borrowDegraded)

  // QNT-39 verifies: Q-153, Q-180, Q-212, Q-269
  val qnt39_repayNeverOverspends = not(s.g.repayOverspend)

  // QNT-40 verifies: Q-008, Q-053, Q-213, Q-397
  // Every caller of the one entry point, registered or not, funds its own gap: no Avana balance pays.
  val qnt40_callerFundsOwnGap = not(s.g.avanaFunded)

  // QNT-41 verifies: Q-133, Q-214, Q-401 (the escrow holds refused payouts only)
  val qnt41_escrowSolvent = and {
    s.escrowBal >= HOLDERS.fold(0, (a, h) => a + s.escrowHeld.get(h)),
    HOLDERS.forall(h => s.escrowHeld.get(h) >= 0 and s.escrowCredited.get(h) == s.escrowClaimed.get(h) + s.escrowHeld.get(h)),
  }

  // QNT-42 verifies: Q-216
  // Deadline and minimum payout can only make a liquidation revert.
  val qnt42_paramsOnlyRevert = liqTargets(s).forall(t => Set("k1", "bob").forall(c =>
    Set(s.now - 1, s.now, s.now + 2).forall(dl => Set(0, 2000).forall(mp => {
      val ok = swapLiqOk(s, c, t._1, t._2, t._3, { ...q0(BIG), dl: dl, minPay: mp })
      and {
        ok implies swapLiqOk(s, c, t._1, t._2, t._3, q0(BIG)),
        s.now > dl implies not(ok),
      }
    }))))

  // QNT-43 verifies: Q-133, Q-214, Q-235, Q-401
  // In-kind settlement is removed; a payout the token refuses is credited in full to the
  // payee in the escrow, never lost and never a revert.
  val qnt43_payoutEscrowed = not(s.g.payoutLost)

  // QNT-44 verifies: Q-227, Q-252
  // Pause state: one of None / Frozen / Paused, a reason exactly while Paused; only a pause
  // guardian moves it back to None; no pledge path mints under Paused(MintPathSuspect).
  val qnt44_pauseState = and {
    Set("None", "Frozen", "Paused").contains(s.app),
    (s.app == "Paused") == (s.reason != ""),
    s.reason == "" or s.reason == "General" or s.reason == "MintPathSuspect",
    not(s.g.pauseRoleBreach), not(s.g.mintWhileSuspect),
  }

  // QNT-45 verifies: Q-241, Q-399, REQ-RISK-065
  // Breakers stop new activity only: no non-rescue pledge, borrow or debt-keeping exit
  // through a tripped breaker (reviewed RiskModule). Price drop, seizure surge and route
  // failures are alerts: they never gate a market.
  val qnt45_breakers = and {
    not(s.g.breakerBypass),
    MARKETS.forall(m => marketBreaker(s, m) == or { s.manualMkt.contains(m), s.issuerMkt.contains(m), s.poolThin.contains(m) }),
  }

  // QNT-46 verifies: Q-242
  // Address freeze: a frozen address makes none of the blocked calls; protected addresses
  // are never frozen; each freezer stays within its window limit.
  val qnt46_addressFreeze = and {
    not(s.g.frozenActed), not(s.g.freezeRateBreach),
    s.frozen.intersect(PROTECTED).size() == 0,
    FREEZERS.forall(f => s.freezeWinCount.get(f) <= FREEZE_LIMIT),
  }

  // QNT-47 verifies: Q-252, Q-253
  // Rescue top-ups only into an indebted account below the opening HF, within the restore
  // amount; rescue units never exceed credited units.
  val qnt47_rescue = not(s.g.rescueBreach) and openRecs(s).forall(i =>
    s.recs.get(i).rescue >= 0 and s.recs.get(i).rescue <= s.recs.get(i).credited)

  // QNT-48 verifies: Q-224, Q-257, INV-080
  // Every Adapter call (pledge, withdrawal, partial removal, re-credit, repay with
  // collateral) leaves the market's backing gap unchanged and never negative.
  val qnt48_backingGap = not(s.g.gapChanged) and MARKETS.forall(m => gapOf(s, m) >= 0)

  // QNT-49 verifies: Q-254
  // Partial removal leaves an open record with credited > 0, live >= credited, fees in
  // custody and (with debt) a record worth minPledgeUsd; re-credit leaves credited == live.
  val qnt49_removalRecredit = not(s.g.removalBreach) and not(s.g.recreditBreach)

  // QNT-50 verifies: Q-255
  // Repay with collateral never lowers Aave's HF while debt remains, pays no Avana fee,
  // and covers its flash loan.
  val qnt50_repayWithCollateral = not(s.g.rwcBreach)

  // QNT-51 verifies: Q-225, Q-234, Q-276, Q-278
  // A liquidation changes only the liquidated account: no other proxy's supply or debt moves.
  val qnt51_accountIsolation = not(s.g.crossAccount)

  // QNT-52 verifies: Q-228, Q-259, Q-262
  // Timelock: no call outside SHORT_ELIGIBLE executes earlier than MIN_NORMAL_DELAY after
  // scheduling, none after its grace window; the normal delay stays in its bounds; the
  // enabled short list stays inside the allowlist; admin power stays with the timelock.
  val qnt52_timelockDelays = and {
    not(s.g.tlFast), not(s.g.tlLate),
    s.normalDelay >= MIN_NORMAL, s.normalDelay <= MAX_DELAY,
    s.shortEnabled.subseteq(SHORT_ELIGIBLE), s.admins == Set("TIMELOCK"),
  }

  // QNT-53 verifies: Q-228, Q-245, Q-263
  // Restoring and role-change operations are cancelled only by the Aave DAO canceller;
  // every operation came from a proposer.
  val qnt53_restrictedCancel = s.ops.keys().forall(i => {
    val op = s.ops.get(i)
    and {
      PROPOSERS.contains(op.proposer),
      (op.status == "Cancelled" and daoOnly(op.calls)) implies op.by == DAO_CANCELLER,
    }
  })

  // QNT-54 verifies: Q-248, Q-274
  // A market is Live or Drifting only while a serving route is fresh; a standby switch never
  // bypasses freshness; the debt price is Live only with a fresh route.
  val qnt54_standby = and {
    MARKETS.forall(m => (s.pst.get(m) == Live or s.pst.get(m) == Drifting) implies servingFresh(s, m)),
    s.dpst == Live implies (not(s.dFeedsDown) or s.dStandby),
    not(s.g.standbyBreach),
  }

  // QNT-55 verifies: Q-247, Q-238, Q-278
  // Conservative valuation: Aave never values collateral above the last accepted price nor
  // a debt asset below it.
  val qnt55_conservativeValuation = and {
    MARKETS.forall(m => aavePx(s, m) <= s.price.get(m)),
    aaveDpx(s, "USDT") >= s.dpx,
  }

  // QNT-56 verifies: Q-251, Q-399, Q-401
  // Automatic in-kind is removed: a shortfall report is a monitoring alert and never changes
  // a market breaker or a liquidation halt.
  val qnt56_reportsAlertOnly = not(s.g.reportGateChange)

  // QNT-57 verifies: Q-235, Q-250, Q-251, Q-256
  // Fee = min(oracle-value share, surplus); every sell leg meets its oracle minimum, and
  // without a shortfall allowance the legs alone meet the floor; sell-back meets its floor;
  // the buy leg stays within its oracle bound; the floor shortfall stays within the caller's
  // cap and the caller pays any settlement gap (Q-397).
  val qnt57_waterfall = and {
    not(s.g.feeBreach), not(s.g.legBreach), not(s.g.sellbackBreach), not(s.g.spendBreach), not(s.g.shortfallBreach),
  }

  // QNT-58 verifies: Q-236, Q-267, Q-397
  // The budget sub-caps are removed: the caller top-up is exactly the floor shortfall plus
  // the settlement gap max(0, net cost - recovery - floor shortfall).
  val qnt58_topUpSplit = not(s.g.topUpSplitBreach)

  // Conjunctions for the combined runs in run.sh
  val honestInvariants = and {
    qnt01_oneRecordPerNft, qnt02_recordCustody, qnt03_supplyEqualsBacking, qnt04_allowedHolders,
    qnt05_liquidityCoversCredit, qnt06_hubBalanceEqualsSupplied, qnt07_perProxyLedger,
    qnt08_proxyBinding, qnt09_onlySwapSeizes, qnt10_debitMatchesSeizure, qnt11_feesToDepositor,
    qnt12_rescueOnlyUncredited, qnt13_hostileBounded, qnt14_repayAlwaysOpen,
    qnt15_debtFreeWithdrawOpen, qnt16_feeCollectionOpen, qnt17_partialRepayOpen, qnt18_noBorrowOnStale,
    qnt19_noBorrowWhenFrozen, qnt20_borrowFloorAndCap, qnt21_nonceUnique,
    qnt22_noLiquidationOnStale, qnt23_noHealthySeizure, qnt24_graceRespected, qnt25_topUpStates,
    qnt26_settlementConservation, qnt27_recoveryFloor, qnt28_callerFundsGap, qnt29_gapOnlyOnSeizure,
    qnt30_deficitCoverage, qnt31_hubAccounting, qnt32_avanaHaltBounded, qnt33_avanaRestrictionsExpire,
    qnt34_keeperFloor, qnt35_nftOwnership, qnt36_liquidationLive, qnt37_pendingBacksTokens,
    qnt38_policyGates, qnt39_repayNeverOverspends, qnt40_callerFundsOwnGap, qnt41_escrowSolvent,
    qnt42_paramsOnlyRevert, qnt43_payoutEscrowed, qnt44_pauseState, qnt45_breakers, qnt46_addressFreeze,
    qnt47_rescue, qnt48_backingGap, qnt49_removalRecredit, qnt50_repayWithCollateral,
    qnt51_accountIsolation, qnt52_timelockDelays, qnt53_restrictedCancel, qnt54_standby,
    qnt55_conservativeValuation, qnt56_reportsAlertOnly, qnt57_waterfall, qnt58_topUpSplit,
  }

  // properties that hold under a hostile RiskModule and a hostile LPVaultSwap (stepAll)
  val hostileInvariants = and {
    qnt01_oneRecordPerNft, qnt02_recordCustody, qnt03_supplyEqualsBacking, qnt04_allowedHolders,
    qnt05_liquidityCoversCredit, qnt06_hubBalanceEqualsSupplied, qnt07_perProxyLedger, qnt08_proxyBinding,
    qnt09_onlySwapSeizes, qnt10_debitMatchesSeizure, qnt11_feesToDepositor, qnt12_rescueOnlyUncredited,
    qnt13_hostileBounded, qnt14_repayAlwaysOpen, qnt15_debtFreeWithdrawOpen, qnt16_feeCollectionOpen,
    qnt17_partialRepayOpen, qnt21_nonceUnique, qnt23_noHealthySeizure, qnt28_callerFundsGap,
    qnt29_gapOnlyOnSeizure, qnt30_deficitCoverage, qnt31_hubAccounting, qnt33_avanaRestrictionsExpire,
    qnt34_keeperFloor, qnt35_nftOwnership, qnt37_pendingBacksTokens, qnt39_repayNeverOverspends,
    qnt40_callerFundsOwnGap, qnt41_escrowSolvent, qnt43_payoutEscrowed, qnt44_pauseState,
    qnt46_addressFreeze, qnt47_rescue, qnt48_backingGap, qnt49_removalRecredit, qnt50_repayWithCollateral,
    qnt51_accountIsolation, qnt52_timelockDelays, qnt53_restrictedCancel, qnt54_standby,
    qnt55_conservativeValuation, qnt56_reportsAlertOnly, qnt58_topUpSplit,
  }

  // the Adapter's blast radius (stepHostileAdapter): what holds for any Adapter implementation
  val adapterInvariants = and {
    qnt01_oneRecordPerNft, qnt05_liquidityCoversCredit, qnt09_onlySwapSeizes, qnt12_rescueOnlyUncredited,
    qnt13_hostileBounded, qnt23_noHealthySeizure, qnt28_callerFundsGap, qnt30_deficitCoverage,
    qnt34_keeperFloor, qnt35_nftOwnership, qnt41_escrowSolvent, qnt44_pauseState, qnt52_timelockDelays,
    qnt53_restrictedCancel, qnt54_standby, qnt55_conservativeValuation,
  }
}
