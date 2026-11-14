// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {INonfungiblePositionManager} from "../../src/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {AccountView} from "../../src/lens/lens/types/AccountView.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {RecordView} from "../../src/lens/lens/types/RecordView.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title LpJourneyIntegrationTest
/// @notice `TEST-223` on the real stack (`RealStackFlows`): one LP's journey from wallet to Spoke and back through the
/// real AaveAdapter, PositionProxy, Collateralization, Uniswap v3 LPVault on the NonfungiblePositionManager,
/// LPVaultSwap and Lens, with the Lens asserted at every step against what the chain then holds: deposit → borrow →
/// collect fees → partial repay → top-up → borrow to the limit → price drop → partial liquidation sized by the Lens →
/// `repayAllAndWithdraw` → NFTs returned. Variants: a frozen address, both pause reasons, partial removal with and
/// without debt, and a re-credit after a third party adds liquidity to the custodied NFT.
/// @dev Vault tokens are $2.00 at $1 tokens (CF 30 %). Fees are real: swaps through the market's own pool, out and
/// back to its price in one block (the TWAP is unmoved), accrue Uniswap fees to the NFT, and `collectFees` pays the
/// wallet exactly what the position manager owed. The price drop stays inside the $0.90–$1.02 USD band: both tokens
/// fall to $0.92 on every feed (`_movePoolTokens`, vault token $1.84, -8 %) after the account borrows up to the Lens's
/// `previewBorrowMax`. A donation is a third party's `increaseLiquidity` on the NFT the LPVault holds (the position
/// manager does not restrict the caller); amounts released by a removal are what the position manager pays for that
/// liquidity, read by a reverted dry run.
/// forge-config: default.isolate = false
contract LpJourneyIntegrationTest is RealStackFlows {
    uint256 internal mA;
    address internal vt;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        vt = mkt[mA].vaultToken;
    }

    /// @dev The Lens's account view equals the Spoke's and Collateralization's state in the same block.
    function _lensMatchesChain(
        address wallet
    ) internal view returns (AccountView memory a) {
        a = lens.getAccount(wallet, mA);
        address proxy = adapterC.proxyOf(wallet, mA);
        assertEq(a.proxy, proxy, "Lens: proxy");
        assertTrue(a.deployed, "Lens: deployed");
        assertEq(a.borrowNonce, adapterC.borrowNonce(proxy), "Lens: borrow nonce");
        assertEq(a.healthFactor, _hf(proxy), "Lens: health factor = Spoke");
        assertEq(a.markets[0].suppliedShares, _sharesOf(proxy, mkt[mA].reserveId), "Lens: supplied = Spoke");
        assertEq(a.markets[0].credited, coll.getAccountCredited(proxy, vt), "Lens: credited = Collateralization");
        assertEq(a.debts[0].reserveId, ghoReserveId, "Lens: GHO reserve first");
        assertEq(a.debts[0].total, _debtOf(proxy, ghoReserveId), "Lens: GHO debt = Spoke");
        assertEq(a.debts[1].reserveId, usdcReserveId, "Lens: USDC reserve second");
        assertEq(a.debts[1].total, _debtOf(proxy, usdcReserveId), "Lens: USDC debt = Spoke");
        assertTrue(lens.checkBacking(vt).supplyEqualsCredited, "Lens: vault token backed");
    }

    /// @dev Bob's account of `units` with `usdcDebt` of USDC (call before any price move).
    function _usdcAccount(
        address wallet,
        uint128 units,
        uint256 usdcDebt
    ) internal returns (address proxy, bytes32 key) {
        (key, proxy) = _pledgeAs(wallet, mA, units);
        if (usdcDebt != 0) _borrowAs(wallet, mA, usdcReserveId, usdcDebt);
    }

    function _liquidityOf(
        bytes32 key
    ) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = nfpm.positions(uint256(key));
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

    /// @dev Real fees: `amount` of token0 sold into the market's pool, then the pool swapped back to its price, in
    /// one block, so the in-range NFTs accrue Uniswap fees in both tokens and the TWAP is unmoved.
    function _tradeThroughPool(
        uint256 amount
    ) internal {
        IClPool p = mkt[mA].pool;
        (uint160 start,,,,,,) = p.slot0();
        actor.swap(p, true, int256(amount), 4_295_128_740);
        _swapTo(p, start);
    }

    /// @dev What the position manager owes the NFT (both tokens, in its token0 / token1 order), from a reverted
    /// `collect` by its owner, the LPVault.
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

    /// @dev What the position manager pays for `liquidity` of the NFT, from a reverted `decreaseLiquidity` by its owner.
    function _released(
        bytes32 key,
        uint128 liquidity
    ) internal returns (uint256 a0, uint256 a1) {
        uint256 snap = vm.snapshotState();
        vm.prank(integration);
        (a0, a1) = nfpm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams(uint256(key), liquidity, 0, 0, block.timestamp)
        );
        vm.revertToState(snap);
    }

    uint256[2] internal walletBefore;

    /// @dev Records `wallet`'s balance of the pool's token0 and token1.
    function _snapWallet(
        address wallet
    ) internal {
        IClPool p = mkt[mA].pool;
        walletBefore = [ClTestToken(p.token0()).balanceOf(wallet), ClTestToken(p.token1()).balanceOf(wallet)];
    }

    /// @dev `wallet` received exactly `a0` of token0 and `a1` of token1 since `_snapWallet`.
    function _assertWalletGot(
        address wallet,
        uint256 a0,
        uint256 a1,
        string memory what
    ) internal view {
        IClPool p = mkt[mA].pool;
        assertEq(ClTestToken(p.token0()).balanceOf(wallet) - walletBefore[0], a0, string.concat("token0 ", what));
        assertEq(ClTestToken(p.token1()).balanceOf(wallet) - walletBefore[1], a1, string.concat("token1 ", what));
    }

    // TEST-223 verifies: REQ-LENS-008, REQ-LENS-009, REQ-LENS-011, REQ-LENS-012, REQ-LENS-016, REQ-LENS-028, REQ-LENS-035, REQ-LENS-036, REQ-ADAPTER-071, REQ-ADAPTER-096, REQ-PROXY-032, Q-268, Q-278
    function test_TEST_223_fullJourney() public {
        (bytes32 key, address proxy) = _depositBorrowCollect();
        bytes32 key2 = _repayAndTopUp(proxy);
        _liquidateSized(proxy);
        _repayAllAndExit(proxy, key, key2);
    }

    /// @dev Deposit (the predicted proxy is the one deployed), borrow the Lens's recommended GHO, collect real fees.
    function _depositBorrowCollect() internal returns (bytes32 key, address proxy) {
        (address predicted, bool deployed) = lens.predictProxy(alice, mA);
        assertFalse(deployed, "no account yet");
        (key, proxy) = _pledgeAs(alice, mA, 20_000e6);
        assertEq(proxy, predicted, "CREATE2 address as predicted");
        assertEq(_lensMatchesChain(alice).markets[0].credited, _liquidityOf(key), "credited = the NFT's liquidity");
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, mA, ghoReserveId, _deadline());
        assertLt(rec, max, "recommended below the maximum");
        _borrowAs(alice, mA, ghoReserveId, rec);
        assertApproxEqRel(_hf(proxy), 1.1e18, 1e12, "lands at the recommended 1.10");
        _lensMatchesChain(alice);
        _collectRealFees(key, proxy);
    }

    /// @dev Fees: units, supply and health factor unchanged; the wallet receives what the NFT was owed.
    function _collectRealFees(
        bytes32 key,
        address proxy
    ) internal {
        _tradeThroughPool(1e14);
        (uint256 owed0, uint256 owed1) = _owed(key);
        assertGt(owed0, 0, "token0 fees accrued");
        assertGt(owed1, 0, "token1 fees accrued");
        uint256 hf = _hf(proxy);
        uint256 creditedBefore = _credited(key);
        _snapWallet(alice);
        vm.prank(alice);
        adapterC.collectFees(mA, _ref(key), _deadline());
        _assertWalletGot(alice, owed0, owed1, "fees to the depositor");
        assertEq(_credited(key), creditedBefore, "units unchanged");
        assertEq(_hf(proxy), hf, "health factor unchanged");
    }

    /// @dev A third party repays a quarter 30 days later; the borrower tops up with a second record, then borrows up
    /// to the Lens's maximum.
    function _repayAndTopUp(
        address proxy
    ) internal returns (bytes32 key2) {
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 30 days / BLOCK_TIME);
        _refreshFeeds();
        _pokeAll();
        uint256 owed = _debtOf(proxy, ghoReserveId);
        _repayVia(carol, alice, mA, ghoReserveId, owed / 4, false);
        assertApproxEqAbs(_debtOf(proxy, ghoReserveId), owed - owed / 4, 1, "a quarter repaid");
        _lensMatchesChain(alice);
        (key2,) = _pledgeAs(alice, mA, 2000e6);
        assertEq(lens.getRecords(proxy, 0, 16).length, 2, "Lens: two records");
        _lensMatchesChain(alice);
        uint256 max = lens.previewBorrowMax(alice, mA, ghoReserveId, _deadline());
        _borrowAs(alice, mA, ghoReserveId, max);
        assertGe(_hf(proxy), 1e18, "at the limit, above HF 1");
        _lensMatchesChain(alice);
    }

    /// @dev Both tokens fall to $0.92 (inside the USD band), then a partial liquidation sized by the Lens.
    function _liquidateSized(
        address proxy
    ) internal {
        _movePoolTokens(92_000_000);
        uint256 creditedBefore = coll.getAccountCredited(proxy, vt);
        LiquidationPreview memory p = lens.previewLiquidation(proxy, ghoReserveId, block.timestamp + 120);
        assertTrue(p.aaveLiquidatable && p.pricesUsable, "liquidatable with usable prices");
        LiquidationResult memory r = _liquidateAs(keeper, p.params);
        assertEq(r.debtRepaid, p.expectedDebtRepaid, "D as previewed");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
        AccountView memory a = _lensMatchesChain(alice);
        assertEq(a.markets[0].credited, creditedBefore - r.unitsSeized, "credited fell by the seizure");
        assertGt(a.healthFactor, p.healthFactor, "health restored toward the target");
    }

    /// @dev Repay everything with the Lens's quote and withdraw the first record in one call, then the second.
    function _repayAllAndExit(
        address proxy,
        bytes32 key,
        bytes32 key2
    ) internal {
        _movePoolTokens(100_000_000);
        uint256 quote = lens.quoteRepayAll(alice, mA, ghoReserveId, _deadline());
        RecordView[] memory recs = lens.getRecords(proxy, 0, 16);
        gho.mint(alice, quote);
        vm.prank(alice);
        gho.approve(adapter, quote);
        uint256[] memory ids = new uint256[](1);
        ids[0] = ghoReserveId;
        uint256[] memory spends = new uint256[](1);
        spends[0] = quote;
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(mA, _ref(recs[0].positionKey), recs[0].credited, ids, spends, _deadline());
        assertEq(_debtOf(proxy, ghoReserveId), 0, "debt-free");
        _withdrawVia(alice, mA, recs[1].positionKey, recs[1].credited);
        assertEq(_ownerOf(key), alice, "first NFT returned");
        assertEq(_ownerOf(key2), alice, "second NFT returned");
        assertEq(lens.getRecords(proxy, 0, 16).length, 0, "Lens: no record left");
        assertEq(_lensMatchesChain(alice).markets[0].credited, 0, "nothing credited");
        assertFalse(lock.isLocked(), "Lock free");
    }

    // TEST-223 verifies: REQ-ADAPTER-082, REQ-ADAPTER-086, REQ-LENS-009, Q-242, Q-252
    function test_TEST_223_frozenAddress() public {
        // $20,000 at CF 30 % against 5,714 USDC: HF 1.05 < the 1.10 target, so a top-up up to the restore amount
        // (about $950 of collateral) is a rescue.
        (address proxy, bytes32 key) = _usdcAccount(alice, UNITS, 5714e6);
        _freezeWallet(alice);
        assertTrue(lens.getAccount(alice, mA).walletFrozen, "Lens: frozen wallet shown");
        uint256 nonce = adapterC.borrowNonce(proxy);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.AddressIsFrozen.selector, alice));
        vm.prank(alice);
        adapterC.borrow(mA, usdcReserveId, 1e6, alice, _deadline(), 0, nonce);
        // A rescue top-up of an indebted account stays open ($800, within the restore amount).
        _pledgeAs(alice, mA, 400e6);
        // Exits stay open: repay, then a debt-free withdrawal.
        _repayVia(alice, alice, mA, usdcReserveId, _debtOf(proxy, usdcReserveId), true);
        _withdrawVia(alice, mA, key, _credited(key));
        assertEq(_ownerOf(key), alice, "NFT returned while frozen");
        _lensMatchesChain(alice);
    }

    // TEST-223 verifies: REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ADAPTER-083, REQ-LENS-031, Q-252
    function test_TEST_223_pausedGeneralRescueAndMintPathSuspectExits() public {
        (address proxy, bytes32 key) = _usdcAccount(alice, UNITS, 5714e6);
        _setPause(PauseState.Paused, PauseReason.General);
        assertEq(uint8(lens.getApplicationState(aave.hub)), uint8(PauseState.Paused), "Lens: Paused");
        assertEq(lens.getPauseReason(aave.hub), uint8(PauseReason.General), "Lens: General");
        uint256 nonce = adapterC.borrowNonce(proxy);
        vm.expectRevert(IAaveAdapterErrors.ApplicationPaused.selector);
        vm.prank(alice);
        adapterC.borrow(mA, usdcReserveId, 1e6, alice, _deadline(), 0, nonce);
        _pledgeAs(alice, mA, 400e6);
        assertEq(lens.getRecords(proxy, 0, 16).length, 2, "rescue top-up taken under General");

        _setPause(PauseState.Paused, PauseReason.MintPathSuspect);
        bytes32 k3 = _mintPosition(alice, mA, 1000e6);
        vm.expectRevert(IAaveAdapterErrors.ApplicationPaused.selector);
        vm.prank(alice);
        adapterC.pledge(mA, _ref(k3), _deadline());
        _repayVia(alice, alice, mA, usdcReserveId, _debtOf(proxy, usdcReserveId), true);
        _withdrawVia(alice, mA, key, _credited(key));
        assertEq(_ownerOf(key), alice, "exit open under MintPathSuspect");
        _lensMatchesChain(alice);
    }

    // TEST-223 verifies: REQ-ADAPTER-045, REQ-ADAPTER-086, Q-254
    function test_TEST_223_partialRemovalWithAndWithoutDebt() public {
        (address proxy, bytes32 key) = _usdcAccount(alice, UNITS, 2000e6);
        uint256 credited = coll.getAccountCredited(proxy, vt);
        uint256[] memory mins = new uint256[](2);
        uint256 hfBefore = _hf(proxy);
        (uint256 e0, uint256 e1) = _released(key, 2000e6);
        _snapWallet(alice);
        vm.prank(alice);
        uint256[] memory out = adapterC.removeLiquidity(mA, _ref(key), 2000e6, mins, _deadline(), 0);
        assertEq(out[0], e0, "token0: what the position manager pays for the liquidity");
        assertEq(out[1], e1, "token1: likewise");
        _assertWalletGot(alice, e0, e1, "released to the wallet");
        assertLt(_hf(proxy), hfBefore, "with debt: health factor lower but checked");
        assertEq(coll.getAccountCredited(proxy, vt), credited - 2000e6, "record keeps the rest");
        _repayVia(alice, alice, mA, usdcReserveId, _debtOf(proxy, usdcReserveId), true);
        vm.prank(alice);
        adapterC.removeLiquidity(mA, _ref(key), 3000e6, mins, _deadline(), 0);
        assertEq(coll.getAccountCredited(proxy, vt), credited - 5000e6, "debt-free removal");
        assertEq(_liquidityOf(key), credited - 5000e6, "the NFT's liquidity fell with the units");
        _lensMatchesChain(alice);
    }

    // TEST-223 verifies: REQ-LENS-038, REQ-ADAPTER-083, INV-088, Q-254
    function test_TEST_223_recreditAfterDonation() public {
        (address proxy, bytes32 key) = _usdcAccount(alice, UNITS, 2000e6);
        uint256 sharesBefore = _sharesOf(proxy, mkt[mA].reserveId);
        // A third party adds liquidity to the NFT the LPVault holds.
        address donor = makeAddr("donor");
        uint256 amt = 1000e6 + 1000;
        IClPool p = mkt[mA].pool;
        (ClTestToken t0, ClTestToken t1) = (ClTestToken(p.token0()), ClTestToken(p.token1()));
        t0.mint(donor, amt);
        t1.mint(donor, amt);
        vm.startPrank(donor);
        t0.approve(address(nfpm), amt);
        t1.approve(address(nfpm), amt);
        (uint128 donated,,) = nfpm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams(uint256(key), amt, amt, 0, 0, block.timestamp)
        );
        vm.stopPrank();
        assertEq(_ownerOf(key), integration, "the LPVault still holds the NFT");
        (uint128 added,, bool rescueOnly) = lens.previewRecredit(mA, key);
        assertEq(added, donated, "Lens: the donated units");
        assertFalse(rescueOnly, "Lens: regular re-credit");
        vm.prank(alice);
        uint128 got = adapterC.recredit(mA, _ref(key), "", _deadline());
        assertEq(got, added, "re-credited as previewed");
        assertEq(_sharesOf(proxy, mkt[mA].reserveId), sharesBefore + donated, "minted and supplied");
        assertEq(_credited(key), _liquidityOf(key), "credited = the NFT's liquidity again");
        _lensMatchesChain(alice);
    }
}
