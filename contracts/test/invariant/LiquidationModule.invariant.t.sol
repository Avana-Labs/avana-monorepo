// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {LiquidationModuleTestBase} from "../utils/LiquidationModuleTestBase.sol";
import {LiquidationModuleHandler} from "./handlers/LiquidationModuleHandler.sol";

/// @notice Partial-liquidation invariants over random pledges, borrows, collateral-factor moves and liquidations on
/// both markets of a pool: health never falls, no value leaks, credit loss stays within the seized units, the fee stays
/// within its share, the module keeps nothing, and vault-token supply stays backed by credit.
contract LiquidationModuleInvariantTest is LiquidationModuleTestBase {
    LiquidationModuleHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LiquidationModuleHandler(
            LiquidationModuleHandler.Env({
                adapter: adapter,
                spoke: spoke,
                module: ILiquidationModule(address(module)),
                vault: ILPVault(address(vault)),
                pm: pm,
                token0: token0,
                token1: token1,
                pool: POOL,
                alice: alice,
                bob: bob,
                liquidator: liquidator,
                feeRecipient: feeRecipient,
                debtReserve: DEBT_RESERVE
            })
        );
        targetContract(address(handler));
    }

    function invariant_healthNeverFalls() public view {
        assertEq(handler.healthDrops(), 0);
    }

    function invariant_noValueLeaks() public view {
        assertEq(handler.leaked(), 0);
    }

    function invariant_creditLossWithinSeized() public view {
        assertEq(handler.overTaken(), 0);
    }

    function invariant_feeWithinShare() public view {
        assertEq(handler.feeOverShare(), 0);
    }

    function invariant_moduleKeepsNothing() public view {
        assertEq(token0.balanceOf(address(module)), 0);
        assertEq(token1.balanceOf(address(module)), 0);
        assertEq(usdc.balanceOf(address(module)), 0);
        assertEq(vtFull.balanceOf(address(module)) + vtCustom.balanceOf(address(module)), 0);
    }

    /// @notice Each vault token stays backed: supply at most the market's credit, give or take two units of rounding
    /// per position a liquidation touched.
    function invariant_supplyBackedByCredit() public view {
        uint256 dust = handler.liquidations() * 2 * 16;
        assertLe(vtFull.totalSupply(), vault.getMarket(FULL).totalCredit + dust);
        assertLe(vtCustom.totalSupply(), vault.getMarket(CUSTOM).totalCredit + dust);
    }
}
