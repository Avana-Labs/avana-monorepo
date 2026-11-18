// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {
    IV4InvariantSource,
    IV4StateViewFees,
    UniswapV4FeesCustodyHandler
} from "./handlers/UniswapV4FeesCustodyHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title UniswapV4IntegrationFeesCustodyInvariantTest
/// @notice TEST-091, TEST-084 and TEST-215 (on the LPVault) on the Uniswap v4 LPVault over the real PoolManager,
/// PositionManager and StateView (`out-univ4/`), the real Lock and named Avana callers, with a USDC/USDT market and a
/// native ETH/USDC market (`UniswapV4IntegrationFixture`), each pool with a full-range background position so swaps move
/// the price inside a band around the markets' ranges. Random sequences of `UniswapV4FeesCustodyHandler`'s actions:
/// pledges by two depositors, partial releases, fee collections naming the depositor, the other depositor or an
/// attacker, withdrawals, seizures to LPVaultSwap and reconciliations to Collateralization of any part of a position,
/// swaps, spot moves and donations, USDC blocklisting the second depositor, stray pushes and returns, and direct custody
/// and PositionManager calls by an attacker. After every call: only the depositor of record is paid fees; no seizure
/// lowers a position's owed fees except the fallback removal of `REQ-AMM-V4-013` when USDC refuses the depositor (the
/// fees then go to the recipient with the principal); for every position, the fees owed (or left in the NFT at
/// withdrawal) plus the fees paid plus the fees of fallback removals equal the fees accrued; custody holds for every
/// NFT the PositionManager has minted.
/// forge-config: default.isolate = false
contract UniswapV4IntegrationFeesCustodyInvariantTest is UniswapV4IntegrationFixture, HandlerReach, IV4InvariantSource {
    /// @dev Background liquidity of each pool: full range, so every price in the handler's bands has depth.
    uint128 internal constant BACKGROUND = 1e18;

    UniswapV4FeesCustodyHandler internal handler;

    function setUp() public override {
        super.setUp();
        _mintV4(address(this), stableKey, -887_272, 887_272, BACKGROUND);
        _mintV4(address(this), ethKey, -887_270, 887_270, BACKGROUND);
        PoolKey[2] memory keys_ = [stableKey, ethKey];
        handler = new UniswapV4FeesCustodyHandler(
            UniswapV4FeesCustodyHandler.Wiring({
                vault: vault,
                posm: posm,
                poolActor: v4Actor,
                stateView: IV4StateViewFees(stateView),
                source: this,
                lock: lock
            }),
            [adapter, coll, lpVaultSwap, governor, attacker],
            [alice, bob],
            keys_,
            address(weth)
        );
        // Each depositor starts with a position in each market, so the first calls of a run find work.
        for (uint256 i = 0; i < 4; ++i) {
            handler.pledge(i, i / 2, uint128(type(uint128).max / (i + 2)));
        }
        targetContract(address(handler));
        (bytes4[] memory actions,,) = _reachActions();
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    /// @inheritdoc IV4InvariantSource
    function v4MintFor(
        uint256 marketId,
        address owner,
        uint128 liquidity
    ) external returns (bytes32) {
        require(msg.sender == address(handler), "handler only");
        if (marketId == M1) return _mintFor(owner, stableKey, M1_LOWER, M1_UPPER, liquidity);
        return _mintFor(owner, ethKey, M2_LOWER, M2_UPPER, liquidity);
    }

    // TEST-091 verifies: INV-033, REQ-VAULT-064, REQ-VAULT-065, REQ-VAULT-120, REQ-AMM-CORE-010, REQ-AMM-V4-004, Q-030, Q-061
    // Sources: 5.1 TEST-091 (fee collection pays only the depositor of record), QNT-11, HYP-28
    /// @notice No pool token reached anyone but the position's depositor (or a removal's recipient, exactly the amounts
    /// returned), no collection naming someone else succeeded, and every collection and release paid exactly the fees
    /// the PoolManager owed, read from StateView.
    function invariant_TEST_091_v4FeesOnlyToDepositor() public view {
        assertEq(handler.paidToOthers(), 0, "a pool token reached someone other than the depositor or recipient");
        assertEq(handler.foreignCollections(), 0, "a collection for another address succeeded");
        assertEq(handler.wrongCollections(), 0, "a collection paid other than every owed fee");
        assertEq(handler.wrongReleases(), 0, "a release paid other than every owed fee");
        assertEq(handler.recipientMismatch(), 0, "a recipient received other than the returned amounts");
    }

    // TEST-091 verifies: INV-033, REQ-VAULT-058, REQ-VAULT-067, REQ-AMM-V4-004, REQ-AMM-V4-010, REQ-AMM-V4-013, SPEC-BACK-008, SPEC-AMM-V4-003, Q-061
    // Sources: 5.1 TEST-091 (no liquidation reduces a record's owed fees)
    /// @notice No seizure or reconciliation lowered a position's owed fees: an accepting depositor received exactly the
    /// owed fees, and a depositor USDC refuses received nothing while the recipient's returned amounts covered the fees
    /// (the documented fallback). For every position: owed (or left in the NFT at withdrawal) + paid + fallback = accrued.
    function invariant_TEST_091_v4SeizureNeverReducesOwedFees() public view {
        assertEq(handler.feesCut(), 0, "a seizure took owed fees outside the fallback");
        assertEq(handler.owedFell(), 0, "a pool action lowered owed fees");
        uint256 n = handler.keyCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 key = handler.keys(i);
            (uint256 o0, uint256 o1) = handler.isOpen(key) ? handler.owed(key) : handler.leftWithNft(key);
            (uint256 p0, uint256 p1) = handler.paid(key);
            (uint256 f0, uint256 f1) = handler.forfeited(key);
            (uint256 a0, uint256 a1) = handler.accrued(key);
            assertEq(o0 + p0 + f0, a0, "token0: owed + paid + fallback = accrued");
            assertEq(o1 + p1 + f1, a1, "token1: owed + paid + fallback = accrued");
            if (handler.depositorOfKey(key) != bob) {
                assertEq(f0 + f1, 0, "fallback only for the blocklisted depositor");
            }
        }
    }

    // TEST-084 verifies: INV-002, INV-005, INV-006, INV-007, REQ-VAULT-152, REQ-VAULT-093
    // Sources: 5.1 TEST-084 (each open record's NFT is owned by the LPVault; NFTs are owned only by wallets or the
    // LPVault)
    /// @notice After every call, over every NFT the PositionManager has minted: an open position is held by the LPVault
    /// with its depositor and market of record; a withdrawn one is back with its depositor with no entry; anything else
    /// the LPVault holds is an unreturned stray with no entry; a returned stray is with its sender; no NFT is held by the
    /// AaveAdapter, Collateralization, LPVaultSwap or the timelock. Every pledge, seizure, reconciliation, accepted
    /// collection, release, withdrawal and stray return succeeded.
    function invariant_TEST_084_v4CustodyHoldsEveryRecordedPosition() public view {
        assertEq(handler.liveFailures(), 0, "a call the rules allow failed");
        uint256 next = posm.nextTokenId();
        for (uint256 id = 1; id < next; ++id) {
            bytes32 key = bytes32(id);
            address owner = posm.ownerOf(id);
            address recorded = handler.depositorOfKey(key);
            if (recorded != address(0) && handler.isOpen(key)) {
                assertEq(owner, address(vault), "an open position is held by the LPVault");
                assertEq(vault.depositorOf(key), recorded, "its depositor of record");
                assertEq(vault.marketOfPosition(key), handler.marketOfKey(key), "its market of record");
            } else if (recorded != address(0)) {
                assertEq(owner, recorded, "a withdrawn position is back with its depositor");
                assertEq(vault.depositorOf(key), address(0), "no entry after it left");
            } else {
                assertEq(vault.depositorOf(key), address(0), "an NFT never pledged has no entry");
                if (owner == address(vault)) {
                    assertEq(handler.senderOf(key), attacker, "the LPVault holds only records and strays");
                    assertFalse(handler.strayReturned(key), "a returned stray left the LPVault");
                } else if (handler.strayReturned(key)) {
                    assertEq(owner, handler.senderOf(key), "a returned stray is with its sender");
                }
            }
            assertTrue(
                owner != adapter && owner != coll && owner != lpVaultSwap && owner != governor,
                "never held by a core contract"
            );
        }
    }

    // TEST-215 verifies: INV-005, INV-007, INV-021, INV-033, REQ-VAULT-098, REQ-VAULT-149, REQ-AMM-V4-014, REQ-AMM-CORE-010
    // Sources: 5.1 TEST-215 (multi-actor suite: after every step every invariant the state can witness holds) on the
    // LPVault
    /// @notice After every call: no direct custody call, stray return of a custodied position, or attacker transfer or
    /// decrease of a custodied position succeeded; the LPVault holds no pool token, no WETH and no ether; the attacker
    /// holds no pool token.
    function invariant_TEST_215_v4NoActorMovesValueOutsideTheRules() public view {
        assertEq(handler.forbiddenSuccesses(), 0, "a call that must fail succeeded");
        for (uint256 t = 0; t < 3; ++t) {
            IERC20 token = IERC20(handler.tokens(t));
            assertEq(token.balanceOf(address(vault)), 0, "the LPVault holds no pool token");
            assertEq(token.balanceOf(attacker), 0, "the attacker took no pool token");
        }
        assertEq(address(vault).balance, 0, "the LPVault holds no ether");
    }

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls, and the fallback removal must be reached (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r = _replayLanded(
            address(handler), actions, UniswapV4FeesCustodyHandler.Skipped.selector, 32, 50, 1, own, true
        );
        // Floors: 80 % of the landed share measured with these seeds, rounded down to 5 %; a check's normal return lands.
        uint256[] memory floors = new uint256[](12);
        bool[] memory check = new bool[](12);
        floors[0] = 65; // attack
        check[0] = true;
        floors[1] = 10; // collect
        floors[2] = 80; // donate
        floors[3] = 80; // moveSpot
        floors[4] = 60; // partialRemoval
        floors[5] = 75; // pledge
        floors[6] = 60; // pushStray
        floors[7] = 20; // returnStray
        floors[8] = 75; // seize
        floors[9] = 80; // toggleBlocked
        check[9] = true;
        floors[10] = 80; // swap
        floors[11] = 70; // withdraw
        string[] memory targets = new string[](1);
        targets[0] = "fallback seizure";
        uint256[] memory targetFloors = new uint256[](1);
        targetFloors[0] = 40;
        _check(r, names, targets, floors, targetFloors, check);
    }

    function _reached() internal view override returns (bool[] memory hit) {
        hit = new bool[](1);
        hit[0] = handler.fallbackSeizures() > 0;
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions()
        internal
        pure
        returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds)
    {
        (actions, names, kinds) = (new bytes4[](12), new string[](12), new int16[][](12));
        (actions[0], names[0]) = (UniswapV4FeesCustodyHandler.attack.selector, "attack");
        kinds[0] = _kinds4(256, 256, 256, 1);
        (actions[1], names[1]) = (UniswapV4FeesCustodyHandler.collect.selector, "collect");
        kinds[1] = _kinds2(256, 256);
        (actions[2], names[2]) = (UniswapV4FeesCustodyHandler.donate.selector, "donate");
        kinds[2] = _kinds3(256, 256, 256);
        (actions[3], names[3]) = (UniswapV4FeesCustodyHandler.moveSpot.selector, "moveSpot");
        kinds[3] = _kinds2(256, -24);
        (actions[4], names[4]) = (UniswapV4FeesCustodyHandler.partialRemoval.selector, "partialRemoval");
        kinds[4] = _kinds2(256, 256);
        (actions[5], names[5]) = (UniswapV4FeesCustodyHandler.pledge.selector, "pledge");
        kinds[5] = _kinds3(256, 256, 128);
        (actions[6], names[6]) = (UniswapV4FeesCustodyHandler.pushStray.selector, "pushStray");
        kinds[6] = _kinds2(128, 1);
        (actions[7], names[7]) = (UniswapV4FeesCustodyHandler.returnStray.selector, "returnStray");
        kinds[7] = _kinds2(256, 1);
        (actions[8], names[8]) = (UniswapV4FeesCustodyHandler.seize.selector, "seize");
        kinds[8] = _kinds3(256, 256, 1);
        (actions[9], names[9]) = (UniswapV4FeesCustodyHandler.toggleBlocked.selector, "toggleBlocked");
        kinds[9] = new int16[](0);
        (actions[10], names[10]) = (UniswapV4FeesCustodyHandler.swap.selector, "swap");
        kinds[10] = _kinds3(256, 1, 256);
        (actions[11], names[11]) = (UniswapV4FeesCustodyHandler.withdraw.selector, "withdraw");
        kinds[11] = new int16[](1);
        kinds[11][0] = 256;
    }

    function _kinds2(
        int16 a,
        int16 b
    ) internal pure returns (int16[] memory k) {
        k = new int16[](2);
        (k[0], k[1]) = (a, b);
    }

    function _kinds3(
        int16 a,
        int16 b,
        int16 c
    ) internal pure returns (int16[] memory k) {
        k = new int16[](3);
        (k[0], k[1], k[2]) = (a, b, c);
    }

    function _kinds4(
        int16 a,
        int16 b,
        int16 c,
        int16 d
    ) internal pure returns (int16[] memory k) {
        k = new int16[](4);
        (k[0], k[1], k[2], k[3]) = (a, b, c, d);
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
}
