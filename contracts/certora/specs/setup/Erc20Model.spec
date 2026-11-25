/*
 * Ghost model of standard ERC-20 tokens reached through external calls.
 *
 * Every token outside the verified contract (vault tokens seen from the LPVault, GHO, pool tokens, the route output)
 * is modelled by per-token ghost balances, supply and allowances with OpenZeppelin v5.1.0 semantics: no hooks, no
 * transfer fees, no rebasing, no callbacks. This is the listing rule of 2.7 (fee-on-transfer, rebasing and hook
 * tokens are never listed) and the vault-token rules of 2.3 (no hooks, no permit). A transfer that the real token
 * would reject (short balance or allowance) is pruned with `require`, which matches a revert of the whole call.
 *
 * Vault-token `mint(to, amount)` and `burn(from, amount)` are modelled here as well; their authority (only the
 * AaveAdapter, `adapter()`, PROP-005 and PROP-055) is proved on the real VaultToken in VaultToken.spec, so the model
 * applies them for any caller. `burn` needs no allowance and lowers `balanceOf(from)` and the supply by `amount`.
 *
 * Only ghosts and CVL functions live here; each contract spec binds them in its own `methods` block.
 */

persistent ghost mapping(address => mapping(address => mathint)) erc20Bal {
    init_state axiom forall address t. forall address a. erc20Bal[t][a] == 0;
}

persistent ghost mapping(address => mathint) erc20Supply {
    init_state axiom forall address t. erc20Supply[t] == 0;
}

persistent ghost mapping(address => mapping(address => mapping(address => mathint))) erc20Allow {
    init_state axiom forall address t. forall address o. forall address s. erc20Allow[t][o][s] == 0;
}

// Units of token `t` moved into the verified contract by `transferFrom` during the current call.
persistent ghost mapping(address => mathint) erc20PulledIntoVerified {
    init_state axiom forall address t. erc20PulledIntoVerified[t] == 0;
}

// Vault-token mint and burn bookkeeping for the current call.
persistent ghost mathint vtMintCalls {
    init_state axiom vtMintCalls == 0;
}
persistent ghost address lastMintToken;
persistent ghost address lastMintTo;
persistent ghost mathint lastMintAmount;
persistent ghost mapping(address => mathint) vtBurnedInCall {
    init_state axiom forall address t. vtBurnedInCall[t] == 0;
}

function erc20BalanceOf(address t, address a) returns uint256 {
    require erc20Bal[t][a] >= 0;
    return require_uint256(erc20Bal[t][a]);
}

function erc20TotalSupply(address t) returns uint256 {
    require erc20Supply[t] >= 0;
    return require_uint256(erc20Supply[t]);
}

function erc20Allowance(address t, address owner, address spender) returns uint256 {
    require erc20Allow[t][owner][spender] >= 0;
    return require_uint256(erc20Allow[t][owner][spender]);
}

function erc20Approve(address t, address owner, address spender, uint256 amount) returns bool {
    erc20Allow[t][owner][spender] = amount;
    return true;
}

function erc20Move(address t, address from, address to, uint256 amount) {
    require erc20Bal[t][from] >= to_mathint(amount);
    erc20Bal[t][from] = erc20Bal[t][from] - amount;
    erc20Bal[t][to] = erc20Bal[t][to] + amount;
    if (to == currentContract && from != currentContract) {
        erc20PulledIntoVerified[t] = erc20PulledIntoVerified[t] + amount;
    }
}

function erc20Transfer(address t, address from, address to, uint256 amount) returns bool {
    erc20Move(t, from, to, amount);
    return true;
}

function erc20TransferFrom(address t, address spender, address from, address to, uint256 amount) returns bool {
    if (spender != from) {
        require erc20Allow[t][from][spender] >= to_mathint(amount);
        if (erc20Allow[t][from][spender] != to_mathint(max_uint256)) {
            erc20Allow[t][from][spender] = erc20Allow[t][from][spender] - amount;
        }
    }
    erc20Move(t, from, to, amount);
    return true;
}

// Credit without a modelled source: tokens paid out by an external contract whose own balance no property reads (the Hub paying
// withdrawn or seized units, a route paying GHO, a flash loan).
function erc20Credit(address t, address to, uint256 amount) {
    erc20Bal[t][to] = erc20Bal[t][to] + amount;
}

function vaultTokenMint(address t, address to, uint256 amount) {
    erc20Supply[t] = erc20Supply[t] + amount;
    erc20Bal[t][to] = erc20Bal[t][to] + amount;
    vtMintCalls = vtMintCalls + 1;
    lastMintToken = t;
    lastMintTo = to;
    lastMintAmount = amount;
}

// Units burned from each holder of each vault token during the current call.
persistent ghost mapping(address => mapping(address => mathint)) vtBurnedFrom {
    init_state axiom forall address t. forall address a. vtBurnedFrom[t][a] == 0;
}

function vaultTokenBurn(address t, address from, uint256 amount) {
    require erc20Bal[t][from] >= to_mathint(amount);
    require erc20Supply[t] >= to_mathint(amount);
    erc20Bal[t][from] = erc20Bal[t][from] - amount;
    vtBurnedFrom[t][from] = vtBurnedFrom[t][from] + amount;
    erc20Supply[t] = erc20Supply[t] - amount;
    vtBurnedInCall[t] = vtBurnedInCall[t] + amount;
}
