/*
 * Uniswap v3 integration, the Uniswap v3 LPVault (interface src/amm/uniswap-v3/IUniswapV3Integration.sol, IClIntegration, IAmmIntegration).
 *
 * Exact range match: a market fixes one (pool, tickLower, tickUpper). A unit of liquidity is worth a different amount
 * on every range (a ±1-tick NFT credited at the value per unit of a [0.90, 1.10] market is quoted ×979, z3 check
 * AMM-A6c), so the integration accepts a position only when both ticks equal the market's, never when they merely lie
 * inside it.
 *
 * The position manager's `positions` is summarised by ghosts keyed by tokenId; only the two ticks are read.
 * The implementation is src/amm/uniswap-v3/UniswapV3Integration.sol on the shared base src/amm/concentrated-liquidity/.
 */

methods {
    function clMarket(uint256) external returns (ClMarketConfig) envfree;
    function tokenIdOf(bytes32) external returns (uint256) envfree;
    function validatePosition(uint256, address, bytes32) external returns (uint128) envfree;
    function receivePosition(uint256, address, bytes32) external returns (uint128);
    function _.positions(uint256 id) external => nfpmPositions(id)
        expect (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128);
}

ghost mapping(uint256 => int24) ghostTickLower;
ghost mapping(uint256 => int24) ghostTickUpper;
ghost mapping(uint256 => uint128) ghostLiquidity;

function nfpmPositions(uint256 id)
    returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128) {
    uint96 nonce; address operator; address token0; address token1; uint24 fee;
    uint256 fg0; uint256 fg1; uint128 owed0; uint128 owed1;
    return (nonce, operator, token0, token1, fee, ghostTickLower[id], ghostTickUpper[id], ghostLiquidity[id],
            fg0, fg1, owed0, owed1);
}

// PROP-083 verifies: INV-005, REQ-AMM-CORE-006, REQ-AMM-CORE-016
rule validatePositionRequiresExactRange(uint256 marketId, address owner, bytes32 positionKey) {
    uint256 tokenId = tokenIdOf(positionKey);

    validatePosition(marketId, owner, positionKey);

    UniswapV3Integration.ClMarketConfig m = clMarket(marketId);
    assert ghostTickLower[tokenId] == m.tickLower && ghostTickUpper[tokenId] == m.tickUpper,
        "a position whose ticks differ from the market's exact range was accepted";
}

// PROP-083 verifies: INV-005, REQ-AMM-CORE-006, REQ-AMM-CORE-016
rule receivePositionRequiresExactRange(uint256 marketId, address owner, bytes32 positionKey) {
    env e;
    uint256 tokenId = tokenIdOf(positionKey);
    UniswapV3Integration.ClMarketConfig m = clMarket(marketId);

    receivePosition(e, marketId, owner, positionKey);

    assert ghostTickLower[tokenId] == m.tickLower && ghostTickUpper[tokenId] == m.tickUpper,
        "a position whose ticks differ from the market's exact range was taken into custody";
}
