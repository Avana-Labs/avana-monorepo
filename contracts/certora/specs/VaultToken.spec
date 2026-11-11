/*
 * VaultToken (src/vault-token/vault-token/VaultToken.sol, interface src/vault-token/vault-token/IVaultToken.sol,
 * spec 2.4).
 *
 * Supply authority (only `adapter()` mints and burns), the path rule of every transfer, mint and burn
 * (`isAllowedTransfer`, `REQ-VTOKEN-006`), the append-only proxy registry that never holds a binding, the fixed
 * bindings, and the ERC-20 balance sum. The token is immutable and holds its own registry,
 * so every rule here holds for any AaveAdapter implementation: nothing in this spec is summarised.
 *
 * Storage assumption: OpenZeppelin v5.1.0 `ERC20` storage names `_balances`, `_allowances`, `_totalSupply` and the
 * registry `isValidProxy` of the 2.4 Storage table; plain storage.
 */

methods {
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function allowance(address, address) external returns (uint256) envfree;
    function isAllowedRecipient(address) external returns (bool) envfree;
    function isAllowedTransfer(address, address) external returns (bool) envfree;
    function isValidProxy(address) external returns (bool) envfree;
    function adapter() external returns (address) envfree;
    function hub() external returns (address) envfree;
    function spoke() external returns (address) envfree;
    function marketKey() external returns (bytes32) envfree;
    function integrationId() external returns (uint32) envfree;
    function integration() external returns (address) envfree;
    function lpVaultSwap() external returns (address) envfree;
    function collateralization() external returns (address) envfree;
    function lpOracle() external returns (address) envfree;
    function marketId() external returns (uint256) envfree;
    function decimals() external returns (uint8) envfree;
    function mint(address, uint256) external;
    function burn(address, uint256) external;
    function addValidProxy(address) external;
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
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

// Registry writes of the current call.
persistent ghost mathint registryAdds {
    init_state axiom registryAdds == 0;
}
persistent ghost bool registryRemoved {
    init_state axiom !registryRemoved;
}

hook Sstore isValidProxy[KEY address p] bool newV (bool oldV) {
    if (newV && !oldV) {
        registryAdds = registryAdds + 1;
    }
    if (oldV && !newV) {
        registryRemoved = true;
    }
}

definition isMint(method f) returns bool = f.selector == sig:mint(address, uint256).selector;
definition isBurn(method f) returns bool = f.selector == sig:burn(address, uint256).selector;

definition allowedRecipient(address a) returns bool =
    a == hub() || a == lpVaultSwap() || isValidProxy(a);

// REQ-VTOKEN-040: supply (proxy to Hub), withdrawal (Hub to proxy), seizure (Hub to LPVaultSwap).
definition allowedPath(address from, address to) returns bool =
    (to == hub() && isValidProxy(from)) || (from == hub() && (isValidProxy(to) || to == lpVaultSwap()));

definition isBinding(address a) returns bool =
    a == hub() || a == spoke() || a == adapter() || a == lpVaultSwap() || a == collateralization()
        || a == integration() || a == lpOracle() || a == currentContract;

// ---------------------------------------------------------------------------------------------------------------------
// Supply authority (PROP-005, PROP-055)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-005 verifies: INV-009, INV-010, Q-069, Q-120, Q-165, Q-224
// PROP-055 verifies: INV-009, INV-010, Q-224, Q-226
rule supplyChangesOnlyThroughAdapter(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    // OpenZeppelin's burn lowers _totalSupply unchecked; the supply covers every balance in every reachable state.
    requireInvariant totalSupplyIsSumOfBalances();
    mathint supplyBefore = totalSupply();

    f(e, args);

    mathint supplyAfter = totalSupply();
    assert supplyAfter > supplyBefore => (isMint(f) && e.msg.sender == adapter()),
        "supply rose outside an Adapter mint";
    assert supplyAfter < supplyBefore => (isBurn(f) && e.msg.sender == adapter()),
        "supply fell outside an Adapter burn";
}

// PROP-005 verifies: INV-009, INV-010, Q-069, Q-120, Q-165, Q-224
// PROP-055 verifies: INV-009, INV-010, INV-012, Q-224, Q-226
rule adapterOnlyFunctionsRefuseOtherCallers(method f) filtered {
    f -> isMint(f) || isBurn(f) || f.selector == sig:addValidProxy(address).selector
} {
    env e;
    calldataarg args;
    require e.msg.sender != adapter();

    f@withrevert(e, args);

    assert lastReverted, "mint, burn or addValidProxy succeeded for a caller other than adapter()";
}

// PROP-055 verifies: INV-010, REQ-VTOKEN-014, REQ-VTOKEN-042, Q-224, Q-226
rule burnNeedsNoAllowanceAndLowersExactly(address from, address other, address spender, uint256 amount) {
    env e;
    requireInvariant totalSupplyIsSumOfBalances();
    require other != from;
    mathint balanceBefore = balanceOf(from);
    mathint otherBefore = balanceOf(other);
    mathint supplyBefore = totalSupply();
    mathint allowanceBefore = allowance(from, spender);

    burn(e, from, amount);

    assert isValidProxy(from) || from == lpVaultSwap(), "burned from an address that is not a proxy or LPVaultSwap";
    assert to_mathint(balanceOf(from)) == balanceBefore - amount, "burn did not lower balanceOf(from) by amount";
    assert to_mathint(totalSupply()) == supplyBefore - amount, "burn did not lower the supply by amount";
    assert to_mathint(balanceOf(other)) == otherBefore, "burn changed another holder's balance";
    assert to_mathint(allowance(from, spender)) == allowanceBefore, "burn read or spent an allowance";
}

// PROP-055 verifies: INV-010, Q-224, Q-226
// A burn from a holder that gave the Adapter no allowance succeeds.
rule burnWithoutAllowanceIsReachable(address from, uint256 amount) {
    env e;
    require e.msg.sender == adapter();
    require from == lpVaultSwap();
    require allowance(from, adapter()) == 0;
    burn(e, from, amount);
    satisfy amount > 0;
}

// PROP-005 verifies: INV-009, Q-069, Q-224
rule adapterCanMint(address to, uint256 amount) {
    env e;
    require e.msg.sender == adapter();
    require isValidProxy(to);
    mint(e, to, amount);
    satisfy amount > 0;
}

// ---------------------------------------------------------------------------------------------------------------------
// Path rule and holder set (PROP-008, PROP-055)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-008 verifies: INV-011, Q-068, Q-120, Q-224
// PROP-055 verifies: INV-011, Q-224
rule transferNeedsAllowedRecipientOnly(address to, uint256 amount) {
    env e;

    transfer(e, to, amount);

    assert allowedRecipient(to), "transfer to an address outside {hub, lpVaultSwap} and the registry";
}

// PROP-055 verifies: INV-011, REQ-VTOKEN-008, REQ-VTOKEN-041, REQ-VTOKEN-048, Q-224, Q-300
rule transferOnlyOnAllowedPath(address to, uint256 amount) {
    env e;

    transfer(e, to, amount);

    assert allowedPath(e.msg.sender, to), "transfer off the supply, withdrawal and seizure paths";
    assert amount > 0, "a zero-amount transfer succeeded";
}

// PROP-008 verifies: INV-011, Q-068, Q-120, Q-224
rule transferFromNeedsAllowedRecipientOnly(address from, address to, uint256 amount) {
    env e;

    transferFrom(e, from, to, amount);

    assert allowedRecipient(to), "transferFrom to an address outside {hub, lpVaultSwap} and the registry";
}

// PROP-055 verifies: INV-011, REQ-VTOKEN-008, REQ-VTOKEN-011, REQ-VTOKEN-041, REQ-VTOKEN-048, Q-224, Q-300
// The path and the non-zero amount are checked on `from` and `to`, whoever the spender is and whatever the allowance.
rule transferFromOnlyOnAllowedPath(address from, address to, uint256 amount) {
    env e;

    transferFrom@withrevert(e, from, to, amount);
    bool reverted = lastReverted;

    assert !reverted => allowedPath(from, to), "transferFrom off the supply, withdrawal and seizure paths";
    assert !allowedPath(from, to) => reverted, "an off-path transferFrom succeeded";
    assert amount == 0 => reverted, "a zero-amount transferFrom succeeded";
}

// PROP-055 verifies: INV-011, REQ-VTOKEN-010, Q-224
// Supply by the Spoke as spender of a registered proxy's allowance is reachable.
rule supplyByProxyAllowanceIsReachable(address proxy, uint256 amount) {
    env e;
    require isValidProxy(proxy);
    require e.msg.sender == spoke();
    transferFrom(e, proxy, hub(), amount);
    satisfy amount > 0;
}

// PROP-008 verifies: INV-011, REQ-VTOKEN-012, Q-068, Q-120, Q-224
rule mintNeedsRegisteredProxy(address to, uint256 amount) {
    env e;

    mint(e, to, amount);

    assert isValidProxy(to), "minted to an address that is not a registered proxy";
    assert to != 0, "minted to the zero address";
}

// PROP-055 verifies: INV-011, Q-224
rule allowedRecipientIsTheFixedSet(address a) {
    assert isAllowedRecipient(a) == allowedRecipient(a),
        "isAllowedRecipient differs from Hub, LPVaultSwap or a registered proxy";
}

// PROP-055 verifies: INV-011, REQ-VTOKEN-040
rule allowedTransferIsTheFixedFormula(address from, address to) {
    assert isAllowedTransfer(from, to) == allowedPath(from, to), "isAllowedTransfer differs from REQ-VTOKEN-040";
}

// PROP-008 verifies: INV-011, Q-068, Q-120, Q-224
invariant onlyAllowedRecipientsHoldBalance(address a)
    balanceOf(a) > 0 => isAllowedRecipient(a)
    filtered { f -> !f.isView }

// ---------------------------------------------------------------------------------------------------------------------
// Proxy registry (PROP-009, PROP-055)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-009 verifies: INV-012, Q-092, Q-120, Q-224, Q-225
rule registryIsAppendOnly(method f, address p) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    bool before = isValidProxy(p);

    f(e, args);

    assert before => isValidProxy(p), "a registry entry was removed";
    assert (!before && isValidProxy(p)) => (f.selector == sig:addValidProxy(address).selector && e.msg.sender == adapter()),
        "a registry entry was added outside addValidProxy by adapter()";
}

// PROP-009 verifies: INV-012, REQ-VTOKEN-039, REQ-VTOKEN-042, REQ-VTOKEN-047, Q-224
// No binding and not the token itself ever becomes a proxy, so the Hub's balance is never burnable and LPVaultSwap
// and the Adapter never gain a path.
invariant noBindingIsAProxy(address a)
    isBinding(a) => !isValidProxy(a)
    filtered { f -> !f.isView }

// PROP-009 verifies: INV-012, Q-092, Q-120, Q-224
rule addValidProxyAddsAtMostOne(address p) {
    env e;
    bool before = isValidProxy(p);
    registryAdds = 0;
    registryRemoved = false;

    addValidProxy(e, p);

    assert isValidProxy(p) && p != 0 && !isBinding(p), "addValidProxy did not register a non-zero, non-binding proxy";
    assert registryAdds == (before ? 0 : 1), "addValidProxy added other than the one new entry";
    assert !registryRemoved, "addValidProxy removed an entry";
}

// ---------------------------------------------------------------------------------------------------------------------
// Fixed bindings (PROP-055)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-055 verifies: INV-009, INV-011, INV-012, Q-224, Q-226
rule bindingsNeverChange(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    address a0 = adapter();
    address h0 = hub();
    address s0 = spoke();
    bytes32 k0 = marketKey();
    uint32 i0 = integrationId();
    address v0 = integration();
    address l0 = lpVaultSwap();
    address c0 = collateralization();
    address o0 = lpOracle();
    uint256 m0 = marketId();

    f(e, args);

    assert adapter() == a0 && hub() == h0 && spoke() == s0 && marketKey() == k0 && integrationId() == i0
        && integration() == v0 && lpVaultSwap() == l0 && collateralization() == c0 && lpOracle() == o0
        && marketId() == m0, "an immutable binding changed";
}

// ---------------------------------------------------------------------------------------------------------------------
// Arithmetic (PROP-043; SMTChecker is the 5.2 tool)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-043 verifies: Q-049, Q-092, Q-226
invariant totalSupplyIsSumOfBalances()
    to_mathint(totalSupply()) == sumBalances
    filtered { f -> !f.isView }
