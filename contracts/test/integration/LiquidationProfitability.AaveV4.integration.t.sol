// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/dependencies/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/dependencies/aave/IAaveV4Spoke.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {AaveV4MarketTestBase} from "../utils/AaveV4MarketTestBase.sol";
import {ClPriceMath} from "../utils/libraries/ClPriceMath.sol";
import {
    HubSpokeConfig,
    IHubConfiguratorCalls,
    ISpokeConfiguratorCalls,
    SpokeDynamicReserveConfig,
    SpokeLiquidationConfig,
    SpokeReserveConfig
} from "./VaultToken.AaveV4.integration.t.sol";

/// @title LiquidationProfitabilityAaveV4Base
/// @notice Whether a liquidation stays profitable at the bonus Avana copies from Aave (#359: the market's maximum bonus
/// is the higher of its two tokens' on the price Spoke; the Spoke's bonus factor, health factor for the maximum bonus
/// and target come from the price Spoke), after gas and after selling the unwound volatile leg into the pool at a real
/// pool's depth, and the break-even position size.
/// @dev Runs end to end on the pinned real Aave V4 Hub and CDP Spoke with the real LiquidationModule, LPOracle and
/// Uniswap v3 LPVault, the real v3 pool and NonfungiblePositionManager. The debt asset is the pool's token1 (USDC in the
/// WETH/USDC case), so the liquidator repays in token1, receives both tokens, and sells the token0 leg back into the
/// same pool. Liquidation settings are the test-network price Spoke's (`AaveV4PriceSpokeStandIn`): bonuses USDC and USDT
/// 104.5 %, WETH 105 %; target 1.05, maximum bonus from 0.95, factor 100 %. Depth: the repo has no fork test of a
/// listed pool (the fork pins are 0), so the pool carries the in-range liquidity of the Base WETH/USDC 0.05 % pool read
/// for the periphery design record (1.07e19 at ETH $1,776, Base block 59,598,223), restated for two 18-decimal $1 tokens
/// (4.509e26, the same virtual reserves of about $451M a side) as full-range liquidity. That is the pool's depth at its
/// price; a real concentrated pool is shallower far from it, which only the largest sell here reaches.
///
/// The account: a full-range position of value V borrows 79.2 % of V (health factor 1.01), token0 falls 5 % (the pool
/// is arbitraged to the oracle price), the health factor is 0.985, and the liquidator over-covers so Aave sizes the
/// repayment to its target. Gas is measured on the liquidation and on the sell with every touched contract cooled, plus
/// 21,000 for the transaction, and priced at ETH $1,776.
abstract contract LiquidationProfitabilityAaveV4Base is AaveV4MarketTestBase {
    /// @dev Base WETH/USDC 0.05 % in-range liquidity restated for two 18-decimal $1 tokens.
    uint128 internal constant DEPTH = 4.509e26;
    uint256 internal constant ETH_USD = 1776;
    uint256 internal constant L1_GAS_PRICE = 10 gwei;
    uint256 internal constant BASE_GAS_PRICE = 0.01 gwei;

    /// @dev One measured liquidation.
    struct Run {
        uint256 value;
        uint256 repaid;
        uint256 proceeds;
        int256 netBeforeGas;
        uint256 gas;
        bool full;
    }

    function setUp() public override {
        super.setUp();
        int24 s = pool.tickSpacing();
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 top = (ClPriceMath.MAX_TICK / s) * s;
        actor.mint(pool, -top, top, DEPTH);
        // A deeper credit line than the base's, for the largest account.
        debt.mint(daoTreasury, 5e24);
        vm.startPrank(daoTreasury);
        debt.approve(aave.lendSpoke, 5e24);
        IAaveV4Spoke(aave.lendSpoke).supply(priceReserve1, 5e24, daoTreasury);
        vm.stopPrank();
        debt.mint(liquidator, 5e24);
    }

    /// @notice Bug hunted: the copied bonus does not pay for a liquidation once gas and the sell into the pool are
    /// counted, so accounts go unliquidated and become deficits. At every size from $1,000 to $1,000,000 the
    /// liquidation nets a positive amount before gas, the net per dollar of position does not collapse with size (the
    /// sell's slippage at this depth is small), it pays for Base gas at every size, and it pays for Ethereum gas above
    /// the break-even of its regime. Aave's dust rule splits the sizes in two: below about $1,830 the whole debt is
    /// repaid (more bonus per dollar of position), above it Aave stops at the target; the break-even of each regime is
    /// reported for Ethereum at 10 gwei and Base at 0.01 gwei.
    function test_liquidationIsProfitable_afterGasAndSlippage() public {
        uint256[6] memory sizes = [uint256(500e18), 1000e18, 1500e18, 5000e18, 50_000e18, 500_000e18];
        Run[6] memory runs;
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            runs[i] = _run(sizes[i]);
            vm.revertToState(snap);
        }
        uint256 fullL1 = _breakEven(runs[0], L1_GAS_PRICE);
        uint256 partialL1 = _breakEven(runs[5], L1_GAS_PRICE);
        for (uint256 i; i < sizes.length; ++i) {
            Run memory r = runs[i];
            assertGt(r.netBeforeGas, 0, "positive before gas");
            uint256 bps = uint256(r.netBeforeGas) * 10_000 / r.value;
            assertGe(bps, _minNetBps(), "the bonus net of Avana's share and the sell");
            assertGt(uint256(r.netBeforeGas), r.gas * BASE_GAS_PRICE * ETH_USD, "pays for Base gas");
            bool l1Profitable = uint256(r.netBeforeGas) > r.gas * L1_GAS_PRICE * ETH_USD;
            assertEq(
                l1Profitable, r.value >= (r.full ? fullL1 : partialL1), "Ethereum gas: profitable above break-even"
            );
            emit log_named_uint("position value ($)", r.value / 1e18);
            emit log_named_string("  regime", r.full ? "whole debt (dust rule)" : "to the target");
            emit log_named_uint("  repaid ($)", r.repaid / 1e18);
            emit log_named_decimal_int("  net before gas ($)", r.netBeforeGas, 18);
            emit log_named_uint("  net before gas (bps of position)", bps);
            emit log_named_uint("  gas (liquidate + sell + tx)", r.gas);
        }
        emit log_named_decimal_uint("break-even, whole-debt regime, Ethereum 10 gwei ($)", fullL1, 18);
        emit log_named_decimal_uint("break-even, to-target regime, Ethereum 10 gwei ($)", partialL1, 18);
        emit log_named_decimal_uint(
            "break-even, to-target regime, Base 0.01 gwei ($)", _breakEven(runs[5], BASE_GAS_PRICE), 18
        );
        assertLt(partialL1, 5000e18, "Ethereum: pays above a few thousand dollars");
        assertLt(_breakEven(runs[5], BASE_GAS_PRICE), 10e18, "Base: pays at any listed size");
    }

    /// @notice The gas of a cold partial unwind on the real v3 NonfungiblePositionManager, the AMM-specific part of a
    /// liquidation's gas. `LPVault.UniswapV4.integration.t.sol` measures the same unwind on v4; the difference moves
    /// the break-even linearly. Bug hunted: an unwind so costly that a liquidation through it cannot pay its gas.
    function test_unwindGas_coldPartial() public {
        (bytes32 key,) = _mintFull(carol, 5000e18);
        (, uint128 credit) = _pledge(carol, key);
        vm.cool(address(vault));
        vm.cool(address(nfpm));
        vm.cool(address(pool));
        vm.cool(address(t0));
        vm.cool(address(t1));
        vm.cool(liquidator);
        uint256 g = gasleft();
        vm.prank(address(module));
        vault.unwind(key, credit / 3, 0, 0, liquidator);
        uint256 used = g - gasleft();
        emit log_named_uint("gas: cold partial unwind, Uniswap v3", used);
        assertLt(used, 400_000);
    }

    // ─── Scenario ───

    /// @dev The least net, in bps of the position value, the scenario must clear before gas.
    function _minNetBps() internal pure virtual returns (uint256);

    function _liquidationConfig() internal pure override returns (SpokeLiquidationConfig memory) {
        return SpokeLiquidationConfig(1.05e18, 0.95e18, 10_000);
    }

    /// @dev The debt asset is token1: its Hub asset (listed for the Lend Spoke as a price reserve) also gets the CDP
    /// Spoke, and token1 becomes a borrowable CDP reserve priced by its feed.
    function _listDebt(
        bytes memory
    ) internal override returns (uint256 lendDebtReserve) {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint256 assetId = hubView.getAssetId(address(t1));
        HubSpokeConfig memory config =
            HubSpokeConfig(0, hubView.MAX_ALLOWED_SPOKE_CAP(), hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false);
        IHubConfiguratorCalls(aave.hubConfigurator).addSpoke(aave.hub, aave.cdpSpoke, assetId, config);
        debtReserveId = ISpokeConfiguratorCalls(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                assetId,
                address(feed1),
                SpokeReserveConfig(0, false, false, true, false),
                SpokeDynamicReserveConfig(0, 10_000, 0)
            );
        debt = t1;
        lendDebtReserve = priceReserve1;
    }

    // ─── Helpers ───

    /// @dev Opens an account of value `2 · each`, drops token0 5 %, liquidates to the target, sells the token0 leg.
    function _run(
        uint256 each
    ) internal returns (Run memory r) {
        r.value = 2 * each;
        (bytes32 key,) = _mintFull(carol, each);
        _pledge(carol, key);
        _borrow(carol, r.value * 792 / 1000);
        feed0.set(0.95e8);
        _swapTo(pool, ClPriceMath.oracleSqrtPrice(0.95e8, 1e8, 18, 18));
        address account = adapter.accountOf(carol, MARKET);
        assertLt(spoke.getUserAccountData(account).healthFactor, 1e18);
        assertEq(spoke.getLiquidationBonus(vtReserveId, account, 0.99e18), _vtMaxBonus(), "flat copied bonus");

        _cool(account);
        uint256 g = gasleft();
        vm.prank(liquidator);
        ILiquidationModule.LiquidationResult memory res = module.liquidate(_params(account, r.value));
        r.gas = g - gasleft();
        r.repaid = res.debtRepaid;
        r.full = spoke.getUserTotalDebt(debtReserveId, account) == 0;

        vm.cool(address(pool));
        vm.cool(address(t0));
        vm.cool(address(t1));
        g = gasleft();
        (, int256 d1) = actor.swap(pool, true, int256(res.amount0), 4_295_128_740);
        r.gas += g - gasleft() + 21_000;
        r.proceeds = res.amount1 + uint256(-d1);
        r.netBeforeGas = int256(r.proceeds) - int256(r.repaid);
    }

    /// @dev The position value at which the net per dollar of `r` pays `r.gas` at `gasPrice`, 18-decimal USD.
    function _breakEven(
        Run memory r,
        uint256 gasPrice
    ) internal pure returns (uint256) {
        uint256 gasUsd = r.gas * gasPrice * ETH_USD;
        return gasUsd * r.value / uint256(r.netBeforeGas);
    }

    /// @dev Every contract a liquidation touches, cold, as in a fresh transaction.
    function _cool(
        address account
    ) internal {
        address[22] memory touched = [
            address(module),
            address(rm),
            address(vault),
            address(nfpm),
            address(pool),
            address(factory),
            address(vt),
            address(oracle),
            address(t0),
            address(t1),
            address(feed0),
            address(feed1),
            aave.hub,
            aave.hubImplementation,
            aave.cdpSpoke,
            aave.cdpSpokeImplementation,
            aave.cdpOracle,
            aave.lendSpoke,
            aave.lendSpokeImplementation,
            aave.lendOracle,
            aave.liquidationLogic,
            account
        ];
        for (uint256 i; i < touched.length; ++i) {
            vm.cool(touched[i]);
        }
        vm.cool(liquidator);
        vm.cool(feeRecipient);
        vm.cool(aave.irStrategy);
    }
}

/// @title LiquidationProfitabilityWethUsdcTest
/// @notice WETH/USDC at 0.05 %: bonus 105 % (WETH's, the higher of the two).
contract LiquidationProfitabilityWethUsdcTest is LiquidationProfitabilityAaveV4Base {
    function _poolFee() internal pure override returns (uint24) {
        return 500;
    }

    function _vtMaxBonus() internal pure override returns (uint32) {
        return 10_500;
    }

    function _minNetBps() internal pure override returns (uint256) {
        return 90;
    }
}

/// @title LiquidationProfitabilityStableTest
/// @notice A stable pair (USDC/USDT) at 0.01 %: bonus 104.5 %, the lowest the stand-in copies.
contract LiquidationProfitabilityStableTest is LiquidationProfitabilityAaveV4Base {
    function _poolFee() internal pure override returns (uint24) {
        return 100;
    }

    function _vtMaxBonus() internal pure override returns (uint32) {
        return 10_450;
    }

    function _minNetBps() internal pure override returns (uint256) {
        return 80;
    }
}
