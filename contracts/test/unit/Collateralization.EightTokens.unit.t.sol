// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {Pending} from "../../src/custody/collateralization/types/Pending.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CollateralizationEightTokensUnitTest
/// @notice A market of eight tokens (the AMM-neutral maximum) on the real local Aave V4: every amount array the
/// ledger stores, passes or returns has eight entries in pool order, through a pledge's token counters, a seizure, a
/// reconcile into the pending balance and its settlement; a minimums array of another length is refused.
/// forge-config: default.isolate = false
contract CollateralizationEightTokensUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY7 = bytes32(uint256(7));
    uint256 internal constant N = 8;

    function setUp() public {
        extraTokenCount = N - 2;
        _deployCollateralization();
    }

    // TEST-208 verifies: REQ-COLL-028, REQ-COLL-026, REQ-VAULT-060, REQ-VAULT-135, REQ-VAULT-137, SPEC-BACK-012
    // Sources: 2.3 REQ-COLL-028 (2 to 8 market tokens, arrays in pool order)
    /// @notice Eight token counters move together; an unsettled seizure reconciles eight pending amounts; the honest
    /// seizure that follows pays eight amounts to LPVaultSwap; `settlePending` pays the eight pending amounts.
    function test_TEST_208_eightTokenMarket() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        PledgeCounters memory k = coll.getCounters(vt, alice);
        assertEq(k.tokenUsed.length, N);
        for (uint256 i = 1; i < N; ++i) {
            assertEq(k.tokenUsed[i], k.tokenUsed[0], "every token counter carries the charge");
        }
        assertGt(k.tokenUsed[0], 0);

        _borrow(aliceProxy, 13_000e18);
        vtPrice.set(1.6e8);
        uint256 kept = _seizeAndKeep(aliceProxy, 1000e18);

        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(lpVaultSwap);
        coll.beginSeizure(aliceProxy, vt);
        uint256 seized = _seizeAndKeep(aliceProxy, 1000e18);
        vm.prank(adapter);
        token.burn(lpVaultSwap, seized);
        vm.prank(lpVaultSwap);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.LengthMismatch.selector, N, 2));
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](2));
        uint256[] memory before = _swapBalances();
        vm.prank(lpVaultSwap);
        uint256[] memory amounts = coll.settleSeizure(aliceProxy, vt, seized, new uint256[](N));
        vm.prank(lpVaultSwap);
        lock.release();

        uint256[] memory afterSeizure = _swapBalances();
        assertEq(amounts.length, N);
        for (uint256 i = 0; i < N; ++i) {
            uint256 rate = i == 0 ? 800_000 : i == 1 ? 1_250_000 : 1_000_000;
            assertEq(amounts[i], seized * rate / 1e6, "seizure amount per token");
            assertEq(afterSeizure[i] - before[i], amounts[i], "paid to LPVaultSwap");
        }
        Pending memory p = coll.getPending(vt);
        assertEq(p.units, kept, "the kept seizure is reconciled into pending");
        assertEq(p.amounts.length, N);
        for (uint256 i = 2; i < N; ++i) {
            assertEq(p.amounts[i], kept, "pending amount per token");
        }

        uint256[] memory paid = _settlePending(kept);
        uint256[] memory afterPending = _swapBalances();
        assertEq(paid.length, N);
        for (uint256 i = 0; i < N; ++i) {
            assertEq(paid[i], p.amounts[i], "the whole pending amount");
            assertEq(afterPending[i] - afterSeizure[i], paid[i]);
        }
        assertEq(coll.getPending(vt).units, 0);
        assertEq(_gap(), 0);
    }

    function _swapBalances() internal view returns (uint256[] memory b) {
        b = new uint256[](N);
        b[0] = usdc.balanceOf(lpVaultSwap);
        b[1] = usdt.balanceOf(lpVaultSwap);
        for (uint256 i = 2; i < N; ++i) {
            b[i] = IERC20(address(extraTokens[i - 2])).balanceOf(lpVaultSwap);
        }
    }
}
