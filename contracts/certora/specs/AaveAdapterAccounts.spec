/*
 * AaveAdapter (src/policy/aave-adapter/AaveAdapter.sol, interface IAaveAdapter.sol, design DESIGN.md): one thin
 * AccountProxy per (wallet, market) as the Aave user, with the adapter as its position manager, and automatic routing.
 * The routing rule itself (`RiskModule.routeOf`) is proved in AaveAdapterRouting.spec; here the adapter's use of it.
 *
 *   pledgeRoutesOrReverts              a pledge goes to the market routeOf picks for the NFT's pool and ticks, which is
 *                                      non-zero and active; otherwise the pledge reverts
 *   onlyPositionOwnerChangesPosition   addLiquidity and withdraw succeed only for the wallet whose account holds the
 *                                      position in the LPVault
 *   borrowOnlyFromOwnAccount           a borrow draws only on the caller's own account of that market
 *   accountCreatedOncePerWalletMarket  a wallet's account of a market, once set, never changes
 *   accountOnlyCreatedForCaller        an account is created only by a pledge, and only for the calling wallet
 *
 * Summaries: the LPVault's position reads (`positionInfo`, `getPosition`) and the RiskModule's `routeOf` and
 * `getMarket` are ghost functions of their arguments; the Spoke's `borrow` records its `onBehalfOf`; every other
 * LPVault, Spoke, vault-token and ERC-20 call is NONDET (no effect on the adapter's storage). AccountProxy creation
 * is the real constructor (dynamic_bound 1), whose `setUserPositionManager` is NONDET. `multicall` is excluded from
 * the parametric rules: it delegatecalls the adapter's own functions with the caller kept, so it adds no path.
 */

methods {
    function accountOf(address, uint256) external returns (address) envfree;
    function pledge(bytes32) external returns (uint256, uint128);
    function addLiquidity(bytes32, uint256, uint256, uint256, uint256) external returns (uint128, uint128, uint256, uint256);
    function withdraw(bytes32, uint128, uint256, uint256, address) external returns (uint256);
    function borrow(uint256, uint256, uint256, address) external;

    // LPVault
    function _.positionInfo(bytes32 key) external => positionInfoOf(key) expect (bytes32, int24, int24, uint128);
    function _.getPosition(bytes32 key) external => positionOf(key) expect (ILPVault.Position);
    function _.pledge(address, address, uint256, bytes32) external => NONDET;
    function _.addLiquidity(bytes32, address, uint256, uint256, uint256, uint256) external => NONDET;
    function _.removeLiquidity(bytes32, uint128, uint256, uint256, address) external => NONDET;
    function _.release(bytes32, address) external => NONDET;
    function _.collectFees(address, bytes32[], address) external => NONDET;
    function _.accountCredit(address, uint256) external => NONDET;
    // RiskModule
    function _.routeOf(bytes32 pool, int24 lower, int24 upper) external => routeGhost(pool, lower, upper) expect uint256;
    function _.getMarket(uint256 id) external => riskMarket(id) expect (IRiskModule.Market);
    function _.checkBorrow(address, uint256) external => NONDET;
    // Spoke
    function _.borrow(uint256, uint256, address onBehalfOf) external => recordBorrow(onBehalfOf) expect (uint256, uint256);
    function _.supply(uint256, uint256, address) external => NONDET;
    function _.withdraw(uint256, uint256, address) external => NONDET;
    function _.repay(uint256, uint256, address) external => NONDET;
    function _.setUsingAsCollateral(uint256, bool, address) external => NONDET;
    function _.setUserPositionManager(address, bool) external => NONDET;
    function _.getUserSuppliedAssets(uint256, address) external => NONDET;
    function _.getUserTotalDebt(uint256, address) external => NONDET;
    function _.getReserve(uint256) external => NONDET;
    // Vault token and ERC-20
    function _.isValidProxy(address) external => NONDET;
    function _.addValidProxy(address) external => NONDET;
    function _.mint(address, uint256) external => NONDET;
    function _.burn(address, uint256) external => NONDET;
    function _.transfer(address, uint256) external => NONDET;
    function _.transferFrom(address, address, uint256) external => NONDET;
    function _.approve(address, uint256) external => NONDET;
}

// ---------------------------------------------------------------------------------------------------------------------
// Ghost reads
// ---------------------------------------------------------------------------------------------------------------------

ghost mapping(bytes32 => bytes32) posPool;
ghost mapping(bytes32 => int24) posLower;
ghost mapping(bytes32 => int24) posUpper;
ghost mapping(bytes32 => address) posAccount;
ghost mapping(bytes32 => uint96) posMarket;
ghost routeGhost(bytes32, int24, int24) returns uint256;
ghost mapping(uint256 => address) marketSpoke;
ghost mapping(uint256 => address) marketVaultToken;
ghost mapping(uint256 => uint256) marketReserve;
ghost mapping(uint256 => bool) marketActive;

ghost bool borrowCalled;
ghost address borrowedFor;

function positionInfoOf(bytes32 key) returns (bytes32, int24, int24, uint128) {
    uint128 liquidity;
    return (posPool[key], posLower[key], posUpper[key], liquidity);
}

function positionOf(bytes32 key) returns ILPVault.Position {
    ILPVault.Position p;
    require p.account == posAccount[key] && p.marketId == posMarket[key];
    return p;
}

function riskMarket(uint256 id) returns IRiskModule.Market {
    IRiskModule.Market m;
    require m.spoke == marketSpoke[id] && m.vaultToken == marketVaultToken[id];
    require m.reserveId == marketReserve[id] && m.active == marketActive[id];
    return m;
}

function recordBorrow(address onBehalfOf) returns (uint256, uint256) {
    borrowCalled = true;
    borrowedFor = onBehalfOf;
    uint256 shares;
    uint256 drawn;
    return (shares, drawn);
}

definition isMulticall(method f) returns bool = f.selector == sig:multicall(bytes[]).selector;

// ---------------------------------------------------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------------------------------------------------

rule pledgeRoutesOrReverts(bytes32 key) {
    env e;
    uint256 marketId;
    uint128 credit;
    marketId, credit = pledge(e, key);
    assert marketId == routeGhost(posPool[key], posLower[key], posUpper[key]), "the pledge left the routed market";
    assert marketId != 0 && marketActive[marketId], "a pledge with no fitting active market succeeded";
}

// ---------------------------------------------------------------------------------------------------------------------
// Only the owner acts on a position
// ---------------------------------------------------------------------------------------------------------------------

rule onlyPositionOwnerChangesPosition(method f, bytes32 key) filtered {
    f -> f.selector == sig:addLiquidity(bytes32, uint256, uint256, uint256, uint256).selector
        || f.selector == sig:withdraw(bytes32, uint128, uint256, uint256, address).selector
} {
    env e;
    uint256 a0;
    uint256 a1;
    uint256 m0;
    uint256 m1;
    uint128 liquidity;
    address recipient;
    if (f.selector == sig:addLiquidity(bytes32, uint256, uint256, uint256, uint256).selector) {
        addLiquidity(e, key, a0, a1, m0, m1);
    } else {
        withdraw(e, key, liquidity, m0, m1, recipient);
    }
    address owned = accountOf(e.msg.sender, posMarket[key]);
    assert owned != 0 && owned == posAccount[key], "a wallet changed a position its account does not hold";
}

rule borrowOnlyFromOwnAccount(uint256 marketId, uint256 reserveId, uint256 amount, address recipient) {
    env e;
    require !borrowCalled;
    borrow(e, marketId, reserveId, amount, recipient);
    address own = accountOf(e.msg.sender, marketId);
    assert borrowCalled && own != 0 && borrowedFor == own, "a borrow drew on an account the caller does not own";
}

// ---------------------------------------------------------------------------------------------------------------------
// One account per (wallet, market)
// ---------------------------------------------------------------------------------------------------------------------

rule accountCreatedOncePerWalletMarket(method f, address wallet, uint256 marketId)
    filtered { f -> !f.isView && !isMulticall(f) } {
    env e;
    calldataarg args;
    address before = accountOf(wallet, marketId);
    require before != 0;

    f(e, args);

    assert accountOf(wallet, marketId) == before, "a wallet's account of a market was replaced";
}

rule accountOnlyCreatedForCaller(method f, address wallet, uint256 marketId)
    filtered { f -> !f.isView && !isMulticall(f) } {
    env e;
    calldataarg args;
    require accountOf(wallet, marketId) == 0;

    f(e, args);

    assert accountOf(wallet, marketId) != 0 => (wallet == e.msg.sender && f.selector == sig:pledge(bytes32).selector),
        "an account was created other than by the wallet's own pledge";
}
