// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";

/// @title DebtOracleStaleDebtPriceUnitTest
/// @notice The USDC DebtOracle's side of a stale debt price (5.1 `TEST-201`): what the RiskModule and LPVaultSwap read
/// from it when the USDC feeds stop. A served price older than `borrowPriceMaxAge` clears `borrowAllowed` while the
/// state stays Live and seizure open; with both routes failed the oracle is Cached, serving the accepted price with
/// seizure paused, then Expired, serving the stress price; a fresh update restores Live and every gate.
contract DebtOracleStaleDebtPriceUnitTest is DebtOracleFixture {
    uint256 internal constant A0 = 99_990_000;

    function setUp() public {
        _deployDebtOracle();
    }

    // TEST-201 verifies: REQ-ORACLE-093, SPEC-ORC-018
    /// @notice Borrow age: with the primary's borrow age at 3,600 s, the served price is borrowable at exactly 3,600 s
    /// and not one second later, while the state stays Live and seizure stays open (the liquidation limit is 88,200).
    /// Both routes failing makes the oracle Cached: it serves the accepted price A with seizure of the repaid reserve
    /// paused and borrowing refused, then Expired at `failedSince + cachedWindow`, serving ⌈A × 1.05⌉. A fresh update
    /// on both routes restores Live, the fresh price and `borrowAllowed`.
    function test_TEST_201_staleUsdcDebtPriceGates() public {
        store.setBorrowAge(address(pUsd), 3600);
        vm.warp(T0 - 100 + 3600);
        _refresh(second);
        DebtPriceView memory v = oracle.getPriceState();
        assertTrue(v.borrowAllowed, "at the borrow age");
        vm.warp(T0 - 100 + 3601);
        _refresh(second);
        _refresh(aEth);
        _refresh(ethUsd);
        v = oracle.getPriceState();
        assertFalse(v.borrowAllowed, "older than borrowPriceMaxAge: no new debt");
        assertEq(uint8(v.state), uint8(PriceState.Live), "still Live");
        assertFalse(v.liquidationPaused, "liquidation repaying USDC stays open");

        uint256 t = T0 + 30;
        vm.warp(t);
        pUsd.push(0, t);
        aEth.push(0, t);
        assertEq(uint8(_poke()), uint8(PriceState.Cached), "both routes failed");
        v = oracle.getPriceState();
        assertEq(uint256(v.answer), A0, "Cached serves the accepted price");
        assertTrue(v.liquidationPaused, "a liquidation repaying USDC is refused");
        assertFalse(v.borrowAllowed, "borrowing refused");
        vm.warp(t + 3600);
        v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Expired), "Expired");
        assertEq(uint256(v.answer), 104_989_500, "the stress price ceil(A x 1.05)");
        assertTrue(v.liquidationPaused, "still refused");
        assertFalse(v.borrowAllowed);

        uint256 back = t + 4000;
        vm.warp(back);
        pUsd.push(USDC_USD, back);
        aEth.push(USDC_ETH, back);
        ethUsd.push(ETH_USD, back);
        _refresh(second);
        assertEq(uint8(_poke()), uint8(PriceState.Live), "a fresh update restores Live");
        v = oracle.getPriceState();
        assertEq(uint256(v.answer), A0, "the fresh price");
        assertTrue(v.borrowAllowed, "borrowing restored");
        assertFalse(v.liquidationPaused, "liquidation restored");
    }
}
