# VaultTokenFactory lifecycle

The VaultTokenFactory is the immutable registry of AMM integrations and the deployer of one VaultToken per (CDP Spoke, market key), at an address fixed by the factory, the Spoke and the market key; it holds no power over the tokens or LPVaults it records and calls no integration when it deploys.

## Walkthrough

Setup (Base: the Aerodrome Slipstream LPVault as integration 2 and market 3 on the "Aerodrome Slipstream Stable" Spoke `S`).

1. **Governance prepares the listing payload with [`marketKeyOf`](VaultTokenFactory.sol#L174) and [`predictAddress`](VaultTokenFactory.sol#L219)`(S, marketKey)`**, which depends only on the factory, `S` and the market key, so the Aave listing AIP can name the vault-token reserve before the token exists. The address commits to no other binding; the manifest reads the token's immutables after the batch executes.
2. **AvanaTimelock → [`registerIntegration`](VaultTokenFactory.sol#L117)`(2, slipstreamLPVault)`** (normal delay): checks the ID is new and non-zero, the LPVault is new and not a factory binding, Collateralization names this factory, its Adapter and its LPVaultSwap, and the LPVault's `INTEGRATION_ID() == 2`, `COLLATERALIZATION()`, `LOCK()`, `TIMELOCK()` and `MARKET_REGISTRY()` match the chain's core with a non-zero `AMM_PROTOCOL()`, each read by a bounded `STATICCALL` with 30,000 gas that must answer exactly one word (a 1 MB answer fails within that gas); records the LPVault and its `capabilities()` pool keying (`Address`) and shape kind (`TickRange`) for life ([`integrationKindOf`](VaultTokenFactory.sol#L210)). Event: [`IntegrationRegistered`](IVaultTokenFactory.sol#L36) with `ammProtocol = keccak256("AERODROME_SLIPSTREAM")`, `Address`, `TickRange`. Errors: [`NotTimelock`](IVaultTokenFactory.sol#L67), [`InvalidIntegration`](IVaultTokenFactory.sol#L75).
3. **AvanaTimelock, in the `listCollateralMarket` batch, → [`deployVaultToken`](VaultTokenFactory.sol#L145)** for market 3 with 6 decimals, symbol `avLP-3` and the name "Avana LP Base Aerodrome Slipstream USDC/USDT spacing 1 range (-10 to 10) market 3": the listing checks, the pool address keying and a `TickRange` with `tickLower < tickUpper` included ([`_checkListing`](VaultTokenFactory.sol#L261)), the token's binding checks before CREATE3 ([`_checkDistinct`](VaultTokenFactory.sol#L461), the token's `InvalidBinding`), then [`_deployToken`](VaultTokenFactory.sol#L301) writes `tokenOf[S][marketKey]` and `isVaultToken` and deploys at the address of step 1. The MarketRegistry, in the same batch, calls the LPVault's `bindMarket` and checks the token's immutables against the market and `hubOf(S)`. Event: [`VaultTokenDeployed`](IVaultTokenFactory.sol#L55). Errors: [`UnknownIntegration`](IVaultTokenFactory.sol#L79), [`ZeroAddress`](IVaultTokenFactory.sol#L92), [`InvalidShape`](IVaultTokenFactory.sol#L97), [`DecimalsOutOfRange`](IVaultTokenFactory.sol#L87), [`InvalidMarketId`](IVaultTokenFactory.sol#L101), [`TokenExistsForMarket`](IVaultTokenFactory.sol#L83), [`InvalidTokenMetadata`](IVaultTokenFactory.sol#L105).
4. **Collateralization → [`isVaultToken`](VaultTokenFactory.sol#L194) and [`lpVaultOf`](VaultTokenFactory.sol#L202)** on every pledge: the token must be registered here and its `integration()` must equal the LPVault registered for its `integrationId()`, else `InvalidVaultToken`.
5. **Readers → [`tokenOf`](VaultTokenFactory.sol#L185) / [`marketKeyOf`](VaultTokenFactory.sol#L174)** map a market key to its token on a Spoke; a second token for the same pair reverts `TokenExistsForMarket`, while the same market on a successor Spoke gets a new token.

## What the UI reads and calls

- Lens: market and account views carry the vault token address; direct [`tokenOf`](VaultTokenFactory.sol#L185), [`isVaultToken`](VaultTokenFactory.sol#L194), [`predictAddress`](VaultTokenFactory.sol#L219).
- Events to index: [`IntegrationRegistered`](IVaultTokenFactory.sol#L36), [`VaultTokenDeployed`](IVaultTokenFactory.sol#L55).
- User calls: none.

## Spec

- [2.4 Vault Tokens](../../../../spec/02-contracts/04-vault-tokens.md): `REQ-VTOKEN-019`–`REQ-VTOKEN-024`, `REQ-VTOKEN-035`–`REQ-VTOKEN-038`, `REQ-VTOKEN-044`–`REQ-VTOKEN-046`, `REQ-VTOKEN-049`, `REQ-VTOKEN-050`, `REQ-AMM-CORE-001`, `SPEC-UNIT-001`.
- Flow: [3.8 Market lifecycle](../../../../spec/03-operations/08-market-lifecycle.md) `MKT-007`.
