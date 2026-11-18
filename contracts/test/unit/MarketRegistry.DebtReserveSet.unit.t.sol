// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {
    RegistryAvanaFirstLossReserveMock,
    RegistryDebtOracleMock,
    RegistryLPOracleMock
} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The enabled debt-reserve set of one CDP Spoke with three reserves (GHO at id 0, USDC at id 5, USDT at
/// id 9): the stored record field by field, the order of `debtReserveIds` through removals and re-enablement, the
/// credit-line sums, the settlement reserve a new market takes, and the boundaries of the price-source, flash and
/// coverage checks.
contract MarketRegistryDebtReserveSetUnitTest is MarketRegistryFixture {
    uint256 internal constant USDC_RESERVE = 5;
    uint256 internal constant USDC_ASSET = 2;
    uint256 internal constant USDT_RESERVE = 9;
    uint256 internal constant USDT_ASSET = 3;

    RegistryDebtOracleMock internal usdcOracle;
    RegistryDebtOracleMock internal usdtOracle;
    RegistryAvanaFirstLossReserveMock internal usdcCoverage;
    RegistryAvanaFirstLossReserveMock internal usdtCoverage;

    function setUp() public {
        _setUpWorld();
        (usdcOracle, usdcCoverage) = _prepareStable(address(usdc), USDC_RESERVE, USDC_ASSET, 500_000);
        (usdtOracle, usdtCoverage) = _prepareStable(address(usdt), USDT_RESERVE, USDT_ASSET, 300_000);
    }

    /// @dev The Aave reserve, AaveOracle source, DebtOracle, First-Loss Reserve and credit line of a 6-decimal stablecoin.
    function _prepareStable(
        address token,
        uint256 reserveId,
        uint256 assetId,
        uint40 drawCap
    ) internal returns (RegistryDebtOracleMock o, RegistryAvanaFirstLossReserveMock cs) {
        o = new RegistryDebtOracleMock(token, address(registry), address(ps));
        cs = new RegistryAvanaFirstLossReserveMock(address(hub), token, assetId);
        cs.setFunded(2e12, false);
        hub.setAsset(token, assetId);
        hub.setSpokeConfig(assetId, address(spoke), 0, drawCap);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (token, address(hub), uint16(assetId), 6);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        spoke.setReserve(reserveId, r, c, d);
        aaveOracle.setSource(reserveId, address(o));
        ps.setStressRise(token, 500);
        vm.startPrank(address(timelock));
        registry.setAvanaFirstLossReserve(address(hub), token, address(cs));
        vm.stopPrank();
    }

    function _def(
        address token,
        uint256 reserveId,
        uint256 assetId,
        address oracle,
        address cs
    ) internal view returns (DebtReserveDef memory) {
        return DebtReserveDef({
            reserveId: reserveId,
            asset: token,
            decimals: 6,
            fundingHub: address(hub),
            hubAssetId: assetId,
            priceSource: oracle,
            fixedPrice: false,
            firstLossReserve: cs,
            approved: false
        });
    }

    function _usdcDef() internal view returns (DebtReserveDef memory) {
        return _def(address(usdc), USDC_RESERVE, USDC_ASSET, address(usdcOracle), address(usdcCoverage));
    }

    function _usdtDef() internal view returns (DebtReserveDef memory) {
        return _def(address(usdt), USDT_RESERVE, USDT_ASSET, address(usdtOracle), address(usdtCoverage));
    }

    function _enable(
        DebtReserveDef memory d
    ) internal {
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), d);
    }

    function _enableBoth() internal {
        _enable(_usdcDef());
        _enable(_usdtDef());
    }

    function _remove(
        uint256 reserveId
    ) internal {
        vm.prank(address(timelock));
        registry.removeDebtReserve(address(spoke), reserveId);
    }

    function _ids() internal view returns (uint256[] memory) {
        return registry.getDebtReserveIds(address(spoke));
    }

    function _assertIds(
        uint256[] memory want
    ) internal view {
        uint256[] memory got = _ids();
        assertEq(got.length, want.length, "id count");
        for (uint256 i = 0; i < want.length; ++i) {
            assertEq(got[i], want[i], "id order");
        }
    }

    function _three(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    function _two(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        (x[0], x[1]) = (a, b);
    }

    function _one(
        uint256 a
    ) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    function _expectInvalid(
        DebtReserveDef memory d,
        bytes32 check
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.InvalidDebtReserve.selector, check));
        registry.enableDebtReserve(address(spoke), d);
    }

    // ─── The record ───

    // TEST-185 verifies: REQ-MREG-006, REQ-MREG-009, REQ-CONFIG-079, REQ-CONFIG-081
    // Sources: 5.1 TEST-185, TEST-204
    function test_TEST_185_recordHoldsEveryFieldOfTheDefinition() public {
        _enableBoth();
        DebtReserveDef memory rec = registry.getDebtReserve(address(spoke), USDT_RESERVE);
        assertEq(rec.reserveId, USDT_RESERVE);
        assertEq(rec.asset, address(usdt));
        assertEq(rec.decimals, 6);
        assertEq(rec.fundingHub, address(hub));
        assertEq(rec.hubAssetId, USDT_ASSET);
        assertEq(rec.priceSource, address(usdtOracle));
        assertFalse(rec.fixedPrice);
        assertEq(rec.firstLossReserve, address(usdtCoverage));
        assertTrue(rec.approved);
        rec = registry.getDebtReserve(address(spoke), USDC_RESERVE);
        assertEq(rec.reserveId, USDC_RESERVE);
        assertEq(rec.asset, address(usdc));
        assertEq(rec.hubAssetId, USDC_ASSET);
        rec = registry.getDebtReserve(address(spoke), GHO_RESERVE);
        assertEq(rec.reserveId, GHO_RESERVE);
        assertTrue(rec.fixedPrice);
        // An id never enabled reads as an empty, unapproved record.
        rec = registry.getDebtReserve(address(spoke), 77);
        assertFalse(rec.approved);
        assertEq(rec.asset, address(0));
        assertFalse(registry.isApprovedDebtReserve(address(spoke), 77));
        assertFalse(registry.isApprovedDebtReserve(alice, GHO_RESERVE), "another Spoke");
        _assertIds(_three(GHO_RESERVE, USDC_RESERVE, USDT_RESERVE));
    }

    // TEST-185 verifies: REQ-MREG-006
    function test_TEST_185_enablingTwiceIsRefused() public {
        _enable(_usdcDef());
        _expectInvalid(_usdcDef(), "enabled");
        _assertIds(_two(GHO_RESERVE, USDC_RESERVE));
    }

    // ─── Removal and the order of the set ───

    // TEST-213 verifies: REQ-MREG-010, Q-260
    // Removing the first, the middle or the last id keeps the order of the others.
    function test_TEST_213_removeFirstKeepsTheOrder() public {
        _enableBoth();
        vm.expectEmit(address(registry));
        emit IMarketRegistryBase.DebtReserveRemoved(address(spoke), GHO_RESERVE);
        _remove(GHO_RESERVE);
        _assertIds(_two(USDC_RESERVE, USDT_RESERVE));
    }

    // TEST-213 verifies: REQ-MREG-010, Q-260
    function test_TEST_213_removeMiddleKeepsTheOrder() public {
        _enableBoth();
        _remove(USDC_RESERVE);
        _assertIds(_two(GHO_RESERVE, USDT_RESERVE));
        assertFalse(registry.isApprovedDebtReserve(address(spoke), USDC_RESERVE));
        DebtReserveDef memory rec = registry.getDebtReserve(address(spoke), USDC_RESERVE);
        assertEq(rec.asset, address(0), "record cleared");
        assertEq(rec.reserveId, 0);
    }

    // TEST-213 verifies: REQ-MREG-010, Q-260
    function test_TEST_213_removeLastKeepsTheOrder() public {
        _enableBoth();
        _remove(USDT_RESERVE);
        _assertIds(_two(GHO_RESERVE, USDC_RESERVE));
        _remove(GHO_RESERVE);
        _assertIds(_one(USDC_RESERVE));
        _remove(USDC_RESERVE);
        assertEq(_ids().length, 0);
    }

    // TEST-213 verifies: REQ-MREG-010, REQ-MREG-006
    // A removed reserve can be enabled again; it joins at the end of the set and its draw cap is summed again.
    function test_TEST_213_reEnableAppendsAtTheEnd() public {
        _enableBoth();
        _remove(USDC_RESERVE);
        (uint256 sum,,) = registry.drawCapCoverage(address(hub), address(usdc));
        assertEq(sum, 0, "the Spoke leaves the coverage sum at removal");
        _enable(_usdcDef());
        _assertIds(_three(GHO_RESERVE, USDT_RESERVE, USDC_RESERVE));
        (sum,,) = registry.drawCapCoverage(address(hub), address(usdc));
        assertEq(sum, 500_000, "and joins it again");
    }

    // TEST-213 verifies: REQ-MREG-010
    function testFuzz_TEST_213_removalSequencesKeepRelativeOrder(
        uint8 order
    ) public {
        _enableBoth();
        uint256[3] memory all = [GHO_RESERVE, USDC_RESERVE, USDT_RESERVE];
        bool[3] memory gone;
        uint256 removals = bound(order, 0, 5);
        for (uint256 k = 0; k < 2; ++k) {
            uint256 pick = (removals + k) % 3;
            if (gone[pick]) pick = (pick + 1) % 3;
            _remove(all[pick]);
            gone[pick] = true;
            uint256[] memory got = _ids();
            uint256 j = 0;
            for (uint256 i = 0; i < 3; ++i) {
                if (gone[i]) continue;
                assertEq(got[j++], all[i], "survivors keep their order");
            }
            assertEq(got.length, j);
        }
    }

    // TEST-213 verifies: REQ-MREG-010, ATTACK-136
    function test_TEST_213_removalRefusals() public {
        _enable(_usdcDef());
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.UnknownDebtReserve.selector, address(spoke), 77));
        registry.removeDebtReserve(address(spoke), 77);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.UnknownDebtReserve.selector, alice, USDC_RESERVE));
        registry.removeDebtReserve(alice, USDC_RESERVE);
        vm.stopPrank();
        // Owed amount, then deficit alone, each block the removal.
        hub.setOwed(USDC_ASSET, address(spoke), 1, 0);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryBase.DebtReserveInUse.selector, address(spoke), USDC_RESERVE)
        );
        registry.removeDebtReserve(address(spoke), USDC_RESERVE);
        hub.setOwed(USDC_ASSET, address(spoke), 0, 1);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryBase.DebtReserveInUse.selector, address(spoke), USDC_RESERVE)
        );
        registry.removeDebtReserve(address(spoke), USDC_RESERVE);
        hub.setOwed(USDC_ASSET, address(spoke), 0, 0);
        _remove(USDC_RESERVE);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryBase.UnknownDebtReserve.selector, address(spoke), USDC_RESERVE)
        );
        registry.removeDebtReserve(address(spoke), USDC_RESERVE);
    }

    // ─── The settlement reserve of a market ───

    // TEST-213 verifies: REQ-MREG-033, REQ-MREG-010, Q-358
    // A new market settles into the first id of the Spoke's set at listing; after GHO's removal that is USDC.
    function test_TEST_213_newMarketSettlesIntoTheFirstEnabledReserve() public {
        _enableBoth();
        _remove(GHO_RESERVE);
        (uint256 id,,) = _listMarket();
        assertEq(registry.settlementReserve(id), USDC_RESERVE);
    }

    // TEST-213 verifies: REQ-MREG-033, REQ-CONFIG-078
    // With no debt reserve left there is nothing to settle into: listing is refused.
    function test_TEST_213_listingNeedsADebtReserve() public {
        _remove(GHO_RESERVE);
        (address vt, address o) = _tokenAndOracle();
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryBase.ListingCheckFailed.selector, bytes32("settlementReserve"))
        );
        registry.listCollateralMarket(_marketDef(vt, o));
    }

    function _tokenAndOracle() internal returns (address vt, address o) {
        (address t, RegistryLPOracleMock lpo) = _deployTokenAndOracle(registry.marketCount() + 1, _shape());
        (vt, o) = (t, address(lpo));
    }

    // TEST-213 verifies: REQ-MREG-010, REQ-MREG-033, ATTACK-136
    // A live (Registered) market that settles into a reserve blocks its removal; once the market is Cancelled the
    // reserve can go.
    function test_TEST_213_settlingMarketBlocksRemovalUntilCancelled() public {
        _enable(_usdcDef());
        (uint256 id,,) = _listMarket();
        vm.prank(address(timelock));
        registry.setSettlementReserve(id, USDC_RESERVE);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryBase.DebtReserveInUse.selector, address(spoke), USDC_RESERVE)
        );
        registry.removeDebtReserve(address(spoke), USDC_RESERVE);
        // GHO is no market's settlement reserve now and can go even with the market listed.
        _remove(GHO_RESERVE);
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        _remove(USDC_RESERVE);
        assertEq(_ids().length, 0);
    }

    // TEST-213 verifies: REQ-MREG-033, Q-358
    // The settlement reserve can be changed to any enabled reserve of the market's own Spoke, and back.
    function test_TEST_213_settlementReserveMovesBetweenEnabledReserves() public {
        _enableBoth();
        (uint256 id,,) = _listMarket();
        assertEq(registry.settlementReserve(id), GHO_RESERVE);
        vm.startPrank(address(timelock));
        registry.setSettlementReserve(id, USDT_RESERVE);
        assertEq(registry.settlementReserve(id), USDT_RESERVE);
        registry.setSettlementReserve(id, USDC_RESERVE);
        assertEq(registry.settlementReserve(id), USDC_RESERVE);
        registry.removeDebtReserve(address(spoke), USDT_RESERVE);
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryBase.UnknownDebtReserve.selector, address(spoke), USDT_RESERVE)
        );
        registry.setSettlementReserve(id, USDT_RESERVE);
        vm.stopPrank();
        assertEq(registry.settlementReserve(id), USDC_RESERVE);
    }

    // ─── Boundaries of the enablement checks ───

    // TEST-185 verifies: REQ-MREG-006, REQ-MREG-008
    // A fixed source must answer above 0: 0 and -1 fail, 1 passes.
    function test_TEST_185_fixedSourceAnswerBoundary() public {
        _remove(GHO_RESERVE);
        int256[3] memory answers = [int256(0), int256(-1), int256(1)];
        for (uint256 i = 0; i < 3; ++i) {
            ghoSource.setAnswer(answers[i]);
            if (answers[i] <= 0) {
                _expectInvalid(_ghoDef(), "priceSource");
            } else {
                _enable(_ghoDef());
            }
        }
    }

    // TEST-285 verifies: REQ-MREG-006, INV-095, Q-386, Q-388
    // The flash premium bound phi x 10^4 <= maxFlashFeeBps x F is inclusive, and both amounts must fit 128 bits.
    function test_TEST_285_flashBoundIsInclusiveAndBounded() public {
        // F = 10^6, premium 10 bps = 1,000: 1,000 x 10^4 = 10 x 10^6 exactly.
        flash.setLiquidity(1e6, 10);
        _enable(_usdcDef());
        _remove(USDC_RESERVE);
        // F = 10^6 + 1000 at 10 bps: premium floor(1,001) = 1,001; 1,001 x 10^4 <= 10 x 1,001,000.
        flash.setLiquidity(1_001_000, 10);
        _enable(_usdcDef());
        _remove(USDC_RESERVE);
        // 2^128 available is beyond the bound even at a zero premium.
        flash.setLiquidity(uint256(type(uint128).max) + 1, 0);
        _expectInvalid(_usdcDef(), "flash");
        flash.setLiquidity(type(uint128).max, 0);
        _enable(_usdcDef());
    }

    // TEST-285 verifies: REQ-MREG-006, INV-095, ATTACK-195
    // A flash source whose lender becomes a recorded Hub after it was set is refused at the next enablement.
    function test_TEST_285_lenderTurnedHubRefusedAtEnablement() public {
        flash.setLender(address(hub));
        _expectInvalid(_usdcDef(), "flash");
        flash.setLender(aaveV3Pool);
        _enable(_usdcDef());
    }
}
