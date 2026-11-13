// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FlashLiquidator} from "../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {OperatorFlashLiquidator} from "../../src/periphery/flash-liquidator/OperatorFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";

/// @title LPVaultSwapFlashHelperGuardsIntegrationTest
/// @notice The flash liquidation helper's fixed shape and its refusals (2.11 REQ-HELPER-001, REQ-HELPER-012,
/// REQ-HELPER-013) against the real LPVaultSwap on the local Aave V4: its immutables, no admin surface, nothing held
/// after a call, the request's `params` passed to `liquidate` unchanged with the payout to the caller only, and every
/// refusal of the failure table before LPVaultSwap is called.
/// forge-config: default.isolate = false
contract LPVaultSwapFlashHelperGuardsIntegrationTest is LPVaultSwapUnitBase {
    FlashLiquidator internal helper;
    OperatorFlashLiquidator internal opHelper;
    address internal signer = makeAddr("operatorSigner");
    address internal safe = makeAddr("operatorSafe");
    address internal proxy;

    function setUp() public override {
        super.setUp();
        helper = new FlashLiquidator(address(v3Pool), address(lvs), address(registry), address(store));
        opHelper = new OperatorFlashLiquidator(
            address(v3Pool), address(lvs), address(registry), address(store), signer, safe, 100
        );
        (proxy,) = _bobAccount();
    }

    function _request(
        uint256 x,
        uint256 f
    ) internal view returns (FlashLiquidationRequest memory q) {
        q.params = _params(proxy, x);
        q.flashAmount = f;
        q.maxPremium = type(uint128).max;
    }

    /// @notice The immutables are the Pool, LPVaultSwap, MarketRegistry and ParameterStore (and the operator's signer,
    /// Safe and top-up bound); there is no owner, admin, upgrade, setter, sweep, rescue or arbitrary-call selector; a
    /// zero constructor address or a top-up bound above 10⁴ bps is refused; after a call whose route leaves a USDT
    /// residue, the helper holds no balance and no allowance of the debt asset, the market's tokens or GHO.
    // TEST-289 verifies: REQ-HELPER-001, REQ-HELPER-015
    function test_TEST_289_fixedShapeAndNothingHeldAfterACall() public {
        assertEq(helper.POOL(), address(v3Pool), "POOL");
        assertEq(helper.LP_VAULT_SWAP(), address(lvs), "LP_VAULT_SWAP");
        assertEq(helper.MARKET_REGISTRY(), address(registry), "MARKET_REGISTRY");
        assertEq(helper.PARAMETER_STORE(), address(store), "PARAMETER_STORE");
        assertEq(opHelper.SIGNER(), signer, "SIGNER");
        assertEq(opHelper.FUNDING_SAFE(), safe, "FUNDING_SAFE");
        assertEq(opHelper.MAX_TOP_UP_BPS(), 100, "MAX_TOP_UP_BPS");

        bytes[8] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("transferOwnership(address)", attacker),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", attacker, ""),
            abi.encodeWithSignature("setPool(address)", attacker),
            abi.encodeWithSignature("sweep(address,address)", address(usdc), attacker),
            abi.encodeWithSignature("rescue(address,address,uint256)", address(usdc), attacker, 1),
            abi.encodeWithSignature("execute(address,bytes)", attacker, ""),
            abi.encodeWithSignature("multicall(bytes[])", new bytes[](0))
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool ok,) = address(helper).call(calls[i]);
            assertFalse(ok, "no admin or arbitrary-call selector");
            (ok,) = address(opHelper).call(calls[i]);
            assertFalse(ok, "none on the operator variant");
        }

        vm.expectRevert(IFlashLiquidatorErrors.ZeroAddress.selector);
        new FlashLiquidator(address(v3Pool), address(0), address(registry), address(store));
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.InvalidTopUpBps.selector, 10_001));
        new OperatorFlashLiquidator(
            address(v3Pool), address(lvs), address(registry), address(store), signer, safe, 10_001
        );

        (, uint256 a1) = _released(975e6);
        usdtUsdcPool.setMaxIn(a1 - 7);
        vm.prank(carol);
        helper.flashLiquidate(_request(1950e6, 1950e6));
        assertEq(usdt.balanceOf(carol), 7, "the residue reached the caller");
        PayoutToken[3] memory tokens = [usdc, usdt, gho];
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(tokens[i].balanceOf(address(helper)), 0, "no balance held");
            assertEq(tokens[i].allowance(address(helper), address(lvs)), 0, "no allowance to LPVaultSwap");
            assertEq(tokens[i].allowance(address(helper), address(v3Pool)), 0, "no allowance to the Pool");
        }
    }

    /// @notice The request's `params` reach `liquidate` unchanged; the request carries no route, swap step, recipient
    /// or calldata, so the only routes used are the market's own and the payout goes to the caller alone.
    // TEST-289 verifies: REQ-HELPER-012, REQ-HELPER-010
    function test_TEST_289_paramsPassedUnchangedAndPaidToTheCallerOnly() public {
        FlashLiquidationRequest memory q = _request(1950e6, 1950e6);
        vm.expectCall(address(lvs), abi.encodeCall(lvs.liquidate, (q.params)), 1);
        uint256 swaps = usdtUsdcPool.swaps();
        uint256[4] memory before =
            [usdc.balanceOf(carol), usdc.balanceOf(bob), usdc.balanceOf(attacker), usdc.balanceOf(address(helper))];
        vm.prank(carol);
        uint256 payout = helper.flashLiquidate(q);
        assertGt(payout, 0, "settled");
        assertEq(usdtUsdcPool.swaps(), swaps + 1, "the market's own primary route swapped the USDT leg");
        assertEq(usdc.balanceOf(carol), before[0] + payout, "the caller is paid");
        assertEq(usdc.balanceOf(bob), before[1], "no payment to the borrower");
        assertEq(usdc.balanceOf(attacker), before[2], "no other recipient");
        assertEq(usdc.balanceOf(address(helper)), before[3], "the helper keeps nothing");
    }

    /// @notice Each refusal of the failure table happens before LPVaultSwap is called: `F = 0` on the public helper, `F
    /// > X`, `X` or `maxShortfall` above `2¹²⁸ − 1` (`InvalidFlashAmount`); a non-signer on the operator variant
    /// (`NotSigner`); a Pool recorded as a Hub (`FlashSourceIsHub`); the Pool's callback with no open context, from the
    /// Pool or from anyone else (`InvalidFlashCallback`). The account's debt and collateral are unchanged.
    // TEST-289 verifies: REQ-HELPER-013, REQ-HELPER-003, REQ-HELPER-002
    function test_TEST_289_refusalsBeforeLPVaultSwapIsCalled() public {
        uint256 debt = _debtOf(proxy, usdcReserveId);
        uint256 units = _suppliedUnits(proxy);
        vm.expectCall(address(lvs), abi.encodeWithSelector(lvs.liquidate.selector), 0);
        bytes memory invalid = abi.encodeWithSelector(IFlashLiquidatorErrors.InvalidFlashAmount.selector);

        _expectRefused(address(helper), carol, _request(1950e6, 0), invalid);
        _expectRefused(address(helper), carol, _request(1950e6, 1950e6 + 1), invalid);
        FlashLiquidationRequest memory q = _request(1950e6, 1);
        q.params.debtToCover = uint256(type(uint128).max) + 1;
        _expectRefused(address(helper), carol, q, invalid);
        q = _request(1950e6, 1950e6);
        q.params.maxShortfall = uint256(type(uint128).max) + 1;
        _expectRefused(address(helper), carol, q, invalid);

        _expectRefused(
            address(opHelper),
            carol,
            _request(1950e6, 1950e6),
            abi.encodeWithSelector(IFlashLiquidatorErrors.NotSigner.selector)
        );

        registry.setRecordedHub(address(v3Pool), true);
        _expectRefused(
            address(helper),
            carol,
            _request(1950e6, 1950e6),
            abi.encodeWithSelector(IFlashLiquidatorErrors.FlashSourceIsHub.selector)
        );
        registry.setRecordedHub(address(v3Pool), false);

        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1950e6;
        uint256[] memory premiums = new uint256[](1);
        bytes memory data = abi.encode(_params(proxy, 1950e6));
        address[2] memory callers = [address(v3Pool), attacker];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
            helper.executeOperation(assets, amounts, premiums, address(helper), data);
        }

        assertEq(_debtOf(proxy, usdcReserveId), debt, "no debt repaid");
        assertEq(_suppliedUnits(proxy), units, "no collateral seized");
    }

    /// @notice The Pool's callback is bound to the open context: a callback with a foreign initiator, two assets, two
    /// amounts, two premiums, another asset, another amount or other `params`, and a second callback in the same loan,
    /// each revert `InvalidFlashCallback`; a charged premium above the caller's `maxPremium` reverts `PremiumTooHigh(φ,
    /// maxPremium)` and one above `maxFlashFeeBps × F / 10⁴` (20 bps against the 10 bps cap) reverts `FlashFeeTooHigh`.
    /// Every refusal reverts the whole call: the account's debt and collateral are unchanged.
    // TEST-289 verifies: REQ-HELPER-005, REQ-HELPER-013, SPEC-LIQ-015
    function test_TEST_289_callbackBoundToItsContext() public {
        uint256 debt = _debtOf(proxy, usdcReserveId);
        uint256 units = _suppliedUnits(proxy);
        bytes memory forged = abi.encodeWithSelector(IFlashLiquidatorErrors.InvalidFlashCallback.selector);

        v3Pool.setInitiatorOverride(attacker);
        _expectRefused(address(helper), carol, _request(1950e6, 1950e6), forged);
        v3Pool.setInitiatorOverride(address(0));
        for (uint8 shape = 1; shape <= 6; ++shape) {
            v3Pool.setCallbackShape(shape);
            _expectRefused(address(helper), carol, _request(1950e6, 1950e6), forged);
        }
        v3Pool.setCallbackShape(0);
        v3Pool.setCallbackTwice(true);
        _expectRefused(address(helper), carol, _request(1950e6, 1950e6), forged);
        v3Pool.setCallbackTwice(false);

        FlashLiquidationRequest memory q = _request(1950e6, 1950e6);
        q.maxPremium = 974_999;
        _expectRefused(
            address(helper),
            carol,
            q,
            abi.encodeWithSelector(IFlashLiquidatorErrors.PremiumTooHigh.selector, 975_000, 974_999)
        );
        v3Pool.setPremiumOverride(3_900_000);
        _expectRefused(
            address(helper),
            carol,
            _request(1950e6, 1950e6),
            abi.encodeWithSelector(IFlashLiquidatorErrors.FlashFeeTooHigh.selector, 3_900_000, 1_950_000)
        );

        assertEq(_debtOf(proxy, usdcReserveId), debt, "no debt repaid");
        assertEq(_suppliedUnits(proxy), units, "no collateral seized");
    }

    function _expectRefused(
        address target,
        address caller,
        FlashLiquidationRequest memory q,
        bytes memory err
    ) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(abi.encodeCall(helper.flashLiquidate, (q)));
        assertFalse(ok, "refused");
        assertEq(ret, err, "revert data");
    }
}
