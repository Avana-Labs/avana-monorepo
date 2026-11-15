// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title CapsZeroCapIntegrationTest
/// @notice A market cap and a token cap tightened to 0 through the real timelock and ParameterStore (REQ-RISK-042):
/// a new pledge into the market is refused `CapExceeded(MARKET)`, while an existing account still repays, a debt-free
/// account still withdraws, and an unhealthy account is still liquidated through the real LPVaultSwap.
/// forge-config: default.isolate = false
contract CapsZeroCapIntegrationTest is RealStackFlows {
    uint256 internal mA;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
    }

    // TEST-013 verifies: REQ-RISK-042, REQ-RISK-005, REQ-RISK-040, SPEC-CAP-002
    function test_TEST_013_zeroCapsRefuseNewExposureWhileRepayWithdrawAndLiquidationWork() public {
        // Alice borrows a little, Carol holds a debt-free position, Bob's account is the one to liquidate.
        (, address pAlice) = _pledgeAs(alice, mA, UNITS);
        _borrowAs(alice, mA, usdcReserveId, 1000e6);
        (bytes32 kCarol,) = _pledgeAs(carol, mA, UNITS);
        (, address pBob) = _pledgeAs(bob, mA, UNITS);
        _borrowAs(bob, mA, usdcReserveId, 5880e6);

        address hub = registry.getMarket(mA).hub;
        _govern(address(store), abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (mA, 0)));
        _govern(address(store), abi.encodeCall(IParameterStoreTighten.tightenTokenUsdCap, (hub, address(usdt), 0)));
        assertEq(store.marketUsdCap(mA), 0, "market cap at 0");
        assertEq(store.tokenUsdCap(hub, address(usdt)), 0, "token cap at 0");

        // New exposure: a fresh pledge is refused.
        address dave = makeAddr("dave");
        bytes32 key = _mintPosition(dave, mA, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("MARKET")));
        vm.prank(dave);
        adapterC.pledge(mA, _ref(key), d);

        // Repay of an existing account.
        uint256 owed = _debtOf(pAlice, usdcReserveId);
        usdc.mint(alice, owed);
        vm.prank(alice);
        usdc.approve(adapter, owed);
        vm.prank(alice);
        adapterC.repay(alice, mA, usdcReserveId, owed, true, _deadline());
        assertEq(_debtOf(pAlice, usdcReserveId), 0, "repaid at a zero cap");

        // Debt-free withdrawal.
        uint256 creditedCarol = _credited(kCarol);
        vm.prank(carol);
        adapterC.withdraw(mA, _ref(kCarol), creditedCarol, _deadline(), 0);
        assertEq(IERC721(address(nfpm)).ownerOf(uint256(kCarol)), carol, "withdrawn at a zero cap");

        // Liquidation of an unhealthy account.
        _depegUsdt(93_000_000);
        LiquidationPreview memory pv = lens.previewLiquidation(pBob, usdcReserveId, block.timestamp + 120);
        assertTrue(pv.aaveLiquidatable, "Bob is liquidatable");
        LiquidationParams memory p = _liqParams(pBob, mA, usdcReserveId, pv.params.debtToCover);
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertGt(r.debtRepaid, 0, "liquidated at a zero cap");
    }

    function _credited(
        bytes32 key
    ) internal view returns (uint256) {
        return coll.getRecord(coll.recordIdOf(V3, key)).credited;
    }
}
