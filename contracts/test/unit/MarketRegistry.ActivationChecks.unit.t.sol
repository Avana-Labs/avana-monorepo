// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPOracleMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The activation checks one condition at a time where the other suites test only one side: the Hub asset
/// of the vault token, a paused reserve, each market parameter and cap, the Hub add cap rounded up, every LPOracle
/// state other than Live, and a failed activation leaving the market Registered with no identifiers.
contract MarketRegistryActivationChecksUnitTest is MarketRegistryFixture {
    uint256 internal id;
    address internal vt;
    RegistryLPOracleMock internal lpo;

    function setUp() public {
        _setUpWorld();
        (id, vt, lpo) = _listMarket();
        _prepareActivation(id, vt);
    }

    function _expectCheck(
        bytes32 check
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ActivationCheckFailed.selector, id, check));
        registry.activateMarket(id);
        _assertUntouched();
    }

    /// @dev REQ-CONFIG-066: a failed activation leaves the market Registered with no identifiers or index entries.
    function _assertUntouched() internal view {
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Registered));
        assertEq(registry.getMarket(id).hubAssetId, 0);
        assertEq(registry.getMarket(id).reserveId, 0);
        assertEq(registry.getMarket(id).activatedAt, 0);
        assertEq(registry.marketOfHubAsset(address(hub), VT_ASSET), 0);
        assertEq(registry.marketOfReserve(address(spoke), VT_RESERVE), 0);
        assertEq(registry.activeMarketCount(address(spoke)), 0);
    }

    function _activate() internal {
        vm.prank(address(timelock));
        registry.activateMarket(id);
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Active));
    }

    // TEST-138 verifies: REQ-CONFIG-042, REQ-CONFIG-066
    // Sources: 5.1 TEST-138
    // A vault token the home Hub does not list fails "hubAsset"; the Hub read's revert is reported, not bubbled.
    function test_TEST_138_vaultTokenNotOnTheHub() public {
        vm.mockCallRevert(address(hub), abi.encodeWithSignature("getAssetId(address)", vt), "AssetNotListed");
        _expectCheck("hubAsset");
        vm.clearMockedCalls();
        _activate();
    }

    // TEST-138 verifies: REQ-CONFIG-044, REQ-CONFIG-066
    // A paused reserve fails like a frozen one.
    function test_TEST_138_pausedReserveRefused() public {
        IAaveV4Spoke.ReserveConfig memory c;
        c.paused = true;
        spoke.setConfig(VT_RESERVE, c);
        _expectCheck("reserveState");
        c.paused = false;
        spoke.setConfig(VT_RESERVE, c);
        _activate();
    }

    // TEST-138 verifies: REQ-CONFIG-046, REQ-CONFIG-066
    // Each market parameter and cap must be set: poolRiskFactor and minPledgeUsd ("params"), marketUsdCap and
    // stressFloorUsd ("caps").
    function test_TEST_138_eachParameterAndCapRequired() public {
        ps.setMarket(id, 9500, 0, 1_000_000e8, 100_000e8, 1e8);
        _expectCheck("params");
        ps.setMarket(id, 0, 10e8, 1_000_000e8, 100_000e8, 1e8);
        _expectCheck("params");
        ps.setMarket(id, 9500, 10e8, 1_000_000e8, 100_000e8, 0);
        _expectCheck("caps");
        ps.setMarket(id, 9500, 10e8, 0, 100_000e8, 1e8);
        _expectCheck("caps");
        // A zero top-up slice is allowed.
        ps.setMarket(id, 9500, 10e8, 1_000_000e8, 0, 1e8);
        _activate();
    }

    // TEST-138 verifies: REQ-CONFIG-046, SPEC-CAP-006
    // The add cap is compared with ceil((marketUsdCap + topUpSliceUsd) / stressFloorUsd): with 1,100,000 USD over a
    // 3 USD floor the requirement is ceil(366,666.67) = 366,667 whole tokens; 366,666 fails, 366,667 passes.
    function test_TEST_138_addCapRoundsUp() public {
        ps.setMarket(id, 9500, 10e8, 1_000_000e8, 100_000e8, 3e8);
        hub.setSpokeConfig(VT_ASSET, address(spoke), 366_666, 0);
        _expectCheck("addCap");
        hub.setSpokeConfig(VT_ASSET, address(spoke), 366_667, 0);
        _activate();
    }

    // TEST-138 verifies: REQ-CONFIG-046, SPEC-CAP-006
    function testFuzz_TEST_138_addCapRuleExact(
        uint64 capSeed,
        uint64 sliceSeed,
        uint64 floorSeed,
        uint32 addCapSeed
    ) public {
        uint256 capUsd = bound(capSeed, 1, 1e18);
        uint256 slice = bound(sliceSeed, 0, 1e18);
        uint256 floorUsd = bound(floorSeed, 1, 1e12);
        uint40 addCap = uint40(bound(addCapSeed, 0, type(uint32).max));
        ps.setMarket(id, 9500, 10e8, capUsd, slice, floorUsd);
        hub.setSpokeConfig(VT_ASSET, address(spoke), addCap, 0);
        uint256 need = (capUsd + slice + floorUsd - 1) / floorUsd;
        if (addCap < need) {
            _expectCheck("addCap");
        } else {
            _activate();
        }
    }

    // TEST-138 verifies: REQ-CONFIG-047, REQ-CONFIG-038
    // Every LPOracle state other than Live fails "oracleLive".
    function test_TEST_138_everyNonLiveOracleStateRefused() public {
        PriceState[3] memory bad = [PriceState.Drifting, PriceState.Cached, PriceState.Expired];
        for (uint256 i = 0; i < 3; ++i) {
            lpo.setState(bad[i]);
            _expectCheck("oracleLive");
        }
        lpo.setState(PriceState.Live);
        _activate();
    }

    // TEST-138 verifies: REQ-CONFIG-047, REQ-CONFIG-038
    // An LPOracle whose state read reverts fails "oracleLive" (the read is a static call that fails closed).
    function test_TEST_138_unreadableOracleStateRefused() public {
        vm.mockCallRevert(address(lpo), abi.encodeWithSignature("getPriceState()"), "down");
        _expectCheck("oracleLive");
    }

    // TEST-138 verifies: REQ-CONFIG-047, REQ-CONFIG-027
    // An LPOracle that rejects the ParameterStore's configuration with any non-zero failure code fails "oracleConfig".
    function testFuzz_TEST_138_anyFailedConfigCheckRefused(
        uint256 failed
    ) public {
        lpo.setFailed(failed);
        if (failed == 0) {
            _activate();
        } else {
            _expectCheck("oracleConfig");
        }
    }

    // TEST-231 verifies: REQ-CONFIG-026, REQ-CONFIG-034, REQ-MREG-027
    // A price-source change is checked against a market that is only Registered too: re-pointing USDT's alternate at
    // USDC's standby feed breaks the common-mode guard of the listed USDC/USDT market and is refused, so the market
    // still activates.
    function test_TEST_231_priceSourceChangeGuardsARegisteredMarket() public {
        address[] memory usdcStandby = registry.getToken(address(usdc)).standbyRoute;
        (address[] memory p,, address[] memory s) = _routes("usdt2");
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("commonMode"))
        );
        registry.setPriceSource(address(usdt), p, usdcStandby, s);
        _activate();
    }

    // TEST-138 verifies: REQ-CONFIG-042, REQ-CONFIG-066, REQ-CONFIG-073
    // The drift and Hub-share checks run after the identifiers are written; a failure of either reverts the writes:
    // no identifier and no index entry is left.
    function test_TEST_138_failedAaveChecksWriteNothing() public {
        rm.setDrift(true);
        _expectCheck("aaveConfig");
        rm.setDrift(false);
        rm.setSharesEqual(false);
        _expectCheck("hubShares");
        rm.setSharesEqual(true);
        _activate();
        assertEq(registry.marketOfReserve(address(spoke), VT_RESERVE), id);
    }
}
