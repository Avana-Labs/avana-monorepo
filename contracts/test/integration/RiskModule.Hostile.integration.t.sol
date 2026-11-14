// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IHostileSpokeConfigurator {
    function updateFrozen(
        address spoke,
        uint256 reserveId,
        bool frozen
    ) external;
}

/// @notice A RiskModule implementation that reverts on every call, as a broken upgrade would.
contract RevertingRiskModule {
    error RiskModuleBroken();

    function proxiableUUID() external pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    fallback() external {
        revert RiskModuleBroken();
    }
}

/// @notice A RiskModule implementation that approves every pledge, borrow and withdraw-with-debt.
contract ApproveAllRiskModule {
    function proxiableUUID() external pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    function checkPledge(
        address,
        address,
        uint256,
        uint32,
        bytes32,
        uint128 units,
        bytes calldata,
        bool
    ) external pure returns (PledgeCharge memory charge) {
        charge.usdCharge = units;
    }

    function preBorrowCheck(
        address,
        uint256,
        uint256
    ) external {}

    function preWithdrawCheck(
        address
    ) external {}

    function postHealthCheck(
        address,
        uint256
    ) external pure returns (uint256) {
        return type(uint256).max;
    }

    function checkRemainingRecord(
        uint256,
        uint128
    ) external view {}

    fallback() external {}
}

/// @title RiskModuleHostileIntegrationTest
/// @notice The reviewed RiskModule's proxy upgraded through the real AvanaTimelock (scheduled by the governance
/// multisig, executed after the normal delay) to a broken (always-reverting) or an approve-all implementation, on the
/// real stack (`RealStackFlows`): the real AaveAdapter, Collateralization, Uniswap v3 LPVault, LPVaultSwap and Aave V4
/// Hub and Spoke. A broken RiskModule stops only the actions that call it, and an approving one is still bounded by
/// Aave's health factor and the Spoke's draw cap.
/// @dev Accounts: 10,000 vault tokens ($20,000 at $2.00, CF 30 %, at most $6,000 of debt) against 2,000 USDC; bob's
/// against 5,880 USDC, liquidatable once USDT falls to $0.93 (`_depegUsdt`, HF 0.984). Fees are real: swaps through
/// the market's pool accrue Uniswap fees to the NFT. The Drifting market of TEST-156 is a real feed disagreement: the
/// USDT alternate feed publishes $0.97 against the primary's $1.00 (300 bps, above the 150 bps agreement tolerance).
/// forge-config: default.isolate = false
contract RiskModuleHostileIntegrationTest is RealStackFlows {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal mA;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
    }

    /// @dev The RiskModule proxy upgraded to `implementation` through the real timelock at its required delay.
    function _install(
        address implementation
    ) internal {
        _govern(address(riskModule), abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, "")));
        bytes32 slot = vm.load(address(riskModule), IMPLEMENTATION_SLOT);
        assertEq(address(uint160(uint256(slot))), implementation, "the proxy runs the new implementation");
    }

    function _account(
        address wallet,
        uint128 units,
        uint256 usdcDebt
    ) internal returns (address proxy, bytes32 key) {
        (key, proxy) = _pledgeAs(wallet, mA, units);
        if (usdcDebt != 0) _borrowAs(wallet, mA, usdcReserveId, usdcDebt);
    }

    function _credited(
        bytes32 key
    ) internal view returns (uint256) {
        return coll.getRecord(coll.recordIdOf(V3, key)).credited;
    }

    function _ownerOf(
        bytes32 key
    ) internal view returns (address) {
        return IERC721(address(nfpm)).ownerOf(uint256(key));
    }

    /// @dev Token0 sold into the market's pool, then the pool swapped back to its price in one block: real fees.
    function _tradeThroughPool() internal {
        IClPool p = mkt[mA].pool;
        (uint160 start,,,,,,) = p.slot0();
        actor.swap(p, true, int256(1e14), 4_295_128_740);
        _swapTo(p, start);
    }

    /// @dev What the position manager owes the NFT, from a reverted `collect` by its owner, the LPVault.
    function _owed(
        bytes32 key
    ) internal returns (uint256 owed0, uint256 owed1) {
        uint256 snap = vm.snapshotState();
        vm.prank(integration);
        (owed0, owed1) = nfpm.collect(
            INonfungiblePositionManager.CollectParams(
                uint256(key), makeAddr("dryRun"), type(uint128).max, type(uint128).max
            )
        );
        vm.revertToState(snap);
    }

    /// @dev Real fees accrue to `key`, then the wallet collects exactly what the position manager owed.
    function _collectRealFees(
        address wallet,
        bytes32 key
    ) internal {
        _tradeThroughPool();
        (uint256 owed0, uint256 owed1) = _owed(key);
        assertGt(owed0 + owed1, 0, "fees accrued");
        IClPool p = mkt[mA].pool;
        (ClTestToken t0, ClTestToken t1) = (ClTestToken(p.token0()), ClTestToken(p.token1()));
        (uint256 b0, uint256 b1) = (t0.balanceOf(wallet), t1.balanceOf(wallet));
        vm.prank(wallet);
        adapterC.collectFees(mA, _ref(key), _deadline());
        assertEq(t0.balanceOf(wallet) - b0, owed0, "token0 fees collected");
        assertEq(t1.balanceOf(wallet) - b1, owed1, "token1 fees collected");
    }

    /// @dev Fail closed: a borrow, a withdrawal that leaves debt and a new pledge.
    function _failsClosed(
        address pA,
        bytes32 kA2
    ) internal {
        uint256 nonce = adapterC.borrowNonce(pA);
        uint256 d = _deadline();
        vm.expectRevert(RevertingRiskModule.RiskModuleBroken.selector);
        vm.prank(alice);
        adapterC.borrow(mA, usdcReserveId, 1e6, alice, d, 0, nonce);
        uint256 creditedA2 = _credited(kA2);
        vm.expectRevert(RevertingRiskModule.RiskModuleBroken.selector);
        vm.prank(alice);
        adapterC.withdraw(mA, _ref(kA2), creditedA2, d, 0);
        address dave = makeAddr("dave");
        bytes32 kNew = _mintPosition(dave, mA, 1000e6);
        vm.expectRevert(RevertingRiskModule.RiskModuleBroken.selector);
        vm.prank(dave);
        adapterC.pledge(mA, _ref(kNew), d);
        assertEq(_ownerOf(kNew), dave, "the refused pledge moved nothing");
    }

    /// @dev `repayAllAndWithdraw` of the whole debt and every unit of `kA`.
    function _repayAllAndWithdraw(
        address pA,
        bytes32 kA
    ) internal {
        uint256 owed = _debtOf(pA, usdcReserveId);
        usdc.mint(alice, owed);
        uint256[] memory ids = new uint256[](1);
        ids[0] = usdcReserveId;
        uint256[] memory caps = new uint256[](1);
        caps[0] = owed;
        uint256 creditedA = _credited(kA);
        vm.startPrank(alice);
        usdc.approve(adapter, owed);
        adapterC.repayAllAndWithdraw(mA, _ref(kA), creditedA, ids, caps, _deadline());
        vm.stopPrank();
        assertEq(_debtOf(pA, usdcReserveId), 0, "repaid in full");
        assertEq(_ownerOf(kA), alice, "NFT returned");
    }

    // TEST-132 verifies: REQ-RISK-053, REQ-ADAPTER-009, REQ-RISK-040
    // Sources: 2.7 REQ-RISK-053 (RiskModule implementation broken or reverting), REQ-ADAPTER-009, REQ-RISK-040
    /// @notice With the RiskModule proxy upgraded to an implementation that reverts on every call, a new pledge, a
    /// rescue-free top-up, a borrow and a withdrawal that leaves debt fail closed, while repay by a third party, fee
    /// collection, a debt-free withdrawal, `repayAllAndWithdraw` and a liquidation never call it and succeed.
    function test_TEST_132_brokenRiskModuleStopsOnlyWhatCallsIt() public {
        (address pA, bytes32 kA) = _account(alice, UNITS, 2000e6);
        (bytes32 kA2,) = _pledgeAs(alice, mA, 2000e6);
        (bytes32 kC,) = _pledgeAs(carol, mA, 1000e6);
        (address pB,) = _account(bob, UNITS, 5880e6);
        _install(address(new RevertingRiskModule()));
        // After five days without a feed round (the timelock delay) the market's LPOracle opens its grace window on
        // its next poke, where `liquidate` needs HF below `graceHealthFactor`; the depeg's TWAP wait outlasts it.
        _pokeAll();
        _depegUsdt(93_000_000);
        assertFalse(lens.previewLiquidation(pB, usdcReserveId, block.timestamp + 120).inGrace, "past the grace window");

        _failsClosed(pA, kA2);

        // Exits and liquidation continue.
        _collectRealFees(alice, kA);
        _repayVia(carol, alice, mA, usdcReserveId, 500e6, false);
        _withdrawVia(carol, mA, kC, _credited(kC));
        assertEq(_ownerOf(kC), carol, "debt-free withdrawal");
        LiquidationResult memory r = _liquidateAs(keeper, _liqParams(pB, mA, usdcReserveId, 800e6));
        assertEq(r.debtRepaid, 800e6, "liquidation settles");
        _repayAllAndWithdraw(pA, kA);
        _withdrawVia(alice, mA, kA2, _credited(kA2));
        assertEq(_ownerOf(kA2), alice, "debt-free withdrawal after repay-all");
        assertFalse(lock.isLocked(), "Lock free");
    }

    // TEST-132 verifies: Q-226, Q-229
    // Sources: 5.1 TEST-132 (approve-all RiskModule: Aave HF >= 1 and the drawCap still bound the borrow)
    /// @notice An approve-all RiskModule lets a borrow through every Avana gate, but Aave refuses one that would end
    /// below HF 1, the reserve's draw cap holds, and the Adapter still enforces the nonce and the deadline.
    function test_TEST_132_approveAllRiskModuleStillAaveBounded() public {
        (address pA,) = _account(alice, UNITS, 2000e6);
        _install(address(new ApproveAllRiskModule()));
        _borrowAs(alice, mA, usdcReserveId, 3500e6);
        assertGe(_hf(pA), 1e18, "Aave HF >= 1");
        uint256 nonce = adapterC.borrowNonce(pA);
        uint256 d = _deadline();
        vm.expectRevert();
        vm.prank(alice);
        adapterC.borrow(mA, usdcReserveId, 3000e6, alice, d, 0, nonce);
        assertGe(_hf(pA), 1e18, "still >= 1 after the refused borrow");
        uint256 cap = uint256(IAaveV4Hub(aave.hub).getSpokeConfig(usdcAssetId, aave.cdpSpoke).drawCap) * 1e6;
        assertLe(IAaveV4Hub(aave.hub).getSpokeTotalOwed(usdcAssetId, aave.cdpSpoke), cap, "within drawCap");
        vm.expectRevert();
        vm.prank(alice);
        adapterC.borrow(mA, usdcReserveId, 1e6, alice, d, 0, nonce + 1);
    }

    // TEST-156 verifies: Q-203, Q-229
    // Sources: 5.1 TEST-156 (Quint C-QNT-3, reviewed-implementation scope)
    /// @notice With the reviewed RiskModule, a borrow against an account whose vault-token reserve Aave froze reverts
    /// `ReserveFrozen`, and one against a Drifting market reverts `PriceNotLive`; after the approve-all implementation
    /// is installed through the timelock both borrows pass, and each still ends at Aave HF >= 1.
    function test_TEST_156_reviewedRefusesApproveAllStaysAaveBounded() public {
        (address pA,) = _account(alice, UNITS, 2000e6);
        uint256 vtReserve = mkt[mA].reserveId;
        vm.prank(aaveDao);
        IHostileSpokeConfigurator(aave.spokeConfigurator).updateFrozen(aave.cdpSpoke, vtReserve, true);
        uint256 nonce = adapterC.borrowNonce(pA);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.ReserveFrozen.selector, vtReserve));
        vm.prank(alice);
        adapterC.borrow(mA, usdcReserveId, 500e6, alice, d, 0, nonce);
        vm.prank(aaveDao);
        IHostileSpokeConfigurator(aave.spokeConfigurator).updateFrozen(aave.cdpSpoke, vtReserve, false);
        // The USDT alternate disagrees with the primary beyond the tolerance: the market's LPOracle is Drifting.
        vm.roll(block.number + 1);
        feedsOf[address(usdt)][1].push(97_000_000, block.timestamp);
        assertEq(uint8(mkt[mA].oracle.getPriceState().state), uint8(PriceState.Drifting), "the market is Drifting");
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mA, PriceState.Drifting));
        vm.prank(alice);
        adapterC.borrow(mA, usdcReserveId, 500e6, alice, d, 0, nonce);

        _install(address(new ApproveAllRiskModule()));
        assertEq(uint8(mkt[mA].oracle.getPriceState().state), uint8(PriceState.Drifting), "still Drifting");
        uint256 debtBefore = _debtOf(pA, usdcReserveId);
        _borrowAs(alice, mA, usdcReserveId, 500e6);
        assertGe(_hf(pA), 1e18, "Drifting market: HF >= 1");
        vm.prank(aaveDao);
        IHostileSpokeConfigurator(aave.spokeConfigurator).updateFrozen(aave.cdpSpoke, vtReserve, true);
        _borrowAs(alice, mA, usdcReserveId, 500e6);
        assertGe(_hf(pA), 1e18, "frozen collateral reserve: HF >= 1");
        assertApproxEqAbs(_debtOf(pA, usdcReserveId), debtBefore + 1000e6, 2, "both borrows taken (Aave rounds)");
    }
}
