/*
 * Swap routes (interface src/liquidation/settlement-routes/ISettlementRoute.sol, spec 2.12).
 *
 * A swap route swaps one pool token into one debt asset along a path fixed at deployment. It swaps only for LPVaultSwap
 * while the Lock is held (by LPVaultSwap, or by the AaveAdapter inside repay with collateral), delivers at least the
 * oracle-derived `minOut` it is called with or reverts (`MinOutNotMet`), and pulls no more than `amountIn`; its
 * concentrated-liquidity swap callback (Uniswap v3 and Aerodrome Slipstream pools both call `uniswapV3SwapCallback`)
 * is accepted only from the hop's fixed pool during a hop, so outside `swap` no hop context exists and the callback is
 * refused for every caller.
 *
 * One conf per route type of `routeType()` verifies this spec: PegModuleRoute (0), DexPathRoute (1) and
 * WrapperThenDexRoute (2), under src/liquidation/settlement-routes/. Storage: the hop context (expected pool
 * and amount owed) lives in transient storage (2.12 Storage); every rule is one transaction and starts with empty
 * transient storage (setup/TransientModel.spec). The constructor refuses a zero or shared LPVaultSwap and AaveAdapter
 * binding (routeBindingsSet), which the rules take from that invariant.
 *
 * Summaries: tokens by the ERC-20 model; the Lock by the Lock model. Pools pay an arbitrary amount >= 0 of the route's
 * output token (the debt asset, `routeOut`) to the recipient they are told to pay: Curve `exchange` (to its caller) and
 * the concentrated-liquidity pool `swap` (whose callback the callback rule calls directly). Peg modules (LitePSM
 * `buyGem`, GSM `sellAsset`) pay an arbitrary amount of the debt asset to the address they are told to pay; the
 * wrapper steps (ERC-4626 `redeem`, the DAI-USDS converter) pay an arbitrary amount of their output token `routeMid`
 * to the address they are told to pay, and an ERC-4626 `deposit` mints arbitrary shares to its receiver. The route's
 * minimum-output check is its own code, so it holds for every pool outcome. The lock rule asserts that the Lock is held
 * by LPVaultSwap or by the AaveAdapter (`AAVE_ADAPTER()`), the route's second accepted lock holder (REQ-ROUTE-007).
 */

import "setup/Erc20Model.spec";
import "setup/LockModel.spec";
import "setup/TransientModel.spec";

methods {
    function swap(uint256, uint256) external returns (uint256);
    function uniswapV3SwapCallback(int256, int256, bytes) external;
    function LP_VAULT_SWAP() external returns (address) envfree;
    function AAVE_ADAPTER() external returns (address) envfree;
    function tokenIn() external returns (address) envfree;
    function tokenOut() external returns (address) envfree;
    function routeType() external returns (uint8) envfree;
    function supportsTokenClass(uint8) external returns (bool) envfree;

    function _.balanceOf(address a) external => erc20BalanceOf(calledContract, a) expect uint256;
    function _.allowance(address o, address s) external => erc20Allowance(calledContract, o, s) expect uint256;
    function _.approve(address s, uint256 a) external with (env e) => erc20Approve(calledContract, e.msg.sender, s, a) expect bool;
    function _.transfer(address to, uint256 a) external with (env e) => erc20Transfer(calledContract, e.msg.sender, to, a) expect bool;
    function _.transferFrom(address from, address to, uint256 a) external with (env e) => erc20TransferFrom(calledContract, e.msg.sender, from, to, a) expect bool;
    function _.holder() external => lockHolderOf() expect address;
    function _.isLocked() external => lockIsLocked() expect bool;
    function _.exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external with (env e) => poolPaysOutOne(e.msg.sender) expect uint256;
    function _.swap(address recipient, bool zeroForOne, int256 amount, uint160 limit, bytes data) external => poolSwap(recipient) expect (int256, int256);
    function _.buyGem(address usr, uint256 gemAmt) external => pegPaysOut(usr) expect uint256;
    function _.sellAsset(uint256 maxAmount, address receiver) external => gsmPaysOut(receiver) expect (uint256, uint256);
    function _.usdsToDai(address usr, uint256 wad) external => wrapperPaysOut(usr) expect void;
    function _.redeem(uint256 shares, address receiver, address owner) external => wrapperPaysOutAmount(receiver) expect uint256;
    function _.deposit(uint256 assets, address receiver) external => vaultMintsShares(calledContract, receiver) expect uint256;
    function _.tout() external => NONDET;
}

persistent ghost address routeOut;
// The token a wrapper step pays out (the ERC-4626 vault's asset, or DAI from the DAI-USDS converter).
persistent ghost address routeMid;

// A peg module (LitePSM buyGem, GSM sellAsset) pays an arbitrary amount >= 0 of the debt asset to the address it is
// told to pay.
function pegPaysOut(address usr) returns uint256 {
    uint256 out;
    erc20Credit(routeOut, usr, out);
    return out;
}

function gsmPaysOut(address receiver) returns (uint256, uint256) {
    uint256 sold;
    uint256 out;
    erc20Credit(routeOut, receiver, out);
    return (sold, out);
}

// A wrapper step pays an arbitrary amount >= 0 of its output token to the address it is told to pay.
function wrapperPaysOut(address usr) {
    uint256 out;
    erc20Credit(routeMid, usr, out);
}

function wrapperPaysOutAmount(address receiver) returns uint256 {
    uint256 out;
    erc20Credit(routeMid, receiver, out);
    return out;
}

// An ERC-4626 deposit mints an arbitrary amount >= 0 of the vault's shares to the receiver.
function vaultMintsShares(address vault, address receiver) returns uint256 {
    uint256 shares;
    erc20Credit(vault, receiver, shares);
    return shares;
}

function poolPaysOutOne(address receiver) returns uint256 {
    uint256 out;
    erc20Credit(routeOut, receiver, out);
    return out;
}

function poolSwap(address recipient) returns (int256, int256) {
    uint256 out;
    erc20Credit(routeOut, recipient, out);
    int256 d0;
    int256 d1;
    return (d0, d1);
}

// The route's two accepted callers are fixed, non-zero and distinct (constructor, REQ-ROUTE-007). The swap callback
// is left out of the induction: PegModuleRoute inherits the base callback, which always reverts, so the sanity check
// reports that step as vacuous; the callback writes only transient hop state, never an immutable.
// PROP-037 verifies: INV-054, Q-148, Q-223
invariant routeBindingsSet()
    LP_VAULT_SWAP() != 0 && AAVE_ADAPTER() != 0 && LP_VAULT_SWAP() != AAVE_ADAPTER()
    filtered { f -> f.selector != sig:uniswapV3SwapCallback(int256, int256, bytes).selector }

// PROP-037 verifies: INV-054, Q-148, Q-223
rule swapOnlyForLpVaultSwapUnderLock(uint256 amountIn, uint256 minOut) {
    env e;
    transientStorageEmpty();
    requireInvariant routeBindingsSet();

    swap(e, amountIn, minOut);

    assert e.msg.sender == LP_VAULT_SWAP(), "a route swapped for a caller other than LPVaultSwap";
    assert lockHolder != 0, "a route swapped while the Lock was free";
    assert lockHolder == LP_VAULT_SWAP() || lockHolder == AAVE_ADAPTER(),
        "a route swapped while the Lock was held by neither LPVaultSwap nor the AaveAdapter";
}

// PROP-068 verifies: INV-034, INV-083, Q-250
rule swapDeliversAtLeastMinOut(uint256 amountIn, uint256 minOut) {
    env e;
    transientStorageEmpty();
    require routeOut == tokenOut();
    address lvs = LP_VAULT_SWAP();
    require lvs != currentContract;
    mathint outBefore = erc20Bal[routeOut][lvs];
    mathint inBefore = erc20Bal[tokenIn()][lvs];

    uint256 out = swap(e, amountIn, minOut);

    assert out >= minOut, "swap returned less than minOut";
    assert tokenIn() != routeOut => erc20Bal[routeOut][lvs] - outBefore >= to_mathint(minOut),
        "LPVaultSwap received less of the debt asset than minOut";
    assert tokenIn() != routeOut => inBefore - erc20Bal[tokenIn()][lvs] <= to_mathint(amountIn),
        "the route took more input than amountIn";
}

// PROP-068 verifies: INV-083, Q-250
rule swapIsReachable(uint256 amountIn, uint256 minOut) {
    env e;
    transientStorageEmpty();
    require routeOut == tokenOut();
    uint256 out = swap(e, amountIn, minOut);
    satisfy minOut >= 1 && out >= minOut;
}

// PROP-036 verifies: INV-040, Q-045, Q-148, Q-235
rule swapCallbackRefusedOutsideHop(int256 amount0Delta, int256 amount1Delta, bytes data) {
    env e;
    transientStorageEmpty();

    uniswapV3SwapCallback@withrevert(e, amount0Delta, amount1Delta, data);

    assert lastReverted, "a swap callback was accepted outside a hop";
}
