// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {ParameterStoreRegistryFixture} from "../utils/fixtures/ParameterStoreRegistryFixture.sol";
import {RegistryLPOracleMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {console} from "forge-std/console.sol";

/// @notice The ParameterStore's chain-wide re-check walks market IDs 1..marketCount of the real MarketRegistry, so the
/// registry's `MAX_MARKET_COUNT` bounds its gas. This suite fills the registry to its limit with the fixture's markets
/// (mock LPOracles, whose `checkConfig` is cheap) and measures the most expensive re-check, `setFeedAgreementMarginBps`
/// (every market, `checkConfig` of each LPOracle and the tolerance bound of each pool token). The number is an input to
/// the fork sizing of the limit, which uses the real LPOracle, the worst supported market and cold reads.
contract ParameterStoreMarketCountGasIntegrationTest is ParameterStoreRegistryFixture {
    /// @dev EIP-7825 per-transaction gas cap (2^24): the re-check must fit one transaction.
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    function setUp() public {
        _setUpWorld();
    }

    /// @dev Lists one market of the USDC/USDT pool on its own tick range, so each market has its own key.
    function _listNext() internal returns (uint256 id) {
        id = registry.marketCount() + 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 half = int24(int256(10 * id));
        PositionShape memory shape = PositionShape(ShapeKind.TickRange, -half, half);
        RegistryLPOracleMock lpOracle = new RegistryLPOracleMock(id, address(lpVault));
        vm.prank(address(timelock));
        address vaultToken = factory.deployVaultToken(
            V3,
            pool,
            bytes32(0),
            shape,
            address(hub),
            address(spoke),
            id,
            address(lpOracle),
            18,
            "Avana USDC/USDT",
            "avUSDC-USDT"
        );
        MarketDef memory d;
        (d.hub, d.spoke, d.integrationId, d.pool, d.shape) = (address(hub), address(spoke), V3, pool, shape);
        (d.vaultToken, d.lpOracle) = (vaultToken, address(lpOracle));
        vm.prank(address(timelock));
        registry.listCollateralMarket(d);
    }

    /// @dev Gas of `setFeedAgreementMarginBps`, the SCOPE_ALL re-check with the tolerance bound, as its own call.
    function _recheckGas(
        uint16 margin
    ) internal returns (uint256 used) {
        vm.prank(address(timelock));
        uint256 before = gasleft();
        store.setFeedAgreementMarginBps(margin);
        used = before - gasleft();
    }

    // TEST-295 verifies: REQ-MREG-034, REQ-PSTORE-009
    // Sources: decisions of 2026-11-11 (market-count bound; gas of the re-check at the limit informs the fork sizing)
    function test_TEST_295_recheckGasAtTheMarketCountLimit() public {
        assertEq(registry.MAX_MARKET_COUNT(), MAX_MARKETS);
        _listNext();
        uint256 one = _recheckGas(40);
        while (registry.marketCount() < MAX_MARKETS) {
            _listNext();
        }
        uint256 atCap = _recheckGas(45);
        console.log("re-check gas, 1 market:", one);
        console.log("re-check gas, markets at the limit:", MAX_MARKETS, atCap);
        console.log("marginal gas per market:", (atCap - one) / (MAX_MARKETS - 1));
        assertLt(atCap, TX_GAS_CAP, "re-check at the limit exceeds one transaction");
        assertGt(atCap, one, "re-check does not grow with the market count");
        // The registry refuses the market past its limit, so the walk never grows beyond it.
        uint256 next = registry.marketCount() + 1;
        RegistryLPOracleMock o = new RegistryLPOracleMock(next, address(lpVault));
        PositionShape memory shape = PositionShape(ShapeKind.TickRange, -10_000, 10_000);
        vm.prank(address(timelock));
        address vt = factory.deployVaultToken(
            V3, pool, bytes32(0), shape, address(hub), address(spoke), next, address(o), 18, "Avana", "av"
        );
        MarketDef memory d;
        (d.hub, d.spoke, d.integrationId, d.pool, d.shape) = (address(hub), address(spoke), V3, pool, shape);
        (d.vaultToken, d.lpOracle) = (vt, address(o));
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.MarketCountLimit.selector, MAX_MARKETS));
        registry.listCollateralMarket(d);
    }
}
