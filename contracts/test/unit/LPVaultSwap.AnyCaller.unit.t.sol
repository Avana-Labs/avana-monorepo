// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwap} from "../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @notice A contract caller of `liquidate` (a keeper's own contract): funds the call and keeps the payout.
contract LVSContractCaller {
    function liquidate(
        ILPVaultSwap lvs,
        PayoutToken asset,
        LiquidationParams calldata p
    ) external returns (LiquidationResult memory r) {
        asset.approve(address(lvs), p.debtToCover + p.maxShortfall);
        r = lvs.liquidate(p);
    }
}

/// @title LPVaultSwapAnyCallerUnitTest
/// @notice One entry point for every caller (2.11 REQ-SWAP-001, REQ-SWAP-072, REQ-SWAP-085, REQ-SWAP-086, Q-404): a
/// registered committed operator, an unregistered EOA and a contract all liquidate with either route mode under the
/// same checks and the same settlement; the registry is never read and a liquidation never changes it; the caller is
/// always `msg.sender`, so a copied calldata funds itself and pays only its own sender; the address freeze refuses a
/// frozen direct caller only.
/// forge-config: default.isolate = false
contract LPVaultSwapAnyCallerUnitTest is LPVaultSwapUnitBase {
    LVSContractCaller internal bot;

    function setUp() public override {
        super.setUp();
        bot = new LVSContractCaller();
    }

    /// @notice `liquidatePermissionless`, `reportRecoveryShortfall` and `probeLiquidation` do not exist: each call
    /// reverts on dispatch.
    // TEST-174 verifies: REQ-SWAP-072, REQ-SWAP-080, REQ-SWAP-113, REQ-SWAP-031, REQ-SWAP-102, PROP-053
    function test_TEST_174_noSecondEntryPoint() public {
        bytes4[3] memory absent = [
            bytes4(
                keccak256(
                    "liquidatePermissionless((address,uint256,uint256,uint256,uint8,uint256[],uint256,uint256,uint256))"
                )
            ),
            bytes4(keccak256("reportRecoveryShortfall(uint256)")),
            bytes4(keccak256("probeLiquidation(address,uint256,uint256)"))
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok,) = address(lvs).call(abi.encodeWithSelector(absent[i], uint256(0)));
            assertFalse(ok, "unknown selector dispatched");
        }
    }

    /// @notice A registered operator, an unregistered EOA and a contract each liquidate the same account in both
    /// route modes with identical results: no registry, role or caller type changes the settlement.
    // TEST-174 verifies: REQ-SWAP-001, REQ-SWAP-072, REQ-SWAP-085, REQ-SWAP-086, REQ-SWAP-048, INV-030, INV-062, Q-404
    // TEST-045 verifies: REQ-SWAP-001, REQ-SWAP-032, REQ-SWAP-036, INV-048, Q-404
    // TEST-174 verifies: REQ-ACCESS-052, REQ-ACCESS-139, REQ-ACCESS-092, REQ-ACCESS-068
    function test_TEST_174_everyCallerBothModesSameSettlement() public {
        (address proxy,) = _bobAccount();
        assertTrue(lvs.isApprovedKeeper(keeper), "keeper registered");
        assertFalse(lvs.isApprovedKeeper(carol), "carol unregistered");
        address[3] memory callers = [keeper, carol, address(bot)];
        LiquidationResult memory first;
        for (uint256 i = 0; i < callers.length; ++i) {
            for (uint256 m = 0; m < 2; ++m) {
                uint256 snapshot = vm.snapshotState();
                LiquidationParams memory p = _params(proxy, 1950e6);
                p.routeMode = m == 0 ? RouteMode.PrimaryThenBackup : RouteMode.BackupOnly;
                LiquidationResult memory r = _liquidateFrom(callers[i], p);
                if (i == 0 && m == 0) first = r;
                assertEq(r.debtRepaid, first.debtRepaid, "D");
                assertEq(r.recovered, first.recovered, "R (primary and backup at the same rate)");
                assertEq(r.avanaFee, first.avanaFee, "A");
                assertEq(r.keeperOut, first.keeperOut, "keeperOut");
                assertEq(usdc.balanceOf(callers[i]), r.keeperOut, "paid to msg.sender");
                vm.revertToState(snapshot);
            }
        }
    }

    function _liquidateFrom(
        address caller,
        LiquidationParams memory p
    ) internal returns (LiquidationResult memory r) {
        if (caller == address(bot)) {
            usdc.mint(address(bot), p.debtToCover);
            r = bot.liquidate(lvs, usdc, p);
        } else {
            r = _liquidateAs(caller, p);
        }
    }

    /// @notice A liquidation leaves the committed-operator registry unchanged, and an operator removed from it (or
    /// never added) liquidates exactly as before.
    // TEST-045 verifies: REQ-SWAP-001, REQ-SWAP-038, INV-048, PROP-035
    function test_TEST_045_registryNeitherReadNorWritten() public {
        (address proxy,) = _bobAccount();
        address[] memory before = lvs.getKeepers();
        vm.prank(timelock);
        lvs.addKeeper(carol);
        vm.prank(timelock);
        lvs.removeKeeper(keeper);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(r.debtRepaid, 0, "removed operator still liquidates");
        assertEq(lvs.getKeepers().length, before.length, "registry size unchanged by the liquidation");
        assertTrue(lvs.isApprovedKeeper(carol), "registry unchanged");
        assertFalse(lvs.isApprovedKeeper(keeper), "registry unchanged");
    }

    /// @notice A front-runner copying the calldata funds the call itself and receives only what the original caller
    /// would have: no caller or recipient address is taken from calldata (REQ-SWAP-001, REQ-SWAP-046).
    // TEST-174 verifies: REQ-SWAP-001, REQ-SWAP-046, Q-213
    function test_TEST_174_copiedCalldataFundsItself() public {
        (address proxy,) = _bobAccount();
        LiquidationParams memory p = _params(proxy, 1950e6);
        _fund(usdc, keeper, 1950e6);
        // The attacker copies the call but holds no USDC: the pull from msg.sender fails.
        vm.prank(attacker);
        usdc.approve(address(lvs), type(uint256).max);
        vm.prank(attacker);
        vm.expectRevert();
        lvs.liquidate(p);
        // Funded, it settles and is paid as the original caller would have been; the original caller is untouched.
        LiquidationResult memory r = _liquidateAs(attacker, p);
        assertEq(usdc.balanceOf(attacker), r.keeperOut, "attacker paid only its own payout");
        assertEq(usdc.balanceOf(keeper), 1950e6, "keeper's funds untouched");
    }

    /// @notice REQ-SWAP-105: the freeze binds `msg.sender` only. A frozen EOA is refused directly, a contract it
    /// controls is not frozen and liquidates; unfreezing restores the direct call.
    // TEST-229 verifies: REQ-SWAP-105, REQ-SWAP-109, INV-085, PROP-066, Q-242, Q-404
    function test_TEST_229_freezeBindsMsgSenderOnly() public {
        (address proxy,) = _bobAccount();
        registry.setFrozen(carol, true);
        _expectLiquidateRevert(
            carol, _params(proxy, 1950e6), abi.encodeWithSelector(ILPVaultSwapErrors.AddressIsFrozen.selector, carol)
        );
        usdc.mint(address(bot), 1950e6);
        vm.prank(carol);
        LiquidationResult memory r = bot.liquidate(lvs, usdc, _params(proxy, 1950e6));
        assertGt(r.keeperOut, 0, "contract caller settles");
        registry.setFrozen(carol, false);
        _liquidateAs(carol, _params(proxy, 1950e6));
    }

    /// @notice `BackupOnly` never calls the primary route, and either mode is open to every caller.
    // TEST-174 verifies: REQ-SWAP-010, REQ-SWAP-022, REQ-SWAP-072
    function test_TEST_174_backupOnlySkipsPrimary() public {
        (address proxy,) = _bobAccount();
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.routeMode = RouteMode.BackupOnly;
        uint256 primarySwaps = usdtUsdcPool.swaps();
        uint256 backupSwaps = usdtUsdcPool2.swaps();
        _liquidateAs(carol, p);
        assertEq(usdtUsdcPool.swaps(), primarySwaps, "primary never called");
        assertEq(usdtUsdcPool2.swaps(), backupSwaps + 1, "backup called once");
    }

    /// @notice A `routeMode` value outside the enum reverts on ABI decoding (no in-kind mode exists).
    // TEST-174 verifies: REQ-SWAP-010, REQ-SWAP-063, Q-401
    function test_TEST_174_invalidRouteModeRevertsOnDecode() public {
        (address proxy,) = _bobAccount();
        bytes memory data = abi.encodeCall(lvs.liquidate, (_params(proxy, 1950e6)));
        // routeMode is the fifth word of the tuple, after the head offset word.
        assembly {
            mstore(add(data, add(0x24, mul(0x20, 5))), 2)
        }
        _fund(usdc, keeper, 1950e6);
        vm.prank(keeper);
        (bool ok,) = address(lvs).call(data);
        assertFalse(ok, "mode 2 decoded");
    }
}
