// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistryActivationLogic} from "../../src/policy/market-registry/MarketRegistryActivationLogic.sol";
import {MarketRegistryHubsLogic} from "../../src/policy/market-registry/MarketRegistryHubsLogic.sol";
import {MarketRegistryListingLogic} from "../../src/policy/market-registry/MarketRegistryListingLogic.sol";
import {MarketRegistryRoutesLogic} from "../../src/policy/market-registry/MarketRegistryRoutesLogic.sol";
import {MarketRegistrySafetyLogic} from "../../src/policy/market-registry/MarketRegistrySafetyLogic.sol";
import {MarketRegistryWindDownLogic} from "../../src/policy/market-registry/MarketRegistryWindDownLogic.sol";
import {MarketRegistryImmutables} from "../../src/policy/market-registry/types/MarketRegistryImmutables.sol";
import {MarketRegistryLogics} from "../../src/policy/market-registry/types/MarketRegistryLogics.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {RegistryAdapterMock, RegistryFlashSourceMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

/// @title MarketRegistryHalmosTest
/// @notice Symbolic checks of the real MarketRegistry (proxy, router and logic contracts) for every caller and input:
/// the per-Hub pause transitions and reason, and the address freeze's protected set and per-caller limit.
/// @dev Roles: `FREEZER` holds only `APPLICATION_FREEZE_GUARDIAN`, `GUARDIAN` holds both guardian roles, `TIMELOCK`
/// holds `APPLICATION_ADMIN`; every other address is a stranger. Two Hubs are recorded; the flash source lends from
/// `LENDER`, the Aave V3 Pool behind it.
contract MarketRegistryHalmosTest is Test {
    address internal constant TIMELOCK = address(0x7111);
    address internal constant EXECUTOR = address(0x7112);
    address internal constant GUARDIAN = address(0x7113);
    address internal constant FREEZER = address(0x7114);
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
            standardSpokeImplementation: address(0x7209)
        });
        MarketRegistryLogics memory l;
        l.hubs = address(new MarketRegistryHubsLogic(im));
        l.listing = address(new MarketRegistryListingLogic(im));
        l.activation = address(new MarketRegistryActivationLogic(im));
        l.routes = address(new MarketRegistryRoutesLogic(im));
        l.safety = address(new MarketRegistrySafetyLogic(im));
        l.windDown = address(new MarketRegistryWindDownLogic(im));
        MarketRegistry impl = new MarketRegistry(im, l);
        registry = IMarketRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(MarketRegistry.initialize, (TIMELOCK))))
        );
        vm.startPrank(TIMELOCK);
        registry.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, GUARDIAN);
        registry.grantRole(AvanaRoles.APPLICATION_FREEZE_GUARDIAN, GUARDIAN);
        registry.grantRole(AvanaRoles.APPLICATION_FREEZE_GUARDIAN, FREEZER);
        registry.recordHub(HUB, RiskTier.Stable);
        registry.recordHub(OTHER_HUB, RiskTier.Correlated);
        flash = address(new RegistryFlashSourceMock(LENDER, im.lpVaultSwap));
        registry.setFlashSource(flash);
        vm.stopPrank();
    }

    function _call(
        address caller,
        uint8 op,
        uint8 reason
    ) internal returns (bool ok) {
        bytes memory data;
        uint8 k = op % 4;
        if (k == 0) data = abi.encodeCall(registry.freeze, (HUB));
        else if (k == 1) data = abi.encodeCall(registry.pause, (HUB, PauseReason(reason % 3)));
        else if (k == 2) data = abi.encodeCall(registry.unfreeze, (HUB));
        else data = abi.encodeCall(registry.unpause, (HUB));
        vm.prank(caller);
        (ok,) = address(registry).call(data);
    }

    function _isPauser(
        address a
    ) internal pure returns (bool) {
        return a == GUARDIAN || a == TIMELOCK;
    }

    // PROP-041 verifies: REQ-MREG-001, REQ-MREG-004, REQ-MREG-017, REQ-MREG-024, REQ-CONFIG-082, INV-049, Q-227, Q-252
    /// @notice After any two calls by any callers: the reason is `None` exactly when the state is not Paused; a
    /// successful call is one of the four transitions by a caller holding its role; the freeze-only holder never moves
    /// the state toward None; the other Hub never changes.
    function check_PROP_041_pauseTransitions(
        address c1,
        uint8 op1,
        uint8 r1,
        address c2,
        uint8 op2,
        uint8 r2
    ) public {
        address[2] memory callers = [c1, c2];
        uint8[2] memory ops = [op1, op2];
        uint8[2] memory reasons = [r1, r2];
        for (uint256 i = 0; i < 2; ++i) {
            PauseState before = registry.pauseState(HUB);
            PauseReason beforeReason = registry.pauseReason(HUB);
            bool ok = _call(callers[i], ops[i], reasons[i]);
            PauseState afterS = registry.pauseState(HUB);
            PauseReason afterR = registry.pauseReason(HUB);
            assert((afterS == PauseState.Paused) == (afterR != PauseReason.None));
            assert(registry.pauseState(OTHER_HUB) == PauseState.None);
            if (!ok) {
                assert(afterS == before && afterR == beforeReason);
                continue;
            }
            uint8 k = ops[i] % 4;
            if (k == 0) {
                assert(before == PauseState.None && afterS == PauseState.Frozen);
                assert(callers[i] == GUARDIAN || callers[i] == FREEZER || callers[i] == TIMELOCK);
            } else if (k == 1) {
                assert(_isPauser(callers[i]));
                assert(afterS == PauseState.Paused && afterR != PauseReason.None && afterR != beforeReason);
            } else if (k == 2) {
                assert(_isPauser(callers[i]) && before == PauseState.Frozen && afterS == PauseState.None);
            } else {
                assert(_isPauser(callers[i]) && before == PauseState.Paused && afterS == PauseState.None);
            }
        }
    }

    // PROP-071 verifies: REQ-MREG-019, REQ-MREG-020, REQ-MREG-021, INV-085, Q-242
    /// @notice `freezeAddress(a)` succeeds only for a freeze-role holder or the timelock, an address outside the
    /// fixed protected set (the flash source and its lender included) and not a registered proxy, not yet frozen; a success sets the flag and counts one freeze
    /// for the caller.
    function check_PROP_071_freezeAddressGates(
        address caller,
        address a,
        address wallet
    ) public {
        adapter.setWallet(a, wallet);
        bool wasFrozen = registry.isFrozenAddress(a);
        uint256 countBefore = registry.freezesInWindow(caller);
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(registry).call(abi.encodeCall(registry.freezeAddress, (a)));
        bool fixedProtected = a == TIMELOCK || a == EXECUTOR || a == im.vaultTokenFactory || a == address(adapter)
            || a == im.collateralization || a == im.lock || a == im.proxyManager || a == im.parameterStore
            || a == im.riskModule || a == im.lpVaultSwap || a == im.payoutEscrow || a == im.flashLiquidator
            || a == address(registry) || a == HUB || a == OTHER_HUB || a == flash || a == LENDER || a == address(0);
        if (ok) {
            assert(caller == GUARDIAN || caller == FREEZER || caller == TIMELOCK);
            assert(!wasFrozen && !fixedProtected && wallet == address(0));
            assert(registry.isFrozenAddress(a));
            assert(registry.freezesInWindow(caller) == countBefore + 1);
        } else if (caller != GUARDIAN && caller != FREEZER && caller != TIMELOCK) {
            assert(
                keccak256(ret) == keccak256(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, caller))
            );
        } else if (fixedProtected || wallet != address(0)) {
            assert(
                keccak256(ret) == keccak256(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, a))
            );
        }
    }
}
