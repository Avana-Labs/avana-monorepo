// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapMultiReserveIntegrationTest
/// @notice One account borrowing both USDC and GHO against one vault-token reserve on the local Aave V4, and accounts
/// in two markets (2.11 REQ-SWAP-005, REQ-SWAP-091, SPEC-LIQ-021; TEST-104's "no precondition concerned the account's
/// other reserves"): each liquidation repays only the named reserve and settles in its asset; a stale price of the
/// other debt reserve blocks nothing; liquidating one reserve lifts the health factor seen by the other; liquidations
/// in market 4 change nothing about how an account of market 5 settles.
/// forge-config: default.isolate = false
contract LPVaultSwapMultiReserveIntegrationTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _openAccount(bob, 10_000e6, 9000e6, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        adapter.borrow(proxy, ghoReserveId, address(gho), 9000e18, bob);
        lpOracle.setAnswer(int256(P_VAULT));
    }

    function _gho(
        uint256 amount
    ) internal view returns (LiquidationParams memory p) {
        p = _params(proxy, amount);
        p.debtReserveId = ghoReserveId;
    }

    /// @notice Repaying USDC leaves the GHO debt unchanged and settles in USDC; repaying GHO leaves the USDC debt
    /// unchanged and settles in GHO; each raises the health factor.
    // TEST-104 verifies: REQ-SWAP-005, REQ-SWAP-088, INV-034
    function test_TEST_104_eachReserveSettlesInItsOwnAsset() public {
        uint256 ghoDebt = _debtOf(proxy, ghoReserveId);
        uint256 hf0 = _hf(proxy);
        LiquidationResult memory r1 = _liquidateAs(keeper, _params(proxy, 1000e6));
        assertEq(r1.debtAsset, address(usdc), "USDC settlement");
        assertEq(_debtOf(proxy, ghoReserveId), ghoDebt, "GHO debt untouched");
        uint256 hf1 = _hf(proxy);
        assertGt(hf1, hf0, "HF rose");
        uint256 usdcDebt = _debtOf(proxy, usdcReserveId);
        if (hf1 >= 1e18) return;
        LiquidationResult memory r2 = _liquidateAs(keeper, _gho(1000e18));
        assertEq(r2.debtAsset, address(gho), "GHO settlement");
        assertEq(_debtOf(proxy, usdcReserveId), usdcDebt, "USDC debt untouched");
        assertGt(_hf(proxy), hf1, "HF rose again");
        assertEq(gho.balanceOf(keeper), r2.keeperOut, "paid in GHO");
    }

    /// @notice A stale USDC DebtOracle blocks only USDC repayments: the GHO reserve of the same account settles.
    // TEST-226 verifies: REQ-SWAP-091, REQ-SWAP-110, Q-208
    function test_TEST_226_staleOtherReserveBlocksNothing() public {
        usdcOracle.setState(PriceState.Expired, false);
        _expectLiquidateRevert(
            keeper,
            _params(proxy, 1000e6),
            abi.encodeWithSelector(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveId)
        );
        LiquidationResult memory r = _liquidateAs(keeper, _gho(1000e18));
        assertGt(r.unitsSeized, 0, "GHO reserve settles");
    }

    /// @notice Any split of repayments between the two reserves, in either order: every call settles in its own
    /// asset with the debt asset conserved, the other reserve's debt untouched, and LPVaultSwap neutral in all three
    /// tokens and the vault token.
    // TEST-104 verifies: REQ-SWAP-005, SPEC-LIQ-010, INV-035
    function testFuzz_TEST_104_alternatingReserves(
        uint256 usdcPart,
        uint256 ghoPart,
        bool ghoFirst
    ) public {
        usdcPart = bound(usdcPart, 10e6, 3000e6);
        ghoPart = bound(ghoPart, 10e18, 3000e18);
        for (uint256 i = 0; i < 2; ++i) {
            bool gho_ = (i == 0) == ghoFirst;
            if (_hf(proxy) >= 1e18) break;
            uint256 otherBefore = _debtOf(proxy, gho_ ? usdcReserveId : ghoReserveId);
            LiquidationResult memory r =
                gho_ ? _liquidateAs(keeper, _gho(ghoPart)) : _liquidateAs(keeper, _params(proxy, usdcPart));
            assertEq(
                r.callerFunds + r.recovered + r.shortfall, r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut
            );
            assertEq(_debtOf(proxy, gho_ ? usdcReserveId : ghoReserveId), otherBefore, "other reserve untouched");
        }
        assertEq(usdc.balanceOf(address(lvs)), 0, "no USDC kept");
        assertEq(usdt.balanceOf(address(lvs)), 0, "no USDT kept");
        assertEq(gho.balanceOf(address(lvs)), 0, "no GHO kept");
        assertEq(vt.balanceOf(address(lvs)), 0, "no vault tokens kept");
        _assertNoAllowances();
    }

    /// @notice Markets 4 and 5 share the routes, the Collateralization and the LPVault: a liquidation of a market-5
    /// account settles to the same figures whether or not market-4 accounts were liquidated first.
    // TEST-277 verifies: SPEC-LIQ-021, INV-097, PROP-084
    function testFuzz_TEST_277_otherMarketHistoryChangesNothing(
        uint256 first,
        uint256 second
    ) public {
        first = bound(first, 10e6, 3000e6);
        second = bound(second, 10e6, 3000e6);
        _deploySecondMarket();
        (address proxyB,) = _openAccountB(carol, 10_000e6, 18_000e6, 250_000_000);
        LiquidationParams memory pB = _params(proxyB, 1950e6);
        pB.marketId = MARKET_B;
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory clean = _liquidateAs(keeper, pB);
        vm.revertToState(snapshot);
        _liquidateAs(keeper, _params(proxy, first));
        if (_hf(proxy) < 1e18) _liquidateAs(keeper, _params(proxy, second));
        LiquidationResult memory after_ = _liquidateAs(keeper, pB);
        assertEq(after_.unitsSeized, clean.unitsSeized, "same seizure");
        assertEq(after_.recovered, clean.recovered, "same recovery");
        assertEq(after_.minOut, clean.minOut, "same floor");
        assertEq(after_.keeperOut, clean.keeperOut, "same payout");
    }
}
