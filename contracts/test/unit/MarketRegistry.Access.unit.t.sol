// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistryHubsLogic} from "../../src/policy/market-registry/MarketRegistryHubsLogic.sol";
import {
    MarketRegistryImmutables,
    MarketRegistryLogics,
    RiskTier
} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStore} from "../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreLoosen} from "../../src/policy/parameter-store/IParameterStoreLoosen.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @notice Roles, initialization, upgrades, the logic-contract wiring and the selector inventory of the MarketRegistry.
contract MarketRegistryAccessUnitTest is MarketRegistryFixture {
    function setUp() public {
        _setUpWorld();
    }

    // TEST-242 verifies: REQ-MREG-005, REQ-ACCESS-153, INV-084, Q-259, REQ-ACCESS-149, REQ-ACCESS-002, REQ-ACCESS-014, REQ-ACCESS-032
    // Sources: 5.1 TEST-242
    function test_TEST_242_adminRolesOnlyForTimelock() public {
        bytes32 defaultAdmin = registry.DEFAULT_ADMIN_ROLE();
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.AdminRoleOnlyTimelock.selector, APP_ADMIN, alice));
        registry.grantRole(APP_ADMIN, alice);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.AdminRoleOnlyTimelock.selector, defaultAdmin, alice));
        registry.grantRole(defaultAdmin, alice);
        vm.stopPrank();
        assertTrue(registry.hasRole(APP_ADMIN, address(timelock)));
        assertTrue(registry.hasRole(defaultAdmin, address(timelock)));
        assertEq(registry.getRoleAdmin(APP_ADMIN), defaultAdmin);
    }

    // TEST-242 verifies: REQ-MREG-005, REQ-CONFIG-002, REQ-ACCESS-150
    function test_TEST_242_initializeOnlyWithTimelockAndOnce() public {
        MarketRegistry impl = new MarketRegistry(im, logics);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.AdminRoleOnlyTimelock.selector, bytes32(0), alice));
        new ERC1967Proxy(address(impl), abi.encodeCall(MarketRegistry.initialize, (alice)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(address(timelock));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(timelock));
    }

    // TEST-062 verifies: REQ-MREG-004, REQ-MREG-026, REQ-CONFIG-028
    // Sources: 5.1 TEST-062
    function test_TEST_062_strangerRefusedOnEveryWrite() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, APP_ADMIN)
        );
        registry.listToken(address(gho), _tokenDef(new address[](0), new address[](0)));
    }

    // TEST-168 verifies: REQ-CONFIG-001, REQ-CONFIG-002, REQ-MREG-003, REQ-ACCESS-015, REQ-ACCESS-031
    // Sources: 5.1 TEST-168
    function test_TEST_168_upgradeKeepsStateAndNeedsAdmin() public {
        MarketRegistry next = new MarketRegistry(im, logics);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, APP_ADMIN)
        );
        registry.upgradeToAndCall(address(next), "");
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(next), "");
        assertTrue(registry.getToken(address(usdc)).listed);
        assertEq(registry.getDebtReserveIds(address(spoke)).length, 1);
    }

    // TEST-168 verifies: REQ-CONFIG-001, REQ-CONFIG-005
    function test_TEST_168_logicContractsRefuseDirectCallsAndMismatches() public {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.Unauthorized.selector, address(this)));
        MarketRegistryHubsLogic(logics.hubs).recordHub(alice, RiskTier.Stable);
        MarketRegistryLogics memory swapped = logics;
        (swapped.hubs, swapped.listing) = (logics.listing, logics.hubs);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.ListingCheckFailed.selector, bytes32("logic")));
        new MarketRegistry(im, swapped);
        MarketRegistryImmutables memory other = im;
        other.lock = makeAddr("otherLock");
        MarketRegistryLogics memory foreign = logics;
        foreign.windDown = _deployLogics(other).windDown;
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.ListingCheckFailed.selector, bytes32("logic")));
        new MarketRegistry(im, foreign);
        other = im;
        other.riskModule = address(0);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.ListingCheckFailed.selector, bytes32("immutables")));
        new MarketRegistryHubsLogic(other);
        other = im;
        other.flashLiquidator = address(0);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.ListingCheckFailed.selector, bytes32("immutables")));
        new MarketRegistryHubsLogic(other);
    }

    // TEST-168 verifies: REQ-CONFIG-005, REQ-CONFIG-064
    function test_TEST_168_immutableGetters() public view {
        assertEq(registry.TIMELOCK(), address(timelock));
        assertEq(registry.AAVE_GOVERNANCE_EXECUTOR(), aaveGovernanceExecutor);
        assertEq(registry.VAULT_TOKEN_FACTORY(), address(factory));
        assertEq(registry.AAVE_ADAPTER(), address(adapterMock));
        assertEq(registry.COLLATERALIZATION(), address(collat));
        assertEq(registry.LOCK(), lockAddr);
        assertEq(registry.PROXY_MANAGER(), proxyManager);
        assertEq(registry.PARAMETER_STORE(), address(ps));
        assertEq(registry.RISK_MODULE(), address(rm));
        assertEq(registry.LP_VAULT_SWAP(), address(lpVaultSwap));
        assertEq(registry.PAYOUT_ESCROW(), payoutEscrow);
        assertEq(registry.FLASH_LIQUIDATOR(), flashLiquidator);
        assertEq(registry.STANDARD_SPOKE_IMPLEMENTATION(), address(spokeImpl));
        assertEq(registry.flashSource(), address(flash));
    }

    // TEST-053 verifies: REQ-MREG-016, REQ-MREG-029, REQ-MREG-011, REQ-MREG-013, Q-401, REQ-ACCESS-055, REQ-ACCESS-056, REQ-ACCESS-163, REQ-ACCESS-137, REQ-ACCESS-151, SPEC-GOV-010, REQ-CONFIG-068
    // Sources: 5.1 TEST-053, TEST-035
    function test_TEST_053_noInKindNoBuyNoSellBackSelectors() public {
        string[8] memory absent = [
            "enableInKind(uint256)",
            "disableInKind(uint256)",
            "autoEnableInKind(uint256)",
            "isInKindEnabled(uint256)",
            "setBuyRoute(uint256,address,uint8,address)",
            "restoreBuyRoute(uint256,address,uint8,address)",
            "setSellBackRoute(uint256,address,address)",
            "setInKindAutoTrigger(uint256,bool)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok, bytes memory ret) =
                address(registry).call(abi.encodeWithSignature(absent[i], uint256(1), address(0), uint8(0), address(0)));
            assertFalse(ok);
            assertEq(ret.length, 0);
        }
    }

    // TEST-035 verifies: REQ-MREG-003, REQ-CONFIG-082, REQ-ACCESS-035, REQ-ACCESS-081
    // Sources: 5.1 TEST-035
    function test_TEST_035_noPerMarketPauseSelector() public {
        string[4] memory absent =
            ["pauseMarket(uint256)", "freezeMarket(uint256)", "pauseFunction(bytes4)", "suspendKeeper(address)"];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok, bytes memory ret) = address(registry).call(abi.encodeWithSignature(absent[i], uint256(1)));
            assertFalse(ok);
            assertEq(ret.length, 0);
        }
    }

    /// @notice The registry stores no risk parameter, settlement mode, allowlist or markets-per-wallet cap: none of
    /// the ParameterStore's risk-parameter views and setters, and no settlement-mode, allowlist or markets-per-wallet
    /// selector, exists on it (the call reaches no function and reverts with empty data).
    /// @dev Kills: a risk-parameter getter or setter, a settlement-mode switch, an allowlist or a per-wallet market cap
    /// added to the MarketRegistry or one of its logic contracts.
    // TEST-032 verifies: REQ-CONFIG-014
    function test_TEST_032_noRiskParameterModeAllowlistOrWalletCapSelectors() public {
        bytes4[33] memory params = [
            IParameterStore.marketUsdCap.selector,
            IParameterStore.topUpSliceUsd.selector,
            IParameterStore.stressFloorUsd.selector,
            IParameterStore.tokenUsdCap.selector,
            IParameterStore.minPledgeUsd.selector,
            IParameterStore.debtAssetParams.selector,
            IParameterStore.routeDepthThreshold.selector,
            IParameterStoreTighten.tightenSlippageAllowanceBps.selector,
            IParameterStoreTighten.tightenFloorRoundingAllowance.selector,
            IParameterStoreTighten.tightenBorrowPriceMaxAge.selector,
            IParameterStoreTighten.tightenPoolRiskFactor.selector,
            IParameterStoreTighten.tightenRouteDepthThreshold.selector,
            IParameterStoreTighten.tightenMarketUsdCap.selector,
            IParameterStoreTighten.tightenTopUpSliceUsd.selector,
            IParameterStoreTighten.tightenTokenUsdCap.selector,
            IParameterStoreTighten.tightenMinPledgeUsd.selector,
            IParameterStoreLoosen.loosenSlippageAllowanceBps.selector,
            IParameterStoreLoosen.loosenFloorRoundingAllowance.selector,
            IParameterStoreLoosen.loosenRouteDepthThreshold.selector,
            IParameterStoreLoosen.loosenMarketUsdCap.selector,
            IParameterStoreLoosen.loosenTopUpSliceUsd.selector,
            IParameterStoreLoosen.loosenTokenUsdCap.selector,
            IParameterStoreLoosen.loosenMinPledgeUsd.selector,
            IParameterStore.maxShortfallBps.selector,
            IParameterStore.tightenMaxShortfallBps.selector,
            IParameterStore.loosenMaxShortfallBps.selector,
            IParameterStore.debtStressRiseBps.selector,
            IParameterStore.setLiquidationExpectations.selector,
            IParameterStore.deficitMax.selector,
            IParameterStore.tightenDeficitMax.selector,
            IParameterStore.loosenDeficitMax.selector,
            IParameterStore.coverageRatioBps.selector,
            IParameterStore.setCoverageRatioBps.selector
        ];
        for (uint256 i = 0; i < params.length; ++i) {
            _assertNoFunction(params[i]);
        }
        string[10] memory absent = [
            "settlementMode(uint256)",
            "setSettlementMode(uint256,uint8)",
            "isAllowlisted(address)",
            "setAllowlist(address,bool)",
            "allowlist(address)",
            "maxMarketsPerWallet()",
            "setMaxMarketsPerWallet(uint256)",
            "marketsPerWalletCap()",
            "collateralFactor(uint256)",
            "setMinPledgeUsd(uint256,uint256)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            _assertNoFunction(bytes4(keccak256(bytes(absent[i]))));
        }
    }

    function _assertNoFunction(
        bytes4 selector
    ) private {
        (bool ok, bytes memory ret) = address(registry).call(abi.encodePacked(selector, new bytes(32 * 6)));
        assertFalse(ok, "selector present");
        assertEq(ret.length, 0, "selector reached a function");
    }
}
