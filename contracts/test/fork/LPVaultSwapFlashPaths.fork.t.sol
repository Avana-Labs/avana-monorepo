// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveV3FlashSource} from "../../src/flash/AaveV3FlashSource.sol";
import {IFlashReceiver} from "../../src/flash/IFlashReceiver.sol";
import {IFlashSource} from "../../src/flash/IFlashSource.sol";
import {IAaveV3Pool} from "../../src/interfaces/external/aave/IAaveV3Pool.sol";
import {FlashLiquidator} from "../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {MockFlashFeeCap} from "../utils/mocks/MockFlashReceiver.sol";
import {MockMarketRegistry} from "../utils/mocks/MockMarketRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IForkAddressesProvider {
    function getACLManager() external view returns (address);
    function getACLAdmin() external view returns (address);
    function getPoolConfigurator() external view returns (address);
}

interface IForkPool {
    function ADDRESSES_PROVIDER() external view returns (address);
}

interface IForkACLManager {
    function addFlashBorrower(
        address borrower
    ) external;
    function addEmergencyAdmin(
        address admin
    ) external;
}

interface IForkPoolConfigurator {
    function setReservePause(
        address asset,
        bool paused
    ) external;
}

/// @notice LPVaultSwap's side of the core flash source on a fork: the source's bound LPVaultSwap address, which takes
/// a loan the way `deleverage` does (one asset, the context hash checked by the source) and repays `F + φ` to the source
/// inside `onFlashLoan`, from what it received plus a balance the test deals it for the premium.
contract ForkFlashBorrower is IFlashReceiver {
    using SafeERC20 for IERC20;

    bytes32 internal constant MAGIC = keccak256("IFlashReceiver.onFlashLoan");

    IFlashSource public source;
    uint256 public received;
    uint256 public premiumSeen;

    function setSource(
        IFlashSource source_
    ) external {
        source = source_;
    }

    function borrow(
        address asset,
        uint256 amount,
        address spokeHub
    ) external returns (uint256 premium) {
        premium = source.flashLoan(asset, amount, spokeHub, abi.encode(asset, amount));
    }

    function onFlashLoan(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata
    ) external returns (bytes32) {
        require(msg.sender == address(source), "source only");
        received = IERC20(asset).balanceOf(address(this));
        premiumSeen = premium;
        IERC20(asset).safeTransfer(address(source), amount + premium);
        return MAGIC;
    }
}

/// @title LPVaultSwapFlashPathsForkTest
/// @notice TEST-118 on the Ethereum and Base forks: the core `IFlashSource` (`AaveV3FlashSource`) bound to each
/// chain's Aave V3 Pool, used only by `deleverage`, borrows the debt asset alone with interest-rate mode 0 and is
/// repaid in the same transaction (no debt opened); its pre-loan checks refuse an amount above the Pool's idle
/// liquidity and a premium above `maxFlashFeeBps`; a `FLASH_BORROWER` grant makes the premium 0; a paused Pool reserve
/// makes `maxFlashLoan` 0; the lender is not the Hub the caller names. The public helper on the same Pool quotes the
/// same liquidity and premium. LPVaultSwap's own pre-loan ordering (no collateral moves when a check fails) is
/// `LPVaultSwap.Deleverage.unit.t.sol`; the callback checks against a Pool are TEST-046 in the flash-source suites.
/// Skipped without `RPC_MAINNET` / `RPC_BASE`; forks the latest block.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract LPVaultSwapFlashPathsForkTest`.
contract LPVaultSwapFlashPathsForkTest is AvanaTest {
    address internal constant ETH_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant ETH_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETH_GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address internal constant BASE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant HUB = address(0x4B0B);

    ForkFlashBorrower internal borrower;
    AaveV3FlashSource internal source;
    MockFlashFeeCap internal cap;
    FlashLiquidator internal helper;

    function _fork(
        string memory rpcVar,
        address pool
    ) internal returns (bool) {
        string memory rpc = vm.envOr(rpcVar, string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        borrower = new ForkFlashBorrower();
        cap = new MockFlashFeeCap(10);
        source = new AaveV3FlashSource(pool, address(borrower), address(cap));
        borrower.setSource(source);
        helper = new FlashLiquidator(pool, makeAddr("lpVaultSwap"), address(new MockMarketRegistry()), address(cap));
        return true;
    }

    function _loanRepaidSameTx(
        address pool,
        address asset,
        uint256 amount
    ) internal {
        address aToken = IAaveV3Pool(pool).getReserveAToken(asset);
        uint256 available = source.maxFlashLoan(asset);
        assertGt(available, amount, "the Pool lends the asset");
        assertEq(helper.maxFlashLoan(asset), available, "the helper reads the same Pool liquidity");
        uint256 quote = source.flashPremium(asset, amount);
        assertEq(helper.flashPremium(asset, amount), quote, "same premium quote");
        deal(asset, address(borrower), quote);
        uint256 aBefore = IERC20(asset).balanceOf(aToken);
        uint256 premium = borrower.borrow(asset, amount, HUB);
        assertLe(premium, quote, "charged at most the quote");
        assertEq(borrower.received(), amount + quote, "the whole amount forwarded to LPVaultSwap");
        assertEq(IERC20(asset).balanceOf(aToken), aBefore + premium, "repaid in the same transaction, mode 0");
        assertEq(IERC20(asset).balanceOf(address(source)), 0, "source keeps nothing");
        assertEq(IERC20(asset).allowance(address(source), pool), 0, "no allowance left");
    }

    function _preLoanChecks(
        address pool,
        address asset,
        uint256 amount
    ) internal {
        uint256 available = source.maxFlashLoan(asset);
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.InsufficientFlashLiquidity.selector, available));
        borrower.borrow(asset, available + 1, HUB);
        vm.expectRevert(IFlashSource.FlashSourceIsHub.selector);
        borrower.borrow(asset, amount, pool);
        uint256 quote = source.flashPremium(asset, amount);
        if (quote != 0) {
            cap.setMaxFlashFeeBps(0);
            vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, quote, 0));
            borrower.borrow(asset, amount, HUB);
            cap.setMaxFlashFeeBps(10);
        }
    }

    function _grantsAndPause(
        address pool,
        address asset,
        uint256 amount
    ) internal {
        IForkAddressesProvider provider = IForkAddressesProvider(IForkPool(pool).ADDRESSES_PROVIDER());
        IForkACLManager acl = IForkACLManager(provider.getACLManager());
        vm.startPrank(provider.getACLAdmin());
        acl.addFlashBorrower(address(source));
        acl.addFlashBorrower(address(helper));
        acl.addEmergencyAdmin(address(this));
        vm.stopPrank();
        assertEq(source.flashPremium(asset, amount), 0, "FLASH_BORROWER: no premium on the core source");
        assertEq(helper.flashPremium(asset, amount), 0, "FLASH_BORROWER: no premium on the helper");
        assertEq(borrower.borrow(asset, amount, HUB), 0, "charged 0");
        IForkPoolConfigurator(provider.getPoolConfigurator()).setReservePause(asset, true);
        assertEq(source.maxFlashLoan(asset), 0, "a paused reserve lends nothing");
        assertEq(helper.maxFlashLoan(asset), 0, "the helper reads the pause too");
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.InsufficientFlashLiquidity.selector, 0));
        borrower.borrow(asset, amount, HUB);
    }

    /// @notice Ethereum: USDC and GHO from the Core Pool.
    // TEST-118 verifies: REQ-FLASH-001, REQ-FLASH-002, REQ-FLASH-005, REQ-FLASH-007, REQ-FLASH-010, REQ-HELPER-002, REQ-SWAP-106, Q-045, Q-063, Q-366
    function test_TEST_118_ethereumFlashPaths() public {
        if (!_fork("RPC_MAINNET", ETH_POOL)) return;
        _loanRepaidSameTx(ETH_POOL, ETH_USDC, 100_000e6);
        _loanRepaidSameTx(ETH_POOL, ETH_GHO, 100_000e18);
        _preLoanChecks(ETH_POOL, ETH_USDC, 100_000e6);
        _grantsAndPause(ETH_POOL, ETH_USDC, 100_000e6);
    }

    /// @notice Base: USDC from the Base Pool.
    // TEST-118 verifies: REQ-FLASH-001, REQ-FLASH-002, REQ-FLASH-005, REQ-FLASH-007, REQ-HELPER-002, Q-135, Q-362
    function test_TEST_118_baseFlashPaths() public {
        if (!_fork("RPC_BASE", BASE_POOL)) return;
        _loanRepaidSameTx(BASE_POOL, BASE_USDC, 100_000e6);
        _preLoanChecks(BASE_POOL, BASE_USDC, 100_000e6);
        _grantsAndPause(BASE_POOL, BASE_USDC, 100_000e6);
    }
}
