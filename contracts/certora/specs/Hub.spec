/*
 * Avana Stable LP Hub: Aave V4 Hub at a3ef63e (dependencies/aave-v4-a3ef63e/src/hub/instances/HubInstance.sol).
 *
 * The vault-token Hub asset keeps added assets equal to added shares (PROP-040) under the Avana listing configuration
 * of 2.1 (`drawCap == 0` on every Spoke, liquidity fee 0, no reinvestment controller), and with shares == assets a
 * share preview is the identity (PROP-011, primary tool per 5.2: Halmos). These run on the real Hub code; Aave has
 * published no Certora specs for the Hub at this commit, so none are reused.
 *
 * Storage: `HubStorage` (`_assets[assetId]` with `IHub.Asset` fields, `_spokes[assetId][spoke]` with `IHub.SpokeData`
 * fields) as declared at a3ef63e; plain storage below the AccessManaged namespace.
 *
 * Summaries: ERC-20 underlying transfers by the ERC-20 model. The interest-rate strategy and the Aave DAO's
 * AccessManager (`canCall`) are outside `contracts/src` and stay unresolved view calls, so the rules hold for every
 * rate (no draws, so the rate never affects the asset) and every role decision. `previewRemoveByShares` belongs to
 * Aave's `IHubBase`, not to the Avana-side `IAaveV4Hub`, so it is called without a methods entry. Configuration selectors (`addAsset`,
 * `updateAssetConfig`, `addSpoke`, `updateSpokeConfig`, `setInterestRateData`, `initialize`) are filtered: the rule
 * assumes the listing configuration, which those selectors set.
 */

import "setup/Erc20Model.spec";

methods {
    function getAddedAssets(uint256) external returns (uint256);
    function getAddedShares(uint256) external returns (uint256) envfree;

    function _.balanceOf(address a) external => erc20BalanceOf(calledContract, a) expect uint256;
    function _.transfer(address to, uint256 a) external with (env e) => erc20Transfer(calledContract, e.msg.sender, to, a) expect bool;
    function _.transferFrom(address from, address to, uint256 a) external with (env e) => erc20TransferFrom(calledContract, e.msg.sender, from, to, a) expect bool;
}

definition isHubConfiguration(method f) returns bool =
    f.selector == sig:addAsset(address, uint8, address, address, bytes).selector
    || f.selector == sig:updateAssetConfig(uint256, IHub.AssetConfig, bytes).selector
    || f.selector == sig:addSpoke(uint256, address, IHub.SpokeConfig).selector
    || f.selector == sig:updateSpokeConfig(uint256, address, IHub.SpokeConfig).selector
    || f.selector == sig:setInterestRateData(uint256, bytes).selector
    || f.selector == sig:initialize(address).selector;

// PROP-040 verifies: Q-068, Q-181, Q-189
rule vaultTokenAssetKeepsSharesEqualAssets(method f, uint256 assetId) filtered { f -> !f.isView && !isHubConfiguration(f) } {
    env e;
    calldataarg args;
    require e.msg.sender != 0;
    require currentContract._assets[assetId].liquidityFee == 0;
    require currentContract._assets[assetId].reinvestmentController == 0;
    require currentContract._assets[assetId].drawnShares == 0;
    require currentContract._assets[assetId].premiumShares == 0;
    require currentContract._assets[assetId].premiumOffsetRay == 0;
    require currentContract._assets[assetId].deficitRay == 0;
    require currentContract._assets[assetId].realizedFees == 0;
    require currentContract._assets[assetId].swept == 0;
    require currentContract._spokes[assetId][e.msg.sender].drawCap == 0;
    require getAddedAssets(e, assetId) == getAddedShares(assetId);

    f(e, args);

    assert getAddedAssets(e, assetId) == getAddedShares(assetId), "a Hub function made vault-token shares differ from assets";
}

// PROP-011 verifies: INV-014, Q-160, Q-165, Q-189 (primary tool per 5.2: Halmos)
rule previewRemoveBySharesIsIdentity(uint256 assetId, uint256 shares) {
    env e;
    require getAddedAssets(e, assetId) == getAddedShares(assetId);
    require shares < 2^120;

    assert previewRemoveByShares(e, assetId, shares) == shares, "with shares == assets a share is not one unit";
}
