/*
 * VaultToken (src/vault-token/VaultToken.sol, interface src/vault-token/IVaultToken.sol, lifecycle
 * src/vault-token/LIFECYCLE.md).
 *
 * One band market's collateral ERC-20: one base unit is one unit of credit. Mint, burn and proxy registration are
 * `restricted` by the AccessManager, which grants them to the AaveAdapter role (pledge and withdrawal) and the
 * LiquidationModule role (seized tokens). The rules:
 *
 *   onlyAuthorizedCallerMints, onlyAuthorizedCallerBurns   a mint or burn succeeds only for a caller the AccessManager
 *                                                          lets call that selector on this token (now, or through a
 *                                                          scheduled operation)
 *   totalSupplyIsSumOfBalances                             the supply is the sum of all balances
 *   supplyChangesOnlyByMintOrBurn                          no other function moves the supply
 *   mintRaisesSupplyByAmount, burnLowersSupplyByAmount     a mint adds exactly its amount (to a registered proxy), a
 *                                                          burn removes exactly its amount
 *   transfersFollowThePathRule                             a transfer moves a non-zero amount on an allowed path
 *
 * Together: the supply equals the credit the authorized roles minted at pledges minus what they burned at withdrawals
 * and liquidations, and no transfer creates or destroys units.
 *
 * Summaries: the AccessManager is OpenZeppelin's v5.1.0 code (`authority()` is required to be it); its
 * `consumeScheduledOp` is NONDET, so a caller with a positive delay passes the check (the rules allow it: the
 * delay is the AccessManager's, enforced by its own scheduling).
 *
 * Storage assumption: OpenZeppelin v5.1.0 `ERC20` storage `_balances` and `_totalSupply`; plain storage.
 */

using AccessManager as manager;

methods {
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function isValidProxy(address) external returns (bool) envfree;
    function isAllowedTransfer(address, address) external returns (bool) envfree;
    function mint(address, uint256) external;
    function burn(address, uint256) external;
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);

    function manager.canCall(address, address, bytes4) external returns (bool, uint32);
    function _.consumeScheduledOp(address, bytes) external => NONDET;
}

ghost mathint sumBalances {
    init_state axiom sumBalances == 0;
}

hook Sstore _balances[KEY address a] uint256 newBalance (uint256 oldBalance) {
    sumBalances = sumBalances + newBalance - oldBalance;
}

hook Sload uint256 balance _balances[KEY address a] {
    require sumBalances >= to_mathint(balance);
}

definition isMint(method f) returns bool = f.selector == sig:mint(address, uint256).selector;
definition isBurn(method f) returns bool = f.selector == sig:burn(address, uint256).selector;

// ---------------------------------------------------------------------------------------------------------------------
// Only the authorized roles mint and burn
// ---------------------------------------------------------------------------------------------------------------------

rule onlyAuthorizedCallerMints(address to, uint256 amount) {
    env e;
    require authority(e) == manager;
    bool immediate;
    uint32 delay;
    immediate, delay = manager.canCall(e, e.msg.sender, currentContract, to_bytes4(sig:mint(address, uint256).selector));

    mint@withrevert(e, to, amount);

    assert !lastReverted => (immediate || delay > 0), "a caller the AccessManager does not authorize minted";
}

rule onlyAuthorizedCallerBurns(address from, uint256 amount) {
    env e;
    require authority(e) == manager;
    bool immediate;
    uint32 delay;
    immediate, delay = manager.canCall(e, e.msg.sender, currentContract, to_bytes4(sig:burn(address, uint256).selector));

    burn@withrevert(e, from, amount);

    assert !lastReverted => (immediate || delay > 0), "a caller the AccessManager does not authorize burned";
}

// ---------------------------------------------------------------------------------------------------------------------
// Supply
// ---------------------------------------------------------------------------------------------------------------------

invariant totalSupplyIsSumOfBalances()
    to_mathint(totalSupply()) == sumBalances
    filtered { f -> f.contract == currentContract }

rule supplyChangesOnlyByMintOrBurn(method f) filtered { f -> f.contract == currentContract && !f.isView } {
    env e;
    calldataarg args;
    requireInvariant totalSupplyIsSumOfBalances();
    mathint before = totalSupply();

    f(e, args);

    assert to_mathint(totalSupply()) != before => (isMint(f) || isBurn(f)), "the supply moved outside a mint or burn";
}

rule mintRaisesSupplyByAmount(address to, uint256 amount) {
    env e;
    requireInvariant totalSupplyIsSumOfBalances();
    mathint supplyBefore = totalSupply();
    mathint balanceBefore = balanceOf(to);

    mint(e, to, amount);

    assert isValidProxy(to), "minted to an address that is not a registered proxy";
    assert to_mathint(totalSupply()) == supplyBefore + amount, "a mint did not raise the supply by its amount";
    assert to_mathint(balanceOf(to)) == balanceBefore + amount, "a mint did not credit its amount to the proxy";
}

rule burnLowersSupplyByAmount(address from, uint256 amount) {
    env e;
    requireInvariant totalSupplyIsSumOfBalances();
    mathint supplyBefore = totalSupply();
    mathint balanceBefore = balanceOf(from);

    burn(e, from, amount);

    assert to_mathint(totalSupply()) == supplyBefore - amount, "a burn did not lower the supply by its amount";
    assert to_mathint(balanceOf(from)) == balanceBefore - amount, "a burn did not debit its amount";
}

// ---------------------------------------------------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------------------------------------------------

// `viaTransferFrom` picks transferFrom(from, to, amount), else transfer(to, amount) from the caller.
rule transfersFollowThePathRule(bool viaTransferFrom, address from, address to, uint256 amount) {
    env e;
    bool allowed = isAllowedTransfer(from, to);
    if (viaTransferFrom) {
        transferFrom(e, from, to, amount);
    } else {
        require from == e.msg.sender;
        transfer(e, to, amount);
    }
    assert amount > 0 && allowed, "units moved off the proxy-Hub-LiquidationModule paths, or a zero amount moved";
}
