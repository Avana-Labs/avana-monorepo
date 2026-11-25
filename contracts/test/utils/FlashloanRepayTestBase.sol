// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FlashloanRepay} from "../../src/FlashloanRepay.sol";
import {IFlashloanRepay} from "../../src/interfaces/IFlashloanRepay.sol";
import {Swap} from "../../src/libraries/SwapCalls.sol";
import {AaveAdapterTestBase} from "./AaveAdapterTestBase.sol";
import {MockFlashPool, MockSwapRouter} from "./mocks/FlashloanRepayMocks.sol";

/// @notice The adapter setup plus an Aave V3 Pool stand-in holding USDC, a router that sells either pool token for
/// USDC at a set rate, and the repay helper. Alice pledges one Full range NFT of 1e18 liquidity (credit 1e18, borrowing
/// power 8e17) and borrows 7e17 USDC: health factor 1.142857.
abstract contract FlashloanRepayTestBase is AaveAdapterTestBase {
    uint256 internal constant DEBT = 7e17;
    /// @dev Byte offset of `amountIn` in `MockSwapRouter.swap` calldata.
    uint256 internal constant AMOUNT_IN_OFFSET = 68;

    MockFlashPool internal flashPool;
    MockSwapRouter internal router;
    FlashloanRepay internal helper;
    bytes32 internal key;

    function setUp() public virtual override {
        super.setUp();
        flashPool = new MockFlashPool();
        usdc.mint(address(flashPool), 1e30);
        router = new MockSwapRouter();
        helper = new FlashloanRepay(address(adapter), address(flashPool));
        key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        vm.prank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, DEBT, alice);
    }

    function _sell(
        address tokenIn,
        uint256 rateBps,
        uint256 minOut
    ) internal view returns (Swap memory) {
        return Swap({
            tokenIn: tokenIn,
            target: address(router),
            data: abi.encodeCall(MockSwapRouter.swap, (tokenIn, address(usdc), 0, minOut, rateBps)),
            amountInOffset: AMOUNT_IN_OFFSET
        });
    }

    function _sellBoth(
        uint256 rateBps
    ) internal view returns (Swap[] memory s) {
        s = new Swap[](2);
        s[0] = _sell(address(token0), rateBps, 0);
        s[1] = _sell(address(token1), rateBps, 0);
    }

    function _params(
        uint256 amount,
        uint128 liquidity,
        Swap[] memory swaps
    ) internal pure returns (bytes memory) {
        return abi.encode(
            IFlashloanRepay.RepayParams({
                reserveId: DEBT_RESERVE,
                amount: amount,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                swaps: swaps
            })
        );
    }

    /// @dev Alice opens the allowance for `liquidity` and runs the repay.
    function _repayWithCollateral(
        uint256 amount,
        uint128 liquidity,
        Swap[] memory swaps
    ) internal {
        vm.prank(alice);
        adapter.allowWithdraw(address(helper), key, liquidity, _params(amount, liquidity, swaps));
    }

    function _debt() internal view returns (uint256) {
        return spoke.debt(adapter.accountOf(alice, FULL), DEBT_RESERVE);
    }

    function _health() internal view returns (uint256) {
        return spoke.getUserAccountData(adapter.accountOf(alice, FULL)).healthFactor;
    }

    function _assertHelperEmpty() internal view {
        assertEq(usdc.balanceOf(address(helper)), 0, "helper usdc");
        assertEq(token0.balanceOf(address(helper)), 0, "helper token0");
        assertEq(token1.balanceOf(address(helper)), 0, "helper token1");
        assertEq(usdc.allowance(address(helper), address(router)), 0, "router allowance");
        assertEq(usdc.allowance(address(helper), address(adapter)), 0, "adapter allowance");
    }
}
