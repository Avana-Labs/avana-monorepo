// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {DexHop, HopKind} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {DebtOracleInitParams} from "../../src/oracle/debt-oracle/types/DebtOracleInitParams.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {TokenDef} from "../../src/policy/market-registry/types/TokenDef.sol";
import {DebtReserveParams} from "../../src/policy/parameter-store/types/DebtReserveParams.sol";
import {GlobalParams} from "../../src/policy/parameter-store/types/GlobalParams.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {TokenOracleConfig} from "../../src/types/TokenOracleConfig.sol";
import {IVaultTokenFactory} from "../../src/vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {ChainInputs} from "./lib/DeployTypes.sol";
import {IPoolTokens, ListingBase} from "./lib/ListingBase.sol";
import {ITimelockOps} from "./lib/TimelockOperations.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console2} from "forge-std/console2.sol";

interface ISpokeImplementationRead {
    function ORACLE() external view returns (address);
}

/// @title ListMarkets
/// @notice The listing of the network's collateral markets (3.8 `MKT-018`…`MKT-026`, `MKT-044`, `MKT-055`), in the
/// steps the contracts require, each a timelock operation the governance Safe schedules (with `AVANA_SCHEDULE=1` on
/// anvil) and `05_ExecuteOperations` executes once ready. `AVANA_LISTING_STEP` picks the step:
/// - `setup` (normal delay): each integration's AMM contracts recorded and finalized; the Hubs' depositor caps; every
///   feed of the listed tokens (`setFeed`); the pool tokens and debt assets (`listToken`: three routes and the issuer
///   probe, GHO as a fixed-price monitoring-only listing), then their collateral factor, feed-agreement tolerance,
///   second source and Hub token caps, USDC's debt stress rise; each CDP Spoke (`approveSpokeCodeHash`,
///   `deployCdpSpoke`, `setLiquidationExpectations`), whose debt reserves the Aave payload left not borrowable; each
///   (Hub, debt asset)'s Coverage Spoke and credit line.
/// - `oracles` (Avana operators): GHO's fixed price source (a test-network stand-in) and the DebtOracle proxy of each
///   other debt asset, initialised in its deploying transaction once the asset is listed (`DebtOracle.initialize` reads
///   its routes). `10_AaveListingPayload` (`debt`) then names them as the reserves' price sources and makes the
///   approved reserves borrowable.
/// - `markets` (normal delay): Avana operators deploy each market's LPOracle proxy and swap routes; the batch enables
///   the debt reserves (`enableDebtReserve`, the debt asset's settlement parameters and, on the first reserve of a
///   (Hub, asset), `loosenDebtSpeedLimit`), then per market `deployVaultToken`, `listCollateralMarket`,
///   `setInitialMarketParams`, `setInitialMarketCaps`, `loosenMarketSpeedLimits` and the primary and backup route of
///   every pool token into the Spoke's debt asset. `10_AaveListingPayload` (`vault-tokens`) then lists the vault tokens.
/// - `activate` (short delay): every LPOracle poked Live, then `activateMarket` for each market.
/// @dev Speed limits fail closed (Q-411): a market or a (Hub, asset) without a written value refuses every pledge or
/// borrow, so the listing batch writes the launch values (τ 6 h; borrow 25 %, $250k–$2.5M; pledge 25 %, $1M–$10M;
/// (Hub, asset) 25 %, 500k–5M tokens). The `markets` operation's salt is keccak256 of the listing metadata file
/// (`09-market-metadata`), so the operation commits to the pages it adds. Outputs: `listing-oracles.json` and `listing-markets.json` in
/// `deployments-local/<network>/`, read by the manifest producer and the scenarios.
contract ListMarkets is ListingBase {
    uint32 internal constant LP_ORACLE_POKE_MIN_GAS = 1_000_000;
    uint256 internal constant LP_ORACLE_POKE_GAS = 1_500_000;
    uint256 internal constant SHORT_DELAY = 43_200;
    uint256 internal constant NORMAL_DELAY = 432_000;

    // From the network inputs (`ChainInputs` holds arrays of structs, which the legacy pipeline cannot copy to storage).
    address internal safe;
    uint32 internal blockTime;
    GlobalParams internal globals;
    uint32[] internal integrationIds;
    mapping(uint32 => bool) internal isSlipstream;

    function run() external {
        _loadListing();
        ChainInputs memory c = _loadInputs(_network());
        (safe, blockTime, globals) = (c.gov.governanceSafe, c.blockTime, c.globals);
        for (uint256 i = 0; i < c.integrations.length; ++i) {
            integrationIds.push(c.integrations[i].integrationId);
            isSlipstream[c.integrations[i].integrationId] = _eq(c.integrations[i].kind, "slipstream");
        }
        string memory step = vm.envString("AVANA_LISTING_STEP");
        if (_eq(step, "setup")) {
            _propose(_setup(c), NORMAL_DELAY);
        } else if (_eq(step, "oracles")) {
            _oracles();
        } else if (_eq(step, "markets")) {
            _propose(_markets(), NORMAL_DELAY);
        } else if (_eq(step, "activate")) {
            _propose(_activate(), SHORT_DELAY);
        } else {
            revert(string.concat("unknown AVANA_LISTING_STEP ", step));
        }
    }

    function _propose(
        Operation memory op,
        uint256 delay
    ) private {
        bytes32 id = _writeOperation(timelock, op);
        console2.log(op.name, vm.toString(id), _operationPath(op.name));
        if (vm.envOr("AVANA_SCHEDULE", false)) {
            vm.broadcast(safe);
            ITimelockOps(timelock).scheduleBatch(op.targets, op.values, op.payloads, bytes32(0), op.salt, delay);
            console2.log("scheduled as the governance Safe", safe);
        }
    }

    // ─── setup ───

    function _setup(
        ChainInputs memory c
    ) private view returns (Operation memory op) {
        op = _newOperation("listing-setup", release, 200);
        for (uint256 i = 0; i < c.integrations.length; ++i) {
            uint32 id = c.integrations[i].integrationId;
            uint256 n = c.integrations[i].positionManagers.length;
            address[] memory contracts = new address[](2 * n);
            for (uint256 j = 0; j < n; ++j) {
                (contracts[2 * j], contracts[2 * j + 1]) =
                (c.integrations[i].positionManagers[j], c.integrations[i].factories[j]);
            }
            _add(
                op,
                address(registry),
                abi.encodeCall(registry.recordIntegrationContracts, (id, contracts)),
                "MR.recordIntegrationContracts"
            );
            _add(
                op,
                address(registry),
                abi.encodeCall(registry.finalizeIntegrationContracts, (id)),
                "MR.finalizeIntegrationContracts"
            );
        }
        for (uint256 h = 0; h < c.aave.hubs.length; ++h) {
            uint256 cap = vm.parseUint(_str(".listing.hubDepositorUsdCap")) * 1e8;
            _add(
                op,
                address(store),
                abi.encodeCall(store.setInitialHubCaps, (c.aave.hubs[h].hub, cap)),
                "PS.setInitialHubCaps"
            );
        }
        _listTokens(op);
        _listDebtAssets(op);
        _recordSpokes(op);
        _coverageAndLines(op);
    }

    /// @notice The pool tokens: feeds, `listToken`, then the settings that need a listed token.
    function _listTokens(
        Operation memory op
    ) private view {
        uint256 n = _count(cfg, ".listing.tokens");
        string[4] memory roles = ["primary", "alternate", "standby", "second"];
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("tokens", i);
            string memory sym = _str(string.concat(k, ".symbol"));
            uint16 dev = uint16(_uint(string.concat(k, ".deviationBps")));
            for (uint256 r = 0; r < 4; ++r) {
                _add(
                    op,
                    address(store),
                    abi.encodeCall(store.setFeed, (_feed(sym, roles[r]), _feedDef(dev))),
                    "PS.setFeed"
                );
            }
            TokenDef memory d;
            d.listed = true;
            d.decimals = 0; // read on-chain
            d.isUsdStable = _bool(string.concat(k, ".isUsdStable"));
            d.primaryRoute = _one(_feed(sym, "primary"));
            d.alternateRoute = _one(_feed(sym, "alternate"));
            d.standbyRoute = _one(_feed(sym, "standby"));
            d.replacedSlot = RouteSlot.None;
            d.issuerProbe = IssuerProbe.None;
            _add(
                op,
                address(registry),
                abi.encodeCall(registry.listToken, (_token(sym), d)),
                string.concat("MR.listToken ", sym)
            );
        }
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("tokens", i);
            address t = _token(_str(string.concat(k, ".symbol")));
            uint16 cf = uint16(_uint(string.concat(k, ".collateralFactorBps")));
            uint16 tol = uint16(_uint(string.concat(k, ".agreementToleranceBps")));
            SecondSource memory none;
            _add(
                op,
                address(store),
                abi.encodeCall(store.setTokenCollateralFactorBps, (t, cf)),
                "PS.setTokenCollateralFactorBps"
            );
            _add(
                op,
                address(store),
                abi.encodeCall(store.setFeedAgreementToleranceBps, (t, tol)),
                "PS.setFeedAgreementToleranceBps"
            );
            _add(
                op,
                address(store),
                abi.encodeCall(store.setSecondSource, (t, _secondSource(k), none)),
                "PS.setSecondSource"
            );
            string[] memory hubs = vm.parseJsonStringArray(cfg, string.concat(k, ".hubs"));
            uint256 cap = vm.parseUint(_str(string.concat(k, ".tokenCapUsd"))) * 1e8;
            for (uint256 h = 0; h < hubs.length; ++h) {
                _add(
                    op,
                    address(store),
                    abi.encodeCall(store.setInitialTokenCap, (_hub(hubs[h]), t, cap)),
                    "PS.setInitialTokenCap"
                );
            }
        }
    }

    /// @notice Debt assets that are no pool token are listed here: a fixed-price asset monitoring-only (its primary feed),
    /// any other with its three routes. A non-fixed asset gets its debt stress rise (`MKT-044`).
    function _listDebtAssets(
        Operation memory op
    ) private view {
        uint256 n = _count(cfg, ".listing.debtAssets");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("debtAssets", i);
            string memory sym = _str(string.concat(k, ".symbol"));
            address asset = _token(sym);
            bool fixedPrice = _bool(string.concat(k, ".fixedPrice"));
            if (bytes(_tokenKey(asset)).length == 0) {
                uint16 dev = uint16(_uint(string.concat(k, ".deviationBps")));
                _add(
                    op,
                    address(store),
                    abi.encodeCall(store.setFeed, (_feed(sym, "primary"), _feedDef(dev))),
                    "PS.setFeed"
                );
                require(fixedPrice, "a debt asset that is no pool token must be fixed-price here");
                TokenDef memory d;
                d.listed = true;
                d.isUsdStable = true;
                d.primaryRoute = _one(_feed(sym, "primary"));
                d.alternateRoute = new address[](0);
                d.standbyRoute = new address[](0);
                _add(
                    op,
                    address(registry),
                    abi.encodeCall(registry.listToken, (asset, d)),
                    string.concat("MR.listToken ", sym)
                );
            }
            if (!fixedPrice) {
                uint16 rise = uint16(_uint(string.concat(k, ".stressRiseBps")));
                _add(
                    op,
                    address(store),
                    abi.encodeCall(store.tightenDebtStressRiseBps, (asset, rise)),
                    "PS.tightenDebtStressRiseBps"
                );
            }
        }
    }

    /// @notice `MKT-055`: each CDP Spoke's implementation hash (once each), the Spoke and its liquidation expectations.
    function _recordSpokes(
        Operation memory op
    ) private view {
        uint256 n = _count(cfg, ".listing.spokes");
        bytes32 standard = registry.STANDARD_SPOKE_IMPLEMENTATION().codehash;
        bytes32[] memory seen = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("spokes", i);
            string memory label = _str(string.concat(k, ".label"));
            address impl = _implementationOf(_spokeAddr(label));
            bytes32 h = impl.codehash;
            bool approved = h == standard || registry.isApprovedSpokeCodeHash(h);
            for (uint256 j = 0; j < i; ++j) {
                if (seen[j] == h) approved = true;
            }
            seen[i] = h;
            if (!approved) {
                _add(
                    op, address(registry), abi.encodeCall(registry.approveSpokeCodeHash, (h)), "MR.approveSpokeCodeHash"
                );
            }
            SpokeDef memory d;
            d.hub = _hub(_str(string.concat(k, ".hub")));
            d.integrationId = uint32(_uint(string.concat(k, ".integrationId")));
            d.riskTier = RiskTier(uint8(_uint(string.concat(k, ".tier"))));
            d.implementation = impl;
            d.aaveOracle = ISpokeImplementationRead(_spokeAddr(label)).ORACLE();
            _add(
                op,
                address(registry),
                abi.encodeCall(registry.deployCdpSpoke, (d)),
                string.concat("MR.deployCdpSpoke ", label)
            );
            _add(
                op,
                address(store),
                abi.encodeCall(store.setLiquidationExpectations, (_spokeAddr(label), 1.1e18, uint16(200))),
                "PS.setLiquidationExpectations"
            );
        }
    }

    /// @notice Each (Hub, debt asset) of the debt reserves: its Coverage Spoke and the Hub's credit line, which bounds
    /// the CDP Spokes' draw caps on the asset.
    function _coverageAndLines(
        Operation memory op
    ) private view {
        string memory coverage = vm.readFile(_outputPath("coverage"));
        uint256 n = _count(cfg, ".listing.debtReserves");
        for (uint256 i = 0; i < n; ++i) {
            if (!_firstOfPair(i)) continue;
            string memory k = _at("debtReserves", i);
            string memory sym = _str(string.concat(k, ".symbol"));
            string memory hubLabel = _hubOfSpoke(_str(string.concat(k, ".spoke")));
            address hub = _hub(hubLabel);
            address cs = vm.parseJsonAddress(coverage, string.concat("$['CoverageSpoke.", hubLabel, ".", sym, "']"));
            _add(
                op,
                address(registry),
                abi.encodeCall(registry.setCoverageSpoke, (hub, _token(sym), cs)),
                "MR.setCoverageSpoke"
            );
            _add(
                op,
                address(registry),
                abi.encodeCall(registry.recordCreditLine, (hub, _token(sym), _uint(".listing.creditLineWhole"))),
                "MR.recordCreditLine"
            );
        }
    }

    /// @notice Whether debt reserve `i` is the first of its (Hub, asset) in the config.
    function _firstOfPair(
        uint256 i
    ) private view returns (bool) {
        string memory sym = _str(string.concat(_at("debtReserves", i), ".symbol"));
        string memory hub = _hubOfSpoke(_str(string.concat(_at("debtReserves", i), ".spoke")));
        for (uint256 j = 0; j < i; ++j) {
            if (
                _eq(_str(string.concat(_at("debtReserves", j), ".symbol")), sym)
                    && _eq(_hubOfSpoke(_str(string.concat(_at("debtReserves", j), ".spoke"))), hub)
            ) return false;
        }
        return true;
    }

    // ─── oracles ───

    function _oracles() private {
        uint256 n = _count(cfg, ".listing.debtAssets");
        string memory o = "oracles";
        string memory json;
        vm.startBroadcast(deployerOf());
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("debtAssets", i);
            string memory sym = _str(string.concat(k, ".symbol"));
            address source;
            if (_bool(string.concat(k, ".fixedPrice"))) {
                source = _deploy(
                    string.concat("FixedPriceSource.", sym), _artifact("FixedPriceSource.sol", "FixedPriceSource")
                );
            } else {
                DebtOracleInitParams memory p = DebtOracleInitParams({
                    timelock: timelock,
                    asset: _token(sym),
                    marketRegistry: address(registry),
                    parameterStore: address(store),
                    description: string.concat(sym, " / USD debt"),
                    pokeMinGas: uint32(_uint(string.concat(k, ".debtOraclePokeMinGas")))
                });
                address impl = vm.parseJsonAddress(avanaJson, ".debtOracleImplementation");
                source = _deploy(
                    string.concat("DebtOracle.", sym),
                    bytes.concat(
                        type(ERC1967Proxy).creationCode, abi.encode(impl, abi.encodeCall(IDebtOracle.initialize, (p)))
                    )
                );
            }
            json = vm.serializeAddress(o, sym, source);
            console2.log("price source", sym, source);
        }
        vm.stopBroadcast();
        vm.writeJson(json, _outputPath("listing-oracles"));
    }

    function deployerOf() internal view returns (address) {
        return vm.parseJsonAddress(avanaJson, ".deployer");
    }

    // ─── markets ───

    /// @notice One market's computed inputs.
    struct Mkt {
        string key;
        uint256 marketId;
        uint32 integrationId;
        string spokeLabel;
        address spoke;
        address hub;
        address pool;
        address token0;
        address token1;
        PositionShape shape;
        bytes integrationData;
        address lpVault;
        uint8 decimals;
        address lpOracle;
        address vaultToken;
        address debtAsset;
    }

    function _markets() private returns (Operation memory op) {
        op = _newOperation("listing-markets", release, 200);
        uint256 first = registry.marketCount() + 1;
        op.salt = _listingMetadataHash(first);
        _enableDebtReserves(op);
        uint256 n = _count(cfg, ".listing.markets");
        string memory out = "markets";
        string memory json;
        for (uint256 i = 0; i < n; ++i) {
            Mkt memory m = _market(i, first + i);
            _deployLpOracle(m);
            IVaultTokenFactory f = IVaultTokenFactory(vm.parseJsonAddress(avanaJson, ".vaultTokenFactory"));
            m.vaultToken = f.predictAddress(m.spoke, f.marketKeyOf(m.integrationId, m.pool, bytes32(0), m.shape));
            address[] memory routes = _listMarket(op, m, f);
            json = vm.serializeString(out, string.concat("market", vm.toString(m.marketId)), _marketJson(m, routes));
        }
        vm.writeJson(json, _outputPath("listing-markets"));
    }

    /// @notice The listing's timelock salt: keccak256 of the listing metadata file `09-market-metadata` wrote
    /// (`script/deploy/market-metadata.ts`), the pages this listing adds. Convex loads the file by that hash once the
    /// operation executes and refuses one whose bytes hash otherwise. The file must be for this chain and for the market
    /// IDs this listing gives, the ones after `marketCount()`.
    function _listingMetadataHash(
        uint256 firstMarketId
    ) private view returns (bytes32 hash) {
        string memory pointer = vm.readFile(_outputPath("listing-metadata"));
        hash = vm.parseJsonBytes32(pointer, ".hash");
        require(vm.parseJsonUint(pointer, ".chainId") == block.chainid, "listing metadata is for another chain");
        require(
            vm.parseJsonUint(pointer, ".firstMarketId") == firstMarketId,
            "listing metadata names other market IDs: rerun 09-market-metadata"
        );
        string memory file = string.concat(
            vm.projectRoot(), "/", OUTPUT_DIR, "/", _network(), "/", vm.parseJsonString(pointer, ".file")
        );
        require(keccak256(vm.readFileBinary(file)) == hash, "listing metadata file does not hash to its name");
    }

    function _market(
        uint256 i,
        uint256 marketId
    ) private returns (Mkt memory m) {
        m.key = _at("markets", i);
        m.marketId = marketId;
        m.integrationId = uint32(_uint(string.concat(m.key, ".integrationId")));
        m.spokeLabel = _str(string.concat(m.key, ".spoke"));
        m.spoke = _spokeAddr(m.spokeLabel);
        m.hub = _hub(_hubOfSpoke(m.spokeLabel));
        m.pool = _pool(_str(string.concat(m.key, ".pool")));
        (m.token0, m.token1) = (IPoolTokens(m.pool).token0(), IPoolTokens(m.pool).token1());
        int24 lower = int24(vm.parseJsonInt(cfg, string.concat(m.key, ".tickLower")));
        int24 upper = int24(vm.parseJsonInt(cfg, string.concat(m.key, ".tickUpper")));
        if (lower == 0 && upper == 0) {
            int24 sp = IPoolTokens(m.pool).tickSpacing();
            upper = (887_272 / sp) * sp;
            lower = -upper;
        }
        m.shape = PositionShape(ShapeKind.TickRange, lower, upper);
        (uint256 p0, uint256 p1) = (_price8(m.token0), _price8(m.token1));
        uint256 idx = _integrationIndex(m.integrationId);
        m.integrationData = isSlipstream[m.integrationId]
            ? abi.encode(_uint(string.concat(m.key, ".generation")), p0, p1)
            : abi.encode(p0, p1);
        m.lpVault = vm.parseJsonAddressArray(avanaJson, ".lpVaults")[idx];
        // The vault-token decimals `d` the LPVault's `bindMarket` derives inside `listCollateralMarket`, read by a
        // simulated binding that is reverted: `deployVaultToken` earlier in the batch must name the same `d`.
        uint256 snap = vm.snapshotState();
        vm.prank(address(registry));
        (, m.decimals) =
            IAmmIntegration(m.lpVault).bindMarket(m.marketId, m.pool, bytes32(0), m.shape, m.integrationData);
        vm.revertToState(snap);
        m.debtAsset = _debtAssetOf(m.spokeLabel);
    }

    function _integrationIndex(
        uint32 id
    ) private view returns (uint256) {
        for (uint256 i = 0; i < integrationIds.length; ++i) {
            if (integrationIds[i] == id) return i;
        }
        revert("unknown integration");
    }

    function _debtAssetOf(
        string memory spokeLabel
    ) private view returns (address) {
        uint256 n = _count(cfg, ".listing.debtReserves");
        for (uint256 i = 0; i < n; ++i) {
            if (_eq(_str(string.concat(_at("debtReserves", i), ".spoke")), spokeLabel)) {
                return _token(_str(string.concat(_at("debtReserves", i), ".symbol")));
            }
        }
        revert(string.concat("no debt reserve for ", spokeLabel));
    }

    /// @notice `MKT-019`: the market's LPOracle, a proxy of its integration's `LPOracleCL` initialised in its deploying
    /// transaction; `initialize` refuses a configuration that does not price Live.
    function _deployLpOracle(
        Mkt memory m
    ) private {
        InitParams memory p;
        p.timelock = timelock;
        p.parameterStore = address(store);
        p.marketRegistry = address(registry);
        p.marketId = m.marketId;
        p.integration = m.lpVault;
        p.isUsdStable = new bool[](2);
        p.isUsdStable[0] = _bool(string.concat(_tokenKey(m.token0), ".isUsdStable"));
        p.isUsdStable[1] = _bool(string.concat(_tokenKey(m.token1), ".isUsdStable"));
        p.description = _str(string.concat(m.key, ".name"));
        p.pokeMinGas = LP_ORACLE_POKE_MIN_GAS;
        p.config = _oracleConfig(m, p.isUsdStable[0] && p.isUsdStable[1]);
        p.market = abi.encode(m.pool, m.shape.tickLower, m.shape.tickUpper);
        address impl = vm.parseJsonAddressArray(avanaJson, ".clOraclePricing")[_integrationIndex(m.integrationId)];
        vm.broadcast(deployerOf());
        m.lpOracle = _deploy(
            string.concat("LPOracle.", vm.toString(m.marketId)),
            bytes.concat(type(ERC1967Proxy).creationCode, abi.encode(impl, abi.encodeCall(ILPOracle.initialize, (p))))
        );
        console2.log("LPOracle", m.marketId, m.lpOracle);
    }

    function _oracleConfig(
        Mkt memory m,
        bool allStable
    ) private view returns (OracleConfig memory o) {
        o.marketId = m.marketId;
        o.tokens = new TokenOracleConfig[](2);
        o.tokens[0] = _tokenOracleConfig(m.token0);
        o.tokens[1] = _tokenOracleConfig(m.token1);
        o.twapWindow = 1800;
        o.twapMinObservations = uint16((1800 + blockTime - 1) / blockTime + 1);
        o.consistencyToleranceBps = uint16(_uint(string.concat(m.key, ".consistencyToleranceBps")));
        o.maxQuoteChangeBps = 100;
        o.usdBandLow = allStable ? globals.usdBandLow : 0;
        o.usdBandHigh = allStable ? globals.usdBandHigh : type(uint256).max;
        o.cachedWindow = globals.cachedWindow;
        o.disagreementPauseMax = globals.disagreementPauseMax;
        o.graceDuration = globals.graceDuration;
    }

    function _tokenOracleConfig(
        address token
    ) private view returns (TokenOracleConfig memory t) {
        string memory k = _tokenKey(token);
        string memory sym = _str(string.concat(k, ".symbol"));
        uint16 dev = uint16(_uint(string.concat(k, ".deviationBps")));
        t.token = token;
        t.routes[0] = _route(_feed(sym, "primary"), dev);
        t.routes[1] = _route(_feed(sym, "alternate"), dev);
        t.feedAgreementToleranceBps = uint16(_uint(string.concat(k, ".agreementToleranceBps")));
        t.secondSource = _secondSource(k);
    }

    /// @notice `enableDebtReserve` for each configured reserve, the asset's settlement parameters and, on the first
    /// reserve of a (Hub, asset), its launch borrow-speed limit (written after the reserve exists, `UnknownDebtReserve`
    /// otherwise).
    function _enableDebtReserves(
        Operation memory op
    ) private view {
        string memory sources = vm.readFile(_outputPath("listing-oracles"));
        string memory coverage = vm.readFile(_outputPath("coverage"));
        uint256 n = _count(cfg, ".listing.debtReserves");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("debtReserves", i);
            string memory sym = _str(string.concat(k, ".symbol"));
            string memory spokeLabel = _str(string.concat(k, ".spoke"));
            DebtReserveDef memory d;
            d.asset = _token(sym);
            (d.fundingHub, d.hubAssetId, d.reserveId) = _reserveOf(spokeLabel, d.asset);
            d.decimals = IDecimals(d.asset).decimals();
            d.priceSource = vm.parseJsonAddress(sources, string.concat(".", sym));
            d.fixedPrice = _debtAssetFixed(sym);
            d.coverageSpoke = vm.parseJsonAddress(
                coverage, string.concat("$['CoverageSpoke.", _hubOfSpoke(spokeLabel), ".", sym, "']")
            );
            d.approved = true;
            _add(
                op,
                address(registry),
                abi.encodeCall(registry.enableDebtReserve, (_spokeAddr(spokeLabel), d)),
                string.concat("MR.enableDebtReserve ", spokeLabel, " ", sym)
            );
            if (!_firstOfPair(i)) continue;
            uint256 unit = 10 ** d.decimals;
            SpeedLimit memory s = SpeedLimit({
                rateBps: uint16(_uint(".listing.speedLimits.debtRateBps")),
                window: uint32(_uint(".listing.speedLimits.window")),
                min: uint96(_uint(".listing.speedLimits.debtMinWhole") * unit),
                max: uint96(_uint(".listing.speedLimits.debtMaxWhole") * unit)
            });
            _add(
                op,
                address(store),
                abi.encodeCall(store.loosenDebtSpeedLimit, (d.fundingHub, d.asset, s)),
                "PS.loosenDebtSpeedLimit"
            );
        }
        uint256 a = _count(cfg, ".listing.debtAssets");
        for (uint256 i = 0; i < a; ++i) {
            string memory k = _at("debtAssets", i);
            DebtReserveParams memory p = DebtReserveParams({
                floorRoundingAllowance: vm.parseUint(_str(string.concat(k, ".floorRoundingAllowance")))
            });
            _add(
                op,
                address(store),
                abi.encodeCall(store.setDebtAssetParams, (_token(_str(string.concat(k, ".symbol"))), p)),
                "PS.setDebtAssetParams"
            );
        }
    }

    function _debtAssetFixed(
        string memory sym
    ) private view returns (bool) {
        uint256 a = _count(cfg, ".listing.debtAssets");
        for (uint256 i = 0; i < a; ++i) {
            if (_eq(_str(string.concat(_at("debtAssets", i), ".symbol")), sym)) {
                return _bool(string.concat(_at("debtAssets", i), ".fixedPrice"));
            }
        }
        revert(string.concat("not a debt asset ", sym));
    }

    /// @notice `ParameterStore.setInitialMarketCaps` for one market, from its USD caps in the config. Its own function:
    /// the unoptimized coverage build runs out of stack slots when `_listMarket` encodes it inline.
    function _marketCapsCall(
        Mkt memory m
    ) private view returns (bytes memory) {
        return abi.encodeCall(
            store.setInitialMarketCaps,
            (
                m.marketId,
                vm.parseUint(_str(string.concat(m.key, ".marketUsdCap"))) * 1e8,
                vm.parseUint(_str(string.concat(m.key, ".topUpSliceUsd"))) * 1e8,
                vm.parseUint(_str(string.concat(m.key, ".stressFloorUsd"))) * 1e8
            )
        );
    }

    /// @notice The listing calls of one market (`MKT-018`, `MKT-020`, `MKT-021`) and its swap routes.
    function _listMarket(
        Operation memory op,
        Mkt memory m,
        IVaultTokenFactory f
    ) private returns (address[] memory routes) {
        string memory id = vm.toString(m.marketId);
        _add(
            op,
            address(f),
            _vaultTokenCall(m, string.concat("Avana LP ", _str(string.concat(m.key, ".name")), " market ", id), id),
            "VTF.deployVaultToken"
        );
        MarketDef memory d = MarketDef({
            hub: m.hub,
            spoke: m.spoke,
            integrationId: m.integrationId,
            pool: m.pool,
            poolId: bytes32(0),
            shape: m.shape,
            vaultToken: m.vaultToken,
            lpOracle: m.lpOracle,
            integrationData: m.integrationData
        });
        _add(op, address(registry), abi.encodeCall(registry.listCollateralMarket, (d)), "MR.listCollateralMarket");
        _add(
            op,
            address(store),
            abi.encodeCall(store.setInitialMarketParams, (m.marketId, _marketParams(m.key))),
            "PS.setInitialMarketParams"
        );
        _add(op, address(store), _marketCapsCall(m), "PS.setInitialMarketCaps");
        _add(
            op,
            address(store),
            abi.encodeCall(store.loosenMarketSpeedLimits, (m.marketId, _speedLimits())),
            "PS.loosenMarketSpeedLimits"
        );
        routes = _routes(op, m);
    }

    /// @dev Name `Avana LP <market> market <id>` and symbol `avLP-<id>` (`REQ-VTOKEN-050`).
    function _vaultTokenCall(
        Mkt memory m,
        string memory name,
        string memory id
    ) private pure returns (bytes memory) {
        return abi.encodeCall(
            IVaultTokenFactory.deployVaultToken,
            (
                m.integrationId,
                m.pool,
                bytes32(0),
                m.shape,
                m.hub,
                m.spoke,
                m.marketId,
                m.lpOracle,
                m.decimals,
                name,
                string.concat("avLP-", id)
            )
        );
    }

    function _marketParams(
        string memory k
    ) private view returns (MarketParams memory p) {
        p.twapWindow = 1800;
        p.consistencyToleranceBps = uint16(_uint(string.concat(k, ".consistencyToleranceBps")));
        p.slippageAllowanceBps = uint16(_uint(string.concat(k, ".slippageAllowanceBps")));
        p.slippageAllowanceMinBps = uint16(_uint(string.concat(k, ".slippageAllowanceMinBps")));
        p.poolRiskFactor = uint16(_uint(string.concat(k, ".poolRiskFactorBps")));
        p.minPledgeUsd = vm.parseUint(_str(string.concat(k, ".minPledgeUsd"))) * 1e8;
    }

    function _speedLimits() private view returns (MarketSpeedLimits memory s) {
        string memory k = ".listing.speedLimits";
        s.window = uint32(_uint(string.concat(k, ".window")));
        s.borrowRateBps = uint16(_uint(string.concat(k, ".borrowRateBps")));
        s.pledgeRateBps = uint16(_uint(string.concat(k, ".pledgeRateBps")));
        s.borrowMinUsd = uint96(_uint(string.concat(k, ".borrowMinUsd")) * 1e8);
        s.borrowMaxUsd = uint96(_uint(string.concat(k, ".borrowMaxUsd")) * 1e8);
        s.pledgeMinUsd = uint96(_uint(string.concat(k, ".pledgeMinUsd")) * 1e8);
        s.pledgeMaxUsd = uint96(_uint(string.concat(k, ".pledgeMaxUsd")) * 1e8);
    }

    /// @notice The primary (kind 0) and backup (kind 1) `DexPathRoute` of each configured (pool token, debt asset),
    /// deployed by Avana operators (immutable per version, `REQ-ROUTE-017`) and recorded by `setRoute` in the batch.
    function _routes(
        Operation memory op,
        Mkt memory m
    ) private returns (address[] memory routes) {
        uint256 n = _count(cfg, string.concat(m.key, ".routes"));
        routes = new address[](2 * n);
        for (uint256 i = 0; i < n; ++i) {
            string memory rk = string.concat(m.key, ".routes[", vm.toString(i), "]");
            address tokenIn = _token(_str(string.concat(rk, ".token")));
            address asset = _token(_str(string.concat(rk, ".asset")));
            for (uint8 kind = 0; kind < 2; ++kind) {
                string[] memory pools =
                    vm.parseJsonStringArray(cfg, string.concat(rk, kind == 0 ? ".primary" : ".backup"));
                address route = _deployRoute(m, tokenIn, asset, pools);
                routes[2 * i + kind] = route;
                _add(
                    op,
                    address(registry),
                    abi.encodeCall(registry.setRoute, (m.marketId, tokenIn, asset, kind, route)),
                    "MR.setRoute"
                );
            }
        }
    }

    function _deployRoute(
        Mkt memory m,
        address tokenIn,
        address tokenOut,
        string[] memory pools
    ) private returns (address) {
        DexHop[] memory hops = new DexHop[](pools.length);
        address cur = tokenIn;
        for (uint256 h = 0; h < pools.length; ++h) {
            address pool = _pool(pools[h]);
            (address t0, address t1) = (IPoolTokens(pool).token0(), IPoolTokens(pool).token1());
            require(cur == t0 || cur == t1, string.concat("route hop does not hold its input: ", pools[h]));
            cur = cur == t0 ? t1 : t0;
            hops[h] = DexHop({kind: HopKind.ConcentratedLiquidity, pool: pool, tokenOut: cur, i: 0, j: 0});
        }
        require(cur == tokenOut, "route does not end in the debt asset");
        RouteConfig memory rc;
        rc.lpVaultSwap = vm.parseJsonAddress(avanaJson, ".lpVaultSwap.proxy");
        rc.lock = vm.parseJsonAddress(avanaJson, ".lock");
        rc.aaveAdapter = vm.parseJsonAddress(avanaJson, ".aaveAdapter.proxy");
        rc.tokenIn = tokenIn;
        rc.tokenOut = tokenOut;
        rc.tokenClassMask = uint8(1 << _uint(string.concat(_spokeKey(m.spokeLabel), ".tier")));
        rc.uniswapV3Factory = _addr(cfg, ".listing.uniswapV3Factory");
        rc.curveLegacyPools = new address[](0);
        vm.broadcast(deployerOf());
        return
            _deploy("DexPathRoute", bytes.concat(_artifact("DexPathRoute.sol", "DexPathRoute"), abi.encode(rc, hops)));
    }

    function _marketJson(
        Mkt memory m,
        address[] memory routes
    ) private returns (string memory) {
        string memory k = string.concat("market.", vm.toString(m.marketId));
        vm.serializeString(k, "name", _str(string.concat(m.key, ".name")));
        vm.serializeUint(k, "marketId", m.marketId);
        vm.serializeUint(k, "integrationId", m.integrationId);
        vm.serializeString(k, "spokeLabel", m.spokeLabel);
        vm.serializeAddress(k, "spoke", m.spoke);
        vm.serializeAddress(k, "hub", m.hub);
        vm.serializeAddress(k, "pool", m.pool);
        vm.serializeAddress(k, "token0", m.token0);
        vm.serializeAddress(k, "token1", m.token1);
        vm.serializeInt(k, "tickLower", m.shape.tickLower);
        vm.serializeInt(k, "tickUpper", m.shape.tickUpper);
        vm.serializeUint(k, "decimals", m.decimals);
        vm.serializeAddress(k, "lpVault", m.lpVault);
        vm.serializeAddress(k, "lpOracle", m.lpOracle);
        vm.serializeAddress(k, "debtAsset", m.debtAsset);
        vm.serializeAddress(k, "routes", routes);
        vm.serializeUint(k, "collateralFactorBps", _uint(string.concat(m.key, ".collateralFactorBps")));
        vm.serializeUint(k, "maxLiquidationBonus", _uint(string.concat(m.key, ".maxLiquidationBonus")));
        vm.serializeUint(k, "collateralRisk", _uint(string.concat(m.key, ".collateralRisk")));
        return vm.serializeAddress(k, "vaultToken", m.vaultToken);
    }

    // ─── activate ───

    /// @notice `MKT-022`, `MKT-026`: every listed LPOracle poked (it must be Live), then `activateMarket` for each.
    function _activate() private returns (Operation memory op) {
        string memory markets = vm.readFile(_outputPath("listing-markets"));
        uint256 n = _count(cfg, ".listing.markets");
        uint256 first = registry.marketCount() + 1 - n;
        op = _newOperation("listing-activate", release, n);
        vm.startBroadcast(deployerOf());
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = first + i;
            // `poke` refuses less than `pokeMinGas` at entry (1,000,000 here); a gas estimate is the gas it uses, so the
            // limit is set explicitly.
            ILPOracle(vm.parseJsonAddress(markets, string.concat(".market", vm.toString(id), ".lpOracle")))
            .poke{gas: LP_ORACLE_POKE_GAS}();
        }
        vm.stopBroadcast();
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = first + i;
            _add(op, address(registry), abi.encodeCall(registry.activateMarket, (id)), "MR.activateMarket");
        }
    }
}

interface IDecimals {
    function decimals() external view returns (uint8);
}
