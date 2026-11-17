/*
 * AvanaGasVault (src/periphery/gas-vault/AvanaGasVault.sol, interface src/periphery/gas-vault/IAvanaGasVault.sol,
 * spec 2.24).
 *
 * Gas for Avana's own keeper signers. A top-up is permissionless and pays only an allowlisted signer below its
 * `minBalance`, at most `min(targetBalance − balance, periodCap − sentInPeriod, vault balance)`, so it never fills a
 * signer above its target and never takes the window `(now − 24 h, now]` above `periodCap` (PROP-113). ETH leaves the
 * vault only to a listed signer through a top-up or to `TREASURY` through `withdraw` by `TIMELOCK`; `GUARDIAN` can only
 * tighten (remove, lower, pause) and never withdraw, raise, add or unpause; the only external calls the vault makes
 * carry no calldata (ETH transfers).
 *
 * Storage assumption: plain storage (immutable contract); the reentrancy flag is transient and empty at the start of a
 * rule. Native balances are the prover's `nativeBalances`.
 *
 * Bounds: `topUpAll` is checked with at most `loop_iter` (4) listed signers and `_window` over its 4 slots exactly; the
 * per-signer step of `topUpAll` is the same code as `topUp`, and the 8-signer case is covered by TEST-333 and TEST-335.
 * Calls with empty calldata (the ETH transfers to a signer and to `TREASURY`) are assumed not to change the vault's
 * state (`optimistic_fallback`): a recipient's code can re-enter only `fund`/`receive`, which add ETH, because the
 * reentrancy guard closes every other state-changing entry point; TEST-333 shows both re-entries refused.
 */

methods {
    function TREASURY() external returns (address) envfree;
    function TIMELOCK() external returns (address) envfree;
    function GUARDIAN() external returns (address) envfree;
    function MAX_SIGNERS() external returns (uint256) envfree;
    function paused() external returns (bool) envfree;
    function isSigner(address) external returns (bool) envfree;
    function signerConfig(address) external returns (IAvanaGasVault.SignerConfig) envfree;
    function sentInPeriod(address) external returns (uint256);
    function topUp(address) external returns (uint256);
    function topUpAll() external returns (uint256, uint256);
    function withdraw(uint256) external;
}

// Calls with calldata made by the vault in the current rule (any is a violation of noExternalCallButEthSend).
persistent ghost bool callWithData;
persistent ghost bool delegated;

hook CALL(uint g, address addr, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    if (executingContract == currentContract && argsLength != 0) {
        callWithData = true;
    }
}

hook DELEGATECALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    if (executingContract == currentContract) {
        delegated = true;
    }
}

function cfgMin(address s) returns uint256 {
    IAvanaGasVault.SignerConfig c = signerConfig(s);
    return c.minBalance;
}

function cfgTarget(address s) returns uint256 {
    IAvanaGasVault.SignerConfig c = signerConfig(s);
    return c.targetBalance;
}

function cfgCap(address s) returns uint256 {
    IAvanaGasVault.SignerConfig c = signerConfig(s);
    return c.periodCap;
}

// PROP-113 verifies: REQ-GASV-005, INV-111
/// @title A successful `topUp` leaves the window `(now − 24 h, now]` at or below the signer's `periodCap`, and adds
/// exactly what it sent to it.
rule periodCapNeverExceeded(env e, address s) {
    require s != currentContract;
    mathint before = sentInPeriod(e, s);
    uint256 sent = topUp(e, s);
    mathint after = sentInPeriod(e, s);
    assert after == before + sent, "window grows by the send";
    assert after <= to_mathint(cfgCap(s)), "window above periodCap";
}

// PROP-113 verifies: REQ-GASV-005, REQ-GASV-006, INV-111
/// @title `topUpAll` never takes any signer's window above its `periodCap` when it was within it before.
rule periodCapNeverExceededByTopUpAll(env e, address s) {
    require s != currentContract;
    require to_mathint(sentInPeriod(e, s)) <= to_mathint(cfgCap(s));
    topUpAll(e);
    assert to_mathint(sentInPeriod(e, s)) <= to_mathint(cfgCap(s)), "window above periodCap";
}

// PROP-113 verifies: REQ-GASV-004
/// @title A successful `topUp` was due, pays a listed signer, never fills it above its target, and sends exactly
/// `min(target − balance, cap room, vault balance)` at most.
rule topUpNeverAboveTarget(env e, address s) {
    require s != currentContract && e.msg.value == 0;
    mathint balBefore = nativeBalances[s];
    mathint vaultBefore = nativeBalances[currentContract];
    mathint window = sentInPeriod(e, s);
    bool listed = isSigner(s);
    bool wasPaused = paused();
    uint256 minB = cfgMin(s);
    uint256 target = cfgTarget(s);
    uint256 cap = cfgCap(s);
    uint256 sent = topUp(e, s);
    assert listed && !wasPaused, "topUp of an unlisted signer or while paused";
    assert balBefore < to_mathint(minB), "topUp of a signer not below its minimum";
    assert sent > 0, "topUp sent nothing";
    assert nativeBalances[s] == balBefore + sent, "signer not paid the amount";
    assert nativeBalances[s] <= to_mathint(target), "signer above its target";
    assert to_mathint(sent) <= vaultBefore, "sent above the vault balance";
    assert window + sent <= to_mathint(cap), "sent above the cap room";
}

// PROP-113 verifies: REQ-GASV-004, REQ-GASV-006, REQ-GASV-010, REQ-GASV-012
/// @title No call raises the native balance of any address other than the vault, except a then-listed signer or, through
/// `withdraw` by `TIMELOCK`, `TREASURY`.
rule onlyAllowlistedReceive(env e, method f, address a) filtered { f -> !f.isView } {
    // A call with value only moves ETH from the caller into the vault; the rule is about ETH leaving it.
    require a != currentContract && e.msg.value == 0;
    bool listed = isSigner(a);
    mathint before = nativeBalances[a];
    calldataarg args;
    f(e, args);
    assert nativeBalances[a] > before => (listed && a != TREASURY())
        || (a == TREASURY() && f.selector == sig:withdraw(uint256).selector && e.msg.sender == TIMELOCK()),
        "ETH reached an address that is neither a listed signer nor the treasury";
}

// PROP-113 verifies: REQ-GASV-009, REQ-GASV-010, REQ-GASV-011
/// @title A call by `GUARDIAN` (not also `TIMELOCK`) never raises a signer's values, lists a signer, unpauses or moves
/// ETH out of the vault other than a permissionless top-up.
rule guardianOnlyTightens(env e, method f, address s) filtered { f -> !f.isView } {
    require e.msg.sender == GUARDIAN() && GUARDIAN() != TIMELOCK();
    require f.selector != sig:topUp(address).selector && f.selector != sig:topUpAll().selector;
    bool listedBefore = isSigner(s);
    bool pausedBefore = paused();
    uint256 minB = cfgMin(s);
    uint256 target = cfgTarget(s);
    uint256 cap = cfgCap(s);
    mathint held = nativeBalances[currentContract];
    calldataarg args;
    f(e, args);
    assert isSigner(s) => listedBefore, "guardian listed a signer";
    assert cfgMin(s) <= minB && cfgTarget(s) <= target && cfgCap(s) <= cap, "guardian raised a value";
    assert pausedBefore => paused(), "guardian unpaused";
    assert nativeBalances[currentContract] >= held, "guardian moved ETH out";
}

// PROP-113 verifies: REQ-GASV-012
/// @title `withdraw(amount)` succeeds only from `TIMELOCK` and moves exactly `amount` from the vault to `TREASURY`.
rule withdrawOnlyToTreasury(env e, uint256 amount) {
    address t = TREASURY();
    require t != currentContract;
    mathint tBefore = nativeBalances[t];
    mathint vBefore = nativeBalances[currentContract];
    withdraw(e, amount);
    assert e.msg.sender == TIMELOCK(), "withdraw by another caller";
    assert nativeBalances[t] == tBefore + amount, "treasury not paid the amount";
    assert nativeBalances[currentContract] == vBefore - amount, "vault not debited the amount";
}

// PROP-113 verifies: REQ-GASV-001
/// @title The vault makes no call with calldata and no delegatecall: its only external effect is an ETH transfer.
rule noExternalCallButEthSend(env e, method f) {
    require !callWithData && !delegated;
    calldataarg args;
    f(e, args);
    assert !callWithData, "external call with calldata";
    assert !delegated, "delegatecall";
}

// PROP-113 verifies: REQ-GASV-004
/// @title Liveness witness: a listed, due signer of an unpaused, funded vault with cap room can be topped up.
rule topUpIsReachable(env e, address s) {
    require s != currentContract;
    uint256 sent = topUp(e, s);
    satisfy sent > 0;
}
