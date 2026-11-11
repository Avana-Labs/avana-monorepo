/*
 * Lock (src/lock/lock/Lock.sol, interface src/lock/lock/ILock.sol, spec 2.16).
 *
 * The two-member lock of the chain: only the AaveAdapter or LPVaultSwap acquires it, only while it is free (no
 * nesting, not even by the holder), and only the holder releases it. Every LPVault and Collateralization entry point
 * that moves value checks that its caller is one of the two and holds the Lock, so a new CDP Spoke, market or LPVault
 * never needs a Lock redeploy. The per-contract halves of PROP-037 (each inner entry point checks its named caller and
 * holder) are in Collateralization.spec, LPVault.spec, AaveAdapter.spec, PayoutEscrow.spec and
 * SettlementRoute.spec.
 *
 * Storage: the holder lives in the transient HOLDER_SLOT; the rules read it through `holder()` and `isLocked()`.
 * The prover keeps transient storage across the calls of one rule, as within one transaction. Nothing is summarised:
 * the Lock makes no external call.
 */

methods {
    function holder() external returns (address) envfree;
    function isLocked() external returns (bool) envfree;
    function AAVE_ADAPTER() external returns (address) envfree;
    function LP_VAULT_SWAP() external returns (address) envfree;
    function SELF() external returns (address) envfree;
    function acquire() external;
    function release() external;
}

definition isMember(address a) returns bool =
    a == AAVE_ADAPTER() || a == LP_VAULT_SWAP();

// PROP-037 verifies: INV-054, Q-148, Q-223
rule acquireOnlyByMembersWhileFree() {
    env e;
    // The constructor refuses a zero member, so a zero caller is never a member (lockMembersDistinctAndSet).
    requireInvariant lockMembersDistinctAndSet();
    address before = holder();

    acquire(e);

    address caller = e.msg.sender;
    assert before == 0, "the lock was acquired while held";
    assert holder() == caller && isLocked(), "the lock does not record its acquirer";
    assert isMember(caller), "the lock was acquired by an address outside the fixed set";
}

// PROP-037 verifies: INV-054, Q-148, Q-223
rule releaseOnlyByHolder() {
    env e;
    address before = holder();

    release(e);

    assert before == e.msg.sender && before != 0, "the lock was released by an address other than its holder";
    assert holder() == 0 && !isLocked(), "release left the lock held";
}

// PROP-037 verifies: INV-054, Q-148, Q-223
rule holderChangesOnlyThroughAcquireAndRelease(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    address before = holder();

    f(e, args);

    assert holder() != before => (
        f.selector == sig:acquire().selector || f.selector == sig:release().selector), "the holder changed outside acquire and release";
}

// PROP-037 verifies: INV-054, Q-148, Q-223
rule secondAcquireFails() {
    env e1;
    env e2;
    requireInvariant lockMembersDistinctAndSet();
    acquire(e1);
    acquire@withrevert(e2);
    assert lastReverted, "a held lock was acquired again";
}

// PROP-043 verifies: Q-049, Q-226
rule isLockedMatchesHolder() {
    assert isLocked() == (holder() != 0), "isLocked disagrees with the holder slot";
}

// PROP-037 verifies: INV-054, Q-148, Q-223
// Each member, not just one of them, takes a free lock without reverting, and the holder reads back in the same rule
// (which also checks that transient storage persists across the calls of one rule, as Lock.spec assumes).
rule memberAcquiresFreeLockWithoutRevert(bool bySwap) {
    env e;
    require e.msg.value == 0;
    require e.msg.sender == (bySwap ? LP_VAULT_SWAP() : AAVE_ADAPTER());
    require holder() == 0 && SELF() == currentContract;

    acquire@withrevert(e);

    assert !lastReverted, "a member could not take a free lock";
    assert holder() == e.msg.sender, "the holder did not read back after acquire";
}

// PROP-037 verifies: INV-054, INV-091
// The holder is always free or one of the two members.
invariant holderIsFreeOrMember()
    holder() == 0 || isMember(holder());

// PROP-037 verifies: INV-054, Q-148, Q-223
// A member can always take a free lock.
rule memberAcquiresAFreeLock() {
    env e;
    require holder() == 0 && isMember(e.msg.sender) && SELF() == currentContract;
    acquire(e);
    satisfy holder() == e.msg.sender;
}

// The Lock has exactly two members, fixed at construction: AaveAdapter and LPVaultSwap. Any other caller, including an
// LPVault, Collateralization, the IFlashSource implementation or a vault token, is refused.
// PROP-075 verifies: INV-091, INV-054
rule acquireRefusedOutsideTheTwoMembers() {
    env e;
    require e.msg.value == 0;
    address adapter = AAVE_ADAPTER();
    address swap = LP_VAULT_SWAP();

    acquire@withrevert(e);

    assert e.msg.sender != adapter && e.msg.sender != swap => lastReverted,
        "an address other than the AaveAdapter or LPVaultSwap acquired the lock";
}

// PROP-075 verifies: INV-091, INV-054
invariant lockMembersDistinctAndSet()
    AAVE_ADAPTER() != 0 && LP_VAULT_SWAP() != 0 && AAVE_ADAPTER() != LP_VAULT_SWAP();
