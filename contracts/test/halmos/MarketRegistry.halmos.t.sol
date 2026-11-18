// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistryActivationLogic} from "../../src/policy/market-registry/MarketRegistryActivationLogic.sol";
import {MarketRegistryHubsLogic} from "../../src/policy/market-registry/MarketRegistryHubsLogic.sol";
import {MarketRegistryListingLogic} from "../../src/policy/market-registry/MarketRegistryListingLogic.sol";
import {MarketRegistryRoutesLogic} from "../../src/policy/market-registry/MarketRegistryRoutesLogic.sol";
import {MarketRegistryWindDownLogic} from "../../src/policy/market-registry/MarketRegistryWindDownLogic.sol";
import {
    MarketRegistryImmutables,
    MarketRegistryLogics,
    RiskTier
} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {RegistryAdapterMock, RegistryFlashSourceMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

/// @title MarketRegistryHalmosTest
/// @notice Symbolic checks of the real MarketRegistry (proxy, router and logic contracts) for every caller and input:
/// the flash source never lends from a recorded Hub.
/// @dev `TIMELOCK` holds `APPLICATION_ADMIN`; every other address is a stranger. Two Hubs are recorded; the flash
/// source lends from `LENDER`, the Aave V3 Pool behind it.
contract MarketRegistryHalmosTest is Test {
    address internal constant TIMELOCK = address(0x7111);
    address internal constant EXECUTOR = address(0x7112);
    address internal constant HUB = address(0x7115);
    address internal constant OTHER_HUB = address(0x7116);
    address internal constant LENDER = address(0x7117);

    IMarketRegistry internal registry;
    address internal flash;
    RegistryAdapterMock internal adapter;
    MarketRegistryImmutables internal im;

    function setUp() public {
        adapter = new RegistryAdapterMock();
        im = MarketRegistryImmutables({
            timelock: TIMELOCK,
            aaveGovernanceExecutor: EXECUTOR,
            vaultTokenFactory: address(0x7201),
            aaveAdapter: address(adapter),
            collateralization: address(0x7202),
            lock: address(0x7203),
            proxyManager: address(0x7204),
            parameterStore: address(0x7205),
            riskModule: address(0x7206),
            lpVaultSwap: address(0x7207),
            payoutEscrow: address(0x7208),
            flashLiquidator: address(0x720A),
            standardSpokeImplementation: address(0x7209),
            maxMarketCount: 1000
        });
        MarketRegistryLogics memory l;
        l.hubs = address(new MarketRegistryHubsLogic(im));
        l.listing = address(new MarketRegistryListingLogic(im));
        l.activation = address(new MarketRegistryActivationLogic(im));
        l.routes = address(new MarketRegistryRoutesLogic(im));
        l.windDown = address(new MarketRegistryWindDownLogic(im));
        MarketRegistry impl = new MarketRegistry(im, l);
        registry = IMarketRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(MarketRegistry.initialize, (TIMELOCK))))
        );
        vm.startPrank(TIMELOCK);
        registry.recordHub(HUB, RiskTier.Stable);
        registry.recordHub(OTHER_HUB, RiskTier.Correlated);
        flash = address(new RegistryFlashSourceMock(LENDER, im.lpVaultSwap));
        registry.setFlashSource(flash);
        vm.stopPrank();
    }

    // PROP-096 verifies: REQ-FLASH-006, INV-095, Q-386, Q-388
    /// @notice For any caller, lender, LPVaultSwap and new Hub: `setFlashSource` succeeds only for the timelock with a
    /// source naming this chain's LPVaultSwap whose `LENDER()` is no recorded Hub, and the timelock's refusal is
    /// `InvalidRoute`; once a source is in force, `recordHub` of its lender reverts `InvalidRoute`; so the recorded
    /// flash source never lends from a recorded Hub.
    function check_PROP_096_flashSourceNeverAHub(
        address caller,
        address lender,
        address swapOf,
        address newHub
    ) public {
        address source = address(new RegistryFlashSourceMock(lender, swapOf));
        address before = registry.flashSource();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(registry).call(abi.encodeCall(registry.setFlashSource, (source)));
        bool lenderIsHub = registry.isRecordedHub(lender);
        if (ok) {
            assert(caller == TIMELOCK && swapOf == im.lpVaultSwap && !lenderIsHub);
            assert(registry.flashSource() == source);
        } else {
            assert(registry.flashSource() == before);
            if (caller == TIMELOCK) {
                assert(swapOf != im.lpVaultSwap || lenderIsHub);
                assert(keccak256(ret) == keccak256(abi.encodeWithSelector(IMarketRegistryBase.InvalidRoute.selector)));
            }
        }
        address inForceLender = RegistryFlashSourceMock(registry.flashSource()).LENDER();
        assert(!registry.isRecordedHub(inForceLender));
        vm.prank(TIMELOCK);
        (bool recorded, bytes memory err) =
            address(registry).call(abi.encodeCall(registry.recordHub, (newHub, RiskTier.Volatile)));
        if (newHub == inForceLender && newHub != address(0)) {
            assert(!recorded);
            assert(keccak256(err) == keccak256(abi.encodeWithSelector(IMarketRegistryBase.InvalidRoute.selector)));
        }
        assert(!registry.isRecordedHub(RegistryFlashSourceMock(registry.flashSource()).LENDER()));
    }
}
