// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IGhoFlashMinter} from "../../src/interfaces/external/gho/IGhoFlashMinter.sol";
import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {FlashLiquidator} from "../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {Market} from "../../src/types/Market.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {MockFlashFeeCap} from "../utils/mocks/MockFlashReceiver.sol";
import {MockMarketRegistry} from "../utils/mocks/MockMarketRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice LPVaultSwap's caller-facing settlement on a fork, for any debt asset: pulls `X`, sends `D` to a sink (the
/// Spoke's pull) and pays `keeperOut = X - D + gain` from a balance the test deals it.
contract ForkLiquidationSwap is ILPVaultSwapLiquidation {
    using SafeERC20 for IERC20;

    address public constant SINK = address(0x5B0CE);
    IERC20 public asset;
    uint256 public debtRepaid;
    uint256 public gain;

    function setOutcome(
        IERC20 asset_,
        uint256 debtRepaid_,
        uint256 gain_
    ) external {
        (asset, debtRepaid, gain) = (asset_, debtRepaid_, gain_);
    }

    function liquidate(
        LiquidationParams calldata params
    ) external override returns (LiquidationResult memory result) {
        asset.safeTransferFrom(msg.sender, address(this), params.debtToCover);
        asset.safeTransfer(SINK, debtRepaid);
        uint256 keeperOut = params.debtToCover + gain;
        asset.safeTransfer(msg.sender, keeperOut);
        result.debtAsset = address(asset);
        result.debtRepaid = debtRepaid;
        result.keeperOut = keeperOut;
    }

    function settlePending(
        uint256,
        uint256
    ) external pure override returns (uint256, uint256[] memory, uint256) {
        revert("not modelled");
    }
}

/// @title FlashLiquidatorGhoForkTest
/// @notice TEST-292 on an Ethereum fork: the public helper bound to the Ethereum Core Pool and the deployed GHO flash
/// minter. GHO is lent by the minter (its live `maxFlashLoan` and `flashFee`, the ERC-3156 callback, the pull of
/// `F + fee` and the burn), USDC by the Pool. LPVaultSwap, the MarketRegistry and the ParameterStore are stand-ins.
/// Skipped without `RPC_MAINNET`; forks the latest block.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract FlashLiquidatorGhoForkTest`.
contract FlashLiquidatorGhoForkTest is AvanaTest {
    address internal constant POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant GHO_FLASH_MINTER = 0xb639D208Bcf0589D54FaC24E655C79EC529762B8;
    address internal constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant SPOKE = address(0x5B);
    uint256 internal constant MARKET_ID = 7;
    uint256 internal constant USDC_RESERVE = 3;
    uint256 internal constant GHO_RESERVE = 4;

    FlashLiquidator internal helper;
    ForkLiquidationSwap internal swap;
    MockMarketRegistry internal registry;
    address internal keeperAddr = makeAddr("forkKeeper");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        swap = new ForkLiquidationSwap();
        registry = new MockMarketRegistry();
        Market memory m;
        m.spoke = SPOKE;
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (USDC, GHO);
        registry.setMarket(MARKET_ID, m);
        DebtReserveDef memory d;
        d.reserveId = USDC_RESERVE;
        d.asset = USDC;
        d.approved = true;
        registry.setDebtReserve(SPOKE, d);
        d.reserveId = GHO_RESERVE;
        d.asset = GHO;
        registry.setDebtReserve(SPOKE, d);
        // Cap at the ParameterStore's upper bound, so the live fees are measured rather than refused.
        MockFlashFeeCap cap = new MockFlashFeeCap(100);
        helper = new FlashLiquidator(POOL, address(swap), address(registry), address(cap), GHO_FLASH_MINTER);
    }

    function _request(
        uint256 reserveId,
        uint256 amount
    ) internal view returns (FlashLiquidationRequest memory r) {
        r.params.proxy = address(0xB0B);
        r.params.marketId = MARKET_ID;
        r.params.debtReserveId = reserveId;
        r.params.debtToCover = amount;
        r.params.routeMode = RouteMode.PrimaryThenBackup;
        r.params.deadline = block.timestamp + 60;
        r.flashAmount = amount;
        r.maxPremium = type(uint256).max;
    }

    /// @notice The deployed minter lends GHO to the helper: quotes equal the minter's own for the helper, the loan is
    /// minted and burned (GHO supply unchanged), the minter keeps exactly the fee, and the helper ends empty.
    // TEST-292 verifies: REQ-HELPER-015, REQ-HELPER-009, REQ-HELPER-005, REQ-FLASH-010
    function test_TEST_292_forkGhoLiquidationThroughFlashMinter() public {
        assertEq(IGhoFlashMinter(GHO_FLASH_MINTER).GHO_TOKEN(), GHO, "minter mints Ethereum GHO");
        uint256 available = helper.maxFlashLoan(GHO);
        assertEq(available, IGhoFlashMinter(GHO_FLASH_MINTER).maxFlashLoan(GHO));
        assertGt(available, 1000e18, "the minter's bucket has room");
        uint256 f = 1000e18;
        vm.prank(address(helper));
        uint256 fee = IGhoFlashMinter(GHO_FLASH_MINTER).flashFee(GHO, f);
        assertEq(helper.flashPremium(GHO, f), fee, "the fee the helper is charged, read live");

        swap.setOutcome(IERC20(GHO), f, 10e18);
        deal(GHO, address(swap), 10e18);
        uint256 supplyBefore = IERC20(GHO).totalSupply();
        uint256 minterBefore = IERC20(GHO).balanceOf(GHO_FLASH_MINTER);
        vm.prank(keeperAddr);
        uint256 payout = helper.flashLiquidate(_request(GHO_RESERVE, f));
        assertEq(payout, 10e18 - fee);
        assertEq(IERC20(GHO).balanceOf(keeperAddr), payout);
        assertEq(IERC20(GHO).totalSupply(), supplyBefore, "minted and burned");
        assertEq(IERC20(GHO).balanceOf(GHO_FLASH_MINTER), minterBefore + fee, "the minter keeps the fee");
        assertEq(IERC20(GHO).balanceOf(address(helper)), 0);
        assertEq(IERC20(GHO).allowance(address(helper), GHO_FLASH_MINTER), 0);
    }

    /// @notice USDC keeps the Core Pool: its quote is the Pool's, and a loan through the helper settles.
    // TEST-292 verifies: REQ-HELPER-015, REQ-HELPER-009
    function test_TEST_292_forkUsdcStaysOnThePool() public {
        uint256 f = 1000e6;
        assertGt(helper.maxFlashLoan(USDC), f);
        uint256 premium = helper.flashPremium(USDC, f);
        swap.setOutcome(IERC20(USDC), f, 10e6);
        deal(USDC, address(swap), 10e6);
        vm.prank(keeperAddr);
        uint256 payout = helper.flashLiquidate(_request(USDC_RESERVE, f));
        assertLe(10e6 - payout, premium, "charged at most the quote");
        assertEq(IERC20(USDC).balanceOf(address(helper)), 0);
        assertEq(IERC20(USDC).allowance(address(helper), POOL), 0);
    }
}
