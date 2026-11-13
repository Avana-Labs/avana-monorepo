// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {LiquidationParams} from "../../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {RepayWithCollateralParams} from "../../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {CollPoolToken} from "../mocks/CollateralizationMocks.sol";
import {IntegLPOracleMock} from "../mocks/IntegOracleMocks.sol";
import {IntegrationFixture} from "./IntegrationFixture.sol";

/// @title IntegrationFlows
/// @notice Wallet-level flows on `IntegrationFixture`: every helper calls the real AaveAdapter or LPVaultSwap as the
/// wallet, payer or caller would, with funding and approvals made the way a wallet makes them, in any listed market
/// (each helper resolves the market's integration, LPVault, CDP Spoke and debt reserves).
abstract contract IntegrationFlows is IntegrationFixture {
    // ─── Accounts through the AaveAdapter ───

    function _newKey() internal returns (bytes32) {
        return keccak256(abi.encode("integration position", ++keyNonce));
    }

    function _ref(
        bytes32 key
    ) internal pure returns (PositionRef memory) {
        return PositionRef(INTEGRATION, key);
    }

    /// @notice The position reference of `key` in `marketId`'s AMM integration.
    function _refFor(
        uint256 marketId,
        bytes32 key
    ) internal view returns (PositionRef memory) {
        return PositionRef(markets[marketId].integrationId, key);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + DEADLINE_SLACK;
    }

    /// @notice Mints an LP position of `units` for `wallet` in `marketId` and pledges it through the Adapter.
    function _pledgeVia(
        address wallet,
        uint256 marketId,
        uint128 units
    ) internal returns (bytes32 key, address proxy) {
        key = _newKey();
        markets[marketId].vault.mintPosition(key, wallet, marketId, units);
        vm.prank(wallet);
        (proxy,,) = adapterC.pledge(marketId, _refFor(marketId, key), _deadline());
    }

    function _borrowVia(
        address wallet,
        uint256 marketId,
        uint256 reserveId,
        uint256 amount
    ) internal returns (uint256 drawn) {
        address proxy = adapterC.proxyOf(wallet, marketId);
        uint256 nonce = adapterC.borrowNonce(proxy);
        vm.prank(wallet);
        drawn = adapterC.borrow(marketId, reserveId, amount, wallet, _deadline(), 0, nonce);
    }

    /// @notice `payer` funds and approves `maxSpend` of the reserve's asset and repays `wallet`'s debt.
    function _repayVia(
        address payer,
        address wallet,
        uint256 marketId,
        uint256 reserveId,
        uint256 maxSpend,
        bool repayAll
    ) internal returns (uint256 spent) {
        CollPoolToken asset = _assetOf(marketId, reserveId);
        asset.mint(payer, maxSpend);
        vm.startPrank(payer);
        asset.approve(adapter, maxSpend);
        spent = adapterC.repay(wallet, marketId, reserveId, maxSpend, repayAll, _deadline());
        asset.approve(adapter, 0);
        vm.stopPrank();
    }

    function _withdrawVia(
        address wallet,
        uint256 marketId,
        bytes32 key,
        uint256 units
    ) internal {
        vm.prank(wallet);
        adapterC.withdraw(marketId, _refFor(marketId, key), units, _deadline(), 0);
    }

    function _rwcParams(
        uint256 marketId,
        bytes32 key,
        uint128 units,
        uint256 reserveId
    ) internal view returns (RepayWithCollateralParams memory p) {
        p = RepayWithCollateralParams({
            marketId: marketId,
            position: _refFor(marketId, key),
            units: units,
            debtReserveId: reserveId,
            minAmounts: new uint256[](2),
            minDebtRepaid: 0,
            deadline: _deadline(),
            minHealthFactor: 0
        });
    }

    /// @notice Opens `wallet`'s account in `marketId`: a position of `units` pledged at `pledgePrice8`, a USDC borrow
    /// of `borrowed`, then the market's price back to `P_VAULT`.
    function _openAccount(
        address wallet,
        uint256 marketId,
        uint128 units,
        uint256 borrowed,
        uint256 pledgePrice8
    ) internal returns (address proxy, bytes32 key) {
        _setPrice(marketId, pledgePrice8);
        (key, proxy) = _pledgeVia(wallet, marketId, units);
        if (borrowed != 0) _borrowVia(wallet, marketId, cdp[markets[marketId].integrationId].usdcReserveId, borrowed);
        _setPrice(marketId, P_VAULT);
    }

    /// @notice The standard unhealthy account of the 2.11 examples: 10,000 vault tokens pledged at $2.50 against
    /// 18,000 USDC, HF 0.933 at $2.10 (Aave's maximum bonus applies at HF <= 0.95).
    function _bobAccount() internal returns (address proxy, bytes32 key) {
        (proxy, key) = _openAccount(bob, MARKET_ID, 10_000e6, 18_000e6, 250_000_000);
    }

    // ─── Prices ───

    function _lpoOf(
        uint256 marketId
    ) internal view returns (IntegLPOracleMock) {
        return markets[marketId].oracle;
    }

    /// @notice Sets the market's served price (Aave's source and the LPOracle are one contract).
    function _setPrice(
        uint256 marketId,
        uint256 price8
    ) internal {
        _lpoOf(marketId).setAnswer(int256(price8));
    }

    /// @notice New feed rounds at the current block for every leg of every market and the USDC DebtOracle.
    function _refreshPrices() internal {
        for (uint256 i = 0; i < marketIds.length; ++i) {
            markets[marketIds[i]].oracle.refresh(uint64(block.timestamp));
        }
        usdcOracle.setLeg(uint64(block.timestamp));
    }

    // ─── Liquidation through LPVaultSwap ───

    function _liqParams(
        address proxy,
        uint256 marketId,
        uint256 reserveId,
        uint256 debtToCover
    ) internal view returns (LiquidationParams memory p) {
        p = LiquidationParams({
            proxy: proxy,
            marketId: marketId,
            debtReserveId: reserveId,
            debtToCover: debtToCover,
            routeMode: RouteMode.PrimaryThenBackup,
            minAmounts: new uint256[](0),
            deadline: block.timestamp + 120,
            minPayout: 0,
            maxShortfall: 0
        });
    }

    /// @notice Funds `caller` with `debtToCover + maxShortfall` of the debt asset, approves LPVaultSwap for exactly
    /// that and calls `liquidate` as `caller`.
    function _liquidateAs(
        address caller,
        LiquidationParams memory p
    ) internal returns (LiquidationResult memory r) {
        _fundCaller(caller, p);
        vm.prank(caller);
        r = lvs.liquidate(p);
    }

    /// @notice Mints `debtToCover + maxShortfall` of the debt asset to `caller` and approves LPVaultSwap for exactly
    /// that, so the next call can be the caller's `liquidate`.
    function _fundCaller(
        address caller,
        LiquidationParams memory p
    ) internal {
        CollPoolToken asset = _assetOf(p.marketId, p.debtReserveId);
        asset.mint(caller, p.debtToCover + p.maxShortfall);
        vm.prank(caller);
        asset.approve(lpVaultSwap, p.debtToCover + p.maxShortfall);
    }

    // ─── Reads ───

    /// @notice The debt asset of `reserveId` on the Uniswap v3 CDP Spoke.
    function _asset(
        uint256 reserveId
    ) internal view returns (CollPoolToken) {
        return _assetOf(MARKET_ID, reserveId);
    }

    /// @notice The debt asset of `reserveId` on `marketId`'s CDP Spoke.
    function _assetOf(
        uint256 marketId,
        uint256 reserveId
    ) internal view returns (CollPoolToken) {
        return CollPoolToken(reg.getDebtReserve(markets[marketId].spoke, reserveId).asset);
    }

    function _vtReserve(
        uint256 marketId
    ) internal view returns (uint256) {
        return markets[marketId].reserveId;
    }

    function _vtAddr(
        uint256 marketId
    ) internal view returns (address) {
        return markets[marketId].vaultToken;
    }

    /// @notice The CDP Spoke of `proxy`'s account (the Uniswap v3 one before the account exists).
    function _spokeOf(
        address proxy
    ) internal view returns (address spoke) {
        (spoke,,,) = adapterC.accountOf(proxy);
        if (spoke == address(0)) spoke = aave.cdpSpoke;
    }

    function _hf(
        address proxy
    ) internal view returns (uint256) {
        return IAaveV4Spoke(_spokeOf(proxy)).getUserAccountData(proxy).healthFactor;
    }

    function _debtOf(
        address proxy,
        uint256 reserveId
    ) internal view returns (uint256) {
        return IAaveV4Spoke(_spokeOf(proxy)).getUserTotalDebt(reserveId, proxy);
    }

    function _suppliedOf(
        address proxy,
        uint256 marketId
    ) internal view returns (uint256) {
        return IAaveV4Spoke(markets[marketId].spoke).getUserSuppliedShares(_vtReserve(marketId), proxy);
    }
}
