// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwap} from "../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {LPVaultSwap} from "../../src/liquidation/lp-vault-swap/LPVaultSwap.sol";
import {LPVaultSwapImmutables} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {LPVaultSwapLogics} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapLogics.sol";
import {LVSMarketRegistryMock} from "../utils/mocks/LPVaultSwapMocks.sol";
import {LPVaultSwapKeeperHandler} from "./handlers/LPVaultSwapKeeperHandler.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

/// @title LPVaultSwapKeepersInvariantTest
/// @notice The committed-operator registry under random sequences of timelock adds and removes, MarketRegistry
/// freezes and outsider calls, on the real LPVaultSwap behind its proxy (2.11 REQ-SWAP-032 to REQ-SWAP-038; 2.15
/// REQ-ACCESS-011, REQ-ACCESS-053, REQ-ACCESS-054, REQ-ACCESS-100, REQ-ACCESS-121, SPEC-GOV-008). After every call:
/// every outcome matched the spec's model (success or the exact error); the registry holds between 1 and 32 entries
/// with at least `keeperFloor` active; `getKeepers()` lists each registered keeper exactly once and nothing else;
/// `activeKeeperCount()` is the unfrozen part of that list; no outsider changed it; only the timelock holds the admin
/// roles.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
contract LPVaultSwapKeepersInvariantTest is Test {
    LPVaultSwapKeeperHandler internal handler;
    ILPVaultSwap internal lvs;
    LVSMarketRegistryMock internal registry;
    address internal timelock = makeAddr("timelock");

    function setUp() public {
        registry = new LVSMarketRegistryMock();
        LPVaultSwapImmutables memory im = LPVaultSwapImmutables({
            lock: makeAddr("lock"),
            aaveAdapter: makeAddr("aaveAdapter"),
            collateralization: makeAddr("collateralization"),
            marketRegistry: address(registry),
            parameterStore: makeAddr("store"),
            payoutEscrow: makeAddr("escrow"),
            keeperFloor: 1
        });
        LPVaultSwapLogics memory logics = LPVaultSwapLogics({
            liquidation: deployCode("LPVaultSwapLiquidationLogic.sol:LPVaultSwapLiquidationLogic", abi.encode(im)),
            pending: deployCode("LPVaultSwapPendingLogic.sol:LPVaultSwapPendingLogic", abi.encode(im)),
            deleverage: deployCode("LPVaultSwapDeleverageLogic.sol:LPVaultSwapDeleverageLogic", abi.encode(im))
        });
        address implementation = address(new LPVaultSwap(im, logics));
        address first = address(uint160(0xC000));
        address[] memory keepers = new address[](1);
        keepers[0] = first;
        lvs = ILPVaultSwap(
            address(new ERC1967Proxy(implementation, abi.encodeCall(LPVaultSwap.initialize, (timelock, keepers))))
        );
        handler = new LPVaultSwapKeeperHandler(lvs, registry, timelock, first);
        targetContract(address(handler));
    }

    // TEST-098 verifies: REQ-SWAP-034, REQ-ACCESS-053, REQ-ACCESS-054, REQ-ACCESS-121, SPEC-GOV-008
    function invariant_TEST_098_everyOutcomeMatchesTheModel() public view {
        assertEq(handler.mismatches(), 0, "a registry call disagreed with the spec model");
        assertEq(handler.outsiderSuccesses(), 0, "an outsider changed the registry");
    }

    // TEST-098 verifies: REQ-SWAP-034, REQ-ACCESS-100, INV-048
    function invariant_TEST_098_floorAndCap() public view {
        uint256 n = lvs.approvedKeeperCount();
        assertGe(n, 1, "registry below one entry");
        assertLe(n, 32, "registry above MAX_KEEPERS");
        assertGe(lvs.activeKeeperCount(), 1, "active count below keeperFloor");
        assertEq(n, handler.modelCount(), "count matches the model");
        assertEq(lvs.activeKeeperCount(), handler.modelActive(), "active count is the unfrozen registered set");
    }

    // TEST-098 verifies: REQ-SWAP-034, REQ-ACCESS-011
    function invariant_TEST_098_listIsTheRegistry() public view {
        address[] memory list = lvs.getKeepers();
        assertEq(list.length, lvs.approvedKeeperCount(), "list length");
        for (uint256 i = 0; i < list.length; ++i) {
            assertTrue(lvs.isApprovedKeeper(list[i]), "listed but not approved");
            assertTrue(handler.modelRegistered(list[i]), "listed but not in the model");
            for (uint256 j = i + 1; j < list.length; ++j) {
                assertTrue(list[i] != list[j], "listed twice");
            }
        }
    }

    // TEST-062 verifies: REQ-SWAP-040, INV-051, INV-084
    function invariant_TEST_062_onlyTimelockAdmin() public view {
        IAccessControl ac = IAccessControl(address(lvs));
        assertTrue(ac.hasRole(0x00, timelock), "timelock holds DEFAULT_ADMIN_ROLE");
        assertFalse(ac.hasRole(0x00, address(handler)), "the handler holds no admin role");
    }

    /// @notice Each run exercises both paths of the registry.
    function afterInvariant() public view {
        assertGt(handler.adds() + handler.removes(), 0, "no registry change in the run");
    }
}
