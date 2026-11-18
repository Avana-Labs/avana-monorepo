// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../../src/amm/IClIntegration.sol";
import {ILPVault} from "../../src/custody/lp-vault/ILPVault.sol";
import {UniswapV4PoolKey} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {DexHop, HopKind, RouteConfig} from "../../src/liquidation/settlement-routes/types/SettlementRouteTypes.sol";
import {ILPOracle} from "../../src/oracle/ILPOracle.sol";
import {LPOracle} from "../../src/oracle/LPOracle.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {
    DebtReserveDef,
    MarketStatus,
    RiskTier,
    SpokeDef,
    TokenDef
} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {
    DebtReserveParams,
    GlobalParams,
    MarketParams,
    MarketSpeedLimits,
    SpeedLimit
} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {MarketDef} from "../../src/types/MarketTypes.sol";
import {OracleConfig, RouteSlot, SecondSource, TokenOracleConfig} from "../../src/types/OracleTypes.sol";
import {PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
import {IVaultTokenFactory} from "../../src/vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {ChainInputs} from "./lib/DeployTypes.sol";
import {IPoolTokens, ListingBase} from "./lib/ListingBase.sol";
import {ITimelockOps} from "./lib/TimelockOperations.sol";
import {TokenProbe} from "./lib/TokenProbe.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {console2} from "forge-std/console2.sol";

interface ISpokeImplementationRead {
    function ORACLE() external view returns (address);
}

/// @notice The Uniswap v4 LPVault and PositionManager views a v4 listing reads.
interface IUniswapV4Reads {
    function POOL_MANAGER() external view returns (address);
    function wrappedNative() external view returns (address);
    function poolManager() external view returns (address);
}

/// @notice The vault-token views a relisting reads.
interface IRelistedToken {
    function marketId() external view returns (uint256);
    function lpOracle() external view returns (address);
    function decimals() external view returns (uint8);
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
///   (Hub, debt asset)'s First-Loss Reserve and credit line.
/// - `oracles` (Avana operators): GHO's fixed price source (a test-network stand-in) and the DebtOracle proxy of each
///   other debt asset, initialised in its deploying transaction once the asset is listed (`DebtOracle.initialize` reads
///   its routes). `10_AaveListingPayload` (`debt`) then names them as the reserves' price sources and makes the
///   approved reserves borrowable.
/// - `markets` (normal delay): Avana operators deploy each market's LPOracle proxy and swap routes (a cancelled market
///   of the config is relisted under its reserved ID with its first vault token and LPOracle); the batch enables
///   the debt reserves (`enableDebtReserve`, the debt asset's settlement parameters and, on the first reserve of a
///   (Hub, asset), `loosenDebtSpeedLimit`), then per market `deployVaultToken`, `listCollateralMarket`,
///   `setInitialMarketParams`, `setInitialMarketCaps`, `loosenMarketSpeedLimits`, the primary and backup route of
///   every pool token into the Spoke's debt asset and each route slot's depth threshold (`tightenRouteDepthThreshold`,
///   from the route's `depthThreshold` in the config). `10_AaveListingPayload` (`vault-tokens`) then lists the vault
///   tokens.
/// - `activate` (short delay): every LPOracle poked Live, then `activateMarket` for each market.
/// @dev A Uniswap v4 market has no pool address: its config `pool` names an entry of `listing.uniswapV4Pools` (the pool
/// key's currencies, fee and tick spacing, and the Uniswap v3 reference pool of its pair), and the market is keyed by
/// `poolId = keccak256(abi.encode(key))` with `pool = address(0)`. Native ETH (`currency0 = address(0)`) is the
/// LPVault's `wrappedNative()` among the market's tokens.
/// Speed limits fail closed (Q-411): a market or a (Hub, asset) without a written value refuses every pledge or
/// borrow, so the listing batch writes the config values (τ 6 h; borrow 25 %, $250k–$2.5M; pledge 25 %, $1M–$10M;
/// (Hub, asset) 25 %, 500k–5M tokens). The `markets` operation's salt is keccak256 of the listing metadata file
/// (`09-market-metadata`), so the operation commits to the pages it adds. Outputs: `listing-oracles.json` and `listing-markets.json` in
/// `deployments-local/<network>/`, read by the manifest producer and the scenarios.
contract ListMarkets is ListingBase {
    // From the network inputs (`ChainInputs` holds arrays of structs, which the legacy pipeline cannot copy to storage).
    address internal safe;
    uint32 internal blockTime;
    GlobalParams internal globals;
    uint32[] internal integrationIds;
    mapping(uint32 => bool) internal isSlipstream;
    mapping(uint32 => bool) internal isUniswapV4;

    function run() external {
        _loadListing();
        ChainInputs memory c = _loadInputs(_network());
        (safe, blockTime, globals) = (c.gov.governanceSafe, c.blockTime, c.globals);
        for (uint256 i = 0; i < c.integrations.length; ++i) {
            integrationIds.push(c.integrations[i].integrationId);
            isSlipstream[c.integrations[i].integrationId] = _eq(c.integrations[i].kind, "slipstream");
            isUniswapV4[c.integrations[i].integrationId] = _eq(c.integrations[i].kind, "uniswap-v4");
        }
        string memory step = vm.envString("AVANA_LISTING_STEP");
        if (_eq(step, "setup")) {
            Operation memory op = _setup(c);
            _proposeInParts(op, _everyCall(op.targets.length));
        } else if (_eq(step, "oracles")) {
            _oracles();
        } else if (_eq(step, "markets")) {
            (Operation memory op, uint256[] memory starts) = _markets();
            _proposeInParts(op, _leadingCallsApart(starts, op.targets.length));
        } else if (_eq(step, "activate")) {
            _propose(_activate(), true);
        } else {
            revert(string.concat("unknown AVANA_LISTING_STEP ", step));
        }
    }

    /// @notice Writes the operation and, with `AVANA_SCHEDULE`, schedules it as the Safe at the delay the timelock
    /// requires of it: the short delay for an operation that must be short (`short`, the activation), else the normal
    /// delay set at deployment.
    function _propose(
        Operation memory op,
        bool short
    ) private {
        // Every step lists only what the config adds to the chain; with nothing new there is no operation to schedule,
        // and the previous operation file (already executed) stays as it is.
        if (op.targets.length == 0) {
            console2.log(op.name, "nothing to schedule: everything in the config is already on chain");
            return;
        }
        _freshSalt(timelock, op);
        bytes32 id = _writeOperation(timelock, op);
        console2.log(op.name, vm.toString(id), _operationPath(op.name));
        if (vm.envOr("AVANA_SCHEDULE", false)) {
            uint256 delay = ITimelockOps(timelock).requiredDelay(op.targets, op.payloads);
            require(
                !short || delay == ITimelockOps(timelock).getMinDelay(),
                string.concat(op.name, " is not a short-delay operation")
            );
            vm.broadcast(safe);
            ITimelockOps(timelock).scheduleBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt, delay);
            console2.log("scheduled as the governance Safe", safe);
        }
    }

    // ─── setup ───

    function _setup(
        ChainInputs memory c
    ) private returns (Operation memory op) {
        op = _newOperation("listing-setup", release, 200);
        for (uint256 i = 0; i < c.integrations.length; ++i) {
            uint32 id = c.integrations[i].integrationId;
            uint256 n = c.integrations[i].positionManagers.length;
            // Recorded and finalized once per integration (the registry refuses a second record).
            if (registry.integrationContracts(id).length != 0) continue;
            address[] memory contracts = new address[](2 * n);
            for (uint256 j = 0; j < n; ++j) {
                (contracts[2 * j], contracts[2 * j + 1]) =
                (c.integrations[i].positionManagers[j], c.integrations[i].factories[j]);
            }
            // Uniswap v4: the PositionManager and its PoolManager; the Uniswap v3 factory of the reference pools is not
            // recorded (routes swap through its pools).
            if (isUniswapV4[id]) contracts[1] = IUniswapV4Reads(contracts[0]).poolManager();
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
        _listTokens(op);
        _listDebtAssets(op);
        _recordSpokes(op);
        _coverageAndLines(op);
    }

    /// @notice The pool tokens: feeds, `listToken`, then the settings that need a listed token.
    function _listTokens(
        Operation memory op
    ) private {
        uint256 n = _cfgCount(".listing.tokens");
        string[4] memory roles = ["primary", "alternate", "standby", "second"];
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("tokens", i);
            string memory sym = _str(string.concat(k, ".symbol"));
            if (registry.getToken(_token(sym)).listed) continue;
            _checkTokenBehaviour(_token(sym), sym);
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
            d.issuerProbe = _issuerProbe(k);
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
            bool listed = registry.getToken(t).listed;
            string[] memory hubs = vm.parseJsonStringArray(cfg, string.concat(k, ".hubs"));
            uint256 cap = vm.parseUint(_str(string.concat(k, ".tokenCapUsd"))) * 1e8;
            for (uint256 h = 0; h < hubs.length; ++h) {
                if (store.tokenUsdCap(_hub(hubs[h]), t) != 0) continue;
                _add(
                    op,
                    address(store),
                    abi.encodeCall(store.setInitialTokenCap, (_hub(hubs[h]), t, cap)),
                    "PS.setInitialTokenCap"
                );
            }
            if (listed) continue;
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
        }
    }

    /// @notice Debt assets that are no pool token are listed here: a fixed-price asset monitoring-only (its primary feed),
    /// any other with its three routes. A non-fixed asset gets its debt stress rise (`MKT-044`).
    function _listDebtAssets(
        Operation memory op
    ) private view {
        uint256 n = _cfgCount(".listing.debtAssets");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("debtAssets", i);
            string memory sym = _str(string.concat(k, ".symbol"));
            address asset = _token(sym);
            bool fixedPrice = _bool(string.concat(k, ".fixedPrice"));
            if (bytes(_tokenKey(asset)).length == 0 && !registry.getToken(asset).listed) {
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
            if (!fixedPrice && store.debtStressRiseBps(asset) == 0) {
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
        uint256 n = _cfgCount(".listing.spokes");
        bytes32 standard = registry.STANDARD_SPOKE_IMPLEMENTATION().codehash;
        bytes32[] memory seen = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("spokes", i);
            string memory label = _str(string.concat(k, ".label"));
            if (registry.getSpoke(_spokeAddr(label)).approved) continue;
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

    /// @notice Each (Hub, debt asset) of the debt reserves: its First-Loss Reserve and the Hub's credit line, which bounds
    /// the CDP Spokes' draw caps on the asset.
    function _coverageAndLines(
        Operation memory op
    ) private view {
        string memory coverage = vm.readFile(_outputPath("coverage"));
        uint256 n = _cfgCount(".listing.debtReserves");
        for (uint256 i = 0; i < n; ++i) {
            if (!_firstOfPair(i)) continue;
            string memory k = _at("debtReserves", i);
            string memory sym = _str(string.concat(k, ".symbol"));
            string memory hubLabel = _hubOfSpoke(_str(string.concat(k, ".spoke")));
            address hub = _hub(hubLabel);
            address cs =
                vm.parseJsonAddress(coverage, string.concat("$['AvanaFirstLossReserve.", hubLabel, ".", sym, "']"));
            uint256 line = _debtAssetUint(sym, "creditLineWhole", ".listing");
            if (registry.firstLossReserveOf(hub, _token(sym)) != address(0)) {
                // A later release adds CDP Spokes whose draw caps the recorded line must still bound: raise it.
                (uint256 recorded,) = registry.creditLine(hub, _token(sym));
                if (recorded < line) {
                    _add(
                        op,
                        address(registry),
                        abi.encodeCall(registry.recordCreditLine, (hub, _token(sym), line)),
                        "MR.recordCreditLine"
                    );
                }
                continue;
            }
            _add(
                op,
                address(registry),
                abi.encodeCall(registry.setAvanaFirstLossReserve, (hub, _token(sym), cs)),
                "MR.setAvanaFirstLossReserve"
            );
            _add(
                op,
                address(registry),
                abi.encodeCall(registry.recordCreditLine, (hub, _token(sym), line)),
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

    /// @notice `listing.tokens[k].issuerProbe`: how the RiskModule watches the issuer (`PausedFlag` for a pausable token
    /// such as USDC, `UsdtFeeRate` or `UsdtFeeRateAndPaused` for USDT's fee switch); `None` when absent.
    function _issuerProbe(
        string memory k
    ) private view returns (IssuerProbe) {
        string memory kk = string.concat(k, ".issuerProbe");
        if (!vm.keyExistsJson(cfg, kk)) return IssuerProbe.None;
        bytes32 p = keccak256(bytes(_str(kk)));
        if (p == keccak256("None")) return IssuerProbe.None;
        if (p == keccak256("PausedFlag")) return IssuerProbe.PausedFlag;
        if (p == keccak256("UsdtFeeRate")) return IssuerProbe.UsdtFeeRate;
        if (p == keccak256("UsdtFeeRateAndPaused")) return IssuerProbe.UsdtFeeRateAndPaused;
        revert(string.concat(k, ".issuerProbe: unknown probe ", _str(kk)));
    }

    /// @notice `REQ-ARCH-014` before a token is listed: it answers `decimals()`, a transfer delivers exactly the amount
    /// sent, and a balance does not change without a transfer. A fee-on-transfer, rebasing or decimals-less token
    /// stops the step before anything is scheduled. Runs on a snapshot of the chain, reverted afterwards.
    function _checkTokenBehaviour(
        address t,
        string memory sym
    ) private {
        uint256 snap = vm.snapshotState();
        string memory why;
        try new TokenProbe().check(t) {}
        catch Error(string memory reason) {
            // forge's storage cheat fails when the balance is not the stored value (rebasing or share-based).
            why = vm.contains(reason, "stdStorage")
                ? "a balance does not follow its storage (a rebasing or share-based token)"
                : reason;
        } catch {
            why = "the transfer probe reverted";
        }
        vm.revertToState(snap);
        if (bytes(why).length != 0) revert(string.concat(sym, " cannot be listed (REQ-ARCH-014): ", why));
    }

    // ─── oracles ───

    function _oracles() private {
        uint256 n = _cfgCount(".listing.debtAssets");
        string memory o = "oracles";
        string memory json = _keepOutput(o, "listing-oracles");
        vm.startBroadcast(deployerOf());
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("debtAssets", i);
            string memory sym = _str(string.concat(k, ".symbol"));
            address source = _recorded("listing-oracles", string.concat(".", sym));
            if (source != address(0)) {
                console2.log("price source", sym, source, "(deployed earlier)");
                continue;
            }
            if (_bool(string.concat(k, ".fixedPrice"))) {
                source = _deploy(
                    string.concat("FixedPriceSource.", sym), _artifact("FixedPriceSource.sol", "FixedPriceSource")
                );
            } else {
                // Aave reads the asset's own Chainlink USD feed: its one-leg primary route in the registry.
                (address[] memory primary,,) = registry.activePriceRoutes(_token(sym));
                require(primary.length == 1, string.concat(sym, ": a debt asset needs a one-leg USD feed"));
                source = primary[0];
            }
            json = vm.serializeAddress(o, sym, source);
            console2.log("price source", sym, source);
        }
        vm.stopBroadcast();
        if (bytes(json).length != 0) vm.writeJson(json, _outputPath("listing-oracles"));
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
        // address(0) for Uniswap v4, whose market is keyed by `poolId`.
        address pool;
        bytes32 poolId;
        address token0;
        address token1;
        PositionShape shape;
        bytes integrationData;
        address lpVault;
        uint8 decimals;
        uint8 unitExp;
        address lpOracle;
        address vaultToken;
        address debtAsset;
        // A cancelled market relisted under its reserved ID.
        bool relisting;
    }

    /// @return op The listing batch.
    /// @return starts The index in `op` of each new market's first call; the calls before the first are the routes of
    /// listed markets and the debt reserves.
    function _markets() private returns (Operation memory op, uint256[] memory starts) {
        op = _newOperation("listing-markets", release, 400);
        uint256 first = registry.marketCount() + 1;
        uint256 n = _cfgCount(".listing.markets");
        starts = new uint256[](n);
        uint256 newMarkets;
        IVaultTokenFactory f = IVaultTokenFactory(vm.parseJsonAddress(avanaJson, ".vaultTokenFactory"));
        // Routes the config adds to listed markets come first: enabling a debt reserve on a Spoke requires every live
        // market of that Spoke to have its primary and backup routes into the asset (REQ-MREG-032).
        for (uint256 i = 0; i < n; ++i) {
            uint256 listed = registry.marketOfKey(_marketKeyOf(f, i));
            if (listed == 0) continue;
            console2.log("market listed already:", _str(string.concat(_at("markets", i), ".name")), listed);
            Mkt memory old;
            (old.key, old.marketId) = (_at("markets", i), listed);
            old.spokeLabel = _str(string.concat(old.key, ".spoke"));
            _routes(op, old);
        }
        _enableDebtReserves(op);
        string memory out = "markets";
        string memory json = _keepOutput(out, "listing-markets");
        uint256 next = first;
        for (uint256 i = 0; i < n; ++i) {
            // A market already listed (any status but Cancelled) keeps its ID; the new ones take the next IDs in
            // config order, as the registry requires.
            bytes32 marketKey = _marketKeyOf(f, i);
            if (registry.marketOfKey(marketKey) != 0) continue;
            // A cancelled market of this (Spoke, market key) is relisted under its reserved ID with the vault token
            // and LPOracle of its first listing (REQ-MREG-030): the factory writes a token once per pair.
            address token = f.tokenOf(_spokeAddr(_str(string.concat(_at("markets", i), ".spoke"))), marketKey);
            Mkt memory m = token == address(0) ? _market(i, next++, address(0)) : _market(i, 0, token);
            _checkCollateralFactor(m);
            if (token == address(0)) {
                _deployLpOracle(m);
                m.vaultToken = f.predictAddress(m.spoke, marketKey);
            } else {
                console2.log("relisting cancelled market", m.marketId, m.vaultToken);
            }
            starts[newMarkets++] = op.targets.length;
            address[] memory routes = _listMarket(op, m, f, token == address(0));
            json = vm.serializeString(out, string.concat("market", vm.toString(m.marketId)), _marketJson(m, routes));
        }
        assembly ("memory-safe") {
            mstore(starts, newMarkets)
        }
        if (op.targets.length != 0) op.salt = _listingMetadataHash(first);
        // A listing with calls but no market (debt assets only) has no market entry to record.
        if (op.targets.length != 0 && bytes(json).length != 0) vm.writeJson(json, _outputPath("listing-markets"));
    }

    // ─── listing batch gas ───

    /// @notice Gas the timelock spends per call of a batch beyond the call itself (the loop, the cold call, the
    /// payload copy and the `CallExecuted` event), the price of a calldata byte, and a transaction's base cost.
    uint256 internal constant PER_CALL_GAS = 12_000;
    uint256 internal constant CALLDATA_GAS_PER_BYTE = 16;
    uint256 internal constant TX_BASE_GAS = 21_000;
    /// @notice Default execution gas budget of one timelock operation: about five markets on Ethereum, well inside a
    /// block. `.chain.operationGasBudget` in the network config sets a chain's own; `AVANA_OPERATION_GAS_BUDGET`
    /// overrides both.
    uint256 internal constant DEFAULT_OPERATION_GAS_BUDGET = 40_000_000;

    function _operationGasBudget() internal view returns (uint256) {
        uint256 budget = vm.keyExistsJson(cfg, ".chain.operationGasBudget")
            ? vm.parseJsonUint(cfg, ".chain.operationGasBudget")
            : DEFAULT_OPERATION_GAS_BUDGET;
        return vm.envOr("AVANA_OPERATION_GAS_BUDGET", budget);
    }

    /// @notice Schedules a listing batch as one or more operations, each estimated to execute within the chain's
    /// budget (`_operationGasBudget`). The batch is cut only at the group starts in `starts`: for `listing-markets`
    /// between any two of the calls before the first new market (the routes of listed markets and the debt reserves)
    /// and between markets, each market's calls staying together (`_leadingCallsApart`); for `listing-setup` between
    /// any two calls (`_everyCall`), since the parts run in order. Part 1 keeps the batch's name; part k is `<name>.<k>` and names part k-1 as its predecessor, so the
    /// parts execute in order (`05_ExecuteOperations` follows them). The last part carries the batch's salt (for
    /// `listing-markets` the listing metadata salt, so the pages load once every market of the listing is on chain);
    /// the others' salts derive from it.
    function _proposeInParts(
        Operation memory op,
        uint256[] memory starts
    ) private {
        if (op.targets.length == 0) {
            _propose(op, false);
            return;
        }
        uint256[] memory gas = _simulatedGas(op);
        uint256 budget = _operationGasBudget();
        uint256[] memory cuts = _cuts(op, starts, gas, budget);
        uint256 parts = cuts.length - 1;
        bytes32 previous;
        for (uint256 k = 0; k < parts; ++k) {
            Operation memory part = _part(op, gas, cuts[k], cuts[k + 1], k, parts);
            part.predecessor = previous;
            console2.log(part.name, "calls", part.targets.length);
            console2.log("  estimated execution gas", part.gasEstimate, "budget", budget);
            _propose(part, false);
            previous = _operationId(timelock, part);
        }
        if (parts > 1) console2.log(string.concat(op.name, " split in"), parts, "operations, executed in order");
    }

    /// @notice Group starts that let `_cuts` cut a batch of `n` calls between any two calls: one group per call.
    function _everyCall(
        uint256 n
    ) private pure returns (uint256[] memory starts) {
        starts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            starts[i] = i;
        }
    }

    /// @notice Group starts for `listing-markets`: each call before the first new market (the routes of listed
    /// markets, then the debt reserves) is a group of its own, since those calls only need to run in order, and each
    /// new market's calls are one group (`marketStarts`, the index of each new market's first call). Kept with the
    /// first market, those calls can need more gas than one operation may use.
    function _leadingCallsApart(
        uint256[] memory marketStarts,
        uint256 n
    ) private pure returns (uint256[] memory starts) {
        uint256 leading = marketStarts.length == 0 ? n : marketStarts[0];
        starts = new uint256[](leading + marketStarts.length);
        for (uint256 i = 0; i < leading; ++i) {
            starts[i] = i;
        }
        for (uint256 j = 0; j < marketStarts.length; ++j) {
            starts[leading + j] = marketStarts[j];
        }
    }

    /// @notice Where the batch is cut: `cuts[k]` is the first call of part k and the last entry is the batch length.
    /// Groups are [0, starts[1]), then [starts[g], starts[g + 1]) for each later group; a group goes into the current
    /// part unless that takes the part over `budget`.
    function _cuts(
        Operation memory op,
        uint256[] memory starts,
        uint256[] memory gas,
        uint256 budget
    ) private pure returns (uint256[] memory cuts) {
        uint256 groups = starts.length == 0 ? 1 : starts.length;
        cuts = new uint256[](groups + 1);
        uint256 parts;
        uint256 partGas = TX_BASE_GAS;
        for (uint256 g = 0; g < groups; ++g) {
            uint256 from = g == 0 ? 0 : starts[g];
            uint256 to = g + 1 < groups ? starts[g + 1] : op.targets.length;
            uint256 groupGas;
            for (uint256 i = from; i < to; ++i) {
                groupGas += gas[i];
            }
            require(
                TX_BASE_GAS + groupGas <= budget,
                string.concat(
                    op.name,
                    ": the calls from ",
                    op.labels[from],
                    " need about ",
                    vm.toString(groupGas),
                    " gas, above the operation budget ",
                    vm.toString(budget)
                )
            );
            if (g != 0 && partGas + groupGas > budget) {
                cuts[++parts] = from;
                partGas = TX_BASE_GAS;
            }
            partGas += groupGas;
        }
        cuts[++parts] = op.targets.length;
        assembly ("memory-safe") {
            mstore(cuts, add(parts, 1))
        }
    }

    /// @notice Part `k` of `parts`: calls [from, to) of the batch with their gas estimate. Part 1 keeps the batch's
    /// name and part k is `<name>.<k>`; the last part keeps the batch's salt and the others' derive from it.
    function _part(
        Operation memory op,
        uint256[] memory gas,
        uint256 from,
        uint256 to,
        uint256 k,
        uint256 parts
    ) private view returns (Operation memory part) {
        part = _newOperation(k == 0 ? op.name : string.concat(op.name, ".", vm.toString(k + 1)), release, to - from);
        part.gasEstimate = TX_BASE_GAS;
        for (uint256 i = from; i < to; ++i) {
            _add(part, op.targets[i], op.payloads[i], op.labels[i]);
            part.values[i - from] = op.values[i];
            part.gasEstimate += gas[i];
        }
        part.salt = k + 1 == parts ? op.salt : keccak256(abi.encode(op.salt, "part", k + 1));
    }

    /// @notice Each call's estimated execution gas inside `executeBatch`: the call itself, made in order as the
    /// timelock on a snapshot of the chain that is reverted afterwards, plus the timelock's per-call cost and its
    /// calldata. A call that reverts stops the step, since it would revert at execution, after the delay.
    function _simulatedGas(
        Operation memory op
    ) private returns (uint256[] memory gas) {
        gas = new uint256[](op.targets.length);
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < op.targets.length; ++i) {
            vm.prank(timelock);
            uint256 before = gasleft();
            (bool ok, bytes memory ret) = op.targets[i].call{value: op.values[i]}(op.payloads[i]);
            uint256 used = before - gasleft();
            if (!ok) {
                // The call's own revert data, which forge decodes (a custom error by name), after the call's label.
                console2.log(
                    string.concat(op.name, ": this call reverts when simulated, so it would at execution:"),
                    op.labels[i]
                );
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            // A payload costs its bytes plus its offset, length, target and value words in the batch's calldata.
            gas[i] = used + PER_CALL_GAS + CALLDATA_GAS_PER_BYTE * (op.payloads[i].length + 4 * 32);
        }
        vm.revertToState(snap);
    }

    /// @notice Refuses a market whose `collateralFactorBps` (the vault token's Aave collateral factor, set by step 10's
    /// AIP) is above `SPEC-CF-001`'s bound, min(token collateral factors) x `poolRiskFactorBps` / 1e4. Activation
    /// would fail `CollateralFactorAboveExpected` after both timelock delays; the step fails before scheduling instead.
    function _checkCollateralFactor(
        Mkt memory m
    ) private view {
        uint256 c0 = store.tokenCollateralFactorBps(m.token0);
        uint256 c1 = store.tokenCollateralFactorBps(m.token1);
        uint256 bound = ((c0 < c1 ? c0 : c1) * _uint(string.concat(m.key, ".poolRiskFactorBps"))) / 1e4;
        uint256 cf = _uint(string.concat(m.key, ".collateralFactorBps"));
        require(
            cf <= bound,
            string.concat(
                _str(string.concat(m.key, ".name")),
                ": collateralFactorBps ",
                vm.toString(cf),
                " is above min(token collateral factors) x poolRiskFactorBps = ",
                vm.toString(bound)
            )
        );
    }

    /// @notice The VaultTokenFactory market key of config market `i`: integration, pool (or v4 pool ID) and position
    /// shape.
    function _marketKeyOf(
        IVaultTokenFactory f,
        uint256 i
    ) private view returns (bytes32) {
        string memory key = _at("markets", i);
        (address pool, bytes32 poolId) = _poolOf(key);
        return f.marketKeyOf(uint32(_uint(string.concat(key, ".integrationId"))), pool, poolId, _shapeOf(key));
    }

    /// @notice The pool of a config market: its address, or for Uniswap v4 address(0) and the pool key's ID.
    function _poolOf(
        string memory key
    ) private view returns (address pool, bytes32 poolId) {
        string memory name = _str(string.concat(key, ".pool"));
        if (!_isV4Market(key)) return (_pool(name), bytes32(0));
        return (address(0), keccak256(abi.encode(_v4Key(name))));
    }

    function _isV4Market(
        string memory key
    ) private view returns (bool) {
        return isUniswapV4[uint32(_uint(string.concat(key, ".integrationId")))];
    }

    /// @notice The hookless pool key of `listing.uniswapV4Pools[name]` (currencies sorted, address(0) for native ETH).
    function _v4Key(
        string memory name
    ) private view returns (UniswapV4PoolKey memory k) {
        string memory p = string.concat(".listing.uniswapV4Pools['", name, "']");
        k.currency0 = _addr(cfg, string.concat(p, ".currency0"));
        k.currency1 = _addr(cfg, string.concat(p, ".currency1"));
        k.fee = uint24(_uint(string.concat(p, ".fee")));
        k.tickSpacing = int24(vm.parseJsonInt(cfg, string.concat(p, ".tickSpacing")));
        require(k.currency0 < k.currency1, string.concat("uniswapV4Pools currencies not sorted: ", name));
    }

    /// @notice The Uniswap v3 reference pool of `listing.uniswapV4Pools[name]` (same pair, native ETH as WETH).
    function _v4ReferencePool(
        string memory name
    ) private view returns (address) {
        return _addr(cfg, string.concat(".listing.uniswapV4Pools['", name, "'].referencePool"));
    }

    /// @notice The position shape of a config market: its tick range, or the pool's full range when both are 0.
    function _shapeOf(
        string memory key
    ) private view returns (PositionShape memory) {
        int24 lower = int24(vm.parseJsonInt(cfg, string.concat(key, ".tickLower")));
        int24 upper = int24(vm.parseJsonInt(cfg, string.concat(key, ".tickUpper")));
        if (lower == 0 && upper == 0) {
            int24 sp = _tickSpacingOf(key);
            upper = (887_272 / sp) * sp;
            lower = -upper;
        }
        return PositionShape(ShapeKind.TickRange, lower, upper);
    }

    function _tickSpacingOf(
        string memory key
    ) private view returns (int24) {
        string memory name = _str(string.concat(key, ".pool"));
        return _isV4Market(key) ? _v4Key(name).tickSpacing : IPoolTokens(_pool(name)).tickSpacing();
    }

    /// @notice The listing's timelock salt: keccak256 of the listing metadata file `09-market-metadata` wrote
    /// (`script/deploy/market-metadata.ts`), the pages this listing adds. Convex loads the file by that hash once the
    /// operation executes and refuses one whose bytes hash otherwise. The file must be for this chain and for the market
    /// IDs this listing gives, the ones after `marketCount()`.
    function _listingMetadataHash(
        uint256 firstMarketId
    ) private view returns (bytes32 hash) {
        string memory pointer = vm.readFile(_outputPath("listing-metadata"));
        require(vm.parseJsonUint(pointer, ".chainId") == block.chainid, "listing metadata is for another chain");
        require(
            vm.parseJsonUint(pointer, ".firstMarketId") == firstMarketId,
            "listing metadata names other market IDs: rerun 09-market-metadata"
        );
        // No new market or debt reserve (new routes only): no pages; the salt names the release, the next market ID and
        // the time, so two such operations never share an ID.
        if (vm.parseJsonUint(pointer, ".entries") == 0) {
            return keccak256(
                bytes(
                    string.concat(
                        "avana.",
                        release,
                        ".operation.listing-markets.",
                        vm.toString(firstMarketId),
                        ".",
                        vm.toString(block.timestamp)
                    )
                )
            );
        }
        hash = vm.parseJsonBytes32(pointer, ".hash");
        string memory file = string.concat(
            vm.projectRoot(), "/", OUTPUT_DIR, "/", _network(), "/", vm.parseJsonString(pointer, ".file")
        );
        require(keccak256(vm.readFileBinary(file)) == hash, "listing metadata file does not hash to its name");
    }

    /// @param vaultToken The vault token of a cancelled market being relisted (its ID, LPOracle and decimals are the
    /// first listing's), or `address(0)` for a new market with ID `marketId`.
    function _market(
        uint256 i,
        uint256 marketId,
        address vaultToken
    ) private returns (Mkt memory m) {
        m.key = _at("markets", i);
        m.marketId = vaultToken == address(0) ? marketId : IRelistedToken(vaultToken).marketId();
        m.integrationId = uint32(_uint(string.concat(m.key, ".integrationId")));
        m.spokeLabel = _str(string.concat(m.key, ".spoke"));
        m.spoke = _spokeAddr(m.spokeLabel);
        m.hub = _hub(_hubOfSpoke(m.spokeLabel));
        m.lpVault = vm.parseJsonAddressArray(avanaJson, ".lpVaults")[_integrationIndex(m.integrationId)];
        (m.pool, m.poolId) = _poolOf(m.key);
        (m.token0, m.token1) = _tokensOf(m);
        m.shape = _shapeOf(m.key);
        m.integrationData = _integrationData(m);
        m.debtAsset = _debtAssetOf(m.spokeLabel);
        if (vaultToken != address(0)) {
            // A relisting: the integration keeps the reserved ID's binding, which listCollateralMarket checks.
            (m.vaultToken, m.lpOracle, m.relisting) = (vaultToken, IRelistedToken(vaultToken).lpOracle(), true);
            m.decimals = IRelistedToken(vaultToken).decimals();
            m.unitExp = IClIntegration(m.lpVault).unitExponent(m.marketId);
            return m;
        }
        // The vault-token decimals `d` and the pool's unit exponent `k` the LPVault's `bindMarket` derives inside
        // `listCollateralMarket`, read by a simulated binding that is reverted: `deployVaultToken` earlier in the batch
        // must name the same `d`, and the market's LPOracle the same `k` (SPEC-ORC-005, `CL_CHECK_UNIT_EXP`).
        uint256 snap = vm.snapshotState();
        vm.prank(address(registry));
        (, m.decimals) = ILPVault(m.lpVault).bindMarket(m.marketId, m.pool, m.poolId, m.shape, m.integrationData);
        m.unitExp = IClIntegration(m.lpVault).unitExponent(m.marketId);
        vm.revertToState(snap);
    }

    /// @notice The market's two tokens in pool order: the pool's, or a v4 key's currencies with native ETH as the
    /// LPVault's wrapped native token.
    function _tokensOf(
        Mkt memory m
    ) private view returns (address, address) {
        if (m.poolId == bytes32(0)) return (IPoolTokens(m.pool).token0(), IPoolTokens(m.pool).token1());
        UniswapV4PoolKey memory k = _v4Key(_str(string.concat(m.key, ".pool")));
        address c0 = k.currency0 == address(0) ? IUniswapV4Reads(m.lpVault).wrappedNative() : k.currency0;
        return (c0, k.currency1);
    }

    /// @notice `bindMarket`'s integration data, with the 8-decimal listing prices in the market's token order: Uniswap
    /// v3 `(price0, price1)`, Slipstream `(generation, price0, price1)`, Uniswap v4
    /// `(key, referencePool, price0, price1)`.
    function _integrationData(
        Mkt memory m
    ) private view returns (bytes memory) {
        (uint256 p0, uint256 p1) = (_price8(m.token0), _price8(m.token1));
        if (isSlipstream[m.integrationId]) return abi.encode(_uint(string.concat(m.key, ".generation")), p0, p1);
        if (m.poolId == bytes32(0)) return abi.encode(p0, p1);
        string memory name = _str(string.concat(m.key, ".pool"));
        return abi.encode(_v4Key(name), _v4ReferencePool(name), p0, p1);
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
        uint256 n = _cfgCount(".listing.debtReserves");
        for (uint256 i = 0; i < n; ++i) {
            if (_eq(_str(string.concat(_at("debtReserves", i), ".spoke")), spokeLabel)) {
                return _token(_str(string.concat(_at("debtReserves", i), ".symbol")));
            }
        }
        revert(string.concat("no debt reserve for ", spokeLabel));
    }

    /// @notice `MKT-019`: the market's stateless LPOracle, valuing its vault token from each token's primary Chainlink
    /// route and the LPVault's composition.
    function _deployLpOracle(
        Mkt memory m
    ) private {
        address[2] memory toks = [m.token0, m.token1];
        ILPOracle.TokenRoute[] memory routes = new ILPOracle.TokenRoute[](2);
        for (uint256 i = 0; i < 2; ++i) {
            (address[] memory primary,,) = registry.activePriceRoutes(toks[i]);
            routes[i] = ILPOracle.TokenRoute({
                token: toks[i], isUsdStable: _bool(string.concat(_tokenKey(toks[i]), ".isUsdStable")), feeds: primary
            });
        }
        ILPOracle.Params memory p = ILPOracle.Params({
            marketId: m.marketId,
            integration: m.lpVault,
            parameterStore: address(store),
            description: _str(string.concat(m.key, ".name")),
            vaultDecimals: m.decimals,
            routes: routes
        });
        vm.broadcast(deployerOf());
        m.lpOracle = _deploy(
            string.concat("LPOracle.", vm.toString(m.marketId)),
            bytes.concat(type(LPOracle).creationCode, abi.encode(p))
        );
        console2.log("LPOracle", m.marketId, m.lpOracle);
    }

    /// @notice The LPOracle's `market`: `abi.encode(pool, tickLower, tickUpper, k)`, or for Uniswap v4
    /// `abi.encode(poolManager, key, tickLower, tickUpper, k, referencePool)`; k is the pool's unit exponent
    /// (SPEC-ORC-005).
    function _oracleMarket(
        Mkt memory m
    ) private view returns (bytes memory) {
        if (m.poolId == bytes32(0)) {
            return abi.encode(m.pool, m.shape.tickLower, m.shape.tickUpper, uint256(m.unitExp));
        }
        string memory name = _str(string.concat(m.key, ".pool"));
        return abi.encode(
            IUniswapV4Reads(m.lpVault).POOL_MANAGER(),
            _v4Key(name),
            m.shape.tickLower,
            m.shape.tickUpper,
            uint256(m.unitExp),
            _v4ReferencePool(name)
        );
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
    /// reserve of a (Hub, asset), its borrow-speed limit (written after the reserve exists, `UnknownDebtReserve`
    /// otherwise).
    function _enableDebtReserves(
        Operation memory op
    ) private view {
        string memory sources = vm.readFile(_outputPath("listing-oracles"));
        string memory coverage = vm.readFile(_outputPath("coverage"));
        uint256 n = _cfgCount(".listing.debtReserves");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = _at("debtReserves", i);
            string memory sym = _str(string.concat(k, ".symbol"));
            string memory spokeLabel = _str(string.concat(k, ".spoke"));
            DebtReserveDef memory d;
            d.asset = _token(sym);
            (d.fundingHub, d.hubAssetId, d.reserveId) = _reserveOf(spokeLabel, d.asset);
            if (registry.isApprovedDebtReserve(_spokeAddr(spokeLabel), d.reserveId)) continue;
            d.decimals = IDecimals(d.asset).decimals();
            d.priceSource = vm.parseJsonAddress(sources, string.concat(".", sym));
            d.fixedPrice = _debtAssetFixed(sym);
            d.firstLossReserve = vm.parseJsonAddress(
                coverage, string.concat("$['AvanaFirstLossReserve.", _hubOfSpoke(spokeLabel), ".", sym, "']")
            );
            d.approved = true;
            _add(
                op,
                address(registry),
                abi.encodeCall(registry.enableDebtReserve, (_spokeAddr(spokeLabel), d)),
                string.concat("MR.enableDebtReserve ", spokeLabel, " ", sym)
            );
            if (!_firstOfPair(i) || store.debtSpeedLimit(d.fundingHub, d.asset).window != 0) continue;
            uint256 unit = 10 ** d.decimals;
            SpeedLimit memory s = SpeedLimit({
                rateBps: uint16(_uint(".listing.speedLimits.debtRateBps")),
                window: uint32(_uint(".listing.speedLimits.window")),
                min: uint96(_debtAssetUint(sym, "debtMinWhole", ".listing.speedLimits") * unit),
                max: uint96(_debtAssetUint(sym, "debtMaxWhole", ".listing.speedLimits") * unit)
            });
            _add(
                op,
                address(store),
                abi.encodeCall(store.loosenDebtSpeedLimit, (d.fundingHub, d.asset, s)),
                "PS.loosenDebtSpeedLimit"
            );
        }
        uint256 a = _cfgCount(".listing.debtAssets");
        for (uint256 i = 0; i < a; ++i) {
            string memory k = _at("debtAssets", i);
            if (store.floorRoundingAllowance(_token(_str(string.concat(k, ".symbol")))) != 0) continue;
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

    /// @notice A whole-token amount of debt asset `sym`: its own `listing.debtAssets[].<field>` when set, else
    /// `<fallbackParent>.<field>`. The chain-wide credit line and (Hub, asset) speed-limit bounds count whole tokens, which
    /// a token priced far from $1 (a meme coin at $0.00001, WBTC at $95,000) overrides.
    function _debtAssetUint(
        string memory sym,
        string memory field,
        string memory fallbackParent
    ) private view returns (uint256) {
        uint256 a = _cfgCount(".listing.debtAssets");
        for (uint256 i = 0; i < a; ++i) {
            string memory k = _at("debtAssets", i);
            if (!_eq(_str(string.concat(k, ".symbol")), sym)) continue;
            string memory own = string.concat(k, ".", field);
            if (vm.keyExistsJson(cfg, own)) return _uint(own);
            break;
        }
        return _uint(string.concat(fallbackParent, ".", field));
    }

    function _debtAssetFixed(
        string memory sym
    ) private view returns (bool) {
        uint256 a = _cfgCount(".listing.debtAssets");
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
        IVaultTokenFactory f,
        bool deployToken
    ) private returns (address[] memory routes) {
        string memory id = vm.toString(m.marketId);
        if (deployToken) {
            _add(
                op,
                address(f),
                _vaultTokenCall(m, string.concat("Avana LP ", _str(string.concat(m.key, ".name")), " market ", id), id),
                "VTF.deployVaultToken"
            );
        }
        MarketDef memory d = MarketDef({
            hub: m.hub,
            spoke: m.spoke,
            integrationId: m.integrationId,
            pool: m.pool,
            poolId: m.poolId,
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
        // A relisted market kept its speed limits; loosening to the same values reverts NotLooser.
        if (keccak256(abi.encode(store.marketSpeedLimits(m.marketId))) != keccak256(abi.encode(_speedLimits()))) {
            _add(
                op,
                address(store),
                abi.encodeCall(store.loosenMarketSpeedLimits, (m.marketId, _speedLimits())),
                "PS.loosenMarketSpeedLimits"
            );
        }
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
                m.poolId,
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
        uint256 n = _cfgCount(string.concat(m.key, ".routes"));
        routes = new address[](2 * n);
        for (uint256 i = 0; i < n; ++i) {
            string memory rk = string.concat(m.key, ".routes[", vm.toString(i), "]");
            address tokenIn = _token(_str(string.concat(rk, ".token")));
            address asset = _token(_str(string.concat(rk, ".asset")));
            for (uint8 kind = 0; kind < 2; ++kind) {
                (address existing,) = registry.getRoute(m.marketId, tokenIn, asset, kind);
                // A relisting starts a new route epoch (REQ-MREG-030): the cancelled registration's routes are set
                // again, the deployed route contracts reused.
                if (existing != address(0) && !m.relisting) {
                    routes[2 * i + kind] = existing;
                    _depthThreshold(op, m.marketId, rk, tokenIn, asset, kind);
                    continue;
                }
                address route = existing != address(0)
                    ? existing
                    : _deployRoute(
                        m,
                        tokenIn,
                        asset,
                        vm.parseJsonStringArray(cfg, string.concat(rk, kind == 0 ? ".primary" : ".backup"))
                    );
                routes[2 * i + kind] = route;
                _add(
                    op,
                    address(registry),
                    abi.encodeCall(registry.setRoute, (m.marketId, tokenIn, asset, kind, route)),
                    "MR.setRoute"
                );
                _depthThreshold(op, m.marketId, rk, tokenIn, asset, kind);
            }
        }
    }

    /// @notice The depth threshold of one route slot (`REQ-ROUTE-006`, `REQ-CONFIG-070`), set in the listing batch by
    /// `tightenRouteDepthThreshold` after the market's `setInitialMarketParams`. The route's `depthThreshold` (and, for the
    /// backup, `backupDepthThreshold` when given) is in whole units of the debt asset and is stored in its base units: a
    /// GHO threshold of 2000000 is 2,000,000 × 10^18. A slot already at or above that value is left as it is (a relisting or
    /// a rerun); a lower one is `loosenRouteDepthThreshold` at the normal delay, outside the listing. A route without a
    /// threshold is refused, except on the local anvil network, where the monitor then reports the slot as `noThreshold`.
    function _depthThreshold(
        Operation memory op,
        uint256 marketId,
        string memory rk,
        address tokenIn,
        address asset,
        uint8 kind
    ) private view {
        string memory backupKey = string.concat(rk, ".backupDepthThreshold");
        string memory key =
            kind == 1 && vm.keyExistsJson(cfg, backupKey) ? backupKey : string.concat(rk, ".depthThreshold");
        if (!vm.keyExistsJson(cfg, key)) {
            require(_isLocalChain(block.chainid), string.concat("route without depthThreshold: ", rk));
            return;
        }
        uint256 value = _uint(key) * 10 ** IDecimals(asset).decimals();
        require(value > 0, string.concat("route depthThreshold is 0: ", rk));
        if (store.routeDepthThreshold(marketId, tokenIn, asset, kind) >= value) return;
        _add(
            op,
            address(store),
            abi.encodeCall(store.tightenRouteDepthThreshold, (marketId, tokenIn, asset, kind, value)),
            "PS.tightenRouteDepthThreshold"
        );
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
        rc.uniswapV3Factory = _cfgAddr(".listing.uniswapV3Factory");
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
        vm.serializeBytes32(k, "poolId", m.poolId);
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
        IVaultTokenFactory f = IVaultTokenFactory(vm.parseJsonAddress(avanaJson, ".vaultTokenFactory"));
        uint256 n = _cfgCount(".listing.markets");
        op = _newOperation("listing-activate", release, n);
        // The config's markets that are listed and still Registered: each LPOracle poked Live, then `activateMarket`.
        uint256[] memory ids = new uint256[](n);
        uint256 k;
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = registry.marketOfKey(_marketKeyOf(f, i));
            if (id != 0 && registry.getMarket(id).status == MarketStatus.Registered) ids[k++] = id;
        }
        for (uint256 i = 0; i < k; ++i) {
            _add(op, address(registry), abi.encodeCall(registry.activateMarket, (ids[i])), "MR.activateMarket");
        }
    }
}

interface IDecimals {
    function decimals() external view returns (uint8);
}
