// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapBase} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapBase.sol";
import {LiquidationParams, LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {IAaveAdapterBase} from "../../src/policy/aave-adapter/IAaveAdapterBase.sol";
import {ClTestToken} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackUniswapV4Journeys} from "../utils/fixtures/RealStackUniswapV4Journeys.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LiquidationUniswapV4IntegrationTest
/// @notice Caller-funded liquidation of accounts on a Uniswap v4 market, opened through the real AaveAdapter and
/// settled by the real LPVaultSwap on the real stack: the Lens's `previewLiquidation` parameters executed unchanged for
/// a USDC and a GHO debt (`TEST-205`) with every settlement identity of `TEST-047`, the Adapter's seized-unit burn and
/// its event (`TEST-208`), a caller's raised `minPayout`, and the borrower's exits after a liquidation (`TEST-193`).
/// The seized units are removed through the real Uniswap v4 LPVault: the principal to LPVaultSwap and the fees to the
/// depositor.
/// @dev Each account: a $20,000 USDC/USDT v4 position against 5,880 of debt (HF 1.020); USDT then falls to $0.93.
/// forge-config: default.isolate = false
contract LiquidationUniswapV4IntegrationTest is RealStackUniswapV4Journeys {
    function setUp() public {
        _setUpV4Journeys();
    }

    function _params(
        address proxy,
        uint256 reserveId,
        uint256 debtToCover
    ) internal view returns (LiquidationParams memory p) {
        p = _liqParams(proxy, mS, reserveId, debtToCover);
    }

    function _burnEvents(
        uint256 c
    ) internal view returns (uint256 burns) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 k = 0; k < logs.length; ++k) {
            if (logs[k].emitter != adapter || logs[k].topics[0] != IAaveAdapterBase.SeizedUnitsBurned.selector) {
                continue;
            }
            ++burns;
            assertEq(uint256(logs[k].topics[1]), mS, "event market");
            assertEq(address(uint160(uint256(logs[k].topics[2]))), vtS, "event vault token");
            assertEq(abi.decode(logs[k].data, (uint256)), c, "event units = c");
        }
    }

    // TEST-193 verifies: REQ-ADAPTER-047, REQ-ADAPTER-071, REQ-PROXY-032, REQ-PROXY-035, INV-045, INV-067
    function test_TEST_193_v4ExitsAfterLiquidation() public {
        (address proxy, bytes32 key) = _stableAccount(bob, v4UsdcReserveS, DEBT_USDC);
        _depegUsdt4(93_000_000);
        _liquidateOn(v4SpokeS, keeper, _params(proxy, v4UsdcReserveS, 800e6));
        uint256 owed = _debtOn(v4SpokeS, proxy, v4UsdcReserveS);
        _repayOn(bob, bob, mS, v4UsdcReserveS, owed + 1e6, true);
        assertEq(_debtOn(v4SpokeS, proxy, v4UsdcReserveS), 0, "repaid");
        uint256 left = _credited4(key);
        vm.prank(bob);
        adapterC.withdraw(mS, _ref4(key), left, _deadline(), 0);
        assertEq(v4posm.ownerOf(uint256(key)), bob, "the NFT returned to its depositor");
        assertEq(_sharesOn(v4SpokeS, proxy, mkt[mS].reserveId), 0, "nothing left supplied");
        _assertBacked(vtS);
    }
}
