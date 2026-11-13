// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {IMarketRegistryWindDown} from "../../src/policy/market-registry/IMarketRegistryWindDown.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {WindDownState} from "../../src/policy/market-registry/types/WindDownState.sol";
import {Market} from "../../src/types/Market.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPOracleMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice Market lifecycle sequences: list, cancel, relist, activate, offboard, wind down and close, with the status
/// machine of every transition from every status, the indexes each step writes and frees, and the wind-down ramp at its
/// boundaries.
contract MarketRegistryLifecycleUnitTest is MarketRegistryFixture {
    /// @dev The second market's Hub asset and Spoke reserve, both different from the first market's (1 and 1).
    uint256 internal constant ASSET_2 = 7;
    uint256 internal constant RESERVE_2 = 5;

    uint256 internal id;
    address internal vt;
    RegistryLPOracleMock internal lpo;

    function setUp() public {
        _setUpWorld();
        (id, vt, lpo) = _listMarket();
        _prepareActivation(id, vt);
    }

    // ─── Helpers ───

    function _wide() internal pure returns (PositionShape memory) {
        return PositionShape(ShapeKind.TickRange, -100, 100);
    }

    function _wideDef(
        address token,
        address oracle
    ) internal view returns (MarketDef memory d) {
        d = _marketDef(token, oracle);
        d.shape = _wide();
    }

    function _activate(
        uint256 marketId
    ) internal {
        vm.prank(address(timelock));
        registry.activateMarket(marketId);
    }

    /// @dev Lists the `[-100, 100]` market as market 2.
    function _listSecond() internal returns (uint256 id2, address vt2, RegistryLPOracleMock o2) {
        (vt2, o2) = _deployTokenAndOracle(registry.marketCount() + 1, _wide());
        vm.prank(address(timelock));
        id2 = registry.listCollateralMarket(_wideDef(vt2, address(o2)));
    }

    /// @dev The Aave payload of market 2: Hub asset `ASSET_2`, Spoke reserve `RESERVE_2`, CF 7,000.
    function _prepareSecond(
        uint256 id2,
        address vt2
    ) internal {
        hub.setAsset(vt2, ASSET_2);
        hub.setSpokeConfig(ASSET_2, address(spoke), 2_000_000, 0);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (vt2, address(hub), uint16(ASSET_2), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (7000, 10_500);
        spoke.setReserve(RESERVE_2, r, c, d);
        ps.setMarket(id2, 9500, 10e8, 1_000_000e8, 100_000e8, 1e8);
        _setRoutesInto(id2, address(gho));
    }

    function _setCf(
        uint256 reserveId,
        uint16 cf
    ) internal {
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (cf, 10_500);
        spoke.setDynamic(reserveId, d);
    }

    function _status(
        uint256 marketId
    ) internal view returns (MarketStatus) {
        return registry.getMarket(marketId).status;
    }

    function _offboard(
        uint256 marketId
    ) internal returns (uint256 t0) {
        vm.prank(address(timelock));
        registry.setMarketOffboarding(marketId);
        t0 = block.timestamp;
    }

    // ─── Activation writes the market's own identifiers ───

    // TEST-138 verifies: REQ-CONFIG-007, REQ-CONFIG-042, REQ-CONFIG-043, REQ-CONFIG-073, REQ-MREG-031
    // Sources: 5.1 TEST-138
    function test_TEST_138_secondMarketWiresItsOwnAssetAndReserve() public {
        _activate(id);
        (uint256 id2, address vt2,) = _listSecond();
        assertEq(id2, 2);
        _prepareSecond(id2, vt2);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.MarketActivated(id2, block.chainid, address(spoke), RESERVE_2, address(hub), ASSET_2);
        _activate(id2);
        Market memory m = registry.getMarket(id2);
        assertEq(m.hubAssetId, ASSET_2);
        assertEq(m.reserveId, RESERVE_2);
        assertEq(m.activatedAt, block.timestamp);
        assertEq(registry.marketOfHubAsset(address(hub), ASSET_2), id2);
        assertEq(registry.marketOfReserve(address(spoke), RESERVE_2), id2);
        // The first market keeps its own pair.
        assertEq(registry.marketOfHubAsset(address(hub), VT_ASSET), id);
        assertEq(registry.marketOfReserve(address(spoke), VT_RESERVE), id);
        assertEq(registry.getMarket(id).reserveId, VT_RESERVE);
        uint256[] memory ids = registry.marketsOfSpoke(address(spoke));
        assertEq(ids.length, 2);
        assertEq(ids[0], id);
        assertEq(ids[1], id2);
        assertEq(registry.activeMarketCount(address(spoke)), 2);
        assertEq(registry.marketCount(), 2);
    }

    // TEST-138 verifies: REQ-CONFIG-007, REQ-CONFIG-042
    // A market whose Spoke reserve is held by a live market cannot activate, even on another Hub asset.
    function test_TEST_138_reserveHeldByLiveMarketBlocksActivation() public {
        _activate(id);
        (uint256 id2, address vt2,) = _listSecond();
        _prepareSecond(id2, vt2);
        // Point the second token's Hub asset at the first market's Spoke reserve.
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (vt2, address(hub), uint16(ASSET_2), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (7000, 10_500);
        spoke.setReserve(VT_RESERVE, r, c, d);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.DuplicateMarketKey.selector);
        registry.activateMarket(id2);
        assertEq(registry.getMarket(id2).reserveId, 0);
        assertEq(registry.marketOfHubAsset(address(hub), ASSET_2), 0);
    }

    // TEST-138 verifies: REQ-CONFIG-007, REQ-CONFIG-080
    // A Closed market frees its Hub asset and Spoke reserve keys for a later market.
    function test_TEST_138_closedMarketFreesItsReserveKeys() public {
        _activate(id);
        uint256 t0 = _offboard(id);
        vm.warp(t0 + 5 days);
        registry.closeMarket(id);
        (uint256 id2, address vt2,) = _listSecond();
        _prepareSecond(id2, vt2);
        // Reuse the closed market's Hub asset and reserve identifiers.
        hub.setAsset(vt2, VT_ASSET);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (vt2, address(hub), uint16(VT_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (7000, 10_500);
        spoke.setReserve(VT_RESERVE, r, c, d);
        _activate(id2);
        assertEq(registry.marketOfReserve(address(spoke), VT_RESERVE), id2);
        assertEq(registry.marketOfHubAsset(address(hub), VT_ASSET), id2);
        assertEq(registry.activeMarketCount(address(spoke)), 1);
    }

    // ─── Status machine ───

    /// @dev Markets in every status: 1 Registered, 2 Active, 3 Offboarding, 4 Cancelled, 5 Closed (by id), and an
    /// unknown id 99.
    function _marketsInEveryStatus() internal returns (uint256[6] memory ids) {
        // id 1 stays Registered.
        ids[1] = id;
        // id 2 Active.
        (uint256 a,,) = _listMarketWith(PositionShape(ShapeKind.TickRange, -10, 10), 11, 11);
        _activate(a);
        ids[2] = a;
        // id 3 Offboarding.
        (uint256 o,,) = _listMarketWith(PositionShape(ShapeKind.TickRange, -20, 20), 12, 12);
        _activate(o);
        _offboard(o);
        ids[3] = o;
        // id 4 Cancelled.
        (uint256 c,,) = _listMarketWith(PositionShape(ShapeKind.TickRange, -30, 30), 13, 13);
        vm.prank(address(timelock));
        registry.cancelRegistration(c);
        ids[4] = c;
        // id 5 Closed.
        (uint256 z,,) = _listMarketWith(PositionShape(ShapeKind.TickRange, -40, 40), 14, 14);
        _activate(z);
        uint256 t0 = _offboard(z);
        vm.warp(t0 + 5 days);
        registry.closeMarket(z);
        ids[5] = z;
        ids[0] = 99;
    }

    /// @dev Lists a market of `shape` with its Aave payload at Hub asset and Spoke reserve `slot`.
    function _listMarketWith(
        PositionShape memory shape,
        uint256 assetId,
        uint256 reserveId
    ) internal returns (uint256 m, address token, RegistryLPOracleMock o) {
        (token, o) = _deployTokenAndOracle(registry.marketCount() + 1, shape);
        MarketDef memory d = _marketDef(token, address(o));
        d.shape = shape;
        vm.prank(address(timelock));
        m = registry.listCollateralMarket(d);
        hub.setAsset(token, assetId);
        hub.setSpokeConfig(assetId, address(spoke), 2_000_000, 0);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (token, address(hub), uint16(assetId), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory dc;
        (dc.collateralFactor, dc.maxLiquidationBonus) = (7000, 10_500);
        spoke.setReserve(reserveId, r, c, dc);
        ps.setMarket(m, 9500, 10e8, 1_000_000e8, 100_000e8, 1e8);
        _setRoutesInto(m, address(gho));
    }

    // TEST-213 verifies: REQ-CONFIG-042, REQ-CONFIG-048, REQ-MREG-015, REQ-CONFIG-080, Q-227, Q-355, REQ-ACCESS-134, REQ-ACCESS-036
    // Sources: 5.1 TEST-213, TEST-138
    function test_TEST_213_everyTransitionFromEveryStatus() public {
        uint256[6] memory ids = _marketsInEveryStatus();
        // Status order: None (unknown), Registered, Active, Offboarding, Cancelled, Closed.
        for (uint256 s = 0; s < 6; ++s) {
            uint256 m = ids[s];
            assertEq(uint8(_status(m)), uint8(s), "status of the prepared market");
            vm.warp(block.timestamp + 6 days);
            _expectTransition(abi.encodeCall(registry.activateMarket, (m)), s == 1, _err("reg", m));
            _expectTransition(abi.encodeCall(registry.cancelRegistration, (m)), s == 1, _err("reg", m));
            _expectTransition(abi.encodeCall(registry.setMarketOffboarding, (m)), s == 2, _err("active", m));
            _expectTransition(abi.encodeCall(registry.closeMarket, (m)), s == 3, _err("offboarding", m));
        }
    }

    function _err(
        string memory kind,
        uint256 m
    ) internal pure returns (bytes memory) {
        if (keccak256(bytes(kind)) == keccak256("reg")) {
            return abi.encodeWithSelector(IMarketRegistryErrors.MarketNotRegistered.selector, m);
        }
        if (keccak256(bytes(kind)) == keccak256("active")) {
            return abi.encodeWithSelector(IMarketRegistryErrors.MarketNotActive.selector, m);
        }
        return abi.encodeWithSelector(IMarketRegistryWindDown.MarketNotOffboarding.selector, m);
    }

    /// @dev Runs `data` as the timelock from a snapshot: it succeeds when `ok`, else reverts with exactly `err`.
    function _expectTransition(
        bytes memory data,
        bool ok,
        bytes memory err
    ) internal {
        uint256 snap = vm.snapshotState();
        vm.prank(address(timelock));
        (bool success, bytes memory ret) = address(registry).call(data);
        vm.revertToState(snap);
        assertEq(success, ok, "transition admitted against the status machine");
        if (!ok) assertEq(ret, err, "status error");
    }

    // TEST-213 verifies: REQ-MREG-031, REQ-MREG-015, REQ-CONFIG-080
    // activeMarketCount counts exactly the Active and Offboarding markets of the Spoke.
    function test_TEST_213_activeCountOverEveryStatus() public {
        _marketsInEveryStatus();
        assertEq(registry.activeMarketCount(address(spoke)), 2, "Active and Offboarding only");
        assertEq(registry.activeMarketCount(alice), 0, "unknown Spoke");
        assertEq(registry.marketsOfSpoke(address(spoke)).length, 5, "every listed market stays in the Spoke list");
    }

    // ─── Cancel and relist ───

    // TEST-252 verifies: REQ-CONFIG-048, REQ-CONFIG-007, REQ-MREG-030, Q-265
    // Sources: 5.1 TEST-252, TEST-138
    function test_TEST_252_cancelFreesTheListingIndexes() public {
        Market memory m = registry.getMarket(id);
        bytes32 key = factory.marketKeyOf(V3, pool, bytes32(0), _shape());
        assertEq(registry.marketOfKey(key), id);
        assertEq(registry.marketOfVaultToken(vt), id);
        assertEq(registry.marketOfLpOracle(address(lpo)), id);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.MarketRegistrationCancelled(id);
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        assertEq(registry.marketOfKey(key), 0, "key freed");
        assertEq(registry.marketOfVaultToken(vt), 0, "vault token freed");
        assertEq(registry.marketOfLpOracle(address(lpo)), 0, "LPOracle freed");
        Market memory c = registry.getMarket(id);
        assertEq(uint8(c.status), uint8(MarketStatus.Cancelled));
        // The cancelled record keeps its immutable fields; the identifier stays reserved.
        assertEq(c.vaultToken, m.vaultToken);
        assertEq(c.lpOracle, m.lpOracle);
        assertEq(c.registeredAt, m.registeredAt);
        assertEq(registry.marketCount(), 1);
        assertEq(registry.marketsOfSpoke(address(spoke)).length, 1);
        assertEq(registry.activeMarketCount(address(spoke)), 0);
    }

    // TEST-252 verifies: REQ-MREG-030, REQ-CONFIG-007, REQ-CONFIG-048
    // A relisting takes the reserved identifier back, rewrites the indexes and does not grow the market count or the
    // Spoke's list; a new market listed after it takes the next identifier.
    function test_TEST_252_relistReclaimsTheIdAndIndexes() public {
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(timelock));
        uint256 again = registry.listCollateralMarket(_marketDef(vt, address(lpo)));
        assertEq(again, id);
        bytes32 key = factory.marketKeyOf(V3, pool, bytes32(0), _shape());
        assertEq(registry.marketOfKey(key), id);
        assertEq(registry.marketOfVaultToken(vt), id);
        assertEq(registry.marketOfLpOracle(address(lpo)), id);
        assertEq(uint8(_status(id)), uint8(MarketStatus.Registered));
        assertEq(registry.getMarket(id).registeredAt, block.timestamp, "registration time restarts");
        assertEq(registry.marketCount(), 1);
        assertEq(registry.marketsOfSpoke(address(spoke)).length, 1);
        (uint256 id2,,) = _listSecond();
        assertEq(id2, 2);
    }

    // TEST-252 verifies: REQ-MREG-030, REQ-CONFIG-080
    // Only a Cancelled registration can be relisted: a Closed market's (Spoke, market key) pair is retired, because the
    // factory's token for the pair still carries the closed identifier.
    function test_TEST_252_closedMarketCannotBeRelisted() public {
        _activate(id);
        uint256 t0 = _offboard(id);
        vm.warp(t0 + 5 days);
        registry.closeMarket(id);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
        registry.listCollateralMarket(_marketDef(vt, address(lpo)));
    }

    // TEST-252 verifies: REQ-MREG-030, REQ-CONFIG-007
    // While a registration is live its key, token and LPOracle stay taken: a second listing of the same definition is
    // a duplicate.
    function test_TEST_252_liveRegistrationKeepsItsKey() public {
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.DuplicateMarketKey.selector);
        registry.listCollateralMarket(_marketDef(vt, address(lpo)));
        _activate(id);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.DuplicateMarketKey.selector);
        registry.listCollateralMarket(_marketDef(vt, address(lpo)));
        _offboard(id);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.DuplicateMarketKey.selector);
        registry.listCollateralMarket(_marketDef(vt, address(lpo)));
    }

    // TEST-213 verifies: REQ-CONFIG-048, REQ-MREG-030, REQ-CONFIG-042, REQ-MREG-015, REQ-CONFIG-080, REQ-MREG-031
    // The whole life of one market: list, cancel, relist, activate, offboard, wind down, close; the Spoke's live count
    // and the status after every step.
    function test_TEST_213_fullLifeOfOneMarket() public {
        assertEq(registry.activeMarketCount(address(spoke)), 0);
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        vm.prank(address(timelock));
        registry.listCollateralMarket(_marketDef(vt, address(lpo)));
        _setRoutesInto(id, address(gho));
        _activate(id);
        assertEq(uint8(_status(id)), uint8(MarketStatus.Active));
        assertEq(registry.activeMarketCount(address(spoke)), 1);
        vm.warp(block.timestamp + 100 days);
        uint256 t0 = _offboard(id);
        assertEq(uint8(_status(id)), uint8(MarketStatus.Offboarding));
        assertEq(registry.activeMarketCount(address(spoke)), 1);
        // The Aave DAO lowers the threshold once after the notice in its own payload; the registry only publishes the
        // target and the date, and closes the market once it is debt-free.
        assertEq(registry.windDownState(id).targetLtBps, 3750, "half of the 7,500 bps threshold");
        vm.warp(t0 + 5 days);
        registry.closeMarket(id);
        assertEq(uint8(_status(id)), uint8(MarketStatus.Closed));
        assertEq(registry.activeMarketCount(address(spoke)), 0);
        // The closed market keeps its record and its token binding.
        assertEq(registry.getMarket(id).vaultToken, vt);
        assertEq(registry.marketOfVaultToken(vt), id);
    }

    // ─── Offboarding notice and the one-step target ───

    // TEST-213 verifies: REQ-MREG-015, REQ-CONFIG-080, Q-355
    // Offboarding records the collateral factor of the reserve's latest dynamic key at that moment, after any Aave
    // change since activation, and publishes the one target, half of it.
    function test_TEST_213_offboardingRecordsTheCurrentCollateralFactor() public {
        _activate(id);
        _setCf(VT_RESERVE, 6100);
        vm.warp(3_000_000);
        uint256 t0 = _offboard(id);
        WindDownState memory w = registry.windDownState(id);
        assertEq(w.offboardedAt, t0);
        assertEq(w.unusedLastStepAt, 0, "the former ramp field stays 0");
        assertEq(w.startLtBps, 6100);
        assertEq(w.targetLtBps, 3050, "one drop to half: 6,100 x 5,000 / 10,000");
    }

    // TEST-213 verifies: REQ-CONFIG-080
    // The target rounds down: an odd threshold of 4,201 bps halves to 2,100.
    function test_TEST_213_targetRoundsDown() public {
        _setCf(VT_RESERVE, 5000);
        _activate(id);
        _setCf(VT_RESERVE, 4201);
        _offboard(id);
        WindDownState memory w = registry.windDownState(id);
        assertEq(w.startLtBps, 4201);
        assertEq(w.targetLtBps, 2100);
    }

    // TEST-213 verifies: REQ-CONFIG-080
    function testFuzz_TEST_213_targetIsHalfTheStart(
        uint16 startCf
    ) public {
        startCf = uint16(bound(startCf, 1, 9999));
        _activate(id);
        _setCf(VT_RESERVE, startCf);
        _offboard(id);
        WindDownState memory w = registry.windDownState(id);
        assertEq(w.startLtBps, startCf);
        assertEq(w.targetLtBps, uint256(startCf) * 5000 / 10_000);
        assertEq(w.unusedLastStepAt, 0);
    }

    // TEST-213 verifies: REQ-CONFIG-080
    // The registry has no ramp entry point any more: the old `stepWindDown()` selector reaches no function.
    function test_TEST_213_noRampEntryPoint() public {
        _activate(id);
        uint256 t0 = _offboard(id);
        vm.warp(t0 + 40 days);
        (bool ok,) = address(registry).call(abi.encodeWithSignature("stepWindDown(uint256)", id));
        assertFalse(ok, "stepWindDown is gone");
        assertEq(registry.windDownState(id).targetLtBps, 3750, "nothing moved the record");
    }

    // TEST-213 verifies: REQ-CONFIG-080, REQ-COLL-040, Q-355
    // A debt-free market closes exactly when the notice ends, by any caller, without any ramp step.
    function test_TEST_213_closeAtTheNoticeBoundaryWithoutSteps() public {
        _activate(id);
        uint256 t0 = _offboard(id);
        vm.warp(t0 + 5 days);
        vm.expectEmit(address(registry));
        emit IMarketRegistryWindDown.MarketClosed(id);
        vm.prank(makeAddr("anyone"));
        registry.closeMarket(id);
        assertEq(registry.windDownState(id).unusedLastStepAt, 0, "close needs no step");
    }

    // TEST-213 verifies: REQ-CONFIG-080, REQ-COLL-040
    // Open debt blocks the close at any time; repaying it lets the close through.
    function test_TEST_213_debtBlocksCloseUntilRepaid() public {
        _activate(id);
        uint256 t0 = _offboard(id);
        collat.setHasDebt(vt, true);
        for (uint256 d = 5; d <= 365; d += 120) {
            vm.warp(t0 + d * 1 days);
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.MarketHasDebt.selector, id));
            registry.closeMarket(id);
        }
        collat.setHasDebt(vt, false);
        registry.closeMarket(id);
        assertEq(uint8(_status(id)), uint8(MarketStatus.Closed));
    }

    // TEST-213 verifies: REQ-CONFIG-080
    // The notice is checked before the debt: an indebted market closed too early reports the time.
    function test_TEST_213_closeChecksTheNoticeBeforeTheDebt() public {
        _activate(id);
        uint256 t0 = _offboard(id);
        collat.setHasDebt(vt, true);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.OffboardNoticeRunning.selector, t0 + 5 days));
        registry.closeMarket(id);
    }
}
