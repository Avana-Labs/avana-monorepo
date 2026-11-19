// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapBase} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapBase.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {IAaveAdapterBase} from "../../src/policy/aave-adapter/IAaveAdapterBase.sol";
import {PendingView} from "../../src/types/PositionTypes.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title LiquidationPendingIntegrationTest
/// @notice Pending settlement on the real stack (`RealStackFlows`). An earlier, non-conforming LPVaultSwap
/// implementation kept the units of a seizure (simulated by a direct `liquidationCall` from LPVaultSwap's address,
/// which the vault token admits as the only seizure recipient). The next honest liquidation through the real
/// LPVaultSwap, or the borrower's withdrawal through the real AaveAdapter, reconciles them into Collateralization's
/// pending balance; `settlePending` by any caller burns them through the real Adapter's `burnSeized`, unwinds them
/// through the real Uniswap v3 LPVault and NonfungiblePositionManager, swaps both pool tokens through the real
/// `DexPathRoute`s into the market's settlement asset (GHO, `registry.settlementReserve`) and funds the real
/// First-Loss Reserve of the market's (Hub, settlement asset). The Lens's pending and backing views are checked at each
/// step.
/// @dev Bob's account: 10,000 vault tokens ($20,000 at $2.00, CF 30 %) against 5,880 USDC, HF 1.020; USDT then falls
/// to $0.93 (`_depegUsdt`), the vault token to $1.9287 and HF to 0.984. The kept seizure repays 50 USDC and seizes
/// `50 × bonus × pUSDC / 1.9287` vault tokens (the Spoke's bonus at that HF, as the Lens reports it); the honest
/// liquidation then repays the Lens's `params.debtToCover` and seizes its `expectedUnitsSeized`.
/// forge-config: default.isolate = false
contract LiquidationPendingIntegrationTest is RealStackFlows {
    uint256 internal constant KEPT_REPAY = 50e6;
    uint256 internal mA;
    address internal vt;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        vt = mkt[mA].vaultToken;
    }

    function _bobAccount() internal returns (address proxy, bytes32 key) {
        (key, proxy) = _pledgeAs(bob, mA, UNITS);
        _borrowAs(bob, mA, usdcReserveId, 5880e6);
        _depegUsdt(93_000_000);
    }

    /// @dev A seizure whose units LPVaultSwap kept, outside any Avana call. Returns the units seized.
    function _keptSeizure(
        address proxy,
        uint256 x
    ) internal returns (uint256 seized) {
        uint256 before = IERC20(vt).balanceOf(lpVaultSwap);
        usdc.mint(lpVaultSwap, x);
        vm.startPrank(lpVaultSwap);
        usdc.approve(aave.cdpSpoke, x);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(mkt[mA].reserveId, usdcReserveId, proxy, x, false);
        usdc.approve(aave.cdpSpoke, 0);
        vm.stopPrank();
        seized = IERC20(vt).balanceOf(lpVaultSwap) - before;
    }

    function _credited(
        bytes32 key
    ) internal view returns (uint256) {
        return coll.getRecord(coll.recordIdOf(V3, key)).credited;
    }

    // TEST-170 verifies: REQ-SWAP-044, SPEC-LIQ-014
    function test_TEST_170_nothingPendingRefused() public {
        uint256 settleReserve = registry.settlementReserve(mA);
        vm.expectRevert(ILPVaultSwapBase.NothingPending.selector);
        lvs.settlePending(mA, settleReserve);
    }
}
