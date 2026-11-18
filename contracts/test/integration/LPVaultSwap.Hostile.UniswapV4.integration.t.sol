// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {ICollateralization} from "../../src/custody/collateralization/ICollateralization.sol";
import {ICollateralizationBase} from "../../src/custody/collateralization/ICollateralizationBase.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {IAaveAdapter} from "../../src/policy/aave-adapter/IAaveAdapter.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {RealStackUniswapV4Journeys} from "../utils/fixtures/RealStackUniswapV4Journeys.sol";
import {HostileLiquidatorImpl} from "./LPVaultSwap.Hostile.integration.t.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LPVaultSwapHostileUniswapV4IntegrationTest
/// @notice A hostile LPVaultSwap installed through the real AvanaTimelock, against accounts on a Uniswap v4 market of
/// the real stack: it cannot seize a healthy account, mint vault tokens, burn more than it holds or debit another
/// account's records (`TEST-131`); and the C-QNT-1 regression (`TEST-154`): units it seized and kept become pending
/// through the borrower's exits, both v4 NFTs return to the borrower, and the honest LPVaultSwap restored through the
/// timelock settles the pending units through the real Uniswap v4 LPVault into the settlement asset's First-Loss
/// Reserve, leaving the market's supply at 0.
/// @dev Accounts are made liquidatable by USDT falling to $0.93 (`_depegUsdt4`).
/// forge-config: default.isolate = false
contract LPVaultSwapHostileUniswapV4IntegrationTest is RealStackUniswapV4Journeys {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal honestImpl;
    HostileLiquidatorImpl internal hostile;

    function setUp() public {
        _setUpV4Journeys();
        honestImpl = address(uint160(uint256(vm.load(lpVaultSwap, IMPL_SLOT))));
        hostile = new HostileLiquidatorImpl(address(accessManager));
    }

    function _install(
        address impl
    ) internal {
        _govern(lpVaultSwap, abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, "")));
        assertEq(address(uint160(uint256(vm.load(lpVaultSwap, IMPL_SLOT)))), impl, "implementation");
    }

    function _run(
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        return HostileLiquidatorImpl(lpVaultSwap).run(target, data);
    }

    /// @dev The hostile implementation repays `amount` of `proxy`'s USDC debt through `liquidationCall` on the v4
    /// Spoke and keeps the seized vault tokens. Returns the units it received.
    function _seizeAndKeep(
        address proxy,
        uint256 amount
    ) internal returns (uint256 c) {
        uint256 before = IERC20(vtS).balanceOf(lpVaultSwap);
        usdc.mint(lpVaultSwap, amount);
        _run(address(usdc), abi.encodeCall(IERC20.approve, (v4SpokeS, amount)));
        _run(
            v4SpokeS,
            abi.encodeCall(IAaveV4Spoke.liquidationCall, (mkt[mS].reserveId, v4UsdcReserveS, proxy, amount, false))
        );
        c = IERC20(vtS).balanceOf(lpVaultSwap) - before;
    }

    // TEST-131 verifies: REQ-VAULT-049, REQ-VAULT-050, REQ-VAULT-051, REQ-ADAPTER-070, ATTACK-025, ATTACK-079
    function test_TEST_131_v4HostileLPVaultSwapBoundedByAaveAndTheLedger() public {
        (address healthy,) = _stableAccount(alice, v4UsdcReserveS, 2000e6);
        (address bobProxy,) = _stableAccount(bob, v4UsdcReserveS, DEBT_USDC);
        _depegUsdt4(93_000_000);
        uint256 aliceCredited = coll.getAccountCredited(healthy, vtS);
        _install(address(hostile));
        usdc.mint(lpVaultSwap, 1000e6);
        _run(address(usdc), abi.encodeCall(IERC20.approve, (v4SpokeS, 1000e6)));
        vm.expectRevert();
        _run(
            v4SpokeS,
            abi.encodeCall(IAaveV4Spoke.liquidationCall, (mkt[mS].reserveId, v4UsdcReserveS, healthy, 1000e6, false))
        );
        vm.expectRevert(IVaultToken.OnlyAdapter.selector);
        _run(vtS, abi.encodeWithSignature("mint(address,uint256)", lpVaultSwap, 1));

        _run(address(lock), abi.encodeCall(ILock.acquire, ()));
        _run(address(coll), abi.encodeCall(ICollateralization.beginSeizure, (healthy, vtS)));
        uint256 c = _seizeAndKeep(bobProxy, 500e6);
        assertGt(c, 0, "bob seized");
        vm.expectRevert();
        _run(adapter, abi.encodeCall(IAaveAdapter.burnSeized, (mS, vtS, c + 1)));
        _run(adapter, abi.encodeCall(IAaveAdapter.burnSeized, (mS, vtS, c)));
        vm.expectRevert(ICollateralizationBase.SeizureMismatch.selector);
        _run(address(coll), abi.encodeCall(ICollateralization.settleSeizure, (bobProxy, vtS, c, new uint256[](0))));
        vm.expectRevert(ICollateralizationBase.DebitMismatch.selector);
        _run(address(coll), abi.encodeCall(ICollateralization.settleSeizure, (healthy, vtS, c, new uint256[](0))));
        _run(address(lock), abi.encodeCall(ILock.release, ()));
        assertEq(coll.getAccountCredited(healthy, vtS), aliceCredited, "alice's records untouched");
    }

    // TEST-154 verifies: REQ-SWAP-066, REQ-VAULT-129, REQ-VAULT-131, INV-001, INV-042, REQ-AMM-V4-004
    function test_TEST_154_v4KeptUnitsSettleThroughTheExitsAndTheFirstLossReserve() public {
        (bytes32 k42, address proxy) = _v4PledgeUsd(alice, mS, 20_000);
        (bytes32 k7,) = _v4PledgeUsd(alice, mS, 16_000);
        // $36,000 at CF 30 % against 10,500 USDC: below HF 1 after the depeg; the kept seizure repays 300 USDC.
        _borrowAs(alice, mS, v4UsdcReserveS, 10_500e6);
        _depegUsdt4(93_000_000);
        assertLt(_hfOn(v4SpokeS, proxy), 1e18, "liquidatable");
        uint256 credited42 = _credited4(k42);
        uint256 credited7 = _credited4(k7);
        _install(address(hostile));
        uint256 c = _seizeAndKeep(proxy, 300e6);
        assertGt(c, 0, "units seized and kept");

        _repayOn(alice, alice, mS, v4UsdcReserveS, _debtOn(v4SpokeS, proxy, v4UsdcReserveS) + 1e6, true);
        uint256 units42 = coll.previewRelease(V4, k42);
        assertEq(units42, credited42 - c, "NFT 42 previews its remaining units");
        vm.prank(alice);
        adapterC.withdraw(mS, _ref4(k42), units42, _deadline(), 0);
        assertEq(v4posm.ownerOf(uint256(k42)), alice, "NFT 42 returned");
        assertEq(coll.getPending(vtS).units, c, "the kept units are pending");
        vm.prank(alice);
        adapterC.withdraw(mS, _ref4(k7), credited7, _deadline(), 0);
        assertEq(v4posm.ownerOf(uint256(k7)), alice, "NFT 7 returned");

        _install(honestImpl);
        uint256 settleReserve = registry.settlementReserve(mS);
        address asset = registry.getDebtReserve(v4SpokeS, settleReserve).asset;
        IAvanaFirstLossReserve reserve = IAvanaFirstLossReserve(firstLossReserveOf[asset]);
        uint256 funded = reserve.fundedBalance();
        (uint256 units,, uint256 added) = lvs.settlePending(mS, settleReserve);
        assertEq(units, c, "the pending units settled");
        assertEq(IERC20(vtS).totalSupply(), 0, "market supply 0");
        assertEq(coll.getPending(vtS).units, 0, "nothing pending");
        assertGt(added, 0, "proceeds recovered");
        assertApproxEqAbs(reserve.fundedBalance(), funded + added, 1, "the proceeds fund the First-Loss Reserve");
        assertEq(v4Vault.balance, 0, "the LPVault never holds ETH");
    }
}
