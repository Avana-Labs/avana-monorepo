// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracle} from "../../src/LPOracle.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {UniswapV2TestBase} from "../utils/UniswapV2TestBase.sol";
import {BandTestFeed, BandTestPriceSpoke} from "../utils/mocks/BandOracleMocks.sol";
import {MintableToken} from "../utils/mocks/UniswapV3Mocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The Uniswap v2 Full range market end to end on a v2-core pair: the unchanged full-range LPOracle prices the
/// √k credit, an attacker pushes the pair's price far from Aave's, and the in-kind liquidation still pays at least
/// the collateral value the oracle reported.
contract LPVaultUniswapV2IntegrationTest is UniswapV2TestBase {
    uint256 internal constant ETH_PRICE = 2000e8;
    uint256 internal constant USD_PRICE = 1e8;

    MintableToken internal eth;
    MintableToken internal usd;
    LPOracle internal oracle;

    function setUp() public {
        eth = new MintableToken("WETH", 18);
        usd = new MintableToken("USDC", 18);
        (uint256 seedEth, uint256 seedUsd) = (100e18, 200_000e18);
        bool ethFirst = address(eth) < address(usd);
        _deploy(address(eth), address(usd), ethFirst ? seedEth : seedUsd, ethFirst ? seedUsd : seedEth);
        BandTestPriceSpoke priceSpoke = new BandTestPriceSpoke(8);
        priceSpoke.init();
        uint256 ethId = priceSpoke.addReserve(address(eth), 18, address(new BandTestFeed(8, int256(ETH_PRICE))));
        uint256 usdId = priceSpoke.addReserve(address(usd), 18, address(new BandTestFeed(8, int256(USD_PRICE))));
        oracle = new LPOracle(
            ILPOracle.Params({
                lpVault: address(vault),
                marketId: FULL,
                unitDecimals: 18,
                priceSpoke: address(priceSpoke),
                reserveId0: ethFirst ? ethId : usdId,
                reserveId1: ethFirst ? usdId : ethId,
                description: "UNI-V2 WETH/USDC Full range"
            })
        );
    }

    function test_priceMoveThenInKindLiquidation_paysAtLeastTheOracleValue() public {
        bool ethFirst = t0 == address(eth);
        (bytes32 key, uint128 credit) = _position(user, ethFirst ? 10e18 : 20_000e18, ethFirst ? 20_000e18 : 10e18);
        uint256 answer = uint256(oracle.latestAnswer());
        uint256 collateral = Math.mulDiv(credit, answer, 1e18);
        // 10 ETH + 20,000 USDC is $40,000; the full-range oracle values it a hair under that, never above.
        assertLe(collateral, 40_000e8);
        assertGe(collateral, 39_990e8);

        // The attacker dumps 300 ETH into the pair: the pool price drops ~16x, Aave's does not.
        _swap(attacker, ethFirst, 300e18);
        assertEq(uint256(oracle.latestAnswer()), answer);
        assertEq(vault.getPosition(key).credit, credit);

        // Liquidation in kind at the manipulated reserves: the tokens paid are worth at least the credit's oracle value.
        vm.prank(adapter);
        (,, uint256 a0, uint256 a1) = vault.unwind(key, credit, 0, 0, recipient);
        (uint256 ethOut, uint256 usdOut) = ethFirst ? (a0, a1) : (a1, a0);
        uint256 paid = (ethOut * ETH_PRICE + usdOut * USD_PRICE) / 1e18;
        assertGe(paid, collateral);
        assertEq(eth.balanceOf(recipient), ethOut);
        assertEq(usd.balanceOf(recipient), usdOut);
        assertEq(vault.getPosition(key).credit, 0);
    }
}
