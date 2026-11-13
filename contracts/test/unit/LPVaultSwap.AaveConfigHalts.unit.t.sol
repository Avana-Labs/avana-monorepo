// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

interface IAaveRiskConfigurator {
    function updateLiquidationFee(
        address spoke,
        uint256 reserveId,
        uint32 dynamicConfigKey,
        uint256 liquidationFee
    ) external;

    function updateReceiveSharesEnabled(
        address spoke,
        uint256 reserveId,
        bool receiveSharesEnabled
    ) external;
}

/// @notice Runs two LPVaultSwap liquidations in one transaction, optionally with a reverting one between them.
contract TwoLiquidations {
    function run(
        address lvs,
        address asset,
        LiquidationParams calldata a,
        LiquidationParams calldata failing,
        LiquidationParams calldata b,
        bool withFailure
    ) external returns (LiquidationResult memory ra, LiquidationResult memory rb, bool failed) {
        (bool okA,) = asset.call(abi.encodeWithSignature("approve(address,uint256)", lvs, type(uint256).max));
        require(okA, "approve");
        ra = ILiquidate(lvs).liquidate(a);
        if (withFailure) {
            try ILiquidate(lvs).liquidate(failing) returns (LiquidationResult memory) {}
            catch {
                failed = true;
            }
        }
        rb = ILiquidate(lvs).liquidate(b);
    }
}

interface ILiquidate {
    function liquidate(
        LiquidationParams calldata p
    ) external returns (LiquidationResult memory);
}

/// @title LPVaultSwapAaveConfigHaltsUnitTest
/// @notice Adversarial hypotheses on Aave-side configuration and on transient state, on the real local Aave V4, the real
/// LPVaultSwap, Collateralization, Lock and vault token. Each test asserts what the code does today.
/// forge-config: default.isolate = false
contract LPVaultSwapAaveConfigHaltsUnitTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    function _vtKey() internal view returns (uint32) {
        return IAaveV4Spoke(aave.cdpSpoke).getUserPosition(vtReserveId, proxy).dynamicConfigKey;
    }

    function _gap() internal view returns (int256) {
        ICollateralizationViews v = ICollateralizationViews(address(coll));
        return int256(v.getTotalCredited(address(vt)) + v.getPending(address(vt)).units) - int256(vt.totalSupply());
    }

    function _setFee(
        uint256 feeBps
    ) internal {
        uint32 key = _vtKey();
        vm.prank(aaveDao);
        IAaveRiskConfigurator(aave.spokeConfigurator).updateLiquidationFee(aave.cdpSpoke, vtReserveId, key, feeBps);
    }

    // TEST-055 verifies: ATTACK-202, ATTACK-120, SPEC-BACK-007, REQ-VAULT-051, REQ-SWAP-003
    /// @notice H1: with `liquidationFee > 0` on the vault-token reserve's key, Aave moves fee shares inside the Hub to
    /// its fee receiver, so the proxy's share drop exceeds the units LPVaultSwap receives. The liquidation settles: the
    /// seized units are debited and unwound to LPVaultSwap, the fee units are debited into the pending balance, the
    /// backing gap is unchanged and the account's credit equals its supplied shares again.
    function test_TEST_055_liquidationFeeOnVaultReserveIsReconciled() public {
        _setFee(1000);
        uint256 sharesBefore = _suppliedUnits(proxy);
        uint256 supplyBefore = vt.totalSupply();
        uint256 pendingBefore = ICollateralizationViews(address(coll)).getPending(address(vt)).units;
        int256 gapBefore = _gap();
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        uint256 drop = sharesBefore - _suppliedUnits(proxy);
        uint256 fee = drop - r.unitsSeized;
        assertGt(r.unitsSeized, 0, "seized");
        assertGt(fee, 0, "Aave took fee shares");
        assertEq(supplyBefore - vt.totalSupply(), r.unitsSeized, "only the seized units were burned");
        assertEq(
            ICollateralizationViews(address(coll)).getPending(address(vt)).units,
            pendingBefore + fee,
            "fee units pending"
        );
        assertEq(_gap(), gapBefore, "backing gap unchanged");
        assertEq(
            ICollateralizationViews(address(coll)).getAccountCredited(proxy, address(vt)),
            _suppliedUnits(proxy),
            "credit equals supplied shares"
        );
    }

    // TEST-055 verifies: ATTACK-202, SPEC-BACK-007, REQ-VAULT-051
    /// @notice Over any liquidation fee Aave can set (1 bp to 50 %), the liquidation settles, the fee units go to the
    /// pending balance and the backing gap does not move.
    function testFuzz_TEST_055_anyLiquidationFeeIsReconciled(
        uint16 feeBps
    ) public {
        feeBps = uint16(bound(feeBps, 1, 5000));
        _setFee(feeBps);
        uint256 sharesBefore = _suppliedUnits(proxy);
        uint256 pendingBefore = ICollateralizationViews(address(coll)).getPending(address(vt)).units;
        int256 gapBefore = _gap();
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        uint256 fee = sharesBefore - _suppliedUnits(proxy) - r.unitsSeized;
        assertEq(ICollateralizationViews(address(coll)).getPending(address(vt)).units, pendingBefore + fee);
        assertEq(_gap(), gapBefore);
    }

    // TEST-055 verifies: ATTACK-203, REQ-ADAPTER-029
    /// @notice H3: with `receiveSharesEnabled` on the vault-token reserve, any address liquidates a proxy with
    /// `receiveShares = true` and takes its supply shares inside the Spoke with no vault-token transfer; withdrawing them
    /// is still refused by the vault token, but the shares sit as the attacker's own collateral position on the CDP
    /// Spoke, outside every Avana record.
    function test_TEST_055_receiveSharesMovesCollateralOutsideAvana() public {
        vm.prank(aaveDao);
        IAaveRiskConfigurator(aave.spokeConfigurator).updateReceiveSharesEnabled(aave.cdpSpoke, vtReserveId, true);
        uint256 before = _suppliedUnits(proxy);
        usdc.mint(attacker, 1950e6);
        vm.startPrank(attacker);
        usdc.approve(aave.cdpSpoke, 1950e6);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, usdcReserveId, proxy, 1950e6, true);
        uint256 taken = IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, attacker);
        assertGt(taken, 0, "the attacker holds vault-token shares on the CDP Spoke");
        assertEq(_suppliedUnits(proxy), before - taken, "taken from the proxy");
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, aave.hub, attacker));
        IAaveV4Spoke(aave.cdpSpoke).withdraw(vtReserveId, taken, attacker);
        vm.stopPrank();
        assertEq(vt.balanceOf(attacker), 0, "no vault token left the Hub");
    }

    // TEST-055 verifies: REQ-SWAP-039, REQ-SWAP-007
    /// @notice H4: added shares differ from added assets on the vault-token Hub asset only through Aave-side actions
    /// (fee shares, a draw, a deficit); while they differ, every seizure of the market reverts `SharesNotEqualAssets`.
    /// Ordinary supply and withdrawal of odd amounts keep them equal.
    function test_TEST_055_sharesEqualAssetsHoldsAndItsBreachHalts() public {
        IAaveV4Hub hub = IAaveV4Hub(aave.hub);
        assertEq(hub.getAddedAssets(vtAssetId), hub.getAddedShares(vtAssetId), "equal at launch");
        _openAccount(carol, 1_234_567, 1, 250_000_000);
        assertEq(hub.getAddedAssets(vtAssetId), hub.getAddedShares(vtAssetId), "odd supply keeps them equal");
        vm.mockCall(
            aave.hub, abi.encodeWithSelector(IAaveV4Hub.getAddedAssets.selector, vtAssetId), abi.encode(uint256(1))
        );
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.SharesNotEqualAssets.selector));
        vm.clearMockedCalls();
    }

    // TEST-055 verifies: REQ-SWAP-002, REQ-LOCK-007
    /// @notice H16: two liquidations in one transaction, with a third that reverts after the Lock was taken between
    /// them, leave no transient state behind: the second one settles exactly as it does alone, and the Lock is free.
    function test_TEST_055_twoLiquidationsInOneTransaction() public {
        (address carolProxy,) = _carolAccount();
        TwoLiquidations multi = new TwoLiquidations();
        LiquidationParams memory a = _params(proxy, 1950e6);
        LiquidationParams memory b = _params(carolProxy, 1950e6);
        LiquidationParams memory failing = _params(proxy, 1950e6);
        failing.minPayout = type(uint256).max; // reverts PayoutTooLow at the end, after the seizure and the swaps
        uint256 snap = vm.snapshotState();
        LiquidationResult memory alone = _liquidateAs(keeper, b);
        vm.revertToState(snap);
        usdc.mint(address(multi), 10_000e6);
        vm.prank(keeper);
        (LiquidationResult memory ra, LiquidationResult memory rb, bool failed) =
            multi.run(address(lvs), address(usdc), a, failing, b, true);
        assertTrue(failed, "the middle call reverted");
        assertGt(ra.unitsSeized, 0, "first settled");
        assertEq(rb.unitsSeized, alone.unitsSeized, "second identical to a lone call");
        assertEq(rb.debtRepaid, alone.debtRepaid, "same repayment");
        assertEq(rb.minOut, alone.minOut, "same floor");
        assertFalse(lock.isLocked(), "Lock free at the end");
        assertEq(lock.holder(), address(0), "no holder");
    }
}
