// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPOracleMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The market-count limit (REQ-MREG-034): `listCollateralMarket` refuses a new market whose identifier would
/// exceed `MAX_MARKET_COUNT`; Cancelled and Closed markets keep their identifiers and count; a relisting reuses its
/// identifier and is not counted again; no listing path assigns an identifier past the limit. The registry here is
/// built with a limit of 3.
contract MarketRegistryMarketCountUnitTest is MarketRegistryFixture {
    uint256 internal constant CAP = 3;

    function _maxMarketCount() internal pure override returns (uint256) {
        return CAP;
    }

    function setUp() public {
        _setUpWorld();
    }

    function _shapeOf(
        uint256 n
    ) internal pure returns (PositionShape memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 half = int24(int256(50 + 10 * n));
        return PositionShape(ShapeKind.TickRange, -half, half);
    }

    /// @dev The vault token and LPOracle of a market carrying `marketId`, on its own tick range `n`.
    function _defFor(
        uint256 marketId,
        uint256 n
    ) internal returns (MarketDef memory d) {
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(marketId, _shapeOf(n));
        d = _marketDef(vt, address(o));
        d.shape = _shapeOf(n);
    }

    function _list(
        MarketDef memory d
    ) internal returns (uint256 id) {
        vm.prank(address(timelock));
        id = registry.listCollateralMarket(d);
    }

    function _fill() internal {
        for (uint256 n = 1; n <= CAP; ++n) {
            assertEq(_list(_defFor(n, n)), n);
        }
    }

    function _expectCapped(
        MarketDef memory d
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.MarketCountLimit.selector, CAP));
        registry.listCollateralMarket(d);
    }

    // TEST-138 verifies: REQ-MREG-034, REQ-CONFIG-078, REQ-CONFIG-005
    // Sources: decisions of 2026-11-11 (market-count bound, enforced at registration)
    // Kills: removing the `MarketCountLimit` check in `_preflight` lets market 4 in.
    function test_TEST_138_listsUpToTheLimitAndRefusesTheNext() public {
        assertEq(registry.MAX_MARKET_COUNT(), CAP);
        _fill();
        assertEq(registry.marketCount(), CAP);
        _expectCapped(_defFor(CAP + 1, CAP + 1));
        assertEq(registry.marketCount(), CAP);
    }

    // TEST-138 verifies: REQ-MREG-034, REQ-CONFIG-048, REQ-CONFIG-080
    // Cancelled and Closed markets keep their identifiers inside 1..marketCount, which the ParameterStore walks, so
    // they still count: with market 1 Closed and market 2 Cancelled a new pair is still refused.
    function test_TEST_138_closedAndCancelledMarketsStillCount() public {
        _fill();
        _prepareActivation(1, registry.getMarket(1).vaultToken);
        vm.startPrank(address(timelock));
        registry.activateMarket(1);
        registry.setMarketOffboarding(1);
        registry.cancelRegistration(2);
        vm.stopPrank();
        vm.warp(block.timestamp + 5 days);
        registry.closeMarket(1);
        assertTrue(registry.getMarket(1).status == MarketStatus.Closed);
        assertTrue(registry.getMarket(2).status == MarketStatus.Cancelled);
        _expectCapped(_defFor(CAP + 1, CAP + 1));
    }

    // TEST-252 verifies: REQ-MREG-034, REQ-MREG-030
    // A relisting at the limit reuses its reserved identifier and adds nothing to the count, so it is accepted.
    function test_TEST_252_relistingAtTheLimitIsNotCounted() public {
        _fill();
        MarketDef memory d3 = _marketDef(registry.getMarket(3).vaultToken, registry.getMarket(3).lpOracle);
        d3.shape = _shapeOf(3);
        vm.prank(address(timelock));
        registry.cancelRegistration(3);
        assertEq(_list(d3), 3);
        assertEq(registry.marketCount(), CAP);
        assertTrue(registry.getMarket(3).status == MarketStatus.Registered);
    }

    // TEST-138 verifies: REQ-MREG-034, REQ-MREG-030, REQ-CONFIG-032
    // No path assigns an identifier past the limit: a new market takes `marketCount + 1` (refused above the limit), a
    // relisting needs a Cancelled market at or below `marketCount`, and a token carrying any other identifier is
    // refused before the limit is read.
    function test_TEST_138_noListingPathPassesTheLimit() public {
        _fill();
        // A token carrying marketCount + 2: neither the next identifier nor a cancelled one.
        _expectMismatch(_defFor(CAP + 2, CAP + 2));
        // A token carrying a live (Registered) identifier: not a relisting.
        MarketDef memory live = _marketDef(registry.getMarket(2).vaultToken, registry.getMarket(2).lpOracle);
        live.shape = _shapeOf(2);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.DuplicateMarketKey.selector);
        registry.listCollateralMarket(live);
        _expectCapped(_defFor(CAP + 1, CAP + 1));
        assertEq(registry.marketCount(), CAP);
    }

    function _expectMismatch(
        MarketDef memory d
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
        registry.listCollateralMarket(d);
    }
}
