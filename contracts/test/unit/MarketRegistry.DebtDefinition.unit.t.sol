// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryCreditLines} from "../../src/policy/market-registry/IMarketRegistryCreditLines.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {
    RegistryCoverageSpokeMock,
    RegistryDebtOracleMock,
    RegistryFeedMock
} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice Each field of a debt-reserve definition checked against Aave, the AaveOracle, the Coverage Spoke and the
/// flash source one at a time, the collateral factor read on the reserve's latest dynamic key, and the order in which
/// the checks report when several fail.
contract MarketRegistryDebtDefinitionUnitTest is MarketRegistryFixture {
    uint256 internal constant USDC_RESERVE = 5;
    uint256 internal constant USDC_ASSET = 2;

    RegistryDebtOracleMock internal usdcOracle;
    RegistryCoverageSpokeMock internal usdcCoverage;

    function setUp() public {
        _setUpWorld();
        usdcOracle = new RegistryDebtOracleMock(address(usdc), address(registry), address(ps));
        usdcCoverage = new RegistryCoverageSpokeMock(address(hub), address(usdc), USDC_ASSET);
        usdcCoverage.setFunded(2e12, false);
        hub.setAsset(address(usdc), USDC_ASSET);
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 500_000);
        _setUsdcReserve(address(usdc), address(hub), USDC_ASSET, 6, true, 0, 0);
        aaveOracle.setSource(USDC_RESERVE, address(usdcOracle));
        ps.setStressRise(address(usdc), 500);
        vm.startPrank(address(timelock));
        registry.setCoverageSpoke(address(hub), address(usdc), address(usdcCoverage));
        registry.recordCreditLine(address(hub), address(usdc), 1_000_000);
        vm.stopPrank();
    }

    /// @dev Writes the Aave reserve at USDC_RESERVE with collateral factor `cf` on dynamic key `key`.
    function _setUsdcReserve(
        address underlying,
        address h,
        uint256 assetId,
        uint8 decimals,
        bool borrowable,
        uint32 key,
        uint16 cf
    ) internal {
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals, r.dynamicConfigKey) =
        (underlying, h, uint16(assetId), decimals, key);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = borrowable;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        d.collateralFactor = cf;
        spoke.setReserve(USDC_RESERVE, r, c, d);
    }

    function _def() internal view returns (DebtReserveDef memory) {
        return DebtReserveDef({
            reserveId: USDC_RESERVE,
            asset: address(usdc),
            decimals: 6,
            fundingHub: address(hub),
            hubAssetId: USDC_ASSET,
            priceSource: address(usdcOracle),
            fixedPrice: false,
            coverageSpoke: address(usdcCoverage),
            crossHub: false,
            approved: false
        });
    }

    function _expect(
        DebtReserveDef memory d,
        bytes memory err
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(err);
        registry.enableDebtReserve(address(spoke), d);
    }

    function _invalid(
        bytes32 check
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IMarketRegistryErrors.InvalidDebtReserve.selector, check);
    }

    function _enable(
        DebtReserveDef memory d
    ) internal {
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), d);
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-MREG-007, REQ-CONFIG-079, ATTACK-121
    // Sources: 5.1 TEST-185
    // The Aave reserve must match the definition field by field: underlying, Hub, Hub asset id, the reserve's
    // decimals and the token's own decimals; each mismatch alone is "reserve".
    function test_TEST_185_aaveReserveFieldByField() public {
        _setUsdcReserve(address(usdt), address(hub), USDC_ASSET, 6, true, 0, 0);
        _expect(_def(), _invalid("reserve"));
        _setUsdcReserve(address(usdc), alice, USDC_ASSET, 6, true, 0, 0);
        _expect(_def(), _invalid("reserve"));
        _setUsdcReserve(address(usdc), address(hub), USDC_ASSET + 1, 6, true, 0, 0);
        _expect(_def(), _invalid("reserve"));
        _setUsdcReserve(address(usdc), address(hub), USDC_ASSET, 8, true, 0, 0);
        _expect(_def(), _invalid("reserve"));
        // The reserve and the definition agree on 8, but the token itself has 6 decimals.
        _setUsdcReserve(address(usdc), address(hub), USDC_ASSET, 8, true, 0, 0);
        DebtReserveDef memory d = _def();
        d.decimals = 8;
        _expect(d, _invalid("reserve"));
        _setUsdcReserve(address(usdc), address(hub), USDC_ASSET, 6, true, 0, 0);
        _enable(_def());
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-MREG-007, Q-233
    // The collateral factor is read on the reserve's latest dynamic key: a non-zero factor on an older key does not
    // count, a non-zero factor on the latest key does.
    function test_TEST_185_collateralFactorOnTheLatestKey() public {
        // Latest key 3 carries CF 1.
        _setUsdcReserve(address(usdc), address(hub), USDC_ASSET, 6, true, 3, 1);
        _expect(_def(), _invalid("collateralFactor"));
        // Key 3 (now an older key) is given CF 7,000 and the latest key 4 carries 0.
        IAaveV4Spoke.DynamicReserveConfig memory old;
        old.collateralFactor = 7000;
        spoke.setDynamic(USDC_RESERVE, old);
        _setUsdcReserve(address(usdc), address(hub), USDC_ASSET, 6, true, 4, 0);
        _enable(_def());
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-MREG-007
    function test_TEST_185_notBorrowableRefused() public {
        _setUsdcReserve(address(usdc), address(hub), USDC_ASSET, 6, false, 0, 0);
        _expect(_def(), _invalid("borrowable"));
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-MREG-008
    // The price source must be non-zero, the AaveOracle's source of the reserve, and report 8 decimals.
    function test_TEST_185_priceSourceEachCondition() public {
        DebtReserveDef memory d = _def();
        d.priceSource = address(0);
        _expect(d, _invalid("priceSource"));
        RegistryDebtOracleMock other = new RegistryDebtOracleMock(address(usdc), address(registry), address(ps));
        d.priceSource = address(other);
        _expect(d, _invalid("priceSource"));
        RegistryFeedMock eighteen = new RegistryFeedMock(18, 1e18);
        aaveOracle.setSource(USDC_RESERVE, address(eighteen));
        d.priceSource = address(eighteen);
        _expect(d, _invalid("priceSource"));
        aaveOracle.setSource(USDC_RESERVE, address(usdcOracle));
        _enable(_def());
        assertTrue(registry.isApprovedDebtReserve(address(spoke), USDC_RESERVE));
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-CONFIG-081, REQ-MREG-009
    // The Coverage Spoke must be the recorded one of (funding Hub, asset): zero reports the zero address; one whose
    // asset id differs from the definition's is "coverageSpoke".
    function test_TEST_185_coverageSpokeOfTheDefinition() public {
        DebtReserveDef memory d = _def();
        d.coverageSpoke = address(0);
        _expect(
            d,
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CoverageSpokeMismatch.selector, address(hub), address(usdc), address(0)
            )
        );
        // The Aave reserve and the definition name Hub asset 9, but the recorded Coverage Spoke covers asset 2.
        _setUsdcReserve(address(usdc), address(hub), 9, 6, true, 0, 0);
        d = _def();
        d.hubAssetId = 9;
        _expect(d, _invalid("coverageSpoke"));
    }

    // TEST-185 verifies: REQ-MREG-006, REQ-MREG-009, REQ-CONFIG-081, REQ-MREG-032
    // When several checks fail the first in this order is reported: approved Spoke, funding Hub, already enabled,
    // funding line, Aave reserve, price source, Coverage Spoke, flash source, credit line, coverage.
    function test_TEST_185_checkOrderWhenSeveralFail() public {
        DebtReserveDef memory d = _def();
        // Everything wrong at once.
        d.fundingHub = alice;
        d.priceSource = address(0);
        d.coverageSpoke = address(0);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, alice));
        registry.enableDebtReserve(alice, d);
        _expect(d, _invalid("fundingHub"));
        d.fundingHub = address(hub);
        d.crossHub = true;
        _expect(d, _invalid("crossHub"));
        d.crossHub = false;
        d.hubAssetId = 8;
        _expect(d, _invalid("reserve"));
        d.hubAssetId = USDC_ASSET;
        _expect(d, _invalid("priceSource"));
        d.priceSource = address(usdcOracle);
        _expect(
            d,
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CoverageSpokeMismatch.selector, address(hub), address(usdc), address(0)
            )
        );
        d.coverageSpoke = address(usdcCoverage);
        flash.setLiquidity(0, 5);
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 2_000_000);
        _expect(d, _invalid("flash"));
        flash.setLiquidity(1e30, 5);
        _expect(
            d,
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CreditLineExceeded.selector,
                address(hub),
                address(usdc),
                2_000_000,
                1_000_000
            )
        );
        hub.setSpokeConfig(USDC_ASSET, address(spoke), 0, 500_000);
        usdcCoverage.setFunded(1, false);
        _expect(
            d,
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CoverageBelowRatio.selector, address(hub), address(usdc), 2e11, 1
            )
        );
        usdcCoverage.setFunded(2e12, false);
        _enable(d);
        _expect(d, _invalid("enabled"));
    }
}
