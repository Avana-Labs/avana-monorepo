/*
 * Platform flows across the AaveAdapter (src/AaveAdapter.sol, the real contract with its AccountProxy), the
 * LPVault, the RiskModule, the LiquidationModule and Aave V4. The adapter is verified; the other contracts are
 * summarised by what their own specs prove, and Aave by what Aave V4 does:
 *
 *   supplyBackedByCredit              every adapter function keeps each account's Aave supply of its market's vault
 *                                     token at most the account's credit in the LPVault: a pledge and a top-up supply
 *                                     exactly the credit added, a withdrawal trims the supply to the credit left, a
 *                                     borrow or a repayment does not touch it
 *   pledgeBorrowRepayRelease          the whole user flow: a wallet pledges a position into a new account, borrows on
 *                                     it, repays all of it and withdraws the whole position. The NFT goes to the
 *                                     recipient, the account owes nothing and has neither credit nor supply left. The rule is checked for vacuity, so the four calls succeed
 *                                     together on some path.
 *   withdrawLowersSupplyOnlyWhenHealthy  a withdrawal (release or partial) keeps the supply within the credit left,
 *                                     never changes the debt, and lowers the supply only through Aave's withdraw,
 *                                     which leaves the health factor at least 1; when the credit left still covers the
 *                                     supply nothing is withdrawn and the health factor does not move. So a position
 *                                     leaves only when its credit is not needed for the supply that carries the debt.
 *   pledgeThenLiquidate               a fresh account pledges and borrows, prices fall below health 1 and the account
 *                                     is liquidated (the LiquidationModule step below), then the wallet withdraws the
 *                                     rest: the supply stays within the credit at every step and the NFT goes back
 *   borrowNeedsHealthAfter            a borrow succeeds only if the account's supply carries its debt after it
 *
 * Summaries, and the spec that proves each:
 *  - LPVault (LPVaultV2.spec, LPVaultV3.spec): records per key (account, market, liquidity, credit) and the account's
 *    credit per market, `accountCredit`. `pledge` writes the record for the account and market it is given, adds a
 *    positive credit to the account and takes the NFT (pledgeRecordsThePosition; only an unpledged key); `addLiquidity`
 *    adds some credit to the record's account and market (topUpAddsExactlyNewLp, creditWithinFloorCredit);
 *    `removeLiquidity` lowers the record's credit by at most its credit; `release` deletes the record, lowers the
 *    account's credit by its credit and sends the NFT to the recipient (releaseReturnsTheNft). `positionInfo` is a ghost
 *    per key. Each record's credit is at most its account's credit in its market (`accountCredit` sums the credit of
 *    the account's records of the market, LPVault.accountCredit), required of the pre-state.
 *  - RiskModule (RiskModuleActivation.spec, AaveAdapterRouting.spec): `routeOf` and `getMarket` are ghosts per input;
 *    a market's Spoke, vault token and reserve are fixed once active (activeMarketNeverChanges); `checkBorrow` is a
 *    view that may refuse.
 *  - Aave V4 Spoke: supplied vault-token units and debt per (Spoke, reserve, account). `supply` adds the amount for
 *    `onBehalfOf`; `withdraw` takes at most the supply (vault-token units are 1:1 with assets on the Hub, Hub.spec)
 *    and is refused when the account then has debt its supply does not carry; `borrow` adds the amount to the debt
 *    and is refused likewise; `repay` takes at most the debt. "Carries" is the ghost function `carry` of the supply
 *    (Aave's health factor at least 1: collateral value times collateral factor over debt value), fixed per Spoke and
 *    account within a rule (prices do not move inside one transaction).
 *  - LiquidationModule (LiquidationModule.spec): a liquidation goes through Aave's liquidationCall, which refuses an
 *    account whose supply carries its debt (liquidateGoesThroughAaveLiquidationCall); it seizes at most the supply,
 *    repays some debt, burns every seized unit (payoutIsEverythingUnwound) and unwinds at most the units seized of
 *    the account's credit (unwindCreditAtMostSeizedUnits). It is the CVL step `liquidateModel`.
 *  - Vault-token calls (mint, burn, proxies), token transfers and the Spoke's other calls are NONDET (no effect on the
 *    adapter's storage or the ghosts); the AccountProxy constructor's `setUserPositionManager` and Multicall's
 *    delegatecall are the unresolved calls of AaveAdapterAccounts.spec, NONDET.
 *
 * Every rule stands for one transaction or a sequence of them and starts with empty transient storage
 * (setup/TransientModel.spec). `multicall` (delegatecalls of the adapter's own functions) and `allowWithdraw` (whose
 * only state change is the operator's re-entrant calls of these same functions, each covered by supplyBackedByCredit,
 * and whose own health check only refuses) are left out of the parametric rule.
 */

import "setup/TransientModel.spec";

methods {
    function accountOf(address, uint256) external returns (address) envfree;
    function pledge(bytes32) external returns (uint256, uint128);
    function addLiquidity(bytes32, uint256, uint256, uint256, uint256) external returns (uint128, uint128, uint256, uint256);
    function withdraw(bytes32, uint128, uint256, uint256, address) external returns (uint256);
    function borrow(uint256, uint256, uint256, address) external;
    function repay(uint256, uint256, uint256, address) external returns (uint256);

    // LPVault
    function _.positionInfo(bytes32 key) external => positionInfoOf(key) expect (bytes32, int24, int24, uint128);
    function _.getPosition(bytes32 key) external => positionOf(key) expect (ILPVault.Position);
    function _.pledge(address from, address account, uint256 m, bytes32 key) external => vaultPledge(account, m, key) expect (uint128);
    function _.addLiquidity(bytes32 key, address, uint256, uint256, uint256, uint256) external => vaultAdd(key) expect (uint128, uint128, uint256, uint256);
    function _.removeLiquidity(bytes32 key, uint128 l, uint256, uint256, address) external => vaultRemove(key) expect (uint128, uint256, uint256);
    function _.release(bytes32 key, address recipient) external => vaultRelease(key, recipient) expect (uint128);
    function _.collectFees(address, bytes32[], address) external => NONDET;
    function _.accountCredit(address a, uint256 m) external => accountCreditOf(a, m) expect (uint256);
    // RiskModule
    function _.routeOf(bytes32 pool, int24 lower, int24 upper) external => routeGhost(pool, lower, upper) expect (uint256);
    function _.getMarket(uint256 id) external => riskMarket(id) expect (IRiskModule.Market);
    function _.checkBorrow(address, uint256) external => NONDET;
    // Aave V4 Spoke
    function _.supply(uint256 r, uint256 amount, address onBehalfOf) external => spokeSupply(calledContract, r, amount, onBehalfOf) expect (uint256, uint256);
    function _.withdraw(uint256 r, uint256 amount, address onBehalfOf) external => spokeWithdraw(calledContract, r, amount, onBehalfOf) expect (uint256, uint256);
    function _.borrow(uint256 r, uint256 amount, address onBehalfOf) external => spokeBorrow(calledContract, r, amount, onBehalfOf) expect (uint256, uint256);
    function _.repay(uint256 r, uint256 amount, address onBehalfOf) external => spokeRepay(calledContract, r, amount, onBehalfOf) expect (uint256, uint256);
    function _.getUserSuppliedAssets(uint256 r, address a) external => suppliedOf(calledContract, r, a) expect (uint256);
    function _.getUserTotalDebt(uint256 r, address a) external => debtOf(calledContract, r, a) expect (uint256);
    function _.setUsingAsCollateral(uint256, bool, address) external => NONDET;
    function _.setUserPositionManager(address, bool) external => NONDET;
    function _.getReserve(uint256) external => NONDET;
    function _.getUserAccountData(address) external => NONDET;
    // Vault token and ERC-20
    function _.isValidProxy(address) external => NONDET;
    function _.addValidProxy(address) external => NONDET;
    function _.mint(address, uint256) external => NONDET;
    function _.burn(address, uint256) external => NONDET;
    function _.transfer(address, uint256) external => NONDET;
    function _.transferFrom(address, address, uint256) external => NONDET;
    function _.approve(address, uint256) external => NONDET;

    // The unresolved calls of AaveAdapterAccounts.spec: AccountProxy's constructor call of the Spoke's
    // setUserPositionManager (NONDET as the entry above states) and Multicall's delegatecall (in no rule).
    unresolved external in _._ => DISPATCH [] default NONDET;
}

// ---------------------------------------------------------------------------------------------------------------------
// LPVault model
// ---------------------------------------------------------------------------------------------------------------------

persistent ghost mapping(bytes32 => address) recAccount;
persistent ghost mapping(bytes32 => uint96) recMarket;
persistent ghost mapping(bytes32 => uint128) recCredit;
persistent ghost mapping(bytes32 => address) nftOwner;
persistent ghost address vaultAddress;
persistent ghost mapping(address => mapping(uint256 => mathint)) credit;
persistent ghost mapping(bytes32 => bytes32) posPool;
persistent ghost mapping(bytes32 => int24) posLower;
persistent ghost mapping(bytes32 => int24) posUpper;

function positionInfoOf(bytes32 key) returns (bytes32, int24, int24, uint128) {
    uint128 liquidity;
    return (posPool[key], posLower[key], posUpper[key], liquidity);
}

function positionOf(bytes32 key) returns ILPVault.Position {
    ILPVault.Position p;
    require p.account == recAccount[key] && p.marketId == recMarket[key] && p.credit == recCredit[key];
    return p;
}

function accountCreditOf(address a, uint256 m) returns uint256 {
    return require_uint256(credit[a][m]);
}

function vaultPledge(address account, uint256 m, bytes32 key) returns uint128 {
    require recAccount[key] == 0 && account != 0;
    uint128 c;
    require c > 0;
    recAccount[key] = account;
    recMarket[key] = require_uint96(m);
    recCredit[key] = c;
    credit[account][m] = credit[account][m] + c;
    require credit[account][m] <= max_uint256;
    nftOwner[key] = vaultAddress;
    return c;
}

function vaultAdd(bytes32 key) returns (uint128, uint128, uint256, uint256) {
    require recAccount[key] != 0;
    uint128 liquidity;
    uint128 c;
    uint256 a0;
    uint256 a1;
    require recCredit[key] + c <= max_uint128;
    recCredit[key] = require_uint128(recCredit[key] + c);
    credit[recAccount[key]][recMarket[key]] = credit[recAccount[key]][recMarket[key]] + c;
    require credit[recAccount[key]][recMarket[key]] <= max_uint256;
    return (liquidity, c, a0, a1);
}

function vaultRemove(bytes32 key) returns (uint128, uint256, uint256) {
    require recAccount[key] != 0;
    uint128 removed;
    require removed <= recCredit[key];
    recCredit[key] = require_uint128(recCredit[key] - removed);
    credit[recAccount[key]][recMarket[key]] = credit[recAccount[key]][recMarket[key]] - removed;
    uint256 a0;
    uint256 a1;
    return (removed, a0, a1);
}

function vaultRelease(bytes32 key, address recipient) returns uint128 {
    require recAccount[key] != 0;
    uint128 c = recCredit[key];
    credit[recAccount[key]][recMarket[key]] = credit[recAccount[key]][recMarket[key]] - c;
    recAccount[key] = 0;
    recMarket[key] = 0;
    recCredit[key] = 0;
    nftOwner[key] = recipient;
    return c;
}

// Each record's credit is part of its account's credit in its market.
definition recordWithinAccount(bytes32 key) returns bool =
    recAccount[key] != 0 => to_mathint(recCredit[key]) <= credit[recAccount[key]][recMarket[key]];

// ---------------------------------------------------------------------------------------------------------------------
// RiskModule model
// ---------------------------------------------------------------------------------------------------------------------

ghost routeGhost(bytes32, int24, int24) returns uint256;
persistent ghost mapping(uint256 => address) marketSpoke;
persistent ghost mapping(uint256 => address) marketVaultToken;
persistent ghost mapping(uint256 => uint256) marketReserve;
persistent ghost mapping(uint256 => bool) marketActive;

function riskMarket(uint256 id) returns IRiskModule.Market {
    IRiskModule.Market m;
    require m.spoke == marketSpoke[id] && m.vaultToken == marketVaultToken[id];
    require m.reserveId == marketReserve[id] && m.active == marketActive[id];
    return m;
}

// ---------------------------------------------------------------------------------------------------------------------
// Aave V4 Spoke model
// ---------------------------------------------------------------------------------------------------------------------

persistent ghost mapping(address => mapping(uint256 => mapping(address => mathint))) supplied;
persistent ghost mapping(address => mapping(uint256 => mapping(address => mathint))) debt;
// All of an account's supply and debt on a Spoke (an account holds one collateral: its market's vault token).
persistent ghost mapping(address => mapping(address => mathint)) collateral;
persistent ghost mapping(address => mapping(address => mathint)) totalDebt;
// The most debt a supply carries at health factor 1, per (Spoke, account), at the prices of `priceEpoch`: prices stay
// put inside one transaction and may move between two.
ghost carry(address, address, mathint, mathint) returns mathint;
persistent ghost mathint priceEpoch;

definition healthy(address spoke, address a) returns bool =
    totalDebt[spoke][a] <= carry(spoke, a, collateral[spoke][a], priceEpoch);

function suppliedOf(address spoke, uint256 r, address a) returns uint256 {
    return require_uint256(supplied[spoke][r][a]);
}

function debtOf(address spoke, uint256 r, address a) returns uint256 {
    return require_uint256(debt[spoke][r][a]);
}

function spokeSupply(address spoke, uint256 r, uint256 amount, address a) returns (uint256, uint256) {
    supplied[spoke][r][a] = supplied[spoke][r][a] + amount;
    collateral[spoke][a] = collateral[spoke][a] + amount;
    return (amount, amount);
}

function spokeWithdraw(address spoke, uint256 r, uint256 amount, address a) returns (uint256, uint256) {
    mathint w = to_mathint(amount) < supplied[spoke][r][a] ? to_mathint(amount) : supplied[spoke][r][a];
    supplied[spoke][r][a] = supplied[spoke][r][a] - w;
    collateral[spoke][a] = collateral[spoke][a] - w;
    // Aave V4 refuses a withdrawal that leaves the health factor below 1.
    require healthy(spoke, a);
    return (require_uint256(w), require_uint256(w));
}

function spokeBorrow(address spoke, uint256 r, uint256 amount, address a) returns (uint256, uint256) {
    debt[spoke][r][a] = debt[spoke][r][a] + amount;
    totalDebt[spoke][a] = totalDebt[spoke][a] + amount;
    // Aave V4 refuses a borrow that leaves the health factor below 1.
    require healthy(spoke, a);
    return (amount, amount);
}

function spokeRepay(address spoke, uint256 r, uint256 amount, address a) returns (uint256, uint256) {
    mathint p = to_mathint(amount) < debt[spoke][r][a] ? to_mathint(amount) : debt[spoke][r][a];
    debt[spoke][r][a] = debt[spoke][r][a] - p;
    totalDebt[spoke][a] = totalDebt[spoke][a] - p;
    return (require_uint256(p), require_uint256(p));
}

// ---------------------------------------------------------------------------------------------------------------------
// LiquidationModule model (LiquidationModule.spec)
// ---------------------------------------------------------------------------------------------------------------------

// Liquidates `account` in market `m`: Aave seizes `seized` units of the supply and the module unwinds `unwound` of the
// account's credit from its record `key`, at most the units seized.
function liquidateModel(address account, uint256 m, bytes32 key) {
    address spoke = marketSpoke[m];
    uint256 r = marketReserve[m];
    // Aave's liquidationCall: HealthFactorNotBelowThreshold at a health factor of 1 or more.
    require !healthy(spoke, account);
    mathint seized;
    mathint repaid;
    require 0 <= seized && seized <= supplied[spoke][r][account];
    require 0 <= repaid && repaid <= totalDebt[spoke][account];
    supplied[spoke][r][account] = supplied[spoke][r][account] - seized;
    collateral[spoke][account] = collateral[spoke][account] - seized;
    totalDebt[spoke][account] = totalDebt[spoke][account] - repaid;
    // unwindCreditAtMostSeizedUnits: the unwind removes at most the units seized, and at most the record's credit.
    require recAccount[key] == account && to_mathint(recMarket[key]) == to_mathint(m);
    mathint unwound;
    require 0 <= unwound && unwound <= seized && unwound <= to_mathint(recCredit[key]);
    recCredit[key] = require_uint128(recCredit[key] - unwound);
    credit[account][m] = credit[account][m] - unwound;
}

// ---------------------------------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------------------------------

definition backed(address a, uint256 m) returns bool = supplied[marketSpoke[m]][marketReserve[m]][a] <= credit[a][m];

definition isMulticall(method f) returns bool = f.selector == sig:multicall(bytes[]).selector;
definition isAllowWithdraw(method f) returns bool = f.selector == sig:allowWithdraw(address, bytes32, uint128, bytes).selector;

// A wallet with no account yet in the market its position routes to; after the pledge, the new account starts empty.
function requireFreshAccount(address wallet, uint256 m) {
    require accountOf(wallet, m) == 0;
}

function requireNewAccountEmpty(address account, uint256 m, uint128 c) {
    address spoke = marketSpoke[m];
    require supplied[spoke][marketReserve[m]][account] == to_mathint(c) && collateral[spoke][account] == to_mathint(c);
    require credit[account][m] == to_mathint(c) && totalDebt[spoke][account] == 0;
}

// ---------------------------------------------------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------------------------------------------------

rule supplyBackedByCredit(method f, address account, uint256 m, bytes32 key)
    filtered { f -> !f.isView && !isMulticall(f) && !isAllowWithdraw(f) } {
    env e;
    calldataarg args;
    transientStorageEmpty();
    require backed(account, m);
    require credit[account][m] >= 0 && supplied[marketSpoke[m]][marketReserve[m]][account] >= 0;
    // An account is used for one market only: its supply of another market's reserve is never this market's.
    require forall uint256 m2. m2 != m => (marketSpoke[m2] != marketSpoke[m] || marketReserve[m2] != marketReserve[m]);
    require forall bytes32 k. recAccount[k] != 0 => to_mathint(recCredit[k]) <= credit[recAccount[k]][recMarket[k]];

    f(e, args);

    assert backed(account, m), "an account's supply exceeds its credit";
}

rule pledgeBorrowRepayRelease(bytes32 key, uint256 reserveId, uint256 amount, address recipient) {
    env e;
    transientStorageEmpty();
    address wallet = e.msg.sender;
    uint256 m = routeGhost(posPool[key], posLower[key], posUpper[key]);
    address spoke = marketSpoke[m];
    require reserveId != marketReserve[m];
    requireFreshAccount(wallet, m);

    uint256 market;
    uint128 c;
    market, c = pledge(e, key);
    address account = accountOf(wallet, market);
    requireNewAccountEmpty(account, market, c);
    require debt[spoke][reserveId][account] == 0;
    mathint credit0 = 0;
    assert market == m && account != 0 && recAccount[key] == account, "the pledge went to another market or account";

    borrow(e, market, reserveId, amount, recipient);
    assert debt[spoke][reserveId][account] == to_mathint(amount), "the borrow drew another amount on the account";

    repay(e, market, reserveId, max_uint256, wallet);
    assert debt[spoke][reserveId][account] == 0, "a full repayment left debt";

    withdraw(e, key, 0, 0, 0, recipient);
    assert nftOwner[key] == recipient && recAccount[key] == 0, "the NFT did not go back to the recipient";
    assert credit[account][market] == credit0, "the credit is not back where it started";
    assert supplied[spoke][marketReserve[market]][account] == 0, "supply is left without credit";
    assert totalDebt[spoke][account] == 0, "the account still owes";
}

rule withdrawLowersSupplyOnlyWhenHealthy(bytes32 key, uint128 liquidity, uint256 m0, uint256 m1, address recipient) {
    env e;
    transientStorageEmpty();
    address account = recAccount[key];
    uint256 m = recMarket[key];
    address spoke = marketSpoke[m];
    mathint debt0 = totalDebt[spoke][account];
    mathint collateral0 = collateral[spoke][account];
    bool healthy0 = healthy(spoke, account);
    require credit[account][m] >= recCredit[key];
    require supplied[spoke][marketReserve[m]][account] <= credit[account][m];

    withdraw(e, key, liquidity, m0, m1, recipient);

    assert supplied[spoke][marketReserve[m]][account] <= credit[account][m], "the supply exceeds the credit left";
    assert totalDebt[spoke][account] == debt0, "a withdrawal changed the debt";
    assert collateral[spoke][account] <= collateral0, "a withdrawal raised the supply";
    assert collateral[spoke][account] < collateral0 => healthy(spoke, account),
        "the supply fell while it no longer carries the debt";
    assert collateral[spoke][account] == collateral0 => healthy(spoke, account) == healthy0,
        "a withdrawal without a supply change moved the health factor";
}

rule borrowNeedsHealthAfter(uint256 m, uint256 reserveId, uint256 amount, address recipient) {
    env e;
    transientStorageEmpty();
    borrow(e, m, reserveId, amount, recipient);
    address account = accountOf(e.msg.sender, m);
    assert healthy(marketSpoke[m], account), "a borrow left the account below health 1";
}

rule pledgeThenLiquidate(bytes32 key, uint256 reserveId, uint256 amount, address borrowed, address recipient) {
    env e;
    transientStorageEmpty();
    address wallet = e.msg.sender;
    uint256 m = routeGhost(posPool[key], posLower[key], posUpper[key]);
    address spoke = marketSpoke[m];
    uint256 r = marketReserve[m];
    require reserveId != r;
    requireFreshAccount(wallet, m);

    uint256 market;
    uint128 c;
    market, c = pledge(e, key);
    address account = accountOf(wallet, market);
    requireNewAccountEmpty(account, market, c);
    assert supplied[spoke][r][account] <= credit[account][market], "the pledge supplied more than its credit";

    borrow(e, market, reserveId, amount, borrowed);
    assert healthy(spoke, account), "the borrow left the account below health 1";

    // Prices fall: the account's health factor is below 1, and it is liquidated.
    priceEpoch = priceEpoch + 1;
    liquidateModel(account, market, key);
    assert supplied[spoke][r][account] <= credit[account][market], "the liquidation left the supply above the credit";

    withdraw(e, key, 0, 0, 0, recipient);
    assert supplied[spoke][r][account] <= credit[account][market], "the withdrawal left the supply above the credit";
    assert nftOwner[key] == recipient, "the rest of the position did not go back to the recipient";
}
