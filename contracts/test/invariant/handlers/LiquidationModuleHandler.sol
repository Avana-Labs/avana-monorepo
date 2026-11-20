// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../../src/vault/interfaces/ILPVault.sol";
import {ILiquidationModule} from "../../../src/liquidation/interfaces/ILiquidationModule.sol";
import {AaveAdapter} from "../../../src/adapter/AaveAdapter.sol";
import {LPVaultTestToken, MockPositionManager} from "../../utils/mocks/LPVaultMocks.sol";
import {LiquidationTestSpoke} from "../../utils/mocks/LiquidationTestMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Pledges Full range and Custom range positions for two wallets, borrows, moves the collateral factor and
/// liquidates, recording what every liquidation did for the partial-liquidation invariants.
contract LiquidationModuleHandler is Test {
    struct Env {
        AaveAdapter adapter;
        LiquidationTestSpoke spoke;
        ILiquidationModule module;
        ILPVault vault;
        MockPositionManager pm;
        LPVaultTestToken token0;
        LPVaultTestToken token1;
        bytes32 pool;
        address alice;
        address bob;
        address liquidator;
        address feeRecipient;
        uint256 debtReserve;
    }

    int24 internal constant FULL_LOWER = -887_270;
    int24 internal constant FULL_UPPER = 887_270;
    uint256 internal constant CF_BPS = 8000;

    Env internal env;

    uint256 public liquidations;
    /// @notice Liquidations that left the account less healthy without closing it out.
    uint256 public healthDrops;
    /// @notice Token units that left a position but reached neither the liquidator nor the fee recipient.
    uint256 public leaked;
    /// @notice Liquidations that removed more credit than units seized (beyond two units of rounding).
    uint256 public overTaken;
    /// @notice Liquidations whose fee exceeded Avana's share of the bonus.
    uint256 public feeOverShare;

    constructor(
        Env memory e
    ) {
        env = e;
    }

    function pledge(
        uint256 walletSeed,
        bool custom,
        uint128 liquidity,
        uint256 halfSeed
    ) external {
        address wallet = walletSeed % 2 == 0 ? env.alice : env.bob;
        liquidity = uint128(bound(liquidity, 1e18, 1e24));
        int24 half = int24(int256(bound(halfSeed, 1, 100))) * 10;
        (int24 lower, int24 upper) = custom ? (-half, half) : (FULL_LOWER, FULL_UPPER);
        bytes32 key = bytes32(env.pm.mint(wallet, env.pool, lower, upper, liquidity));
        if (env.vault.positionsOf(_accountOrZero(wallet, custom ? 2 : 1)).length >= 6) return;
        vm.prank(wallet);
        env.adapter.pledge(key);
    }

    function borrow(
        uint256 walletSeed,
        bool custom,
        uint256 bps
    ) external {
        address wallet = walletSeed % 2 == 0 ? env.alice : env.bob;
        uint256 marketId = custom ? 2 : 1;
        address account = env.adapter.accountOf(wallet, marketId);
        if (account == address(0)) return;
        (uint256 power, uint256 owed) = env.spoke.headroom(account);
        if (power <= owed) return;
        uint256 amount = (power - owed) * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        vm.prank(wallet);
        env.adapter.borrow(marketId, env.debtReserve, amount, wallet);
    }

    function shock(
        bool custom,
        uint256 cf
    ) external {
        env.spoke.setCf(custom ? 2 : 1, bound(cf, 3000, CF_BPS));
    }

    struct Before {
        uint256 hf;
        uint256 liquidity;
        uint256 credit;
        uint256 deficit;
        uint256 received;
    }

    function liquidate(
        uint256 walletSeed,
        bool custom,
        uint256 bps
    ) external {
        address wallet = walletSeed % 2 == 0 ? env.alice : env.bob;
        uint256 marketId = custom ? 2 : 1;
        address account = env.adapter.accountOf(wallet, marketId);
        if (account == address(0) || env.spoke.healthFactor(account) >= 1e18) return;
        uint256 toCover = env.spoke.debt(account, env.debtReserve) * bound(bps, 1, 10_000) / 10_000;
        if (toCover == 0) return;
        Before memory b = _before(account);
        vm.prank(env.liquidator);
        try env.module
            .liquidate(
                ILiquidationModule.LiquidationParams(marketId, env.debtReserve, account, toCover, 0, 0, env.liquidator)
            ) returns (
            ILiquidationModule.LiquidationResult memory r
        ) {
            _record(account, marketId, b, r);
        } catch {}
    }

    function _before(
        address account
    ) internal view returns (Before memory b) {
        b.hf = env.spoke.healthFactor(account);
        (b.liquidity, b.credit) = _totals(account);
        b.deficit = env.spoke.deficit(env.debtReserve);
        b.received = _received();
    }

    function _record(
        address account,
        uint256 marketId,
        Before memory b,
        ILiquidationModule.LiquidationResult memory r
    ) internal {
        ++liquidations;
        (uint256 liquidity, uint256 credit) = _totals(account);
        uint256 received = _received() - b.received;
        if (b.liquidity - liquidity != received) leaked += _diff(b.liquidity - liquidity, received);
        bool closedOut = env.spoke.deficit(env.debtReserve) != b.deficit;
        if (!closedOut && env.spoke.healthFactor(account) < b.hf) ++healthDrops;
        if (env.spoke.supplied(account, marketId) != 0 && b.credit - credit > r.seized + 2 * 6) ++overTaken;
        if (r.feeUnits * 10_000 > r.seized * 2000) ++feeOverShare;
    }

    /// @dev Token0 the liquidator and the fee recipient hold; the mock AMM pays one token0 per unit of liquidity.
    function _received() internal view returns (uint256) {
        return env.token0.balanceOf(env.liquidator) + env.token0.balanceOf(env.feeRecipient);
    }

    function _accountOrZero(
        address wallet,
        uint256 marketId
    ) internal view returns (address) {
        return env.adapter.accountOf(wallet, marketId);
    }

    function _totals(
        address account
    ) internal view returns (uint256 liquidity, uint256 credit) {
        bytes32[] memory keys = env.vault.positionsOf(account);
        for (uint256 i; i < keys.length; ++i) {
            ILPVault.Position memory p = env.vault.getPosition(keys[i]);
            liquidity += p.liquidity;
            credit += p.credit;
        }
    }

    function _diff(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
