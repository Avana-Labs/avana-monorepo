/*
 * Ghost model of the MarketRegistry state that other Avana contracts read (2.8): the application pause state and
 * reason, the address-freeze list, the market and debt breakers and the approved debt-reserve set. Every read is counted per kind, so a call-graph rule (PROP-032, PROP-057, PROP-066) can assert that an entry
 * point made no read of a kind, which is how "its success does not depend on it" is checked: a function that never
 * reads a value behaves the same for every value of it.
 *
 * The state is arbitrary ghost state, havocked between calls; the MarketRegistry's own transition rules are proved on
 * the real MarketRegistry in MarketRegistry.spec (PROP-041, PROP-061, PROP-071).
 *
 * PauseState and PauseReason are file-level Solidity types (src/types/), which CVL names through any contract of the
 * scene; they are qualified by AccessControlUpgradeable, the one contract in both scenes that import this model
 * (LPVaultSwap.conf and RiskModule.conf).
 */

persistent ghost AccessControlUpgradeable.PauseState regPauseState;
persistent ghost AccessControlUpgradeable.PauseReason regPauseReason;
persistent ghost mapping(address => bool) regFrozen;
persistent ghost mapping(uint256 => uint32) regMarketBreakerReasons;
persistent ghost mapping(address => mapping(uint256 => uint32)) regDebtBreakerReasons;
ghost regApprovedDebtReserve(address, uint256) returns bool;
ghost regActiveMarketCount(address) returns uint256;

// Read counters of the current call.
persistent ghost mathint regPauseStateReads { init_state axiom regPauseStateReads == 0; }
persistent ghost mathint regPauseReasonReads { init_state axiom regPauseReasonReads == 0; }
persistent ghost mathint regBreakerReads { init_state axiom regBreakerReads == 0; }
persistent ghost mapping(address => mathint) regFreezeReadsOf {
    init_state axiom forall address a. regFreezeReadsOf[a] == 0;
}
persistent ghost mathint regFreezeReads { init_state axiom regFreezeReads == 0; }
persistent ghost mathint regAnyReads { init_state axiom regAnyReads == 0; }
persistent ghost mathint regBreakerWrites { init_state axiom regBreakerWrites == 0; }

function resetRegistryReads() {
    regPauseStateReads = 0;
    regPauseReasonReads = 0;
    regBreakerReads = 0;
    regFreezeReads = 0;
    regAnyReads = 0;
    regBreakerWrites = 0;
    require forall address a. regFreezeReadsOf[a] == 0;
}

function registryPauseState() returns AccessControlUpgradeable.PauseState {
    regPauseStateReads = regPauseStateReads + 1;
    regAnyReads = regAnyReads + 1;
    // pauseReason() == None exactly when the state is not Paused (PROP-041).
    require (regPauseState == AccessControlUpgradeable.PauseState.Paused) == (regPauseReason != AccessControlUpgradeable.PauseReason.None);
    return regPauseState;
}

function registryPauseReason() returns AccessControlUpgradeable.PauseReason {
    regPauseReasonReads = regPauseReasonReads + 1;
    regAnyReads = regAnyReads + 1;
    require (regPauseState == AccessControlUpgradeable.PauseState.Paused) == (regPauseReason != AccessControlUpgradeable.PauseReason.None);
    return regPauseReason;
}

function registryIsFrozenAddress(address a) returns bool {
    regFreezeReads = regFreezeReads + 1;
    regFreezeReadsOf[a] = regFreezeReadsOf[a] + 1;
    regAnyReads = regAnyReads + 1;
    return regFrozen[a];
}

function registryMarketBreaker(uint256 m) returns (uint32, uint64) {
    regBreakerReads = regBreakerReads + 1;
    regAnyReads = regAnyReads + 1;
    uint64 lastBreach;
    return (regMarketBreakerReasons[m], lastBreach);
}

function registryDebtBreaker(address spoke, uint256 r) returns (uint32, uint64) {
    regBreakerReads = regBreakerReads + 1;
    regAnyReads = regAnyReads + 1;
    uint64 lastBreach;
    return (regDebtBreakerReasons[spoke][r], lastBreach);
}

function registryApprovedDebtReserve(address spoke, uint256 r) returns bool {
    regAnyReads = regAnyReads + 1;
    return regApprovedDebtReserve(spoke, r);
}

function registryActiveMarketCount(address spoke) returns uint256 {
    regAnyReads = regAnyReads + 1;
    require regActiveMarketCount(spoke) >= 1;
    return regActiveMarketCount(spoke);
}

function registryBreakerWrite() {
    regBreakerWrites = regBreakerWrites + 1;
}
