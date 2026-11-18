// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {UniswapV4State} from "../../../src/amm/uniswap-v4/UniswapV4State.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {
    IUniswapV4PoolManager,
    UniswapV4PoolKey
} from "../../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {IUniswapV3Factory} from "../../../src/interfaces/external/uniswap/IUniswapV3Factory.sol";
import {ILPOracle} from "../../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCL} from "../../../src/oracle/lp-oracle/LPOracleCL.sol";
import {LPOracleCLInitLogic} from "../../../src/oracle/lp-oracle/LPOracleCLInitLogic.sol";
import {LPOracleCLListingLogic} from "../../../src/oracle/lp-oracle/LPOracleCLListingLogic.sol";
import {LPOracleCLPokeLogic} from "../../../src/oracle/lp-oracle/LPOracleCLPokeLogic.sol";
import {LPOracleCLViewLogic} from "../../../src/oracle/lp-oracle/LPOracleCLViewLogic.sol";
import {InitParams, LPOracleLogicSet} from "../../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {LPOracleV4} from "../../../src/oracle/lp-oracle/LPOracleV4.sol";
import {LPOracleV4ModuleLogic} from "../../../src/oracle/lp-oracle/LPOracleV4ModuleLogic.sol";
import {DebtReserveDef, RiskTier, SpokeDef} from "../../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {MarketDef} from "../../../src/types/MarketTypes.sol";
import {PositionRef, PositionShape, ShapeKind} from "../../../src/types/PositionTypes.sol";
import {IAvanaAaveV4Roles, ISpokeInstanceBatch} from "./AaveV4Fixture.sol";
import {ClTestToken, IClPool} from "./ClPoolFixture.sol";
import {
    CollHubSpokeConfig,
    CollSpokeDynamicReserveConfig,
    CollSpokeLiquidationConfig,
    CollSpokeReserveConfig,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "./CollateralizationFixture.sol";
import {RealStackVolatile} from "./RealStackVolatile.sol";
import {IPermit2Approve, IV4TestPositionManager, TestWETH9, V4PoolActor} from "./UniswapV4WorldFixture.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title RealStackUniswapV4
/// @notice The Volatile Hub (`_setUpVolatile`), a local Uniswap v4 world on the pinned sources (PoolManager,
/// PositionManager, Permit2; the fixture's WETH carries WETH9's code so the PositionManager can wrap), the real
/// `UniswapV4Integration` registered as integration `V4`, its Stable and Volatile CDP Spokes with USDC and GHO debt
/// reserves, and v4 markets priced by the real `LPOracleV4`, each with a Uniswap v3 reference pool of the same pair.
/// @dev The test tokens of the v3 fixtures are minted at `type(uint128).max` per pool actor, far beyond any real token,
/// so `_capSupply` records a total supply below the v4 listing bound (`REQ-AMM-V4-009`) before a v4 market is bound;
/// balances are untouched.
abstract contract RealStackUniswapV4 is RealStackVolatile {
    uint32 internal constant V4 = 4;
    string internal constant SPOKE_CDP_V4_STABLE = "uniswap-v4-stable";
    string internal constant SPOKE_CDP_V4_VOLATILE = "uniswap-v4-volatile";
    uint8 internal constant A_MINT_POSITION = 0x02;
    uint8 internal constant A_SETTLE_PAIR = 0x0d;
    uint8 internal constant A_SWEEP = 0x14;

    IPoolManager internal v4pm;
    IV4TestPositionManager internal v4posm;
    address internal v4permit2;
    V4PoolActor internal v4actor;
    address internal v4Vault;
    address internal v4SpokeS;
    address internal v4SpokeV;
    uint256 internal v4UsdcReserveS;
    uint256 internal v4GhoReserveS;
    uint256 internal v4UsdcReserveV;
    uint256 internal v4GhoReserveV;
    LPOracleV4 internal v4OracleImpl;
    mapping(uint256 marketId => PoolKey) internal v4KeyOf;

    /// @dev Native ETH refunds of the PositionManager's `SWEEP` after a mint.
    receive() external payable {}

    function _setUpUniswapV4() internal {
        _setUpVolatile();
        _deployV4Amm();
        _registerV4();
        v4SpokeS = _v4Spoke(aave.hub, SPOKE_CDP_V4_STABLE, RiskTier.Stable);
        v4SpokeV = _v4Spoke(hubV, SPOKE_CDP_V4_VOLATILE, RiskTier.Volatile);
        v4UsdcReserveS = _v4Debt(aave.hub, v4SpokeS, usdc, usdcAssetId, address(usdcOracle), false);
        v4GhoReserveS = _v4Debt(aave.hub, v4SpokeS, gho, ghoAssetId, address(ghoPrice), true);
        v4UsdcReserveV = _v4Debt(hubV, v4SpokeV, usdc, usdcAssetIdV, address(usdcOracle), false);
        v4GhoReserveV = _v4Debt(hubV, v4SpokeV, gho, ghoAssetIdV, address(ghoPrice), true);
    }

    // ─── The v4 world ───

    function _deployV4Amm() private {
        vm.etch(address(weth), address(new TestWETH9()).code);
        vm.deal(address(weth), 1e30);
        v4pm = IPoolManager(deployCode("out-univ4/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        v4permit2 = deployCode("out-permit2/Permit2.sol/Permit2.json");
        v4posm = IV4TestPositionManager(
            deployCode(
                "out-univ4/PositionManager.sol/PositionManager.json",
                abi.encode(address(v4pm), v4permit2, uint256(100_000), address(0), address(weth))
            )
        );
        v4actor = new V4PoolActor(v4pm);
        vm.deal(address(v4actor), 1e30);
        vm.deal(address(this), 1e30);
        vm.label(address(v4pm), "Uniswap.PoolManager");
        vm.label(address(v4posm), "Uniswap.PositionManager");
        vm.label(v4permit2, "Permit2");
    }

    function _registerV4() private {
        v4Vault = deployCode(
            "UniswapV4Integration.sol:UniswapV4Integration",
            abi.encode(
                V4,
                address(coll),
                address(registry),
                address(lock),
                address(timelock),
                address(v4posm),
                address(factory),
                uint256(BLOCK_TIME)
            )
        );
        vm.label(v4Vault, "UniswapV4Integration");
        address[] memory amm = new address[](2);
        (amm[0], amm[1]) = (address(v4posm), address(v4pm));
        vm.startPrank(address(timelock));
        vtFactory.registerIntegration(V4, v4Vault);
        registry.registerIntegration(V4, v4Vault, makeAddr("v4Pricing"));
        registry.recordIntegrationContracts(V4, amm);
        registry.finalizeIntegrationContracts(V4);
        vm.stopPrank();
        address m = address(
            new LPOracleV4ModuleLogic(address(timelock), BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, address(weth))
        );
        address t = address(timelock);
        LPOracleLogicSet memory logics = LPOracleLogicSet(
            address(new LPOracleCLPokeLogic(t, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m)),
            address(new LPOracleCLInitLogic(t, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m)),
            address(new LPOracleCLListingLogic(t, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m)),
            address(new LPOracleCLViewLogic(t, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m))
        );
        v4OracleImpl = new LPOracleV4(t, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, m, logics, address(weth));
    }

    // ─── CDP Spokes and debt reserves (as the Slipstream fixture's, for integration V4) ───

    function _v4Spoke(
        address hub,
        string memory label,
        RiskTier tier
    ) private returns (address spoke) {
        address batch = deployCode(
            "out-aave/AaveV4SpokeInstanceBatch.sol/AaveV4SpokeInstanceBatch.json",
            abi.encode(
                aaveDao,
                aave.accessManager,
                _linkedSpokeInstanceCode(aave.liquidationLogic),
                ORACLE_DECIMALS,
                CDP_SPOKE_USER_RESERVES_LIMIT,
                _childSalt(aave.salt, "spoke", label)
            )
        );
        (address s, address impl, address oracle) = ISpokeInstanceBatch(batch).getReport();
        spoke = s;
        vm.prank(aaveDao);
        IAccessManager(aave.accessManager).grantRole(0, address(this), 0);
        (bool ok, bytes memory data) =
            aave.roles.delegatecall(abi.encodeCall(IAvanaAaveV4Roles.setupSpoke, (aave.accessManager, spoke)));
        _bubble(ok, data);
        IAccessManager(aave.accessManager).renounceRole(0, address(this));
        vm.startPrank(address(timelock));
        registry.approveSpokeCodeHash(impl.codehash);
        registry.deployCdpSpoke(
            SpokeDef({
                approved: false, hub: hub, integrationId: V4, riskTier: tier, implementation: impl, aaveOracle: oracle
            })
        );
        store.setLiquidationExpectations(spoke, TARGET_HEALTH_FACTOR, 200);
        vm.stopPrank();
        vm.prank(aaveDao);
        ICollSpokeConfigurator(aave.spokeConfigurator)
            .updateLiquidationConfig(spoke, CollSpokeLiquidationConfig(1.1e18, 0.95e18, 5000));
        vm.label(spoke, string.concat("Aave.Spoke.", label));
    }

    function _v4Debt(
        address hub,
        address spoke,
        ClTestToken asset,
        uint256 assetId,
        address source,
        bool fixedPrice
    ) internal returns (uint256 reserveId) {
        uint24 maxRp = IAaveV4Hub(hub).MAX_RISK_PREMIUM_THRESHOLD();
        vm.startPrank(aaveDao);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(hub, spoke, assetId, CollHubSpokeConfig(0, DEBT_DRAW_CAP, maxRp, true, false));
        reserveId = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                spoke,
                hub,
                assetId,
                source,
                CollSpokeReserveConfig(0, false, false, true, false),
                CollSpokeDynamicReserveConfig(0, 10_000, 0)
            );
        vm.stopPrank();
        address cs = hub == hubV ? firstLossReserveOfV[address(asset)] : firstLossReserveOf[address(asset)];
        uint8 dec = asset.decimals();
        vm.prank(address(timelock));
        registry.enableDebtReserve(
            spoke,
            DebtReserveDef({
                reserveId: reserveId,
                asset: address(asset),
                decimals: dec,
                fundingHub: hub,
                hubAssetId: assetId,
                priceSource: source,
                fixedPrice: fixedPrice,
                firstLossReserve: cs,
                crossHub: false,
                approved: false
            })
        );
    }

    // ─── Pools ───

    /// @notice A hookless v4 pool of `c0`/`c1` (sorted; `address(0)` for native ETH, priced as WETH) at the published
    /// prices with `liquidity` on its full range held by outside LPs, and its Uniswap v3 reference pool of the same pair
    /// (fee 500, 151 observations, `liquidity` full range). Call `_ageNewPools` with the reference pools afterwards.
    function _newV4Pool(
        address c0,
        address c1,
        uint24 fee,
        int24 spacing,
        uint128 liquidity
    ) internal returns (PoolKey memory key, IClPool ref) {
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(address(0)));
        address t0 = c0 == address(0) ? address(weth) : c0;
        v4pm.initialize(
            key,
            ClPriceMath.oracleSqrtPrice(
                _usdPrice(t0), _usdPrice(c1), ClTestToken(t0).decimals(), ClTestToken(c1).decimals()
            )
        );
        _v4Fund(c0);
        _v4Fund(c1);
        (int24 lower, int24 upper) = _v4FullRange(spacing);
        _v4Mint(address(v4actor), key, lower, upper, liquidity);
        // The same pair's existing 0.05 % Uniswap v3 pool when the stack has one, else a new one.
        (address a, address b) = t0 < c1 ? (t0, c1) : (c1, t0);
        address existing = IUniswapV3Factory(address(factory)).getPool(a, b, 500);
        if (existing == address(0)) {
            ref = _newVolatilePool(ClTestToken(t0), ClTestToken(c1), 500, liquidity);
        } else {
            ref = IClPool(existing);
            ref.increaseObservationCardinalityNext(151);
        }
    }

    function _v4Fund(
        address token
    ) private {
        if (token == address(0)) return;
        ClTestToken(token).mint(address(this), 1e36);
        ClTestToken(token).mint(address(v4actor), 1e36);
        ERC20(token).approve(v4permit2, type(uint256).max);
        IPermit2Approve(v4permit2).approve(token, address(v4posm), type(uint160).max, type(uint48).max);
    }

    function _v4FullRange(
        int24 spacing
    ) internal pure returns (int24 lower, int24 upper) {
        // forge-lint: disable-next-line(divide-before-multiply)
        upper = (ClPriceMath.MAX_TICK / spacing) * spacing;
        lower = -upper;
    }

    /// @dev Mints a position of `liquidity` on `[lower, upper]` to `owner`, paid by the fixture (ETH by value).
    function _v4Mint(
        address owner,
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) internal returns (uint256 tokenId) {
        tokenId = v4posm.nextTokenId();
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(key, lower, upper, uint256(liquidity), type(uint128).max, type(uint128).max, owner, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(Currency.wrap(address(0)), address(1));
        uint256 value = Currency.unwrap(key.currency0) == address(0) ? 1e27 : 0;
        v4posm.modifyLiquidities{value: value}(
            abi.encode(abi.encodePacked(A_MINT_POSITION, A_SETTLE_PAIR, A_SWEEP), params), block.timestamp
        );
    }

    /// @dev Records a total supply of `10^30` raw units for `token` (see the contract's notes).
    function _capSupply(
        address token
    ) internal {
        vm.store(token, bytes32(uint256(2)), bytes32(uint256(1e30)));
    }

    // ─── Markets ───

    /// @notice Lists and activates the full range of the v4 pool `key` (reference pool `ref`) on the V4 Spoke of its
    /// tier, CF `cf`, with the unit of the real LPVault's `bindMarket`, the real `LPOracleV4`, and routes from each
    /// token into USDC and GHO through the existing route DEX.
    function _addV4Market(
        PoolKey memory key,
        IClPool ref,
        uint16 cf
    ) internal returns (uint256 id) {
        id = registry.marketCount() + 1;
        address t0 = Currency.unwrap(key.currency0) == address(0) ? address(weth) : Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        _capSupply(t0);
        _capSupply(t1);
        bool stable = _isStable(t0) && _isStable(t1);
        ClSite memory site = ClSite(
            V4, v4Vault, stable ? aave.hub : hubV, stable ? v4SpokeS : v4SpokeV, stable ? aave.irStrategy : irV, 7, 0
        );
        MarketInfo storage m = mkt[id];
        m.pool = ref;
        v4KeyOf[id] = key;
        (uint8 d, uint8 k) = _v4UnitOf(t0, t1, key.tickSpacing);
        m.oracle = _v4Oracle(id, key, ref, t0, t1, k);
        m.vaultToken = _v4VaultToken(id, key, d, site, address(m.oracle));
        _v4List(key, ref, site, m.vaultToken, address(m.oracle), t0, t1);
        _storeVolatile(id);
        _aaveVolatile(m, d, cf, site);
        _routesInto(id, address(usdc));
        _routesInto(id, address(gho));
        vm.prank(address(timelock));
        registry.activateMarket(id);
        vm.label(m.vaultToken, string.concat("VaultToken ", vm.toString(id)));
        vm.label(address(m.oracle), string.concat("LPOracleV4 ", vm.toString(id)));
    }

    function _v4Shape(
        int24 spacing
    ) internal pure returns (PositionShape memory) {
        (int24 lower, int24 upper) = _v4FullRange(spacing);
        return PositionShape(ShapeKind.TickRange, lower, upper);
    }

    function _v4VaultToken(
        uint256 id,
        PoolKey memory key,
        uint8 d,
        ClSite memory site,
        address oracle
    ) private returns (address vt) {
        VtMeta memory v;
        (v.name, v.symbol) = _v4Names(id, key);
        v.shape = _v4Shape(key.tickSpacing);
        vm.prank(address(timelock));
        vt = vtFactory.deployVaultToken(
            V4, address(0), keccak256(abi.encode(key)), v.shape, site.hub, site.spoke, id, oracle, d, v.name, v.symbol
        );
    }

    function _v4Names(
        uint256 id,
        PoolKey memory key
    ) private view returns (string memory name, string memory symbol) {
        address t0 = Currency.unwrap(key.currency0) == address(0) ? address(weth) : Currency.unwrap(key.currency0);
        string memory pair =
            string.concat(ClTestToken(t0).symbol(), "-", ClTestToken(Currency.unwrap(key.currency1)).symbol(), "-v4");
        name = string.concat("Avana ", pair, " ", vm.toString(id));
        symbol = string.concat("av", pair, "-", vm.toString(id));
    }

    function _v4List(
        PoolKey memory key,
        IClPool ref,
        ClSite memory site,
        address vt,
        address oracle,
        address t0,
        address t1
    ) private {
        MarketDef memory def;
        (def.hub, def.spoke, def.integrationId, def.pool) = (site.hub, site.spoke, V4, address(0));
        def.poolId = keccak256(abi.encode(key));
        def.shape = _v4Shape(key.tickSpacing);
        (def.vaultToken, def.lpOracle) = (vt, oracle);
        def.integrationData = abi.encode(key, address(ref), _usdPrice(t0), _usdPrice(t1));
        vm.prank(address(timelock));
        registry.listCollateralMarket(def);
    }

    function _v4UnitOf(
        address t0,
        address t1,
        int24 spacing
    ) internal view returns (uint8 d, uint8 k) {
        ClPriceMath.Valuation memory v =
            ClPriceMath.valuation(_usdPrice(t0), _usdPrice(t1), ClTestToken(t0).decimals(), ClTestToken(t1).decimals());
        bool found;
        (found, k) = ClPriceMath.firstBindingExponent(v, spacing);
        require(found, "unit exponent");
        (int24 lower, int24 upper) = _v4FullRange(spacing);
        (found, d) = ClPriceMath.unitDecimals(v, lower, upper, k);
        require(found, "unit decimals");
    }

    function _v4Oracle(
        uint256 id,
        PoolKey memory key,
        IClPool ref,
        address t0,
        address t1,
        uint8 k
    ) private returns (LPOracleCL o) {
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (t0, t1);
        InitParams memory ip;
        ip.timelock = address(timelock);
        ip.parameterStore = address(store);
        ip.marketRegistry = address(registry);
        ip.marketId = id;
        ip.integration = v4Vault;
        ip.isUsdStable = new bool[](2);
        (ip.isUsdStable[0], ip.isUsdStable[1]) = (_isStable(t0), _isStable(t1));
        ip.description = "Uniswap v4 LP / USD";
        ip.pokeMinGas = POKE_FLOOR;
        ip.config = _oracleConfigFor(id, toks);
        if (!ip.isUsdStable[0] || !ip.isUsdStable[1]) {
            (ip.config.usdBandLow, ip.config.usdBandHigh) = (0, type(uint256).max);
        }
        (int24 lower, int24 upper) = _v4FullRange(key.tickSpacing);
        UniswapV4PoolKey memory k4 = UniswapV4PoolKey(
            Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), key.fee, key.tickSpacing, address(0)
        );
        ip.market = abi.encode(address(v4pm), k4, lower, upper, uint256(k), address(ref));
        o = LPOracleCL(address(new ERC1967Proxy(address(v4OracleImpl), abi.encodeCall(ILPOracle.initialize, (ip)))));
    }

    // ─── Positions and prices ───

    /// @notice A full-range v4 position in `marketId` worth about `usd` dollars at the published prices, minted to
    /// `wallet`, approved to the LPVault and pledged through the Adapter.
    function _v4PledgeUsd(
        address wallet,
        uint256 marketId,
        uint256 usd
    ) internal returns (bytes32 key, address proxy) {
        key = _v4MintUsd(wallet, marketId, usd);
        vm.prank(wallet);
        (proxy,,) = adapterC.pledge(marketId, PositionRef(V4, key), _deadline());
    }

    /// @notice The position of `_v4PledgeUsd`, minted and approved but not pledged.
    function _v4MintUsd(
        address wallet,
        uint256 marketId,
        uint256 usd
    ) internal returns (bytes32 key) {
        PoolKey memory pk = v4KeyOf[marketId];
        address t1 = Currency.unwrap(pk.currency1);
        (uint160 s,) = UniswapV4State.slot0(IUniswapV4PoolManager(address(v4pm)), keccak256(abi.encode(pk)));
        // Full range at price s: token1 held ≈ L · s / 2^96, so half the value in token1 gives L.
        uint256 a1 = usd * 10 ** ClTestToken(t1).decimals() * 1e8 / (2 * _usdPrice(t1));
        uint128 liquidity = uint128(a1 * (1 << 96) / s);
        (int24 lower, int24 upper) = _v4FullRange(pk.tickSpacing);
        uint256 tokenId = _v4Mint(wallet, pk, lower, upper, liquidity);
        vm.prank(wallet);
        v4posm.approve(v4Vault, tokenId);
        key = bytes32(tokenId);
    }

    /// @notice Every v4 market's pool swapped to the published prices, then `_repriceMarkets` (the reference pools,
    /// a TWAP wait, feeds, routes and pokes).
    function _repriceV4Markets() internal {
        uint256 n = registry.marketCount();
        for (uint256 id = 1; id <= n; ++id) {
            PoolKey memory pk = v4KeyOf[id];
            if (pk.tickSpacing == 0) continue;
            address t0 = Currency.unwrap(pk.currency0) == address(0) ? address(weth) : Currency.unwrap(pk.currency0);
            address t1 = Currency.unwrap(pk.currency1);
            uint160 target = ClPriceMath.oracleSqrtPrice(
                _usdPrice(t0), _usdPrice(t1), ClTestToken(t0).decimals(), ClTestToken(t1).decimals()
            );
            (uint160 now_,) = UniswapV4State.slot0(IUniswapV4PoolManager(address(v4pm)), keccak256(abi.encode(pk)));
            if (target != now_) v4actor.swap(pk, target < now_, -int256(uint256(type(uint128).max)), target);
        }
        _repriceMarkets();
    }
}
