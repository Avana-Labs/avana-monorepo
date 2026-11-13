// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../../src/amm/IClIntegration.sol";
import {ClLPVaultBase, ClLPVaultSlipstreamHooks, ClLPVaultUniswapHooks} from "../unit/ClLPVault.Base.sol";
import {ClLPVaultCustodyHandler, IClCustodySource} from "./handlers/ClLPVaultCustodyHandler.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

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
contract UniswapV3IntegrationCustodyInvariantTest is ClLPVaultUniswapHooks, ClLPVaultCustodyInvariants {
    function setUp() public override {
        super.setUp();
        _startHandler();
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
