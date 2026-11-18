// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Market} from "../../types/Market.sol";
import {SpokeDef} from "./types/SpokeDef.sol";
import {TokenDef} from "./types/TokenDef.sol";

/// @title IMarketRegistryViews
/// @notice Market, token and Spoke records of the MarketRegistry, market lookups and implementation immutables.
/// @dev Views never revert for a listed market.
interface IMarketRegistryViews {
    /// @notice Returns a market definition.
    function getMarket(
        uint256 marketId
    ) external view returns (Market memory market);

    /// @notice Returns a token definition.
    function getToken(
        address token
    ) external view returns (TokenDef memory def);

    /// @notice Returns a CDP Spoke record.
    function getSpoke(
        address spoke
    ) external view returns (SpokeDef memory def);

    /// @notice Every CDP Spoke ever approved, in approval order.
    function getSpokes() external view returns (address[] memory spokes);

    /// @notice Market identifiers listed on a CDP Spoke, in listing order.
    function marketsOfSpoke(
        address spoke
    ) external view returns (uint256[] memory marketIds);

    /// @notice Market identifier of a market key.
    /// @dev `key = VaultTokenFactory.marketKeyOf(...)`: one live market per (integration, pool, exact shape).
    function marketOfKey(
        bytes32 key
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of a vault token.
    function marketOfVaultToken(
        address vaultToken
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of an LPOracle feed; the ParameterStore resolves `getOracleConfig` through it.
    function marketOfLpOracle(
        address lpOracle
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of a CDP Spoke reserve.
    function marketOfReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of a Hub asset.
    /// @dev Keyed by Hub, since each Hub numbers its assets from 0.
    function marketOfHubAsset(
        address hub,
        uint256 hubAssetId
    ) external view returns (uint256 marketId);

    /// @notice Last assigned market identifier.
    function marketCount() external view returns (uint256 count);

    /// @notice The most markets the registry ever lists (implementation immutable).
    function MAX_MARKET_COUNT() external view returns (uint256 limit);

    /// @notice Immutable Collateralization contract (implementation immutable).
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice ProxyManager fixed proxy address (implementation immutable).
    function PROXY_MANAGER() external view returns (address proxyManager);

    /// @notice ParameterStore fixed proxy address (implementation immutable).
    function PARAMETER_STORE() external view returns (address parameterStore);

    /// @notice LPVaultSwap fixed proxy address (implementation immutable).
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Timelocked vault-token factory (implementation immutable).
    function VAULT_TOKEN_FACTORY() external view returns (address factory);

    /// @notice RiskModule fixed proxy address (implementation immutable).
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice Aave Adapter fixed proxy address (implementation immutable).
    function AAVE_ADAPTER() external view returns (address adapter);

    /// @notice The Avana timelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    function TIMELOCK() external view returns (address timelock);

    /// @notice The Aave governance executor: protected from the freeze and the only caller of `cancelStandbySwitch`.
    function AAVE_GOVERNANCE_EXECUTOR() external view returns (address executor);

    /// @notice The chain's IFlashSource implementation, replaceable through the timelock (protected from the freeze).
    function flashSource() external view returns (address source);

    /// @notice Lock (protected from the freeze).
    function LOCK() external view returns (address lock);

    /// @notice The standard Aave V4 Spoke implementation whose code hash is approved from deployment.
    function STANDARD_SPOKE_IMPLEMENTATION() external view returns (address implementation);

    /// @notice PayoutEscrow, the payout escrow (protected from the freeze).
    function PAYOUT_ESCROW() external view returns (address escrow);

    /// @notice The public flash liquidation helper (implementation immutable, protected from the freeze).
    function FLASH_LIQUIDATOR() external view returns (address helper);
}
