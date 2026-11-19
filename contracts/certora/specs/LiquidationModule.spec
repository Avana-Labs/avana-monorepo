/*
 * LiquidationModule (src/liquidation/liquidation-module/LiquidationModule.sol, arithmetic in
 * libraries/LiquidationMath.sol, design DESIGN.md), through LiquidationModuleHarness
 * (test/utils/harness/LiquidationModuleHarness.sol), which is the module plus external LiquidationMath wrappers.
 *
 *   liquidateGoesThroughAaveLiquidationCall  a liquidation is one Aave liquidationCall on the market's reserve for the
 *                                            account, without receive-shares, that seized units; Aave's own check
 *                                            refuses it at health factor >= 1, so the module liquidates only below 1
 *   unwindCreditAtMostSeizedUnits            a partial unwind removes at most the units seized from a position, and at
 *                                            most its credit: the borrower loses no more credit than Aave took from
 *                                            the supply, so the liquidation's health gain is Aave's (repaid debt
 *                                            against seized collateral) and the unwind never undoes it
 *   feeIsShareOfBonus                        feeUnits = floor(floor(seized * (bonus - 1) / bonus) * share), and none
 *                                            without a bonus; at share 20% it is at most 20% of the bonus units
 *   liquidationFeeIsTwentyPercentOfBonus     in a liquidation with the RiskModule's share at 2,000 bps and a fee
 *                                            recipient, the fee units are that formula at Aave's bonus
 *   feePartAtMostAmount                      the fee recipient's part of each unwound token is at most the amount
 *   payoutIsEverythingUnwound                every unwound token goes to the receiver or the fee recipient, and every
 *                                            seized unit is burned
 *   noValueLeaks                             the module ends a liquidation holding exactly what it started with, for
 *                                            every token
 *
 * Summaries: tokens by Erc20Model (vault-token burn included); the Spoke's `liquidationCall` takes at most
 * `debtToCover` of the debt reserve's underlying from the module and credits it some seized vault-token units, and
 * records its arguments; `getLiquidationBonus` is a ghost; `getReserve` a ghost underlying per reserve; the LPVault's
 * `unwind` pays some amounts of the market's two tokens to its recipient and records them; position, oracle and account
 * reads are NONDET. The RiskModule and LPVault `getMarket` reads are the storage mocks of the conf.
 */

import "setup/Erc20Model.spec";

using LiquidationRiskModuleMock as riskMock;
using LiquidationLPVaultMock as lpMock;

methods {
    function liquidate(ILiquidationModule.LiquidationParams) external returns (ILiquidationModule.LiquidationResult);

    // Tokens
    function _.balanceOf(address a) external => erc20BalanceOf(calledContract, a) expect uint256;
    function _.transfer(address to, uint256 a) external with (env e) => erc20Transfer(calledContract, e.msg.sender, to, a) expect bool;
    function _.transferFrom(address from, address to, uint256 a) external with (env e) => erc20TransferFrom(calledContract, e.msg.sender, from, to, a) expect bool;
    function _.approve(address s, uint256 a) external with (env e) => erc20Approve(calledContract, e.msg.sender, s, a) expect bool;
    function _.burn(address from, uint256 a) external => vaultTokenBurn(calledContract, from, a) expect void;
    function _.decimals() external => NONDET;
    // Spoke
    function _.liquidationCall(uint256 c, uint256 d, address user, uint256 debtToCover, bool rs) external with (env e) => aaveLiquidation(calledContract, e.msg.sender, c, d, user, debtToCover, rs) expect void;
    function _.getLiquidationBonus(uint256, address, uint256) external => liquidationBonus expect uint256;
    function _.getReserve(uint256 id) external => spokeReserve(id) expect (IAaveV4Spoke.Reserve);
    function _.getUserAccountData(address) external => NONDET;
    function _.getUserSuppliedAssets(uint256, address) external => NONDET;
    // LPVault
    function _.unwind(bytes32, uint128 credit, uint256, uint256, address recipient) external => vaultUnwind(credit, recipient) expect (uint128, uint128, uint256, uint256);
    function _.positionsOf(address) external => NONDET;
    function _.getPosition(bytes32) external => NONDET;
    function _.positionInfo(bytes32) external => NONDET;
    // LPOracle
    function _.getPrices() external => NONDET;
    function _.tokens() external => NONDET;
    function _.getUnitAmounts() external => NONDET;
    function _.unitDecimals() external => NONDET;
}

definition BPS() returns mathint = 10000;

// ---------------------------------------------------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------------------------------------------------

persistent ghost uint256 liquidationBonus;
persistent ghost mapping(uint256 => address) reserveUnderlying;
// The market of the liquidation under check; the unwind and seizure models pay that market's tokens.
persistent ghost uint256 liqMarket;

persistent ghost mathint liqCalls;
persistent ghost address liqUser;
persistent ghost uint256 liqCollateralReserve;
persistent ghost bool liqReceiveShares;
persistent ghost mathint unwound0;
persistent ghost mathint unwound1;

function spokeReserve(uint256 id) returns IAaveV4Spoke.Reserve {
    IAaveV4Spoke.Reserve r;
    require r.underlying == reserveUnderlying[id];
    return r;
}

function aaveLiquidation(address spoke, address caller, uint256 c, uint256 d, address user, uint256 debtToCover, bool rs) {
    liqCalls = liqCalls + 1;
    liqUser = user;
    liqCollateralReserve = c;
    liqReceiveShares = rs;
    uint256 repaid;
    require repaid <= debtToCover;
    erc20Move(reserveUnderlying[d], caller, spoke, repaid);
    uint256 seized;
    erc20Credit(riskMock._markets[liqMarket].vaultToken, caller, seized);
}

function vaultUnwind(uint128 credit, address recipient) returns (uint128, uint128, uint256, uint256) {
    uint128 liquidity;
    uint128 removed;
    uint256 a0;
    uint256 a1;
    require removed <= credit;
    erc20Credit(lpMock._markets[liqMarket].token0, recipient, a0);
    erc20Credit(lpMock._markets[liqMarket].token1, recipient, a1);
    unwound0 = unwound0 + a0;
    unwound1 = unwound1 + a1;
    return (liquidity, removed, a0, a1);
}

function startLiquidation(env e, ILiquidationModule.LiquidationParams p) {
    liqMarket = p.marketId;
    liqCalls = 0;
    unwound0 = 0;
    unwound1 = 0;
    require e.msg.sender != currentContract;
}

// The four tokens a liquidation moves are distinct, and no party is the module itself.
function requireDistinctParties(env e, ILiquidationModule.LiquidationParams p) {
    address vt = riskMock._markets[p.marketId].vaultToken;
    address debt = reserveUnderlying[p.debtReserveId];
    address t0 = lpMock._markets[p.marketId].token0;
    address t1 = lpMock._markets[p.marketId].token1;
    require vt != debt && vt != t0 && vt != t1 && debt != t0 && debt != t1 && t0 != t1;
    require riskMock.feeRecipient != currentContract;
}

// ---------------------------------------------------------------------------------------------------------------------
// Only below health 1: through Aave
// ---------------------------------------------------------------------------------------------------------------------

rule liquidateGoesThroughAaveLiquidationCall(ILiquidationModule.LiquidationParams p) {
    env e;
    startLiquidation(e, p);
    ILiquidationModule.LiquidationResult r = liquidate(e, p);
    assert liqCalls == 1 && liqUser == p.account, "the liquidation did not go through one Aave liquidationCall";
    assert liqCollateralReserve == riskMock._markets[p.marketId].reserveId && !liqReceiveShares,
        "the liquidationCall named another collateral reserve or received shares";
    assert r.seized > 0, "a liquidation completed without a seizure";
}

// ---------------------------------------------------------------------------------------------------------------------
// The partial unwind
// ---------------------------------------------------------------------------------------------------------------------

rule unwindCreditAtMostSeizedUnits(uint256 units, uint256 credit, uint256 cap) {
    env e;
    require 0 < cap && units <= cap && credit <= cap;
    uint256 c = creditFor(e, units, credit, cap);
    assert c <= units, "the unwind removes more credit than the units seized";
    assert c <= credit, "the unwind removes more than the position's credit";
}

// ---------------------------------------------------------------------------------------------------------------------
// The fee
// ---------------------------------------------------------------------------------------------------------------------

rule feeIsShareOfBonus(uint256 seized, uint256 bonusBps, uint256 shareBps) {
    env e;
    require to_mathint(shareBps) <= BPS();
    mathint fee = feeUnits(e, seized, bonusBps, shareBps);
    mathint bonusUnits = bonusBps > BPS() ? (seized * (bonusBps - BPS())) / bonusBps : 0;
    assert fee == (bonusUnits * shareBps) / BPS(), "the fee is not the share of the bonus units";
    assert to_mathint(bonusBps) <= BPS() => fee == 0, "a fee was taken without a bonus";
    assert shareBps == 2000 => fee * 5 <= bonusUnits, "at 20% the fee exceeds a fifth of the bonus";
}

rule liquidationFeeIsTwentyPercentOfBonus(ILiquidationModule.LiquidationParams p) {
    env e;
    startLiquidation(e, p);
    require riskMock.feeShareBps == 2000 && riskMock.feeRecipient != 0;
    ILiquidationModule.LiquidationResult r = liquidate(e, p);
    assert r.feeUnits == feeUnits(e, r.seized, liquidationBonus, 2000), "the fee is not 20% of Aave's bonus";
}

rule feePartAtMostAmount(uint256 amount, uint256 fee, uint256 seized) {
    env e;
    require 0 < seized && fee <= seized;
    assert feePart(e, amount, fee, seized) <= amount, "the fee part exceeds the unwound amount";
}

// ---------------------------------------------------------------------------------------------------------------------
// No value leaks
// ---------------------------------------------------------------------------------------------------------------------

rule payoutIsEverythingUnwound(ILiquidationModule.LiquidationParams p) {
    env e;
    startLiquidation(e, p);
    requireDistinctParties(e, p);
    address vt = riskMock._markets[p.marketId].vaultToken;
    mathint burnedBefore = vtBurnedFrom[vt][currentContract];
    ILiquidationModule.LiquidationResult r = liquidate(e, p);
    assert r.amount0 + r.fee0 == unwound0 && r.amount1 + r.fee1 == unwound1,
        "unwound tokens did not all go to the receiver and the fee recipient";
    assert vtBurnedFrom[vt][currentContract] - burnedBefore == to_mathint(r.seized), "seized units were not all burned";
}

rule noValueLeaks(ILiquidationModule.LiquidationParams p, address t) {
    env e;
    startLiquidation(e, p);
    requireDistinctParties(e, p);
    mathint before = erc20Bal[t][currentContract];
    liquidate(e, p);
    assert erc20Bal[t][currentContract] == before, "the module kept or lost tokens in a liquidation";
}
