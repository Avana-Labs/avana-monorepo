// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashSource} from "../../src/flash/IFlashSource.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapBase} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapBase.sol";
import {IAaveAdapterBase} from "../../src/policy/aave-adapter/IAaveAdapterBase.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/AaveAdapterTypes.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DeleverageRepayWithCollateralIntegrationTest
/// @notice Repay with collateral on the real stack (`RealStackFlows`): the wallet calls the real AaveAdapter, which
/// opens its session and calls the real LPVaultSwap's `deleverage`; LPVaultSwap flash-borrows the debt asset from the
/// real `AaveV3FlashSource` (lending from the Aave V3 Pool stand-in, 5 bps), repays through the Adapter's
/// `deleverageRepay`, has the Adapter release and unwind the units through the real Uniswap v3 LPVault and
/// NonfungiblePositionManager (`deleverageRelease`), swaps the pool tokens into the debt asset through the real
/// `DexPathRoute`s, repays the loan and its premium by balance delta and sends the rest to the wallet. The Lens's
/// `previewRepayWithCollateral` is checked against the execution.
/// @dev Bob: 10,000 vault tokens at $2.00 ($20,000, CF 30 %) against 4,000 USDC (HF 1.50). Releasing 1,500 vault
/// tokens ($3,000 at the oracle) repays what the Lens previews (the oracle value less the market's slippage allowance
/// and loan-fee room); the wallet's rest differs from the preview's (valued at `R = V`) by exactly `V - R`, what the
/// real unwind and route pools recovered below the oracle value. `TEST-287` (a transfer fee on the debt asset) is in
/// `Deleverage.RepayWithCollateral.FeeOnTransfer`, on a debt asset whose issuer can switch on a fee.
/// forge-config: default.isolate = false
contract DeleverageRepayWithCollateralIntegrationTest is RealStackFlows {
    uint128 internal constant RELEASE = 1500e6;

    struct Snapshot {
        uint256 pvRepaid;
        uint256 pvToWallet;
        uint256 pvHf;
        uint256 hf;
        uint256 debt;
        uint256 lender;
        uint256 supply;
        uint256 credited;
        uint256 wallet;
    }

    uint256 internal mA;
    address internal vt;
    address internal proxy;
    bytes32 internal key;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        vt = mkt[mA].vaultToken;
        (key, proxy) = _pledgeAs(bob, mA, UNITS);
        _borrowAs(bob, mA, usdcReserveId, 4000e6);
    }

    function _rwc(
        uint128 units,
        uint256 reserveId
    ) internal view returns (RepayWithCollateralParams memory p) {
        p = _rwcParams(mA, key, units, reserveId);
    }

    function _aUsdc() internal view returns (address) {
        return v3Pool.getReserveAToken(address(usdc));
    }

    /// @dev The oracle value of `units` vault-token units in USDC base units (USDC at its Chainlink feed's $1.00).
    function _valueUsdc(
        uint256 units
    ) internal view returns (uint256) {
        (, int256 usdcPrice,,,) = usdcOracle.latestRoundData();
        return units * uint256(mkt[mA].oracle.latestAnswer()) / uint256(usdcPrice);
    }

    function _credited(
        bytes32 k
    ) internal view returns (uint128) {
        return uint128(coll.getRecord(coll.recordIdOf(V3, k)).credited);
    }

    function _checkAfter(
        Snapshot memory b
    ) internal view {
        assertEq(usdc.balanceOf(feeRecipient), 0, "no Avana fee");
        assertEq(b.supply - IERC20(vt).totalSupply(), RELEASE, "the Adapter burned the released units");
        assertEq(b.credited - coll.getTotalCredited(vt), RELEASE, "Collateralization debited them");
        assertEq(IERC20(vt).totalSupply(), coll.getTotalCredited(vt), "supply = credited");
        assertGt(_hf(proxy), b.hf, "health factor rose");
        assertApproxEqRel(_hf(proxy), b.pvHf, 1e15, "health factor after near the preview");
        assertEq(usdc.balanceOf(lpVaultSwap) + usdt.balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps nothing");
        assertEq(usdc.balanceOf(adapter) + usdt.balanceOf(adapter), 0, "the Adapter keeps nothing");
        assertFalse(lock.isLocked(), "Lock released");
    }

    /// @notice Releasing every unit of the only record repays the whole debt, closes the record and returns the NFT
    /// to the wallet.
    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081, REQ-PROXY-089, Q-255
    function test_TEST_239_fullUnitsToZeroDebtReturnPosition() public {
        (bytes32 k2, address p2) = _pledgeAs(alice, mA, 2000e6);
        _borrowAs(alice, mA, usdcReserveId, 1000e6);
        RepayWithCollateralParams memory p = _rwcParams(mA, k2, _credited(k2), usdcReserveId);
        uint256 debtBefore = _debtOf(p2, usdcReserveId);
        uint256 walletBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 repaid, uint256 toWallet) = adapterC.repayWithCollateral(p);
        assertEq(repaid, debtBefore, "the whole debt repaid");
        assertEq(_debtOf(p2, usdcReserveId), 0, "debt-free");
        assertEq(usdc.balanceOf(alice) - walletBefore, toWallet, "the rest to the wallet");
        assertEq(_sharesOf(p2, mkt[mA].reserveId), 0, "nothing left supplied");
        assertEq(_credited(k2), 0, "record closed");
        assertEq(IERC721(address(nfpm)).ownerOf(uint256(k2)), alice, "the NFT returned to its depositor");
    }

    /// @notice A repay with collateral that leaves the account debt-free and empties its last record runs the
    /// collateral cleanup, as every other debt-free exit does: the vault-token reserve is no longer used as
    /// collateral, so a later pledge enables it afresh on Aave's latest dynamic configuration key.
    // TEST-239 verifies: REQ-PROXY-089, REQ-PROXY-046, REQ-ADAPTER-080
    function test_TEST_239_debtFreeRepayWithCollateralRunsTheCollateralCleanup() public {
        (bytes32 k2, address p2) = _pledgeAs(alice, mA, 2000e6);
        _borrowAs(alice, mA, usdcReserveId, 1000e6);
        uint256 r = mkt[mA].reserveId;
        (bool enabledBefore,) = IAaveV4Spoke(aave.cdpSpoke).getUserReserveStatus(r, p2);
        assertTrue(enabledBefore, "the vault-token reserve is collateral while pledged");
        RepayWithCollateralParams memory p = _rwcParams(mA, k2, _credited(k2), usdcReserveId);
        vm.expectEmit(adapter);
        emit IAaveAdapterBase.CollateralDisabled(p2, r);
        vm.prank(alice);
        adapterC.repayWithCollateral(p);
        assertEq(_debtOf(p2, usdcReserveId), 0, "debt-free");
        assertEq(_sharesOf(p2, r), 0, "nothing left supplied");
        (bool enabled,) = IAaveV4Spoke(aave.cdpSpoke).getUserReserveStatus(r, p2);
        assertFalse(enabled, "the emptied reserve is no longer used as collateral");
    }

    function _recoveredLog(
        Vm.Log[] memory logs
    ) internal view returns (uint256 recovered) {
        bytes32 sig = ILPVaultSwapBase.Deleveraged.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == lpVaultSwap && logs[i].topics[0] == sig) {
                (,, recovered,,) = abi.decode(logs[i].data, (uint128, uint256, uint256, uint256, uint256));
                return recovered;
            }
        }
        revert("no Deleveraged");
    }

    function _flashLog(
        Vm.Log[] memory logs
    ) internal view returns (uint256 amount, uint256 premium) {
        bytes32 sig = ILPVaultSwapBase.FlashLoanUsed.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == lpVaultSwap && logs[i].topics[0] == sig) {
                (amount, premium) = abi.decode(logs[i].data, (uint256, uint256));
                return (amount, premium);
            }
        }
        revert("no FlashLoanUsed");
    }
}
