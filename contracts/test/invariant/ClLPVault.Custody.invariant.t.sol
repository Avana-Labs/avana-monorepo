// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../../src/amm/IClIntegration.sol";
import {ClLPVaultBase, ClLPVaultSlipstreamHooks, ClLPVaultUniswapHooks} from "../unit/ClLPVault.Base.sol";
import {ClLPVaultCustodyHandler, IClCustodySource} from "./handlers/ClLPVaultCustodyHandler.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title ClLPVaultCustodyInvariants
/// @notice Custody of a concentrated-liquidity LPVault under random sequences of every actor that reaches it
/// (`ClLPVaultCustodyHandler`): depositors, LPVaultSwap's seizures, Collateralization's reconciles, third-party
/// liquidity, an attacker pushing NFTs and calling custody functions directly, the timelock's stray returns, and pool
/// moves. Every exit and seizure the handler makes must succeed (`fail_on_revert`). Each suite runs on the Uniswap v3
/// and the Slipstream LPVault.
abstract contract ClLPVaultCustodyInvariants is ClLPVaultBase, IClCustodySource {
    ClLPVaultCustodyHandler internal handler;

    function _startHandler() internal {
        Core memory c = _cCore();
        handler = new ClLPVaultCustodyHandler(
            _cVault(), this, c.lock, [c.adapter, c.coll, c.lpVaultSwap, c.timelock, attacker], [alice, bob]
        );
        targetContract(address(handler));
    }

    // TEST-084 verifies: INV-005, INV-006, INV-007, REQ-VAULT-152, REQ-VAULT-093
    // Sources: 5.1 TEST-084 (each open record's NFT is owned by the LPVault, depositorOf equals the record's depositor,
    // live liquidity is at least the credited units; NFTs are owned only by wallets or the LPVault)
    /// @notice After every call: each open position is owned by the LPVault with its depositor and market of record and
    /// at least its credited units of live liquidity; each closed one is back with its depositor with no custody entry;
    /// no position is owned by the AaveAdapter, Collateralization, LPVaultSwap or the timelock.
    function invariant_TEST_084_custodyHoldsEveryOpenPosition() public view {
        IClIntegration v = _cVault();
        Core memory c = _cCore();
        uint256 n = handler.keyCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 key = handler.keys(i);
            address owner = IERC721(cManagerOf(key)).ownerOf(cTokenIdOf(key));
            if (handler.isOpen(key)) {
                assertEq(owner, address(v), "an open position is held by the LPVault");
                assertEq(v.depositorOf(key), handler.depositorOfKey(key), "its depositor of record");
                assertEq(v.marketOfPosition(key), handler.marketOfKey(key), "its market of record");
                assertGe(v.unitsOf(key), handler.credited(key), "live units cover the credited units");
            } else {
                assertEq(owner, handler.depositorOfKey(key), "a closed position is back with its depositor");
                assertEq(v.depositorOf(key), address(0), "no entry after it left");
            }
            assertTrue(
                owner != c.adapter && owner != c.coll && owner != c.lpVaultSwap && owner != c.timelock,
                "never held by a core contract"
            );
        }
    }

    // TEST-215 verifies: INV-005, INV-007, INV-033, REQ-VAULT-098, REQ-VAULT-149
    // Sources: 5.1 TEST-215 (multi-actor suite: borrowers, LPVaultSwap, outside LPs, a pool manipulator, an attacker
    // and the timelock; after every step every invariant the state can witness holds) on the LPVault
    /// @notice After every call: no direct custody call, foreign fee collection or stray return of a custodied position
    /// succeeded; every stray is held with no custody entry or back with its sender; LPVaultSwap received exactly the
    /// amounts it was reported; the attacker holds no pool token and the LPVault holds none.
    function invariant_TEST_215_noActorMovesValueOutsideTheRules() public view {
        IClIntegration v = _cVault();
        assertEq(handler.forbiddenSuccesses(), 0, "a call that must fail succeeded");
        uint256 n = handler.strayCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 stray = handler.strays(i);
            address owner = IERC721(cManagerOf(stray)).ownerOf(cTokenIdOf(stray));
            assertEq(v.depositorOf(stray), address(0), "a stray never gets an entry");
            assertEq(
                owner, handler.strayReturned(stray) ? handler.senderOf(stray) : address(v), "stray held or returned"
            );
        }
        assertEq(handler.swapReceived(0), handler.swapReported(0), "LPVaultSwap got exactly what was reported");
        assertEq(handler.swapReceived(1), handler.swapReported(1));
        for (uint256 m = MKT_A; m <= MKT_B; ++m) {
            for (uint256 t = 0; t < 2; ++t) {
                assertEq(_cToken(m, t).balanceOf(attacker), 0, "the attacker took no pool token");
                assertEq(_cToken(m, t).balanceOf(address(v)), 0, "the LPVault holds no pool token");
            }
        }
    }

    // ─── IClCustodySource ───

    function cMintFor(
        uint256 marketId,
        address owner,
        uint128 liquidity
    ) external returns (bytes32) {
        return _cMint(marketId, owner, liquidity);
    }

    function cManagerOf(
        bytes32 key
    ) public view returns (address) {
        return address(_cManager(key));
    }

    function cTokenIdOf(
        bytes32 key
    ) public pure returns (uint256) {
        return _cTokenId(key);
    }

    function cIncreaseLiquidity(
        bytes32 key,
        uint128 liquidity
    ) external {
        vm.prank(bob);
        _cManager(key).increaseLiquidity(_cTokenId(key), liquidity);
    }

    function cAccrue(
        bytes32 key,
        uint128 amount0,
        uint128 amount1
    ) external {
        _cManager(key).accrue(_cTokenId(key), amount0, amount1);
    }

    function cMovePool(
        uint256 marketId,
        int24 tick,
        uint128 outsideLiquidity
    ) external {
        _cPool(marketId).setPrice(tick);
        _cPool(marketId).setLiquidity(outsideLiquidity);
    }
}

/// @notice `ClLPVaultCustodyInvariants` on the Uniswap v3 LPVault.
/// forge-config: default.isolate = false
/// forge-config: default.invariant.fail_on_revert = true
contract UniswapV3IntegrationCustodyInvariantTest is ClLPVaultUniswapHooks, ClLPVaultCustodyInvariants, HandlerReach {
    function setUp() public override {
        super.setUp();
        _startHandler();
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
        Reach memory r = _replayLanded(address(handler), actions, bytes4(0), 32, 50, 0, own, true);
        _check(r, names, new string[](0), _floors(12, 0), new uint256[](0));
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions() internal pure returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds) {
        (actions, names, kinds) = (new bytes4[](12), new string[](12), new int16[][](12));
        (actions[0], names[0]) = (ClLPVaultCustodyHandler.accrue.selector, "accrue");
        kinds[0] = new int16[](3);
        kinds[0][0] = 256;
        kinds[0][1] = 128;
        kinds[0][2] = 128;
        (actions[1], names[1]) = (ClLPVaultCustodyHandler.attackDirect.selector, "attackDirect");
        kinds[1] = new int16[](4);
        kinds[1][0] = 256;
        kinds[1][1] = 256;
        kinds[1][2] = 256;
        kinds[1][3] = 1;
        (actions[2], names[2]) = (ClLPVaultCustodyHandler.collect.selector, "collect");
        kinds[2] = new int16[](2);
        kinds[2][0] = 256;
        kinds[2][1] = 1;
        (actions[3], names[3]) = (ClLPVaultCustodyHandler.donateLiquidity.selector, "donateLiquidity");
        kinds[3] = new int16[](2);
        kinds[3][0] = 256;
        kinds[3][1] = 128;
        (actions[4], names[4]) = (ClLPVaultCustodyHandler.movePool.selector, "movePool");
        kinds[4] = new int16[](3);
        kinds[4][0] = 256;
        kinds[4][1] = -24;
        kinds[4][2] = 128;
        (actions[5], names[5]) = (ClLPVaultCustodyHandler.partialRemoval.selector, "partialRemoval");
        kinds[5] = new int16[](2);
        kinds[5][0] = 256;
        kinds[5][1] = 256;
        (actions[6], names[6]) = (ClLPVaultCustodyHandler.pledge.selector, "pledge");
        kinds[6] = new int16[](3);
        kinds[6][0] = 256;
        kinds[6][1] = 256;
        kinds[6][2] = 128;
        (actions[7], names[7]) = (ClLPVaultCustodyHandler.pushStray.selector, "pushStray");
        kinds[7] = new int16[](2);
        kinds[7][0] = 128;
        kinds[7][1] = 1;
        (actions[8], names[8]) = (ClLPVaultCustodyHandler.reconcile.selector, "reconcile");
        kinds[8] = new int16[](2);
        kinds[8][0] = 256;
        kinds[8][1] = 256;
        (actions[9], names[9]) = (ClLPVaultCustodyHandler.returnStray.selector, "returnStray");
        kinds[9] = new int16[](2);
        kinds[9][0] = 256;
        kinds[9][1] = 1;
        (actions[10], names[10]) = (ClLPVaultCustodyHandler.seize.selector, "seize");
        kinds[10] = new int16[](2);
        kinds[10][0] = 256;
        kinds[10][1] = 256;
        (actions[11], names[11]) = (ClLPVaultCustodyHandler.withdraw.selector, "withdraw");
        kinds[11] = new int16[](1);
        kinds[11][0] = 256;
    }

    function _calldata(bytes4 selector, uint256 seed) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
    }
}

/// @notice `ClLPVaultCustodyInvariants` on the Slipstream LPVault.
/// forge-config: default.isolate = false
/// forge-config: default.invariant.fail_on_revert = true
contract SlipstreamIntegrationCustodyInvariantTest is ClLPVaultSlipstreamHooks, ClLPVaultCustodyInvariants {
    function setUp() public override {
        super.setUp();
        _startHandler();
    }
}
