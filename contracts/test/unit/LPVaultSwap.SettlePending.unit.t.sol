// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LVSLyingRoute} from "../utils/mocks/LPVaultSwapMocks.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPVaultSwapSettlePendingUnitTest
/// @notice Pending settlement (2.11 REQ-SWAP-066, REQ-SWAP-068, REQ-SWAP-070, REQ-SWAP-071, SPEC-LIQ-014): an earlier
/// implementation seized vault tokens and kept them; the next honest liquidation of the account reconciles them into
/// Collateralization's pending balance; any address then calls `settlePending`, which burns the stranded units,
/// releases the matching pool tokens, swaps them into the market's settlement asset at `s_P = min(slippage, 30)` and
/// funds the First-Loss Reserve of that asset's funding Hub, carrying an amount worth less than one Hub share. The caller
/// supplies and receives nothing.
/// forge-config: default.isolate = false
contract LPVaultSwapSettlePendingUnitTest is LPVaultSwapUnitBase {
    address internal proxy;
    uint256 internal kept;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
        kept = _seizeAndKeep(proxy, 1000e6);
        _liquidateAs(keeper, _params(proxy, 500e6)); // reconciles the gap into the pending balance
    }

    /// @notice Any address settles: the stranded 500 units are burned, the pending tokens released (pro rata of the
    /// pending balance), the USDT swapped into USDC at its 30 bps minimum, and `R` added to the USDC First-Loss Reserve of
    /// the Stable LP Hub through `fund`; the caller's balances do not change and LPVaultSwap's vault-token balance falls
    /// by exactly the units settled.
    // TEST-170 verifies: REQ-SWAP-066, REQ-SWAP-070, REQ-SWAP-092, REQ-SWAP-042, SPEC-LIQ-014, INV-042, Q-201, Q-211, Q-338
    // TEST-280 verifies: REQ-SWAP-066, Q-338
    function test_TEST_170_anyCallerSettlesIntoCoverage() public {
        assertEq(kept, 500e6, "500 units kept by the earlier implementation");
        assertEq(coll.getPending(address(vt)).units, kept, "pending after reconcile");
        uint256 coverageBefore = usdcCoverage.fundedBalance();
        uint256 supplyBefore = vt.totalSupply();
        uint256 attackerUsdc = usdc.balanceOf(attacker);
        (uint256 a0, uint256 a1) = _released(kept);
        uint256 minOut = _ceilDiv(a1 * P_USDT / PRICE_UNIT * (BPS - 30), BPS) - 1 - FLOOR_ROUNDING_ALLOWANCE_USDC;
        vm.expectCall(address(usdtPrimary), abi.encodeCall(ISettlementRoute.swap, (a1, minOut)), 1);
        vm.recordLogs();
        vm.prank(attacker);
        (uint256 units, uint256[] memory amounts, uint256 added) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(units, kept, "x = min(h, p)");
        assertEq(amounts[0], a0, "USDC released");
        assertEq(amounts[1], a1, "USDT released");
        assertEq(added, a0 + a1 * 9995 / 10_000, "R in USDC");
        assertEq(usdcCoverage.fundedBalance(), coverageBefore + added, "First-Loss Reserve funded with R");
        assertEq(vt.totalSupply(), supplyBefore - kept, "stranded units burned");
        assertEq(vt.balanceOf(address(lvs)), 0, "LPVaultSwap holds no vault token");
        assertEq(coll.getPending(address(vt)).units, 0, "pending cleared");
        assertEq(usdc.balanceOf(attacker), attackerUsdc, "the caller receives nothing");
        assertEq(usdc.balanceOf(address(lvs)), 0, "no USDC kept");
        assertEq(usdt.balanceOf(address(lvs)), 0, "no USDT kept");
        _assertNoAllowances();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, PendingSettlementForwarded.selector), 1, "event");
    }

    /// @notice The event carries the market, the units, the released amounts, the settlement asset, `R`, the pending
    /// floor, the First-Loss Reserve, the routes used, the amount funded and the carry after the call.
    // TEST-170 verifies: REQ-SWAP-066, SPEC-LIQ-014
    function test_TEST_170_eventFields() public {
        (uint256 a0, uint256 a1) = _released(kept);
        uint256 added = a0 + a1 * 9995 / 10_000;
        uint256 vp = a0 + _ceilDiv(a1 * P_USDT, PRICE_UNIT);
        uint256 minPending = _floorOf(vp, 30, 2, FLOOR_ROUNDING_ALLOWANCE_USDC);
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (a0, a1);
        uint8[] memory used = new uint8[](2);
        used[1] = 1;
        vm.expectEmit(true, true, true, true, address(lvs));
        emit PendingSettlementForwarded(
            carol,
            MARKET_ID,
            address(vt),
            kept,
            amounts,
            address(usdc),
            added,
            minPending,
            address(usdcCoverage),
            used,
            added,
            0
        );
        vm.prank(carol);
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }

    /// @notice Before the Lock: `UnknownMarket`, then `InvalidFeeRecipient`, then `LockHeld(holder)`; then the pending
    /// view reads give `NothingPending`; then `UnknownDebtReserve` unless the reserve is the market's settlement reserve.
    // TEST-170 verifies: REQ-SWAP-066, REQ-SWAP-068, REQ-LOCK-007, Q-201
    function test_TEST_170_unknownMarketAndNothingPending() public {
        vm.expectRevert(_err(ILPVaultSwapErrors.UnknownMarket.selector));
        lvs.settlePending(99, usdcReserveId);
        store.setFeeRecipient(address(0));
        vm.expectRevert(_err(ILPVaultSwapErrors.InvalidFeeRecipient.selector));
        lvs.settlePending(MARKET_ID, usdcReserveId);
        store.setFeeRecipient(feeRecipient);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.UnknownDebtReserve.selector, ghoReserveId));
        lvs.settlePending(MARKET_ID, ghoReserveId);
        lvs.settlePending(MARKET_ID, usdcReserveId);
        vm.expectRevert(_err(ILPVaultSwapErrors.NothingPending.selector));
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }

    /// @notice The pending balance and LPVaultSwap's held units are read before the Lock (REQ-LOCK-007): while the
    /// AaveAdapter holds the Lock the call reverts `LockHeld(adapter)` before any read that would revert `Locked`.
    // TEST-170 verifies: REQ-SWAP-002, REQ-SWAP-066, REQ-LOCK-007
    // TEST-060 verifies: REQ-SWAP-002, REQ-LOCK-007
    function test_TEST_170_readsPendingBeforeLock() public {
        bytes memory call = abi.encodeCall(ILPVaultSwapLiquidation.settlePending, (MARKET_ID, usdcReserveId));
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.LockHeld.selector, address(adapter)));
        adapter.callUnderLock(call);
        vm.expectCall(address(coll), abi.encodeWithSignature("getPending(address)", address(vt)), 1);
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }

    /// @notice `x = min(h, p)`: when LPVaultSwap holds fewer stranded units than are pending (part of them burned by a
    /// later honest path), only those settle and the rest stays pending; and nothing settles with no units held.
    // TEST-170 verifies: REQ-SWAP-066, REQ-SWAP-068, REQ-SWAP-044
    function test_TEST_170_settlesMinOfHeldAndPending() public {
        // Half the held units leave LPVaultSwap through the AaveAdapter burn in another settlement call path.
        vm.prank(address(lvs));
        lock.acquire();
        vm.prank(address(lvs));
        adapter.burnSeized(MARKET_ID, address(vt), kept / 2);
        vm.prank(address(lvs));
        lock.release();
        (uint256 units,,) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(units, kept / 2, "settles only what it holds");
        assertEq(coll.getPending(address(vt)).units, kept - kept / 2, "the rest stays pending");
        vm.expectRevert(_err(ILPVaultSwapErrors.NothingPending.selector));
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }

    /// @notice REQ-SWAP-070: an amount worth less than one Hub share is carried, not funded; the next settlement into
    /// the same asset funds `R + carry`.
    // TEST-170 verifies: REQ-SWAP-070, REQ-SWAP-042, REQ-FLR-038, Q-211
    function test_TEST_170_subShareCarry() public {
        uint256 coverageBefore = usdcCoverage.fundedBalance();
        vm.mockCall(aave.hub, abi.encodeWithSelector(IAaveV4Hub.previewAddByAssets.selector), abi.encode(uint256(0)));
        (,, uint256 added) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(usdcCoverage.fundedBalance(), coverageBefore, "not funded");
        assertEq(usdc.balanceOf(address(lvs)), added, "carried in LPVaultSwap's balance");
        vm.clearMockedCalls();
        // A second unsettled seizure and its reconcile, then a settlement that funds both amounts.
        _seizeAndKeep(proxy, 400e6);
        _liquidateAs(keeper, _params(proxy, 500e6));
        uint256 carryBefore = usdc.balanceOf(address(lvs));
        vm.recordLogs();
        (,, uint256 added2) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(usdcCoverage.fundedBalance(), coverageBefore + added2 + carryBefore, "R + carry funded");
        assertEq(usdc.balanceOf(address(lvs)), 0, "carry cleared");
    }

    /// @notice Route residue and dust legs of a pending settlement go to `feeRecipient` (escrowed for it when refused),
    /// never to the caller.
    // TEST-170 verifies: REQ-SWAP-066, REQ-SWAP-121, REQ-SWAP-076
    function test_TEST_170_residueToFeeRecipient() public {
        (, uint256 a1) = _released(kept);
        usdtUsdcPool.setMaxIn(a1 - 10);
        usdtUsdcPool2.setMaxIn(a1 - 10);
        uint256 feeUsdt = usdt.balanceOf(feeRecipient);
        // With 10 raw USDT left unswapped the leg still meets its 30 bps minimum.
        lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(usdt.balanceOf(feeRecipient), feeUsdt + 10, "residue to feeRecipient");
        assertEq(usdt.balanceOf(address(this)), 0, "nothing to the caller");
    }

    /// @notice The pending legs run at `s_P = min(slippageAllowanceBps, 30)`: a route returning 1 % below the oracle
    /// (above the 100 bps a liquidation leg would allow after its unit and rounding terms) fails both routes (`NoRouteAvailable`) and nothing changes; the units stay pending.
    // TEST-170 verifies: SPEC-LIQ-014, SPEC-LIQ-018, REQ-SWAP-071
    // TEST-232 verifies: SPEC-LIQ-014, REQ-SWAP-100
    function test_TEST_232_pendingAt30Bps() public {
        usdtUsdcPool.setRate(9900, 10_000);
        usdtUsdcPool2.setRate(9900, 10_000);
        vm.expectRevert(_err(ILPVaultSwapErrors.NoRouteAvailable.selector));
        lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(coll.getPending(address(vt)).units, kept, "still pending");
        store.setSlippage(MARKET_ID, 20);
        usdtUsdcPool.setRate(9995, 10_000);
        (, uint256 a1) = _released(kept);
        uint256 minOut = _ceilDiv(a1 * P_USDT / PRICE_UNIT * (BPS - 20), BPS) - 1 - FLOOR_ROUNDING_ALLOWANCE_USDC;
        vm.expectCall(address(usdtPrimary), abi.encodeCall(ISettlementRoute.swap, (a1, minOut)), 1);
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }

    /// @notice A faulty route that ignores its minimum is held to `minPending`: `RecoveryBelowFloor`, nothing changes.
    // TEST-170 verifies: SPEC-LIQ-014, REQ-SWAP-066, REQ-SWAP-071
    function test_TEST_170_recoveryBelowPendingFloor() public {
        LVSLyingRoute liar = new LVSLyingRoute(address(usdt), address(usdc));
        usdc.mint(address(liar), 1);
        liar.setOut(1);
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(liar), true);
        vm.expectRevert(_err(ILPVaultSwapErrors.RecoveryBelowFloor.selector));
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }

    /// @notice The settlement reserve decides the asset: with GHO as the market's settlement reserve both pool tokens
    /// are swapped into GHO and the GHO First-Loss Reserve is funded; the USDC First-Loss Reserve is never touched.
    // TEST-280 verifies: REQ-SWAP-066, REQ-SWAP-070, Q-338
    function test_TEST_280_pendingToOwnHubAssetAvanaFirstLossReserve() public {
        registry.setSettlementReserve(MARKET_ID, ghoReserveId);
        uint256 usdcCov = usdcCoverage.fundedBalance();
        uint256 ghoCov = ghoCoverage.fundedBalance();
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.UnknownDebtReserve.selector, usdcReserveId));
        lvs.settlePending(MARKET_ID, usdcReserveId);
        (,, uint256 added) = lvs.settlePending(MARKET_ID, ghoReserveId);
        (uint256 a0, uint256 a1) = _released(kept);
        assertEq(added, (a0 + a1) * 1e12, "both legs into GHO at 1:1");
        assertEq(ghoCoverage.fundedBalance(), ghoCov + added, "GHO First-Loss Reserve funded");
        assertEq(usdcCoverage.fundedBalance(), usdcCov, "USDC First-Loss Reserve untouched");
    }

    /// @notice `fund` reverting (the First-Loss Reserve halted on the Hub) reverts the whole settlement; the tokens stay
    /// pending and the stranded units stay at LPVaultSwap.
    // TEST-170 verifies: REQ-SWAP-070, REQ-SWAP-071
    function test_TEST_170_fundRevertKeepsPending() public {
        registry.setAvanaFirstLossReserve(aave.hub, address(usdc), address(0xdead));
        vm.expectRevert();
        lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(coll.getPending(address(vt)).units, kept, "pending unchanged");
        assertEq(vt.balanceOf(address(lvs)), kept, "units still held");
    }

    /// @notice LIQ-I3: with no First-Loss Reserve recorded, or one whose `fund` reverts (a full add cap), `settlePending`
    /// reverts as a whole: the units stay pending and retryable, nothing is carried beyond one Hub share, and
    /// liquidation does not depend on it: the account is still liquidated while the settlement is stuck.
    // TEST-170 verifies: REQ-SWAP-070, REQ-SWAP-071, REQ-SWAP-003, REQ-FLR-037
    function test_TEST_170_stuckSettlementDoesNotBlockLiquidation() public {
        registry.setAvanaFirstLossReserve(aave.hub, address(usdc), address(0));
        vm.expectRevert();
        lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(coll.getPending(address(vt)).units, kept, "pending unchanged");
        assertEq(usdc.balanceOf(address(lvs)), 0, "nothing carried");
        _liquidateAs(keeper, _params(proxy, 100e6));
        assertEq(coll.getPending(address(vt)).units, kept, "still pending after the liquidation");
        registry.setAvanaFirstLossReserve(aave.hub, address(usdc), address(usdcCoverage));
        (uint256 units,,) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(units, kept, "settles once the First-Loss Reserve is back");
    }

    /// @notice The settlement asset's DebtOracle must be Live (REQ-SWAP-091 applied to the settlement reserve).
    // TEST-170 verifies: REQ-SWAP-066, REQ-SWAP-091
    function test_TEST_170_settlementReserveDebtPriceGate() public {
        usdcOracle.setState(PriceState.Expired, true);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveId));
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }

    /// @notice The First-Loss Reserve pull is checked as LPVaultSwap's balance falling by exactly `Rt` (REQ-SWAP-070): a
    /// First-Loss Reserve that takes nothing, one that takes `Rt - 1`, and one that takes `Rt` but sends 1 more back all
    /// revert `FundingMismatch` with the units still pending; the same contract taking exactly `Rt` is funded.
    // TEST-170 verifies: REQ-SWAP-070, REQ-SWAP-071
    function test_TEST_170_fundPullMismatch() public {
        PendingCoverageSkimmer skimmer = new PendingCoverageSkimmer(address(usdc));
        usdc.mint(address(skimmer), 1e6);
        registry.setAvanaFirstLossReserve(aave.hub, address(usdc), address(skimmer));
        PendingCoverageSkimmer.Mode[3] memory faulty = [
            PendingCoverageSkimmer.Mode.None, PendingCoverageSkimmer.Mode.OneShort, PendingCoverageSkimmer.Mode.Rebate
        ];
        for (uint256 i = 0; i < faulty.length; ++i) {
            skimmer.setMode(faulty[i]);
            vm.expectRevert(_err(ILPVaultSwapErrors.FundingMismatch.selector));
            lvs.settlePending(MARKET_ID, usdcReserveId);
            assertEq(coll.getPending(address(vt)).units, kept, "pending unchanged");
            assertEq(vt.balanceOf(address(lvs)), kept, "units still held");
        }
        skimmer.setMode(PendingCoverageSkimmer.Mode.Exact);
        uint256 skimmerBefore = usdc.balanceOf(address(skimmer));
        (,, uint256 added) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(usdc.balanceOf(address(skimmer)), skimmerBefore + added, "exactly R pulled");
        assertEq(usdc.balanceOf(address(lvs)), 0, "nothing carried");
        assertEq(usdc.allowance(address(lvs), address(skimmer)), 0, "approval reset");
    }
}

/// @title PendingCoverageSkimmer
/// @notice A First-Loss Reserve stand-in for the `fund` pull check of `settlePending`: `fund(amount)` takes nothing
/// (`None`), `amount - 1` (`OneShort`), `amount` then sends `amount + 1` back (`Rebate`), or exactly `amount` (`Exact`).
contract PendingCoverageSkimmer {
    using SafeERC20 for IERC20;

    enum Mode {
        Exact,
        None,
        OneShort,
        Rebate
    }

    IERC20 internal immutable _ASSET;
    Mode public mode;

    constructor(
        address asset
    ) {
        _ASSET = IERC20(asset);
    }

    function setMode(
        Mode m
    ) external {
        mode = m;
    }

    function fund(
        uint256 amount
    ) external returns (uint256 shares) {
        if (mode == Mode.None) return 0;
        shares = mode == Mode.OneShort ? amount - 1 : amount;
        _ASSET.safeTransferFrom(msg.sender, address(this), shares);
        if (mode == Mode.Rebate) _ASSET.safeTransfer(msg.sender, amount + 1);
    }
}
