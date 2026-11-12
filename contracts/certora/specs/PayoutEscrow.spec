/*
 * PayoutEscrow (src/liquidation/payout-escrow/PayoutEscrow.sol, interface src/liquidation/payout-escrow/IPayoutEscrow.sol,
 * spec 2.18).
 *
 * The payout escrow, its only job (Q-401; there is no in-kind settlement). Conservation of undelivered payouts (the
 * Avana fee, borrower surpluses, route residues and dust legs in debt assets or pool tokens, and
 * `settlePending` residue, whose transfer failed, AMMN N2a): every credit comes from a deposit by LPVaultSwap while
 * LPVaultSwap holds the Lock and equals the tokens received, capped at the request; every claim is made by the
 * credited account (a borrower's wallet, `feeRecipient` or a liquidation's caller) while the Lock is free, pays exactly
 * its whole credit to the recipient it names and clears it, and reverts if the escrow's balance falls by more than
 * the credit; `totalClaimable[t]` is the sum of the credits and the escrow's balance covers it; no function pays any
 * other address and no computed zero amount moves (Q-214, Q-217). The escrow reads no pause state, breaker or freeze
 * and calls no Avana contract other than the Lock, so a claim runs in every application state and for a frozen
 * account.
 *
 * Storage assumption: `claimable[token][account]` and `totalClaimable[token]` as in the 2.18 Storage table; plain
 * storage (immutable contract); the reentrancy flag is transient and empty at the start of a rule.
 *
 * Summaries: tokens by the ERC-20 model (standard: no fee, hook, rebase or issuer burn; the fee, rounding-up, sender-fee
 * and burn cases are covered by the unit and invariant tests of TEST-173 and TEST-179); the Lock by the Lock model.
 * A donation is a direct token transfer to the escrow that only raises `erc20Bal[t][escrow]`; the invariants are proved
 * from every state that satisfies them, which includes every donated balance, so donations need no separate model.
 */

import "setup/Erc20Model.spec";
import "setup/LockModel.spec";

methods {
    function deposit(address, address, uint256) external;
    function claim(address, address) external returns (uint256);
    function claimable(address, address) external returns (uint256) envfree;
    function totalClaimable(address) external returns (uint256) envfree;
    function LP_VAULT_SWAP() external returns (address) envfree;
    function LOCK() external returns (address) envfree;

    function _.balanceOf(address a) external => erc20BalanceOf(calledContract, a) expect uint256;
    function _.transfer(address to, uint256 a) external with (env e) => escrowTransfer(calledContract, e.msg.sender, to, a) expect bool;
    function _.transferFrom(address from, address to, uint256 a) external with (env e) => escrowTransferFrom(calledContract, e.msg.sender, from, to, a) expect bool;
    function _.holder() external => lockHolderOf() expect address;
    function _.isLocked() external => lockIsLocked() expect bool;
}

// Ghost sums of credits and claims per token and borrower, written by the storage hook on `claimable`.
persistent ghost mapping(address => mapping(address => mathint)) creditedTo {
    init_state axiom forall address t. forall address b. creditedTo[t][b] == 0;
}
persistent ghost mapping(address => mapping(address => mathint)) claimedBy {
    init_state axiom forall address t. forall address b. claimedBy[t][b] == 0;
}
ghost mapping(address => mathint) sumClaimable {
    init_state axiom forall address t. sumClaimable[t] == 0;
}

// Token movements of the current call.
persistent ghost bool zeroAmountMoved;
persistent ghost bool paidOther;
persistent ghost address expectedRecipient;
persistent ghost mathint paidInCall;

hook Sstore claimable[KEY address t][KEY address b] uint256 newV (uint256 oldV) {
    sumClaimable[t] = sumClaimable[t] + newV - oldV;
    if (newV > oldV) {
        creditedTo[t][b] = creditedTo[t][b] + newV - oldV;
    } else {
        claimedBy[t][b] = claimedBy[t][b] + oldV - newV;
    }
}

hook Sload uint256 v claimable[KEY address t][KEY address b] {
    require to_mathint(v) <= sumClaimable[t];
}

function escrowTransfer(address t, address from, address to, uint256 amount) returns bool {
    if (amount == 0) {
        zeroAmountMoved = true;
    }
    if (from == currentContract && to != expectedRecipient) {
        paidOther = true;
    }
    if (from == currentContract) {
        paidInCall = paidInCall + amount;
    }
    erc20Move(t, from, to, amount);
    return true;
}

function escrowTransferFrom(address t, address spender, address from, address to, uint256 amount) returns bool {
    if (amount == 0) {
        zeroAmountMoved = true;
    }
    return erc20TransferFrom(t, spender, from, to, amount);
}

function resetEscrowCall(address recipient) {
    zeroAmountMoved = false;
    paidOther = false;
    expectedRecipient = recipient;
    paidInCall = 0;
}

// ---------------------------------------------------------------------------------------------------------------------
// Conservation (PROP-052)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-052 verifies: INV-061, Q-214
invariant totalClaimableIsSumOfCredits(address t)
    to_mathint(totalClaimable(t)) == sumClaimable[t]
    filtered { f -> !f.isView }

// PROP-052 verifies: INV-061, Q-214
invariant creditedEqualsClaimedPlusHeld(address t, address b)
    creditedTo[t][b] == claimedBy[t][b] + to_mathint(claimable(t, b))
    filtered { f -> !f.isView }

// PROP-052 verifies: INV-061, Q-214
invariant balanceCoversTotalClaimable(address t)
    erc20Bal[t][currentContract] >= to_mathint(totalClaimable(t))
    filtered { f -> !f.isView }
    {
        preserved with (env e) {
            require e.msg.sender != currentContract;
            requireInvariant totalClaimableIsSumOfCredits(t);
        }
    }

// PROP-052 verifies: INV-061, Q-214, Q-217
// PROP-037 verifies: INV-054, Q-148
rule depositOnlyFromLpVaultSwapUnderLock(address t, address b, uint256 amount) {
    env e;
    require e.msg.sender != currentContract;
    resetEscrowCall(0);
    mathint creditBefore = claimable(t, b);
    mathint balanceBefore = erc20Bal[t][currentContract];

    deposit(e, t, b, amount);

    assert e.msg.sender == LP_VAULT_SWAP() && lockHolder == LP_VAULT_SWAP(), "a deposit ran outside LPVaultSwap under the Lock";
    assert amount > 0 && b != 0 && !zeroAmountMoved, "a zero deposit or a zero borrower was accepted";
    assert to_mathint(claimable(t, b)) == creditBefore + amount, "the credit differs from the deposit";
    assert erc20Bal[t][currentContract] == balanceBefore + amount, "the credit differs from the tokens received";
    assert !paidOther, "a deposit paid tokens out";
}

// PROP-052 verifies: INV-061, Q-214, Q-217
rule claimPaysWholeCreditToNamedRecipient(address t, address recipient, address b2) {
    env e;
    address b = e.msg.sender;
    require b != currentContract;
    resetEscrowCall(recipient);
    mathint credit = claimable(t, b);
    mathint otherCredit = claimable(t, b2);
    mathint recipientBefore = erc20Bal[t][recipient];

    uint256 amount = claim(e, t, recipient);

    assert lockHolder == 0, "a claim ran while the Lock was held";
    assert recipient != 0 && recipient != currentContract, "a claim paid the zero address or the escrow";
    assert to_mathint(amount) == credit && credit > 0, "the claim did not pay the whole non-zero credit";
    assert claimable(t, b) == 0, "the claim left a credit";
    assert b2 != b => to_mathint(claimable(t, b2)) == otherCredit, "a claim changed another borrower's credit";
    assert paidInCall == credit && !paidOther && !zeroAmountMoved, "the claim paid other than the credit to the recipient";
    assert erc20Bal[t][recipient] == recipientBefore + credit, "the recipient did not receive the credit";
}

// PROP-052 verifies: INV-061, Q-214
rule onlyTheBorrowerMovesItsCredit(method f, address t, address b) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    mathint before = claimable(t, b);

    f(e, args);

    assert to_mathint(claimable(t, b)) < before => (f.selector == sig:claim(address, address).selector && e.msg.sender == b),
        "a credit fell other than by the borrower's own claim";
    assert to_mathint(claimable(t, b)) > before => (f.selector == sig:deposit(address, address, uint256).selector
        && e.msg.sender == LP_VAULT_SWAP()), "a credit rose other than by an LPVaultSwap deposit";
}

// PROP-052 verifies: INV-061, Q-214
rule claimIsReachable(address t, address recipient) {
    env e;
    uint256 amount = claim(e, t, recipient);
    satisfy amount > 0;
}

// ---------------------------------------------------------------------------------------------------------------------
// Arithmetic bounds (PROP-043; primary tool per 5.2: SMTChecker)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-043 verifies: Q-049, Q-092, Q-226
invariant creditWithinTotal(address t, address b)
    claimable(t, b) <= totalClaimable(t)
    filtered { f -> !f.isView }
    {
        preserved {
            requireInvariant totalClaimableIsSumOfCredits(t);
        }
    }
