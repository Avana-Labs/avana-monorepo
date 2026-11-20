// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../src/amm/concentrated-liquidity/ClTickMath.sol";
import {IUniswapV4Integration} from "../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAggregatorV3} from "../../src/interfaces/external/chainlink/IAggregatorV3.sol";
import {UniswapV4PoolKey} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {IUniswapV4PositionManager} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PositionManager.sol";
import {IUniswapV3Pool} from "../../src/interfaces/external/uniswap/IUniswapV3Pool.sol";
import {ILPOracle} from "../../src/oracle/ILPOracle.sol";
import {LPPriceMath} from "../../src/oracle/LPPriceMath.sol";
import {IRiskModule} from "../../src/policy/risk-module/IRiskModule.sol";
import {IVaultToken} from "../../src/vault-token/IVaultToken.sol";
import {IAaveExecutor} from "./lib/AavePayloads.sol";
import {AccessOperations, IAccessManagerOps} from "./lib/AccessOperations.sol";
import {AvanaAccess} from "./lib/AvanaAccess.sol";
import {CoreRecord} from "./lib/CoreRecord.sol";
import {CoreStack} from "./lib/DeployTypes.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/console2.sol";

/// @title ListMarkets
/// @notice Step 9: Avana's side of every listing, by `AVANA_LISTING_STEP`. Every pool of `listing.markets` becomes two
/// ERC-20 markets with the same LTV and a band fixed for life: Full range (the pool's lowest and highest usable ticks)
/// and Custom range (the Spoke kind's width around the listing price: Stable ±1%, Correlated ±5%, Volatile 0.345x to
/// 2.898x; the RiskModule's defaults).
/// - `setup`: the operation `listing-setup` for the governance Safe: each CDP Spoke of `listing.spokes` registered on
///   its integration's RiskModule with its kind, each debt reserve of `listing.debtReserves` with its Avana First-Loss
///   Reserve (`coverage.json`), the fee (`parameters.globals`), the coverage ratio (`parameters.coverageRatioBps`) and
///   the keepers.
/// - `markets`: the operation `listing-markets`: `listPool` for each pool not listed yet, at the listing tick of the
///   tokens' Chainlink prices now and the LTV of the lower of the two tokens' `collateralFactorBps` (a market's
///   `eModeLtvBps` overrides it for a correlated pair). A Uniswap v4 pool is registered on its LPVault first.
/// - `vault-tokens`: each listed market's VaultToken (decimals the RiskModule chose at listing) and LPOracle (the same
///   feeds), deployed by 03's deployer, and the operation `vault-token-roles` the DAO sends at once as the manager's
///   admin: each token's `mint` and `addValidProxy` to its integration's adapter role and `burn` to its burn role.
///   Writes `deployments-local/<network>/markets.json`, which `10_AaveListingPayload` lists on Aave.
/// - `activate`: the operation `listing-activate`: `activateMarket` for each market not active yet, once Aave lists its
///   vault token with its LPOracle as price source.
/// @dev The governance operations are written for the Safe (`AccessOperations`) and, on anvil with `AVANA_SCHEDULE`,
/// scheduled as the Safe; `05_ExecuteOperations` executes them once the governance delay has passed. A rerun proposes
/// only what is not on chain yet.
contract ListMarkets is AccessOperations, CoreRecord {
    uint256 internal constant OP_CAPACITY = 512;

    string internal cfg;
    address internal manager;
    address internal safe;

    /// @dev One `listing.markets` entry, resolved.
    struct Pool {
        string name;
        uint32 integrationId;
        CoreStack stack;
        address spoke;
        address hub;
        bytes32 id;
        int24 tickSpacing;
        address token0;
        address token1;
        uint256 t0;
        uint256 t1;
        // A Uniswap v4 key to register first; `tickSpacing == 0` for other pools.
        UniswapV4PoolKey v4Key;
    }

    function run() external {
        cfg = vm.readFile(_configPath(_network()));
        manager = _accessManager();
        safe = _addr(cfg, ".governance.governanceSafe");
        string memory step = vm.envOr("AVANA_LISTING_STEP", string(""));
        if (_eq(step, "setup")) _setup();
        else if (_eq(step, "markets")) _markets();
        else if (_eq(step, "vault-tokens")) _vaultTokens();
        else if (_eq(step, "activate")) _activate();
        else revert(string.concat("AVANA_LISTING_STEP ", step, ": setup, markets, vault-tokens or activate"));
    }

    // ─── setup ───

    function _setup() private {
        Operation memory op = _newOperation("listing-setup", OP_CAPACITY);
        uint256 nSpokes = _count(cfg, ".listing.spokes");
        for (uint256 i = 0; i < nSpokes; ++i) {
            string memory k = string.concat(".listing.spokes[", vm.toString(i), "]");
            uint32 integrationId = uint32(vm.parseJsonUint(cfg, string.concat(k, ".integrationId")));
            address spoke = _addr(cfg, string.concat(k, ".spoke"));
            address hub = _hubOf(cfg, vm.parseJsonString(cfg, string.concat(k, ".hub")));
            uint8 tier = uint8(vm.parseJsonUint(cfg, string.concat(k, ".tier")));
            require(tier >= 1 && tier <= 3, "listing.spokes tier: 1 Stable, 2 Correlated, 3 Volatile");
            IRiskModule rm = IRiskModule(_stackOf(integrationId).riskModule);
            if (rm.getSpoke(spoke).kind != IRiskModule.SpokeKind.None) continue;
            _add(
                op,
                address(rm),
                abi.encodeCall(IRiskModule.registerSpoke, (spoke, hub, IRiskModule.SpokeKind(tier))),
                string.concat("registerSpoke ", vm.parseJsonString(cfg, string.concat(k, ".label")))
            );
        }
        _debtReserves(op);
        CoreStack[] memory stacks = _stacks();
        uint256 shareBps = vm.parseJsonUint(cfg, ".parameters.globals.avanaFeeShareBps");
        address recipient = _addr(cfg, ".parameters.globals.feeRecipient");
        uint256 ratioBps = vm.parseJsonUint(cfg, ".parameters.coverageRatioBps");
        address[] memory keepers = _addrs(cfg, ".keepers");
        for (uint256 s = 0; s < stacks.length; ++s) {
            IRiskModule rm = IRiskModule(stacks[s].riskModule);
            string memory tag = string.concat(" (integration ", vm.toString(stacks[s].integrationId), ")");
            if (rm.feeShareBps() != shareBps || rm.feeRecipient() != recipient) {
                _add(
                    op,
                    address(rm),
                    abi.encodeCall(IRiskModule.setFee, (shareBps, recipient)),
                    string.concat("setFee", tag)
                );
            }
            if (rm.coverageRatioBps() != ratioBps) {
                _add(
                    op,
                    address(rm),
                    abi.encodeCall(IRiskModule.setCoverageRatio, (ratioBps)),
                    string.concat("setCoverageRatio", tag)
                );
            }
            for (uint256 i = 0; i < keepers.length; ++i) {
                if (rm.isKeeper(keepers[i])) continue;
                _add(
                    op,
                    address(rm),
                    abi.encodeCall(IRiskModule.addKeeper, (keepers[i])),
                    string.concat("addKeeper", tag)
                );
            }
        }
        _scheduleAs(manager, op, safe);
    }

    function _debtReserves(
        Operation memory op
    ) private view {
        uint256 n = _count(cfg, ".listing.debtReserves");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".listing.debtReserves[", vm.toString(i), "]");
            string memory spokeLabel = vm.parseJsonString(cfg, string.concat(k, ".spoke"));
            (uint32 integrationId, address spoke, address hub) = _listingSpoke(spokeLabel);
            string memory symbol = vm.parseJsonString(cfg, string.concat(k, ".symbol"));
            address asset = _debtAsset(symbol);
            uint256 reserveId = IAaveV4Spoke(spoke).getReserveId(hub, IAaveV4Hub(hub).getAssetId(asset));
            IRiskModule rm = IRiskModule(_stackOf(integrationId).riskModule);
            if (rm.getDebtReserve(spoke, reserveId).hub != address(0)) continue;
            address flr = _firstLossReserveOf(hub, asset);
            require(flr != address(0), string.concat("no First-Loss Reserve for ", symbol, ": run 07 and 08 first"));
            _add(
                op,
                address(rm),
                abi.encodeCall(IRiskModule.setDebtReserve, (spoke, reserveId, flr)),
                string.concat("setDebtReserve ", spokeLabel, " ", symbol)
            );
        }
    }

    // ─── markets ───

    function _markets() private {
        Operation memory op = _newOperation("listing-markets", OP_CAPACITY);
        uint256 n = _count(cfg, ".listing.markets");
        for (uint256 i = 0; i < n; ++i) {
            Pool memory p = _pool(i);
            if (p.v4Key.tickSpacing != 0) {
                IUniswapV4Integration v4 = IUniswapV4Integration(p.stack.lpVault);
                if (v4.poolKey(p.id).tickSpacing == 0) {
                    vm.broadcast(_deployerOf());
                    v4.registerPool(p.v4Key);
                }
            }
            IRiskModule rm = IRiskModule(p.stack.riskModule);
            if (rm.marketsOf(p.id).fullRange != 0) continue;
            IRiskModule.ListPoolParams memory lp;
            lp.pool = p.id;
            lp.spoke = p.spoke;
            lp.tickSpacing = p.tickSpacing;
            lp.token0 = _feeds(p.t0);
            lp.token1 = _feeds(p.t1);
            lp.listingTick = _listingTick(lp.token0, lp.token1, p.token0, p.token1);
            lp.ltvBps = _ltv(i, p);
            _add(op, address(rm), abi.encodeCall(IRiskModule.listPool, (lp)), string.concat("listPool ", p.name));
            console2.log(string.concat(p.name, ": listing tick"), int256(lp.listingTick));
            console2.log(string.concat(p.name, ": LTV bps"), uint256(lp.ltvBps));
        }
        _scheduleAs(manager, op, safe);
    }

    /// @notice The lower of the two tokens' `collateralFactorBps`, or the market's `eModeLtvBps` (correlated pairs).
    function _ltv(
        uint256 i,
        Pool memory p
    ) private view returns (uint16) {
        string memory k = string.concat(".listing.markets[", vm.toString(i), "].eModeLtvBps");
        if (vm.keyExistsJson(cfg, k)) {
            require(
                IRiskModule(p.stack.riskModule).getSpoke(p.spoke).kind == IRiskModule.SpokeKind.Correlated,
                string.concat(p.name, ": eModeLtvBps is for a correlated pair on a Correlated Spoke")
            );
            return uint16(vm.parseJsonUint(cfg, k));
        }
        uint256 a = vm.parseJsonUint(cfg, string.concat(_tk(p.t0), ".collateralFactorBps"));
        uint256 b = vm.parseJsonUint(cfg, string.concat(_tk(p.t1), ".collateralFactorBps"));
        return uint16(a < b ? a : b);
    }

    /// @notice The tick of the Chainlink price, computed as the RiskModule's listing check does.
    function _listingTick(
        ILPOracle.TokenFeeds memory f0,
        ILPOracle.TokenFeeds memory f1,
        address token0,
        address token1
    ) private view returns (int24) {
        uint160 sqrtPrice = LPPriceMath.sqrtPriceX96(
            _price(f0), _price(f1), IERC20Metadata(token0).decimals(), IERC20Metadata(token1).decimals()
        );
        return ClTickMath.getTickAtSqrtPrice(sqrtPrice);
    }

    /// @notice A route's 8-decimal USD price, as `AaveConfigLogic.tokenPrice`: the feeds multiplied, a USD stablecoin at
    /// most $1.
    function _price(
        ILPOracle.TokenFeeds memory route
    ) private view returns (uint256 price) {
        price = LPPriceMath.PRICE_UNIT;
        for (uint256 i = 0; i < route.feeds.length; ++i) {
            (, int256 answer,,,) = IAggregatorV3(route.feeds[i]).latestRoundData();
            uint256 leg = LPPriceMath.normalize(answer, IAggregatorV3(route.feeds[i]).decimals());
            require(leg != 0, "a listing feed answers zero");
            price = Math.mulDiv(price, leg, LPPriceMath.PRICE_UNIT);
        }
        if (route.usdStable && price > LPPriceMath.STABLE_CEILING) price = LPPriceMath.STABLE_CEILING;
    }

    // ─── vault-tokens ───

    function _vaultTokens() private {
        _useCoreNamespace();
        uint256 n = _count(cfg, ".listing.markets");
        MarketRow[] memory rows = new MarketRow[](2 * n);
        Operation memory op = _newOperation("vault-token-roles", 4 * n + 1);
        vm.startBroadcast(deployer);
        for (uint256 i = 0; i < n; ++i) {
            Pool memory p = _pool(i);
            IRiskModule.PoolMarkets memory pm = IRiskModule(p.stack.riskModule).marketsOf(p.id);
            require(pm.fullRange != 0, string.concat(p.name, " not listed: execute listing-markets first"));
            rows[2 * i] = _marketRow(p, pm.fullRange, "Full Range", "F", i);
            rows[2 * i + 1] = _marketRow(p, pm.customRange, "Custom Range", "C", i);
        }
        vm.stopBroadcast();
        for (uint256 r = 0; r < rows.length; ++r) {
            _tokenRoles(op, rows[r]);
        }
        _sendAsAdmin(op);
        _writeMarkets(rows);
    }

    /// @dev One market as `markets.json` records it.
    struct MarketRow {
        string name;
        uint32 integrationId;
        uint256 marketId;
        bytes32 pool;
        uint8 kind;
        address spoke;
        address hub;
        address vaultToken;
        address lpOracle;
        uint8 unitDecimals;
        uint16 ltvBps;
        int24 bandLower;
        int24 bandUpper;
        uint256 maxLiquidationBonus;
        uint256 addCap;
    }

    function _marketRow(
        Pool memory p,
        uint256 marketId,
        string memory kindName,
        string memory tag,
        uint256 i
    ) private returns (MarketRow memory row) {
        IRiskModule.Market memory m = IRiskModule(p.stack.riskModule).getMarket(marketId);
        string memory pair = string.concat(
            vm.parseJsonString(cfg, string.concat(_tk(p.t0), ".symbol")),
            "/",
            vm.parseJsonString(cfg, string.concat(_tk(p.t1), ".symbol"))
        );
        string memory prefix = string.concat("I", vm.toString(p.integrationId), ".");
        string memory id = vm.toString(marketId);
        row.name = p.name;
        row.integrationId = p.integrationId;
        row.marketId = marketId;
        row.pool = p.id;
        row.kind = uint8(m.kind);
        row.spoke = m.spoke;
        row.hub = p.hub;
        row.unitDecimals = m.unitDecimals;
        row.ltvBps = m.ltvBps;
        row.bandLower = m.bandLower;
        row.bandUpper = m.bandUpper;
        string memory mk = string.concat(".listing.markets[", vm.toString(i), "]");
        row.maxLiquidationBonus = vm.parseJsonUint(cfg, string.concat(mk, ".maxLiquidationBonus"));
        row.addCap = vm.parseJsonUint(cfg, string.concat(mk, ".marketUsdCap"));
        row.vaultToken = _predict(string.concat(prefix, "VaultToken.", id));
        if (row.vaultToken.code.length == 0) {
            IVaultToken.Params memory vp = IVaultToken.Params({
                name: string.concat("Avana ", pair, " ", p.name, " ", kindName),
                symbol: string.concat("av", p.name, "-", tag),
                decimals: m.unitDecimals,
                marketId: marketId,
                hub: p.hub,
                liquidationModule: p.stack.liquidationModule,
                authority: manager
            });
            _deploy3(
                string.concat(prefix, "VaultToken.", id),
                bytes.concat(_artifact("VaultToken.sol", "VaultToken"), abi.encode(vp))
            );
        }
        row.lpOracle = _predict(string.concat(prefix, "LPOracle.", id));
        if (row.lpOracle.code.length == 0) {
            ILPOracle.Params memory op = ILPOracle.Params({
                lpVault: p.stack.lpVault,
                marketId: marketId,
                unitDecimals: m.unitDecimals,
                token0: _feeds(p.t0),
                token1: _feeds(p.t1),
                description: string.concat("Avana ", pair, " ", p.name, " ", kindName, " / USD")
            });
            _deploy3(
                string.concat(prefix, "LPOracle.", id),
                bytes.concat(_artifact("LPOracle.sol", "LPOracle"), abi.encode(op))
            );
        }
        console2.log(
            string.concat(p.name, " market ", id, " ", kindName, ": vault token, LPOracle"),
            row.vaultToken,
            row.lpOracle
        );
    }

    function _tokenRoles(
        Operation memory op,
        MarketRow memory row
    ) private view {
        IAccessManagerOps m = IAccessManagerOps(manager);
        uint64 adapterRole = AvanaAccess.coreRole(row.integrationId, AvanaAccess.CORE_ADAPTER);
        uint64 burnRole = AvanaAccess.coreRole(row.integrationId, AvanaAccess.CORE_BURN);
        string memory id = vm.toString(row.marketId);
        if (m.getTargetFunctionRole(row.vaultToken, IVaultToken.mint.selector) != adapterRole) {
            _add(
                op,
                manager,
                abi.encodeCall(
                    IAccessManagerOps.setTargetFunctionRole,
                    (row.vaultToken, AvanaAccess.vaultTokenAdapterSelectors(), adapterRole)
                ),
                string.concat("vault token ", id, ": mint, addValidProxy to the adapter role")
            );
        }
        if (m.getTargetFunctionRole(row.vaultToken, IVaultToken.burn.selector) != burnRole) {
            _add(
                op,
                manager,
                abi.encodeCall(
                    IAccessManagerOps.setTargetFunctionRole,
                    (row.vaultToken, AvanaAccess.vaultTokenBurnSelectors(), burnRole)
                ),
                string.concat("vault token ", id, ": burn to the burn role")
            );
        }
    }

    function _writeMarkets(
        MarketRow[] memory rows
    ) private {
        uint256 n = rows.length;
        string[] memory names = new string[](n);
        uint256[] memory ids = new uint256[](n);
        uint256[] memory integrations = new uint256[](n);
        bytes32[] memory pools = new bytes32[](n);
        uint256[] memory kinds = new uint256[](n);
        address[][4] memory a;
        for (uint256 k = 0; k < 4; ++k) {
            a[k] = new address[](n);
        }
        uint256[][5] memory u;
        for (uint256 k = 0; k < 5; ++k) {
            u[k] = new uint256[](n);
        }
        int256[] memory lowers = new int256[](n);
        int256[] memory uppers = new int256[](n);
        for (uint256 i = 0; i < n; ++i) {
            MarketRow memory r = rows[i];
            (names[i], ids[i], integrations[i], pools[i], kinds[i]) =
            (r.name, r.marketId, r.integrationId, r.pool, r.kind);
            (a[0][i], a[1][i], a[2][i], a[3][i]) = (r.spoke, r.hub, r.vaultToken, r.lpOracle);
            (u[0][i], u[1][i], u[2][i], u[3][i], u[4][i]) =
            (r.unitDecimals, r.ltvBps, r.maxLiquidationBonus, r.addCap, 0);
            (lowers[i], uppers[i]) = (r.bandLower, r.bandUpper);
        }
        string memory o = "markets";
        vm.serializeString(o, "names", names);
        vm.serializeUint(o, "marketIds", ids);
        vm.serializeUint(o, "integrationIds", integrations);
        vm.serializeBytes32(o, "pools", pools);
        // 0 Full range, 1 Custom range (`IRiskModule.MarketKind`).
        vm.serializeUint(o, "kinds", kinds);
        vm.serializeAddress(o, "spokes", a[0]);
        vm.serializeAddress(o, "hubs", a[1]);
        vm.serializeAddress(o, "vaultTokens", a[2]);
        vm.serializeAddress(o, "lpOracles", a[3]);
        vm.serializeUint(o, "unitDecimals", u[0]);
        vm.serializeUint(o, "ltvBps", u[1]);
        vm.serializeUint(o, "maxLiquidationBonus", u[2]);
        vm.serializeUint(o, "addCaps", u[3]);
        vm.serializeInt(o, "bandLowers", lowers);
        string memory json = vm.serializeInt(o, "bandUppers", uppers);
        vm.writeJson(json, _outputPath("markets"));
        console2.log("output", _outputPath("markets"));
    }

    // ─── activate ───

    function _activate() private {
        string memory path = _outputPath("markets");
        require(vm.exists(path), "no markets.json: run 09-vault-tokens first");
        string memory json = vm.readFile(path);
        uint256[] memory ids = vm.parseJsonUintArray(json, ".marketIds");
        uint256[] memory integrations = vm.parseJsonUintArray(json, ".integrationIds");
        address[] memory tokens = vm.parseJsonAddressArray(json, ".vaultTokens");
        address[] memory oracles = vm.parseJsonAddressArray(json, ".lpOracles");
        Operation memory op = _newOperation("listing-activate", ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            IRiskModule rm = IRiskModule(_stackOf(uint32(integrations[i])).riskModule);
            if (rm.getMarket(ids[i]).active) continue;
            _add(
                op,
                address(rm),
                abi.encodeCall(IRiskModule.activateMarket, (ids[i], tokens[i], oracles[i])),
                string.concat("activateMarket ", vm.toString(ids[i]))
            );
        }
        _scheduleAs(manager, op, safe);
    }

    /// @notice Writes the manager-admin operation `op` for the DAO (the Aave governance executor, the manager's
    /// admin) and, with `AVANA_SCHEDULE` on a test network, runs it at once as one `multicall` through the executor
    /// stand-in, from its PayloadsController stand-in.
    function _sendAsAdmin(
        Operation memory op
    ) private {
        address dao = _addr(cfg, ".governance.aaveGovernanceExecutor");
        if (op.targets.length == 0) {
            console2.log(op.name, "nothing to send: everything is on chain");
            return;
        }
        _writeOperation(manager, dao, op);
        console2.log(op.name, _operationPath(op.name));
        if (!vm.envOr("AVANA_SCHEDULE", false)) return;
        vm.broadcast(_addr(cfg, ".aaveLocal.payloadsController"));
        IAaveExecutor(dao)
            .executeTransaction(manager, 0, "", abi.encodeCall(IAccessManagerOps.multicall, (op.payloads)), false);
        console2.log("sent by the DAO through the governance executor", dao);
    }

    // ─── Config ───

    function _deployerOf() private view returns (address) {
        return vm.envOr("AVANA_DEPLOYER", msg.sender);
    }

    function _tk(
        uint256 t
    ) private pure returns (string memory) {
        return string.concat(".listing.tokens[", vm.toString(t), "]");
    }

    /// @notice The `listing.tokens` index of `token`.
    function _tokenIndex(
        address token
    ) private view returns (uint256) {
        uint256 n = _count(cfg, ".listing.tokens");
        for (uint256 i = 0; i < n; ++i) {
            if (_addr(cfg, string.concat(_tk(i), ".address")) == token) return i;
        }
        revert(string.concat("no listing.tokens entry for ", vm.toString(token)));
    }

    /// @notice A token's Chainlink route: `feeds.route` (one or two feeds, multiplied) when given, else
    /// `feeds.primary`; `isUsdStable` caps it at $1.
    function _feeds(
        uint256 t
    ) private view returns (ILPOracle.TokenFeeds memory f) {
        string memory k = string.concat(_tk(t), ".feeds.route");
        if (vm.keyExistsJson(cfg, k)) {
            f.feeds = _addrs(cfg, k);
        } else {
            f.feeds = new address[](1);
            f.feeds[0] = _addr(cfg, string.concat(_tk(t), ".feeds.primary"));
        }
        f.usdStable = vm.parseJsonBool(cfg, string.concat(_tk(t), ".isUsdStable"));
    }

    function _debtAsset(
        string memory symbol
    ) private view returns (address) {
        uint256 n = _count(cfg, ".listing.debtAssets");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".listing.debtAssets[", vm.toString(i), "]");
            if (_eq(vm.parseJsonString(cfg, string.concat(k, ".symbol")), symbol)) {
                return _addr(cfg, string.concat(k, ".address"));
            }
        }
        revert(string.concat("no listing.debtAssets entry ", symbol));
    }

    /// @notice A `listing.spokes` entry: its integration, Spoke and Hub.
    function _listingSpoke(
        string memory label
    ) private view returns (uint32 integrationId, address spoke, address hub) {
        uint256 n = _count(cfg, ".listing.spokes");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".listing.spokes[", vm.toString(i), "]");
            if (!_eq(vm.parseJsonString(cfg, string.concat(k, ".label")), label)) continue;
            integrationId = uint32(vm.parseJsonUint(cfg, string.concat(k, ".integrationId")));
            spoke = _addr(cfg, string.concat(k, ".spoke"));
            hub = _hubOf(cfg, vm.parseJsonString(cfg, string.concat(k, ".hub")));
            return (integrationId, spoke, hub);
        }
        revert(string.concat("no listing.spokes entry ", label));
    }

    /// @notice `listing.markets[i]` resolved: its stack, Spoke, Hub, pool id, spacing and tokens in pool order. Its
    /// `pool` names an entry of `listing.pools` (a Uniswap v3 or Slipstream pool address) or of
    /// `listing.uniswapV4Pools` (a hookless v4 key; native ETH counts as the PositionManager's WETH9).
    function _pool(
        uint256 i
    ) private view returns (Pool memory p) {
        string memory k = string.concat(".listing.markets[", vm.toString(i), "]");
        p.name = vm.parseJsonString(cfg, string.concat(k, ".name"));
        uint32 spokeIntegration;
        (spokeIntegration, p.spoke, p.hub) = _listingSpoke(vm.parseJsonString(cfg, string.concat(k, ".spoke")));
        p.integrationId = uint32(vm.parseJsonUint(cfg, string.concat(k, ".integrationId")));
        require(p.integrationId == spokeIntegration, string.concat(p.name, ": the Spoke is another integration's"));
        p.stack = _stackOf(p.integrationId);
        string memory poolName = vm.parseJsonString(cfg, string.concat(k, ".pool"));
        string memory v3Key = string.concat(".listing.pools['", poolName, "']");
        if (vm.keyExistsJson(cfg, v3Key)) {
            address pool = _addr(cfg, v3Key);
            p.id = bytes32(uint256(uint160(pool)));
            p.tickSpacing = IUniswapV3Pool(pool).tickSpacing();
            (p.token0, p.token1) = (IUniswapV3Pool(pool).token0(), IUniswapV3Pool(pool).token1());
        } else {
            string memory v4 = string.concat(".listing.uniswapV4Pools['", poolName, "']");
            require(vm.keyExistsJson(cfg, v4), string.concat("no listing.pools or uniswapV4Pools entry ", poolName));
            p.v4Key = UniswapV4PoolKey({
                currency0: _addr(cfg, string.concat(v4, ".currency0")),
                currency1: _addr(cfg, string.concat(v4, ".currency1")),
                fee: uint24(vm.parseJsonUint(cfg, string.concat(v4, ".fee"))),
                tickSpacing: int24(int256(vm.parseJsonUint(cfg, string.concat(v4, ".tickSpacing")))),
                hooks: address(0)
            });
            p.id = keccak256(abi.encode(p.v4Key));
            p.tickSpacing = p.v4Key.tickSpacing;
            address weth = IUniswapV4PositionManager(IUniswapV4Integration(p.stack.lpVault).POSITION_MANAGER()).WETH9();
            p.token0 = p.v4Key.currency0 == address(0) ? weth : p.v4Key.currency0;
            p.token1 = p.v4Key.currency1;
        }
        p.t0 = _tokenIndex(p.token0);
        p.t1 = _tokenIndex(p.token1);
    }
}
