/*
 * PositionProxy (src/proxy/position-proxy/PositionProxy.sol, interface src/proxy/position-proxy/IPositionProxy.sol,
 * spec 2.5): a borrower's logic-free, immutable Aave V4 account for one (wallet, CDP Spoke, market).
 *
 * `execute` is the only state-changing function and answers only the AaveAdapter, including calls from the bound
 * wallet; `WALLET()`, `SPOKE()` and `MARKET_ID()` are constructor immutables and never change; the proxy makes no
 * delegatecall and calls only the target the Adapter names. Supply, borrow, repay and withdrawal amounts, approvals
 * and balance deltas are decided and checked by the Adapter (AaveAdapter.spec), not by the proxy.
 *
 * Storage assumption: the proxy keeps no storage; `ADAPTER`, `WALLET`, `SPOKE` and `MARKET_ID` are constructor
 * immutables.
 *
 * Summaries: none. `execute` makes one low-level call with Adapter-supplied calldata. Opcode hooks record every CALL
 * target and every DELEGATECALL made by the proxy, so "no arbitrary external call" is checked over the bytecode.
 */

methods {
    function ADAPTER() external returns (address) envfree;
    function WALLET() external returns (address) envfree;
    function SPOKE() external returns (address) envfree;
    function MARKET_ID() external returns (uint256) envfree;
    function execute(address, bytes) external returns (bytes);
}

// Calls made by the proxy in the current call.
persistent ghost bool delegateCalled;
persistent ghost mathint callsToOthers;
persistent ghost address allowedTarget;
persistent ghost mathint callsToTarget;
persistent ghost bool valueSent;

hook DELEGATECALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    if (executingContract == currentContract) {
        delegateCalled = true;
    }
}

hook CALL(uint g, address addr, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    if (executingContract == currentContract) {
        if (addr != allowedTarget) {
            callsToOthers = callsToOthers + 1;
        } else {
            callsToTarget = callsToTarget + 1;
        }
        if (value != 0) {
            valueSent = true;
        }
    }
}

function resetCalls(address t) {
    delegateCalled = false;
    callsToOthers = 0;
    callsToTarget = 0;
    valueSent = false;
    allowedTarget = t;
}

// PROP-056 verifies: INV-016, INV-063, Q-223, Q-225
rule everyFunctionOnlyFromAdapter(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    require e.msg.sender != ADAPTER();

    f@withrevert(e, args);

    assert lastReverted, "a proxy function ran for a caller other than the Adapter (the bound wallet included)";
}

// PROP-010 verifies: Q-064, Q-092, Q-107, Q-225
rule boundWalletSpokeAndMarketNeverChange(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    address w = WALLET();
    address s = SPOKE();
    uint256 m = MARKET_ID();

    f(e, args);

    assert WALLET() == w && SPOKE() == s && MARKET_ID() == m, "a proxy's wallet, Spoke or market changed";
}

// PROP-010 verifies: Q-064, Q-092, Q-107, Q-225
rule noDelegateCall(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    resetCalls(0);

    f(e, args);

    assert !delegateCalled, "the proxy made a delegatecall";
}

// PROP-010 verifies: Q-107, Q-225
// The proxy calls only the target the Adapter names, never itself or the Adapter, and never with ETH.
rule executeCallsOnlyTheNamedTarget(address target, bytes data) {
    env e;
    resetCalls(target);

    execute(e, target, data);

    assert !delegateCalled && callsToOthers == 0, "execute called a contract other than the named target";
    assert callsToTarget == 1, "execute returned without calling the named target exactly once";
    assert !valueSent, "execute sent ETH with its call";
    assert target != currentContract && target != 0, "execute called itself or the zero address";
    assert target != ADAPTER(), "execute called the AaveAdapter";
}

// PROP-056 verifies: INV-016, Q-223
rule adapterCanExecute(address target, bytes data) {
    env e;
    require e.msg.sender == ADAPTER();
    execute(e, target, data);
    satisfy target != 0;
}
