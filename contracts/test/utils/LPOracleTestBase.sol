// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracle} from "../../src/LPOracle.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {BandTestFeed, BandTestPriceSpoke, BandTestToken, BandTestVault} from "./mocks/BandOracleMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice An LPVault stand-in and an Aave V4 price Spoke on the real pinned `AaveOracle`, with helpers to list a token
/// there and build an LPOracle on it.
abstract contract LPOracleTestBase is Test {
    BandTestVault internal vault;
    BandTestPriceSpoke internal priceSpoke;

    function _setUpPriceSpoke() internal {
        vault = new BandTestVault();
        priceSpoke = new BandTestPriceSpoke(8);
        priceSpoke.init();
    }

    /// @notice A new token listed on the price Spoke with an 8-decimal source at `price`.
    function _listed(
        string memory symbol,
        uint8 decimals,
        int256 price
    ) internal returns (BandTestToken token, BandTestFeed source, uint256 reserveId) {
        token = new BandTestToken(symbol, decimals);
        source = new BandTestFeed(8, price);
        reserveId = priceSpoke.addReserve(address(token), decimals, address(source));
    }

    function _params(
        uint256 marketId,
        uint256 reserveId0,
        uint256 reserveId1
    ) internal view returns (ILPOracle.Params memory) {
        return ILPOracle.Params({
            lpVault: address(vault),
            marketId: marketId,
            unitDecimals: 18,
            priceSpoke: address(priceSpoke),
            reserveId0: reserveId0,
            reserveId1: reserveId1,
            description: "Avana band unit"
        });
    }

    function _oracle(
        uint256 marketId,
        uint256 reserveId0,
        uint256 reserveId1
    ) internal returns (LPOracle) {
        return new LPOracle(_params(marketId, reserveId0, reserveId1));
    }

    function _answer(
        LPOracle o
    ) internal view returns (uint256) {
        return uint256(o.latestAnswer());
    }
}
