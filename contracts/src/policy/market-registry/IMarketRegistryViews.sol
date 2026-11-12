// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Market} from "../../types/Market.sol";
import {SpokeDef} from "./types/SpokeDef.sol";
import {TokenDef} from "./types/TokenDef.sol";

/// @title IMarketRegistryViews
/// @notice Market, token and Spoke records of the MarketRegistry, the market lookups by pool, vault token, LPOracle,
/// Spoke reserve and Hub asset, and the implementation immutables.
/// @dev Every view is `view`, never reverts for a listed market and returns the values in force at the current block.
interface IMarketRegistryViews {
    /// @notice Returns a market definition.
    /// @param marketId Market identifier.
    /// @return market Stored definition.
    /// @custom:spec REQ-CONFIG-006, REQ-CONFIG-064
    function getMarket(
        uint256 marketId
    ) external view returns (Market memory market);

    /// @notice Returns a token definition.
    /// @param token Pool token.
    /// @return def Stored definition.
    /// @custom:spec REQ-CONFIG-064
    function getToken(
        address token
    ) external view returns (TokenDef memory def);

    /// @notice Returns a CDP Spoke record.
    /// @param spoke CDP Spoke.
    /// @return def Stored record.
    /// @custom:spec REQ-CONFIG-016, REQ-CONFIG-064
    function getSpoke(
        address spoke
    ) external view returns (SpokeDef memory def);

    /// @notice Every CDP Spoke ever approved, in approval order.
    /// @return spokes Spoke addresses.
    /// @custom:spec REQ-CONFIG-016, REQ-CONFIG-064, REQ-CONFIG-050
    function getSpokes() external view returns (address[] memory spokes);

    /// @notice Market identifiers listed on a CDP Spoke, in listing order.
    /// @param spoke The Spoke.
    /// @return marketIds The markets.
    /// @custom:spec Q-378
    function marketsOfSpoke(
        address spoke
    ) external view returns (uint256[] memory marketIds);

    /// @notice Market identifier of a market key.
    /// @dev `key = VaultTokenFactory.marketKeyOf(integrationId, pool, poolId, shape)`, that is
    /// `keccak256(abi.encode(chainId, integrationId, pool, poolId, kind, tickLower, tickUpper))`: one live market per
    /// (AMM integration, pool, exact shape) on the chain, so two ranges of one pool are two markets. A key held by a
    /// Cancelled or Closed market can be listed again.
    /// @param key The market key.
    /// @return marketId Market identifier, 0 if none.
    /// @custom:spec REQ-CONFIG-007, Q-376
    function marketOfKey(
        bytes32 key
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of a vault token.
    /// @param vaultToken Vault token.
    /// @return marketId Market identifier, 0 if none.
    /// @custom:spec REQ-CONFIG-007
    function marketOfVaultToken(
        address vaultToken
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of an LPOracle feed; the ParameterStore resolves `getOracleConfig` through it.
    /// @param lpOracle LPOracle feed proxy.
    /// @return marketId Market identifier, 0 if none.
    /// @custom:spec REQ-CONFIG-007, REQ-CONFIG-072
    function marketOfLpOracle(
        address lpOracle
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of a CDP Spoke reserve.
    /// @param spoke CDP Spoke.
    /// @param reserveId Reserve identifier.
    /// @return marketId Market identifier, 0 if none.
    /// @custom:spec REQ-CONFIG-007
    function marketOfReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of a Hub asset.
    /// @dev Keyed by Hub: Aave V4 numbers each Hub's assets from 0, so an asset identifier alone is ambiguous on a
    /// chain with several Hubs.
    /// @param hub The market's home Hub.
    /// @param hubAssetId Hub asset identifier.
    /// @return marketId Market identifier, 0 if none.
    /// @custom:spec REQ-CONFIG-007
    function marketOfHubAsset(
        address hub,
        uint256 hubAssetId
    ) external view returns (uint256 marketId);

    /// @notice Last assigned market identifier.
    /// @return count Number of markets ever registered.
    /// @custom:spec REQ-CONFIG-006
    function marketCount() external view returns (uint256 count);

    /// @notice The most markets the registry ever lists (implementation immutable): `listCollateralMarket` refuses a new
    /// identifier above it with `MarketCountLimit`; Closed and Cancelled markets keep their identifiers and count.
    /// @return limit The limit, sized on a fork so that the most expensive ParameterStore re-check over
    /// `1..limit` fits a block with headroom.
    /// @custom:spec REQ-MREG-034
    function MAX_MARKET_COUNT() external view returns (uint256 limit);

    /// @notice Immutable Collateralization contract (implementation immutable).
    /// @return collateralization Address.
    /// @custom:spec REQ-CONFIG-005, REQ-CONFIG-032
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice ProxyManager fixed proxy address (implementation immutable).
    /// @return proxyManager Address.
    /// @custom:spec REQ-CONFIG-005
    function PROXY_MANAGER() external view returns (address proxyManager);

    /// @notice ParameterStore fixed proxy address (implementation immutable).
    /// @return parameterStore Address.
    /// @custom:spec REQ-CONFIG-005, REQ-CONFIG-014
    function PARAMETER_STORE() external view returns (address parameterStore);

    /// @notice LPVaultSwap fixed proxy address (implementation immutable).
    /// @return lpVaultSwap Address.
    /// @custom:spec REQ-CONFIG-005, REQ-CONFIG-032, REQ-ROUTE-005
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Timelocked vault-token factory (implementation immutable).
    /// @return factory Address.
    /// @custom:spec REQ-CONFIG-005, REQ-CONFIG-032
    function VAULT_TOKEN_FACTORY() external view returns (address factory);

    /// @notice RiskModule fixed proxy address (implementation immutable).
    /// @return riskModule Address.
    /// @custom:spec REQ-CONFIG-044, REQ-CONFIG-046
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice Aave Adapter fixed proxy address (implementation immutable).
    /// @return adapter Address.
    /// @custom:spec REQ-CONFIG-005, REQ-CONFIG-032
    function AAVE_ADAPTER() external view returns (address adapter);

    /// @notice The Avana timelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    /// @return timelock Address.
    /// @custom:spec REQ-CONFIG-005, REQ-MREG-005, Q-259
    function TIMELOCK() external view returns (address timelock);

    /// @notice The Aave governance executor: protected from the freeze and the only caller of `cancelStandbySwitch`.
    /// @return executor Address.
    /// @custom:spec REQ-CONFIG-005, REQ-MREG-020, REQ-MREG-028
    function AAVE_GOVERNANCE_EXECUTOR() external view returns (address executor);

    /// @notice The chain's IFlashSource implementation, replaceable through the timelock (protected from the freeze).
    /// @return source The flash source LPVaultSwap uses.
    /// @custom:spec REQ-MREG-020, Q-379
    function flashSource() external view returns (address source);

    /// @notice Lock (protected from the freeze).
    /// @return lock Address.
    /// @custom:spec REQ-CONFIG-005, REQ-MREG-020
    function LOCK() external view returns (address lock);

    /// @notice The audited standard Aave V4 Spoke implementation whose code hash is approved from deployment
    /// (implementation immutable); further hashes are approved by `approveSpokeCodeHash`.
    /// @return implementation Address.
    /// @custom:spec REQ-CONFIG-005, REQ-CONFIG-074
    function STANDARD_SPOKE_IMPLEMENTATION() external view returns (address implementation);

    /// @notice PayoutEscrow, the payout escrow (protected from the freeze).
    /// @return escrow Address.
    /// @custom:spec REQ-CONFIG-005, REQ-MREG-020
    function PAYOUT_ESCROW() external view returns (address escrow);

    /// @notice The public flash liquidation helper (implementation immutable, protected from the freeze): freezing it
    /// would stop every liquidation funded through it, since LPVaultSwap sees the helper as the caller.
    /// @return helper Address.
    /// @custom:spec REQ-CONFIG-005, REQ-MREG-020, REQ-HELPER-010
    function FLASH_LIQUIDATOR() external view returns (address helper);
}
