// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {
    AAssetListing,
    ADynamicReserveConfig,
    AInterestRateData,
    AReserveConfig,
    AReserveConfigUpdate,
    AReserveListing,
    ASpokeAssetConfig,
    ASpokeConfig,
    ASpokeConfigUpdate,
    ASpokeToAssetsAddition,
    AavePayloads,
    IAaveHubLimits
} from "./lib/AavePayloads.sol";
import {ListingBase} from "./lib/ListingBase.sol";

/// @title AaveListingPayload
/// @notice The Aave DAO's listing AIPs of `MKT-023` and `MKT-044`, Aave V4 payloads on the config engine run by the
/// governance executor; `AVANA_AAVE_STEP` picks the AIP:
/// - `debt` (`AvanaDebtReserves`), after `09_ListMarkets` `oracles`: each approved debt reserve's price source (GHO's
///   fixed source, the DebtOracle of any other asset) and `borrowable = true`, so `enableDebtReserve` finds the reserve
///   it records. Reserves left unapproved stay not borrowable: the standard-Spoke check requires the borrowable set to
///   equal the MarketRegistry's approved set.
/// - `vault-tokens` (`AvanaMarkets`), after the listing batch: each market's vault token as a Hub asset
///   (`liquidityFee = 0`, the treasury fee receiver's `addCap` set to 0), its CDP Spoke registered on it
///   (`drawCap = 0`), and the collateral reserve priced by the market's LPOracle (`borrowable = false`,
///   `receiveSharesEnabled = false`, `liquidationFee = 0`).
/// @dev Every Aave address comes from the config (`aave.*`), so the AIP is the same whether the Aave DAO or Avana ran
/// Aave V4's deployment. On Ethereum and Base only the actions are written, for the AIP author.
contract AaveListingPayload is ListingBase, AavePayloads {
    function run() external {
        _loadListing();
        bool execute = block.chainid != 1 && block.chainid != 8453;
        address controller = execute ? _addr(cfg, ".aaveLocal.payloadsController") : address(0);
        deployer = controller;
        string memory step = vm.envString("AVANA_AAVE_STEP");
        Builder memory b;
        string memory name;
        if (_eq(step, "debt")) (b, name) = (_debt(), "AvanaDebtReserves");
        else if (_eq(step, "vault-tokens")) (b, name) = (_vaultTokens(), "AvanaMarkets");
        else revert(string.concat("unknown AVANA_AAVE_STEP ", step));
        _shipPayload(
            name, b, _addr(cfg, ".aave.configEngine"), _addr(cfg, ".aave.governanceExecutor"), controller, execute
        );
    }

    function _debt() private view returns (Builder memory b) {
        b = _newBuilder();
        string memory sources = vm.readFile(_outputPath("listing-oracles"));
        uint256 n = _count(cfg, ".listing.debtReserves");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("debtReserves", i);
            string memory sym = _str(string.concat(k, ".symbol"));
            string memory spokeLabel = _str(string.concat(k, ".spoke"));
            AReserveConfigUpdate memory u = _keepReserveConfig();
            u.spokeConfigurator = _addr(cfg, ".aave.spokeConfigurator");
            u.spoke = _spokeAddr(spokeLabel);
            u.hub = _hub(_hubOfSpoke(spokeLabel));
            u.underlying = _token(sym);
            u.priceSource = vm.parseJsonAddress(sources, string.concat(".", sym));
            u.borrowable = 1;
            _reserveConfigUpdate(b, u);
        }
    }

    function _vaultTokens() private view returns (Builder memory b) {
        b = _newBuilder();
        string memory markets = vm.readFile(_outputPath("listing-markets"));
        string[] memory keys = vm.parseJsonKeys(markets, "$");
        for (uint256 i = 0; i < keys.length; ++i) {
            string memory k = string.concat(".", keys[i]);
            address vaultToken = vm.parseJsonAddress(markets, string.concat(k, ".vaultToken"));
            require(vaultToken.code.length != 0, "vault token not deployed: execute listing-markets first");
            _vaultAsset(b, markets, k, vaultToken);
            _vaultReserve(b, markets, k, vaultToken);
        }
    }

    /// @notice The vault token as a Hub asset with `liquidityFee = 0`; the fee receiver the listing registers with
    /// Aave's maximum `addCap` is set to 0; the CDP Spoke on the asset with `drawCap = 0`.
    function _vaultAsset(
        Builder memory b,
        string memory markets,
        string memory k,
        address vaultToken
    ) private view {
        address hub = vm.parseJsonAddress(markets, string.concat(k, ".hub"));
        string memory hubLabel = _hubOfSpoke(vm.parseJsonString(markets, string.concat(k, ".spokeLabel")));
        address hubCfg = _addr(cfg, ".aave.hubConfigurator");
        AAssetListing memory l;
        l.hubConfigurator = hubCfg;
        l.hub = hub;
        l.underlying = vaultToken;
        l.feeReceiver = _addr(cfg, ".aave.treasurySpoke");
        l.liquidityFee = 0;
        l.irStrategy = _addr(cfg, string.concat(".aave.irStrategies.", hubLabel));
        l.irData = AInterestRateData(9000, 0, 400, 6000);
        _assetListing(b, l);
        ASpokeConfigUpdate memory fee = _keepSpokeConfig();
        (fee.hubConfigurator, fee.hub, fee.underlying, fee.spoke, fee.addCap) =
        (hubCfg, hub, vaultToken, l.feeReceiver, 0);
        _spokeConfigUpdate(b, fee);
        ASpokeToAssetsAddition memory add;
        (add.hubConfigurator, add.hub, add.spoke) =
        (hubCfg, hub, vm.parseJsonAddress(markets, string.concat(k, ".spoke")));
        add.assets = new ASpokeAssetConfig[](1);
        add.assets[0] = ASpokeAssetConfig(
            vaultToken,
            ASpokeConfig(
                IAaveHubLimits(hub).MAX_ALLOWED_SPOKE_CAP(),
                0,
                IAaveHubLimits(hub).MAX_RISK_PREMIUM_THRESHOLD(),
                true,
                false
            )
        );
        _spokeToAssets(b, add);
    }

    /// @notice The collateral reserve: the market's LPOracle as price source, the three required settings.
    function _vaultReserve(
        Builder memory b,
        string memory markets,
        string memory k,
        address vaultToken
    ) private view {
        AReserveListing memory r;
        r.spokeConfigurator = _addr(cfg, ".aave.spokeConfigurator");
        r.spoke = vm.parseJsonAddress(markets, string.concat(k, ".spoke"));
        r.hub = vm.parseJsonAddress(markets, string.concat(k, ".hub"));
        r.underlying = vaultToken;
        r.priceSource = vm.parseJsonAddress(markets, string.concat(k, ".lpOracle"));
        r.config = AReserveConfig(
            uint24(vm.parseJsonUint(markets, string.concat(k, ".collateralRisk"))), false, false, false, false
        );
        r.dynamicConfig = ADynamicReserveConfig(
            uint16(vm.parseJsonUint(markets, string.concat(k, ".collateralFactorBps"))),
            uint32(vm.parseJsonUint(markets, string.concat(k, ".maxLiquidationBonus"))),
            0
        );
        _reserveListing(b, r);
    }
}
