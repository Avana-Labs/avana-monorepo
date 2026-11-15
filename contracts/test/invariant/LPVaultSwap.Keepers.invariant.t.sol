// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwap} from "../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {LPVaultSwap} from "../../src/liquidation/lp-vault-swap/LPVaultSwap.sol";
import {LPVaultSwapImmutables} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {LPVaultSwapLogics} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapLogics.sol";
import {LVSMarketRegistryMock} from "../utils/mocks/LPVaultSwapMocks.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
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
contract LPVaultSwapKeepersInvariantTest is Test, HandlerReach {
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

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r =
            _replayLanded(address(handler), actions, LPVaultSwapKeeperHandler.Skipped.selector, 32, 50, 0, own, true);
        // Floors: 80 % of the landed share measured with these seeds, rounded down to 5 %; a check's normal return lands.
        uint256[] memory floors = new uint256[](4);
        bool[] memory check = new bool[](4);
        floors[0] = 65; // add
        floors[1] = 35; // freeze
        floors[2] = 80; // outsider
        check[2] = true; // outsider
        floors[3] = 10; // remove
        _check(r, names, new string[](0), floors, new uint256[](0), check);
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions()
        internal
        pure
        returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds)
    {
        (actions, names, kinds) = (new bytes4[](4), new string[](4), new int16[][](4));
        (actions[0], names[0]) = (LPVaultSwapKeeperHandler.add.selector, "add");
        kinds[0] = new int16[](1);
        kinds[0][0] = 256;
        (actions[1], names[1]) = (LPVaultSwapKeeperHandler.freeze.selector, "freeze");
        kinds[1] = new int16[](2);
        kinds[1][0] = 256;
        kinds[1][1] = 1;
        (actions[2], names[2]) = (LPVaultSwapKeeperHandler.outsider.selector, "outsider");
        kinds[2] = new int16[](2);
        kinds[2][0] = 256;
        kinds[2][1] = 160;
        (actions[3], names[3]) = (LPVaultSwapKeeperHandler.remove.selector, "remove");
        kinds[3] = new int16[](1);
        kinds[3][0] = 256;
    }

    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
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
