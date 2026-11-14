/*
 * Ghost model of the price state of each LPOracle (2.10) and each DebtOracle, as read by the RiskModule, the
 * AaveAdapter and LPVaultSwap through `poke()`, `getPriceState()`, `getTokenPrices()` and `latestAnswer()`.
 *
 * Each oracle address has fixed ghost state for the duration of a rule: Cached, Expired, the disagreement pause and
 * its expiry, the grace window, the served source timestamp and the accepted price. `getPriceState()` returns an
 * otherwise arbitrary report whose fields agree with that state, including the oracles' own rule
 * `liquidationPaused = Cached or Expired or disagreementPauseActive or disagreementExpired` (SPEC-ORC-016, Q-208) and
 * the served price of SPEC-ORC-017 and SPEC-ORC-018: an LPOracle that is not Live serves at most its accepted price
 * and at least 1 (exactly 1 when Expired); a DebtOracle that is not Live serves at least its accepted price.
 * `poke()` counts the call and returns the same state. The oracles' own storage rules (when the disagreement start is
 * set and cleared, what each state serves) are proved on the real contracts in LPOracle.spec and DebtOracle.spec
 * (PROP-027, PROP-049, PROP-074).
 *
 * PriceState, PriceStateView and DebtPriceView are file-level Solidity types, which CVL names through any contract of
 * the scene; they are qualified by AccessControlUpgradeable, the one contract in both scenes that import this model
 * (LPVaultSwap.conf and RiskModule.conf).
 */

persistent ghost mapping(address => bool) pvCached;
persistent ghost mapping(address => bool) pvExpired;
persistent ghost mapping(address => bool) pvDrifting;
persistent ghost mapping(address => bool) pvDisagreementPause;
persistent ghost mapping(address => bool) pvDisagreementExpired;
persistent ghost mapping(address => bool) pvInGrace;
persistent ghost mapping(address => uint64) pvServedUpdatedAt;
persistent ghost mapping(address => uint64) pvRecoveredAt;
persistent ghost mapping(address => uint64) pvDisagreeSince;
persistent ghost mapping(address => uint32) pvBorrowMaxAge;
persistent ghost mapping(address => uint32) pvLiquidationMaxAge;
persistent ghost mapping(address => mathint) pvAccepted;
persistent ghost mapping(address => mathint) pvServed;

persistent ghost mapping(address => mathint) pokeCount {
    init_state axiom forall address o. pokeCount[o] == 0;
}
persistent ghost mathint totalPokes {
    init_state axiom totalPokes == 0;
}

function pvLiquidationPaused(address o) returns bool {
    return pvCached[o] || pvExpired[o] || pvDisagreementPause[o] || pvDisagreementExpired[o];
}

// Live means none of Drifting, Cached, Expired and no disagreement.
function pvIsLive(address o) returns bool {
    return !pvCached[o] && !pvExpired[o] && !pvDrifting[o] && !pvDisagreementPause[o] && !pvDisagreementExpired[o];
}

function priceStateOf(address o) returns AccessControlUpgradeable.PriceState {
    AccessControlUpgradeable.PriceState s;
    require pvExpired[o] => s == AccessControlUpgradeable.PriceState.Expired;
    require (pvCached[o] && !pvExpired[o]) => s == AccessControlUpgradeable.PriceState.Cached;
    require (!pvCached[o] && !pvExpired[o] && pvDrifting[o]) => s == AccessControlUpgradeable.PriceState.Drifting;
    require (!pvCached[o] && !pvExpired[o] && !pvDrifting[o]) => s == AccessControlUpgradeable.PriceState.Live;
    return s;
}

// LPOracle served price (SPEC-ORC-017): the accepted price when Live, at most the accepted price and at least 1
// otherwise, exactly 1 when Expired.
function lpServedAnswer(address o) returns int256 {
    require pvAccepted[o] >= 1 && pvAccepted[o] <= max_int256;
    require pvServed[o] >= 1 && pvServed[o] <= max_int256;
    require !pvIsLive(o) => pvServed[o] <= pvAccepted[o];
    require pvExpired[o] => pvServed[o] == 1;
    return require_int256(pvServed[o]);
}

// DebtOracle served price (SPEC-ORC-018): at least the accepted price whenever not Live.
function debtServedAnswer(address o) returns int256 {
    require pvAccepted[o] >= 1 && pvAccepted[o] <= max_int256;
    require pvServed[o] >= 1 && pvServed[o] <= max_int256;
    require !pvIsLive(o) => pvServed[o] >= pvAccepted[o];
    return require_int256(pvServed[o]);
}

function priceStateViewOf(address o) returns AccessControlUpgradeable.PriceStateView {
    AccessControlUpgradeable.PriceStateView v;
    require v.state == priceStateOf(o);
    require v.answer == lpServedAnswer(o);
    require to_mathint(v.acceptedAnswer) == pvAccepted[o];
    require v.servedUpdatedAt == pvServedUpdatedAt[o];
    require v.disagreeSince == pvDisagreeSince[o];
    require v.disagreementPauseActive == pvDisagreementPause[o];
    require v.disagreementExpired == pvDisagreementExpired[o];
    require v.liquidationPaused == pvLiquidationPaused(o);
    require v.recoveredAt == pvRecoveredAt[o];
    require v.inGrace == pvInGrace[o];
    require v.borrowPriceMaxAge == pvBorrowMaxAge[o];
    require v.liquidationPriceMaxAge == pvLiquidationMaxAge[o];
    return v;
}

function debtPriceViewOf(address o) returns AccessControlUpgradeable.DebtPriceView {
    AccessControlUpgradeable.DebtPriceView v;
    require v.state == priceStateOf(o);
    require v.answer == debtServedAnswer(o);
    require to_mathint(v.acceptedAnswer) == pvAccepted[o];
    require v.servedUpdatedAt == pvServedUpdatedAt[o];
    require v.disagreeSince == pvDisagreeSince[o];
    require v.disagreementPauseActive == pvDisagreementPause[o];
    require v.disagreementExpired == pvDisagreementExpired[o];
    require v.liquidationPaused == pvLiquidationPaused(o);
    require v.recoveredAt == pvRecoveredAt[o];
    require v.inGrace == pvInGrace[o];
    require v.borrowPriceMaxAge == pvBorrowMaxAge[o];
    require v.liquidationPriceMaxAge == pvLiquidationMaxAge[o];
    return v;
}

function oraclePoke(address o) returns AccessControlUpgradeable.PriceState {
    pokeCount[o] = pokeCount[o] + 1;
    totalPokes = totalPokes + 1;
    return priceStateOf(o);
}

function oracleTokenPrices(address o) returns (uint256, uint256, uint64, AccessControlUpgradeable.PriceState) {
    uint256 v0;
    uint256 v1;
    require v0 >= 1 && v1 >= 1;
    return (v0, v1, pvServedUpdatedAt[o], priceStateOf(o));
}

function oracleLastAccepted(address o) returns (uint256, uint64) {
    require pvAccepted[o] >= 1 && pvAccepted[o] <= max_uint256;
    uint64 acceptedAt;
    return (require_uint256(pvAccepted[o]), acceptedAt);
}

// Which oracle addresses are DebtOracles (fixed per address); `latestAnswer()` serves per the oracle's kind.
ghost isDebtOracle(address) returns bool;

function oracleLatestAnswer(address o) returns int256 {
    if (isDebtOracle(o)) {
        return debtServedAnswer(o);
    }
    return lpServedAnswer(o);
}
