// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice A third-party liquidator contract calling the CDP Spoke directly.
contract LVSDirectLiquidator {
    function liquidate(
        address spoke,
        address asset,
        uint256 collateralReserve,
        uint256 debtReserve,
        address user,
        uint256 amount,
        bool receiveShares
    ) external {
        (bool ok,) = asset.call(abi.encodeWithSignature("approve(address,uint256)", spoke, amount));
        require(ok, "approve");
        IAaveV4Spoke(spoke).liquidationCall(collateralReserve, debtReserve, user, amount, receiveShares);
    }
}

/// @title LPVaultSwapAaveV4IntegrationTest
/// @notice LPVaultSwap against the pinned Aave V4 release deployed locally: liquidation exclusivity through the vault
/// token (only LPVaultSwap receives a seizure), the seizure Aave sizes at the bonus it pays, sequential liquidation of
/// several debt reserves of one account, a debt-asset price rally, one-sided unwinds, an AaveOracle source different
/// from the market's LPOracle, payouts blocked on every side at once and the deficit Aave reports when the collateral is
/// exhausted. These are the local counterparts of the fork rows (TEST-109, TEST-113, TEST-115, TEST-122, TEST-180,
/// TEST-202, TEST-281, TEST-284, TEST-286), on the same Aave V4 bytecode the forks run.
/// forge-config: default.isolate = false
contract LPVaultSwapAaveV4IntegrationTest is LPVaultSwapUnitBase {
    address internal proxy;
    LVSDirectLiquidator internal direct;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
        direct = new LVSDirectLiquidator();
    }

    /// @notice Every address other than LPVaultSwap, an EOA, a contract and the registered keeper itself, reverts on the
    /// vault token's transfer rule when it calls `liquidationCall` directly; `receiveShares = true` is refused by the
    /// Spoke's reserve setting; LPVaultSwap's `liquidate` seizes.
    // TEST-180 verifies: REQ-SWAP-084, REQ-SWAP-019, INV-013, INV-041, ATTACK-002, Q-116, Q-222
    // TEST-109 verifies: REQ-SWAP-084, INV-013, Q-116, Q-144; shared: the seizure proof's direct liquidationCall attempts, run on the local Aave V4
    function test_TEST_180_nonLPVaultSwapCallersRevertOnVaultTokenTransfer() public {
        address[2] memory eoas = [keeper, attacker];
        for (uint256 i = 0; i < eoas.length; ++i) {
            usdc.mint(eoas[i], 1950e6);
            vm.startPrank(eoas[i]);
            usdc.approve(aave.cdpSpoke, 1950e6);
            vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, aave.hub, eoas[i]));
            IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, usdcReserveId, proxy, 1950e6, false);
            vm.stopPrank();
        }
        usdc.mint(address(direct), 1950e6);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, aave.hub, address(direct)));
        direct.liquidate(aave.cdpSpoke, address(usdc), vtReserveId, usdcReserveId, proxy, 1950e6, false);
        vm.expectRevert();
        direct.liquidate(aave.cdpSpoke, address(usdc), vtReserveId, usdcReserveId, proxy, 1950e6, true);
        LiquidationResult memory r = _liquidateAs(attacker, _params(proxy, 1950e6));
        assertEq(r.unitsSeized, 975e6, "only LPVaultSwap receives the seizure");
    }

    /// @notice The bonus LPVaultSwap uses is the one Aave pays: at HF 0.933 (below `healthFactorForMaxBonus` 0.95) the
    /// maximum 10,500; closer to HF 1 a smaller dynamic bonus, still covering the 1 % slippage; the report's
    /// `bonusBps` equals `Spoke.getLiquidationBonus` and `s = min(100, ⌊10⁴ (b − 10⁴) / b⌋)`.
    // TEST-113 verifies: SPEC-LIQ-001, SPEC-LIQ-003, SPEC-LIQ-016, REQ-SWAP-016, Q-159, Q-190
    // TEST-050 verifies: SPEC-LIQ-001, SPEC-LIQ-003
    function test_TEST_113_bonusAsAavePays() public {
        (address mild,) = _openAccount(carol, 10_000e6, 17_200e6, 250_000_000);
        uint256 hf = _hf(mild);
        assertGt(hf, 0.95e18, "above the max-bonus HF");
        assertLt(hf, 1e18, "liquidatable");
        uint256 bonus = IAaveV4Spoke(aave.cdpSpoke).getLiquidationBonus(vtReserveId, mild, hf);
        assertLt(bonus, 10_500, "dynamic bonus below the max");
        _fund(usdc, keeper, 1950e6);
        vm.recordLogs();
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(_params(mild, 1950e6));
        (SettlementReportView memory rep) = _report(vm.getRecordedLogs());
        assertEq(rep.bonusBps, bonus, "bNet = Aave's bonus at lf = 0");
        assertEq(rep.slippage, _slippageOf(bonus, SLIPPAGE_BPS), "s");
        assertEq(r.unitsSeized, r.debtRepaid * bonus / BPS * PRICE_UNIT / P_VAULT, "c at that bonus");
    }

    struct SettlementReportView {
        uint256 bonusBps;
        uint256 slippage;
    }

    function _report(
        Vm.Log[] memory logs
    ) internal pure returns (SettlementReportView memory v) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == LiquidationSettled.selector) {
                (v.bonusBps, v.slippage) = _decodeBonus(logs[i].data);
            }
        }
    }

    function _decodeBonus(
        bytes memory data
    ) internal pure returns (uint256 bNet, uint256 s) {
        // SettlementReport is one dynamic tuple: offset word, then fields; effectiveSlippageBps is field 7, bonusBps 8.
        assembly {
            let base := add(add(data, 0x20), mload(add(data, 0x20)))
            s := mload(add(base, mul(7, 0x20)))
            bNet := mload(add(base, mul(8, 0x20)))
        }
    }

    /// @notice TEST-115 differential: for a range of repayments the units LPVaultSwap measures equal Aave's sizing at
    /// the maximum bonus, `c = ⌊D × 1.05 / 2.10⌋` vault units, and the floor and payouts follow the spec model.
    // TEST-115 verifies: SPEC-LIQ-004, REQ-SWAP-017, REQ-SWAP-019, Q-127
    function test_TEST_115_seizureMatchesAaveSizing() public {
        uint256[5] memory amounts = [uint256(3e6), 100e6, 777_777_777, 1950e6, 2500e6];
        for (uint256 i = 0; i < amounts.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, amounts[i]));
            assertEq(r.debtRepaid, amounts[i], "D = X below the target-HF amount");
            assertApproxEqAbs(r.unitsSeized, amounts[i] * 10_500 / BPS * PRICE_UNIT / P_VAULT, 1, "c");
            Expect memory e = _expectUsdc(r.unitsSeized, r.debtRepaid, r.callerFunds, r.recovered, 10_500, P_VAULT, 0);
            _assertResult(r, e);
            vm.revertToState(snapshot);
        }
    }

    /// @notice TEST-122: one account owing USDC and GHO is liquidated by sequential calls, one debt reserve each, each
    /// settling in its own asset, until its health factor is restored or its debt is gone.
    // TEST-122 verifies: REQ-SWAP-041, REQ-SWAP-093, REQ-SWAP-094, Q-234
    function test_TEST_122_sequentialMultiDebt() public {
        (address mixed,) = _openAccount(alice, 10_000e6, 15_000e6, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        adapter.borrow(mixed, ghoReserveId, address(gho), 2000e18, alice);
        lpOracle.setAnswer(int256(P_VAULT));
        assertLt(_hf(mixed), 1e18, "liquidatable");
        LiquidationParams memory pg = _params(mixed, 2100e18);
        pg.debtReserveId = ghoReserveId;
        LiquidationResult memory rg = _liquidateAs(keeper, pg);
        assertEq(rg.debtAsset, address(gho), "GHO first");
        assertEq(gho.balanceOf(address(lvs)), 0, "no GHO kept");
        if (_hf(mixed) < 1e18) {
            LiquidationResult memory ru = _liquidateAs(keeper, _params(mixed, 3000e6));
            assertEq(ru.debtAsset, address(usdc), "then USDC");
        }
        assertEq(usdc.balanceOf(address(lvs)), 0, "no USDC kept");
    }

    /// @notice TEST-202: a debt-asset price rally (USDC to $1.06 in the AaveOracle and the DebtOracle) makes the account
    /// liquidatable; LPVaultSwap values the seizure at the higher debt price and settles.
    // TEST-202 verifies: SPEC-LIQ-004, REQ-SWAP-091, Q-238
    function test_TEST_202_debtPriceRally() public {
        (address healthy,) = _openAccount(carol, 10_000e6, 16_000e6, 250_000_000);
        lpOracle.setAnswer(int256(P_VAULT));
        assertGe(_hf(healthy), 1e18, "healthy at $1");
        usdcOracle.setAnswer(106_000_000);
        uint256 hf = _hf(healthy);
        assertLt(hf, 1e18, "liquidatable after the rally");
        uint256 bonus = IAaveV4Spoke(aave.cdpSpoke).getLiquidationBonus(vtReserveId, healthy, hf);
        LiquidationResult memory r = _liquidateAs(keeper, _params(healthy, 1000e6));
        uint256 v = r.unitsSeized * P_VAULT / 106_000_000;
        assertEq(
            r.minOut,
            _floorOf(v, _slippageOf(bonus, SLIPPAGE_BPS), 1 + 1, FLOOR_ROUNDING_ALLOWANCE_USDC),
            "floor at Pdebt = $1.06"
        );
        assertLt(v, r.unitsSeized * P_VAULT / PRICE_UNIT, "V lower in the dearer debt asset");
    }

    /// @notice TEST-281: one-sided unwinds at either range edge: all USDT (one leg swapped) and all USDC (nothing
    /// swapped) both settle at the floor of their own amounts.
    // TEST-281 verifies: REQ-SWAP-021, REQ-SWAP-025, SPEC-LIQ-005, Q-250
    function test_TEST_281_oneSidedUnwinds() public {
        uint256[] memory rates = new uint256[](2);
        rates[0] = 0;
        rates[1] = 2_110_000;
        lpVault.bind(MARKET_ID, pool, _pair(address(usdc), address(usdt)), rates);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(r.amountsOut[0], 0, "no USDC");
        assertGe(r.recovered, r.minOut, "USDT alone meets the floor");
        rates[0] = 2_100_000;
        rates[1] = 0;
        lpVault.bind(MARKET_ID, pool, _pair(address(usdc), address(usdt)), rates);
        uint256 swaps = usdtUsdcPool.swaps();
        r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(usdtUsdcPool.swaps(), swaps, "nothing swapped");
        assertEq(r.recovered, r.amountsOut[0], "R = the USDC released");
    }

    /// @notice TEST-284: the AaveOracle serving the vault-token reserve from another source never stops liquidation:
    /// LPVaultSwap gates on the market's LPOracle and values at the smaller of the two prices.
    // TEST-284 verifies: REQ-SWAP-008, SPEC-LIQ-004, INV-099, Q-327
    function test_TEST_284_oracleSwitchNeverStopsLiquidation() public {
        vm.mockCall(
            aave.cdpOracle,
            abi.encodeWithSignature("getReservePrice(uint256)", vtReserveId),
            abi.encode(uint256(205_000_000))
        );
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        uint256 v = r.unitsSeized * 205_000_000 / PRICE_UNIT;
        assertEq(r.minOut, _floorOf(v, 100, 2, FLOOR_ROUNDING_ALLOWANCE_USDC), "valued at min(2.05, 2.10)");
        vm.mockCall(
            aave.cdpOracle,
            abi.encodeWithSignature("getReservePrice(uint256)", vtReserveId),
            abi.encode(uint256(215_000_000))
        );
        r = _liquidateAs(keeper, _params(proxy, 1950e6));
        v = r.unitsSeized * P_VAULT / PRICE_UNIT;
        assertEq(r.minOut, _floorOf(v, 100, 2, FLOOR_ROUNDING_ALLOWANCE_USDC), "valued at min(2.15, 2.10)");
    }

    /// @notice TEST-286: the fee recipient, the borrower and the caller's residue all blocked at once: the liquidation
    /// completes, every refused payout is credited in the escrow, and the caller's own payout is paid.
    // TEST-286 verifies: REQ-SWAP-076, REQ-SWAP-082, REQ-SWAP-026, INV-061, ATTACK-196, Q-389
    function test_TEST_286_everyEscrowablePayoutBlocked() public {
        usdtUsdcPool.setRate(103, 100);
        (, uint256 a1) = _released(975e6);
        usdtUsdcPool.setMaxIn(a1 - 7);
        usdc.setBlocked(feeRecipient, true);
        usdc.setBlocked(bob, true);
        usdt.setBlocked(keeper, true);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.maxShortfall = 100e6;
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertEq(escrow.claimable(address(usdc), feeRecipient), r.avanaFee, "A escrowed");
        assertEq(escrow.claimable(address(usdc), bob), r.borrowerSurplus, "B escrowed");
        assertEq(escrow.claimable(address(usdt), keeper), 7, "residue escrowed");
        assertGt(r.borrowerSurplus, 0, "B due");
        assertEq(usdc.balanceOf(keeper), r.keeperOut + 100e6 - r.shortfall, "keeperOut paid directly");
    }

    /// @notice REQ-SWAP-018: a liquidation that exhausts the collateral lets Aave report the deficit inside
    /// `liquidationCall`; LPVaultSwap reports nothing, settles to its floor and keeps no balance.
    // TEST-199 verifies: REQ-SWAP-018, INV-041, Q-117
    function test_TEST_199_deficitReportedByAave() public {
        lpOracle.setAnswer(150_000_000); // collateral 15,000 against 18,000 USDC: exhausted by a full liquidation
        uint256 deficitBefore = IAaveV4Hub(aave.hub).getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke);
        Snap memory s0 = _snap(keeper);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 20_000e6));
        assertEq(_suppliedUnits(proxy), 0, "collateral exhausted");
        assertGt(IAaveV4Hub(aave.hub).getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke), deficitBefore, "deficit");
        assertGe(r.recovered + r.shortfall, r.minOut, "floor met");
        _assertNeutral(s0);
    }
}
