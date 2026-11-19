// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapBase} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapBase.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/AaveAdapterTypes.sol";
import {RealStackUniswapV4Journeys} from "../utils/fixtures/RealStackUniswapV4Journeys.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeleverageUniswapV4IntegrationTest
/// @notice Repay with collateral on a Uniswap v4 market of the real stack: the wallet calls the real AaveAdapter, which
/// has the real LPVaultSwap flash-borrow the debt asset, repay, release and unwind the units through the real Uniswap v4
/// LPVault (one PositionManager batch: the fees to the depositor, the principal to LPVaultSwap), swap the pool tokens
/// into the debt asset through the real routes, repay the loan and send the rest to the wallet. The Lens's
/// `previewRepayWithCollateral` is checked against the execution; releasing every unit of the only record repays the
/// whole debt and returns the NFT; a `minDebtRepaid` above the preview reverts and changes nothing.
/// @dev Bob: a $20,000 USDC/USDT v4 position against 4,000 USDC (HF 1.50).
/// forge-config: default.isolate = false
contract DeleverageUniswapV4IntegrationTest is RealStackUniswapV4Journeys {
    address internal proxy;
    bytes32 internal key;

    function setUp() public {
        _setUpV4Journeys();
        (proxy, key) = _stableAccount(bob, v4UsdcReserveS, 4000e6);
    }

    function _rwc(
        bytes32 k,
        uint128 units
    ) internal view returns (RepayWithCollateralParams memory p) {
        p = _rwcParams(mS, k, units, v4UsdcReserveS);
        p.position = _ref4(k);
    }

    struct Before {
        uint256 pvRepaid;
        uint256 pvToWallet;
        uint256 pvHf;
        uint256 hf;
        uint256 debt;
        uint256 supply;
        uint256 a0;
        uint256 a1;
        uint256 f0;
        uint256 f1;
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081, REQ-PROXY-089
    function test_TEST_239_v4FullUnitsToZeroDebtReturnPosition() public {
        (address p2, bytes32 k2) = _stableAccount(alice, v4UsdcReserveS, 1000e6);
        uint256 debtBefore = _debtOn(v4SpokeS, p2, v4UsdcReserveS);
        uint256 walletBefore = usdc.balanceOf(alice);
        RepayWithCollateralParams memory p = _rwc(k2, uint128(_credited4(k2)));
        vm.prank(alice);
        (uint256 repaid, uint256 toWallet) = adapterC.repayWithCollateral(p);
        assertEq(repaid, debtBefore, "the whole debt repaid");
        assertEq(_debtOn(v4SpokeS, p2, v4UsdcReserveS), 0, "debt-free");
        assertGe(usdc.balanceOf(alice) - walletBefore, toWallet, "the rest to the wallet");
        assertEq(_sharesOn(v4SpokeS, p2, mkt[mS].reserveId), 0, "nothing left supplied");
        assertEq(_credited4(k2), 0, "record closed");
        assertEq(v4posm.ownerOf(uint256(k2)), alice, "the NFT returned to its depositor");
        _assertBacked(vtS);
    }
}
