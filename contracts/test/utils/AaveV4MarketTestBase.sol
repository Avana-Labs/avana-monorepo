// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapter} from "../../src/AaveAdapter.sol";
import {LPOracle} from "../../src/LPOracle.sol";
import {LiquidationModule} from "../../src/LiquidationModule.sol";
import {VaultToken} from "../../src/VaultToken.sol";
import {IAaveV4Hub} from "../../src/dependencies/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/dependencies/aave/IAaveV4Spoke.sol";
import {INonfungiblePositionManager} from "../../src/dependencies/uniswap/INonfungiblePositionManager.sol";
import {UniswapV3Integration} from "../../src/integrations/UniswapV3Integration.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";
import {IVaultToken} from "../../src/interfaces/IVaultToken.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {
    HubSpokeConfig,
    IHubConfiguratorCalls,
    ISpokeConfiguratorCalls,
    InterestRateData,
    SpokeDynamicReserveConfig,
    SpokeLiquidationConfig,
    SpokeReserveConfig,
    VaultTokenTestPriceSource
} from "../integration/VaultToken.AaveV4.integration.t.sol";
import {AaveV4Fixture} from "./fixtures/AaveV4Fixture.sol";
import {ClPoolFixture, ClTestToken, IClPool} from "./fixtures/ClPoolFixture.sol";
import {BandTestFeed} from "./mocks/BandOracleMocks.sol";
import {LiquidationTestRiskModule} from "./mocks/LiquidationTestMocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @dev SpokeConfigurator calls of aave-v4 a3ef63e this suite makes beyond `ISpokeConfiguratorCalls`.
interface ILifecycleSpokeConfigurator {
    function updateFrozen(
        address spoke,
        uint256 reserveId,
        bool frozen
    ) external;
    function pauseAllReserves(
        address spoke
    ) external;
    function updatePaused(
        address spoke,
        uint256 reserveId,
        bool paused
    ) external;
    function addDynamicReserveConfig(
        address spoke,
        uint256 reserveId,
        SpokeDynamicReserveConfig calldata dynamicConfig
    ) external returns (uint32);
    function updateDynamicReserveConfig(
        address spoke,
        uint256 reserveId,
        uint32 dynamicConfigKey,
        SpokeDynamicReserveConfig calldata dynamicConfig
    ) external;
    function updatePositionManager(
        address spoke,
        address positionManager,
        bool active
    ) external;
}

/// @dev HubConfigurator call of aave-v4 a3ef63e: halts a Spoke on every asset it is listed for.
interface ILifecycleHubConfigurator {
    function haltSpoke(
        address hub,
        address spoke
    ) external;
    function updateSpokeHalted(
        address hub,
        uint256 assetId,
        address spoke,
        bool halted
    ) external;
}

/// @dev Errors of aave-v4 a3ef63e `ISpoke` and `IHub` the suite expects.
interface IAaveV4Errors {
    error ReserveFrozen();
    error ReservePaused();
    error HealthFactorBelowThreshold();
    error InvalidCollateralFactor();
    error SpokeHalted();
}

/// @title MarketLifecycleAaveV4IntegrationTest
/// @notice Market freeze, deprecation and emergency stops (`design/README.md`), plus the custody cases that touch
/// Aave state, on the pinned real Aave V4 Hub, CDP Spoke and Lend Spoke, configured only through Aave's own
/// configurators. Avana runs its real AaveAdapter, VaultToken, LPOracle, LiquidationModule and Uniswap v3 LPVault on the
/// real v3 factory, pool and NonfungiblePositionManager. The RiskModule is the market-lookup stand-in the adapter and
/// LiquidationModule suites use: it answers `getMarket`, `routeOf` and `checkBorrow` and holds no Aave state.
/// @dev The pool's tokens are listed on the Lend Spoke, which is the LPOracle's price Spoke, as on a real deployment.
/// One full-range market at $1 per token: a full-range position of 1,000 of each token is 1,000e18 credit units worth

/// @title AaveV4MarketTestBase
/// @notice One full-range Uniswap v3 market on the pinned real Aave V4 Hub, CDP Spoke and Lend Spoke, configured only
/// through Aave's own configurators. Avana runs its real AaveAdapter, VaultToken, LPOracle, LiquidationModule and
/// Uniswap v3 LPVault on the real v3 factory, pool and NonfungiblePositionManager. The RiskModule is the market-lookup
/// stand-in the adapter and LiquidationModule suites use: it answers `getMarket`, `routeOf` and `checkBorrow` and holds
/// no Aave state.
/// @dev The pool's tokens are listed on the Lend Spoke, which is the LPOracle's price Spoke, as on a real deployment.
/// One full-range market at $1 per token: a full-range position of 1,000 of each token is 1,000e18 credit units worth
/// $2,000, so the collateral factor of 80 % gives $1,600 of borrowing power. A suite changes the vault token's maximum
/// bonus and the Spoke's liquidation config through `_vtMaxBonus` and `_liquidationConfig`.
abstract contract AaveV4MarketTestBase is AaveV4Fixture, ClPoolFixture {
    uint64 internal constant ADAPTER_ROLE = 11;
    uint64 internal constant LIQUIDATION_ROLE = 12;
    uint64 internal constant BURN_ROLE = 13;
    uint24 internal constant FEE = 3000;
    int24 internal constant FULL_LOWER = -887_220;
    int24 internal constant FULL_UPPER = 887_220;
    uint256 internal constant MARKET = 1;
    uint16 internal constant CF_BPS = 8000;
    uint256 internal constant SIZE = 1000e18;

    INonfungiblePositionManager internal nfpm;
    IClPool internal pool;
    ClTestToken internal t0;
    ClTestToken internal t1;
    ClTestToken internal debt;
    UniswapV3Integration internal vault;
    AccessManager internal am;
    LiquidationTestRiskModule internal rm;
    LiquidationModule internal module;
    AaveAdapter internal adapter;
    VaultToken internal vt;
    LPOracle internal oracle;
    BandTestFeed internal feed0;
    BandTestFeed internal feed1;
    VaultTokenTestPriceSource internal debtPrice;
    uint256 internal priceReserve0;
    uint256 internal priceReserve1;
    uint256 internal vtAssetId;
    uint256 internal vtReserveId;
    uint256 internal debtReserveId;
    IAaveV4Spoke internal spoke;

    address internal dave = makeAddr("dave");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public virtual {
        _deployAaveV4();
        spoke = IAaveV4Spoke(aave.cdpSpoke);
        _deployFactory();
        (ClTestToken a, ClTestToken b, bool aIsToken0) = _sortedTokens("TKA", 18, "TKB", 18);
        (t0, t1) = aIsToken0 ? (a, b) : (b, a);
        pool = _createPool(t0, t1, _poolFee(), 1e8, 1e8, 1, 1e18);
        nfpm = INonfungiblePositionManager(
            _constructInPlace(
                makeAddr("NonfungiblePositionManager"),
                bytes.concat(
                    vm.getCode("out-univ3-periphery/NonfungiblePositionManager.sol/NonfungiblePositionManager.json"),
                    abi.encode(address(factory), makeAddr("WETH9"), address(0))
                )
            )
        );
        am = new AccessManager(address(this));
        vault = new UniswapV3Integration(address(am), address(nfpm), address(factory));
        vault.listMarket(MARKET, bytes32(uint256(uint160(address(pool)))), FULL_LOWER, FULL_UPPER);
        rm = new LiquidationTestRiskModule(address(vault));
        module = new LiquidationModule(address(rm));
        rm.setLiquidationModule(address(module));
        rm.setFee(2000, feeRecipient);
        adapter = new AaveAdapter(address(rm));
        vt = new VaultToken(
            IVaultToken.Params({
                name: "Avana TKA/TKB Uniswap v3 Full Range",
                symbol: "avTK-v3",
                decimals: 18,
                marketId: MARKET,
                hub: aave.hub,
                liquidationModule: address(module),
                authority: address(am)
            })
        );
        _grantRoles();
        _listOnAave();
        rm.setMarket(MARKET, _market());

        debt.mint(liquidator, 1e24);
        vm.prank(liquidator);
        debt.approve(address(module), type(uint256).max);
    }

    /// @dev The pool's fee tier.
    function _poolFee() internal view virtual returns (uint24) {
        return FEE;
    }

    /// @dev The vault token reserve's maximum liquidation bonus.
    function _vtMaxBonus() internal view virtual returns (uint32) {
        return 10_500;
    }

    /// @dev The CDP Spoke's liquidation config: target health factor, health factor for the maximum bonus and bonus
    /// factor.
    function _liquidationConfig() internal view virtual returns (SpokeLiquidationConfig memory) {
        return SpokeLiquidationConfig(1.1e18, 0.95e18, 5000);
    }

    // ─── Shared helpers ───

    function _mintFull(
        address who,
        uint256 amount
    ) internal returns (bytes32 key, uint128 liquidity) {
        t0.mint(who, amount);
        t1.mint(who, amount);
        vm.startPrank(who);
        t0.approve(address(nfpm), amount);
        t1.approve(address(nfpm), amount);
        uint256 id;
        (id, liquidity,,) = nfpm.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(t0),
                token1: address(t1),
                fee: _poolFee(),
                tickLower: FULL_LOWER,
                tickUpper: FULL_UPPER,
                amount0Desired: amount,
                amount1Desired: amount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: who,
                deadline: block.timestamp
            })
        );
        nfpm.setApprovalForAll(address(vault), true);
        vm.stopPrank();
        key = bytes32(id);
    }

    /// @dev A stranger adds liquidity straight on the NFPM, which the NFPM allows for any token ID.
    function _directIncrease(
        bytes32 key,
        uint256 amount
    ) internal returns (uint128 extra) {
        address stranger = makeAddr("stranger");
        t0.mint(stranger, amount);
        t1.mint(stranger, amount);
        vm.startPrank(stranger);
        t0.approve(address(nfpm), amount);
        t1.approve(address(nfpm), amount);
        (extra,,) = nfpm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: uint256(key),
                amount0Desired: amount,
                amount1Desired: amount,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function _fundTopUp(
        address who,
        uint256 amount0,
        uint256 amount1
    ) internal {
        t0.mint(who, amount0);
        t1.mint(who, amount1);
        vm.startPrank(who);
        t0.approve(address(vault), amount0);
        t1.approve(address(vault), amount1);
        vm.stopPrank();
    }

    function _pledge(
        address who,
        bytes32 key
    ) internal returns (uint256 marketId, uint128 credit) {
        vm.prank(who);
        (marketId, credit) = adapter.pledge(key);
    }

    function _borrow(
        address who,
        uint256 amount
    ) internal {
        vm.prank(who);
        adapter.borrow(MARKET, debtReserveId, amount, who);
    }

    function _repayAll(
        address who
    ) internal {
        debt.mint(who, 1e21);
        vm.startPrank(who);
        debt.approve(address(adapter), type(uint256).max);
        adapter.repay(MARKET, debtReserveId, type(uint256).max, who);
        vm.stopPrank();
    }

    function _liquidate(
        address account,
        uint256 debtToCover
    ) internal returns (ILiquidationModule.LiquidationResult memory r) {
        vm.prank(liquidator);
        r = module.liquidate(_params(account, debtToCover));
    }

    function _params(
        address account,
        uint256 debtToCover
    ) internal view returns (ILiquidationModule.LiquidationParams memory) {
        return ILiquidationModule.LiquidationParams({
            marketId: MARKET,
            debtReserveId: debtReserveId,
            account: account,
            debtToCover: debtToCover,
            minAmount0: 0,
            minAmount1: 0,
            receiver: liquidator
        });
    }

    /// @dev Swaps up and back across the current price, which pays fees to every full-range position.
    function _trade() internal {
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(600));
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(-600));
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(0));
    }

    // ─── Setup ───

    function _grantRoles() internal {
        bytes4[] memory vaultSelectors = new bytes4[](5);
        vaultSelectors[0] = ILPVault.pledge.selector;
        vaultSelectors[1] = ILPVault.addLiquidity.selector;
        vaultSelectors[2] = ILPVault.removeLiquidity.selector;
        vaultSelectors[3] = ILPVault.release.selector;
        vaultSelectors[4] = ILPVault.collectFees.selector;
        am.setTargetFunctionRole(address(vault), vaultSelectors, ADAPTER_ROLE);
        bytes4[] memory unwind = new bytes4[](1);
        unwind[0] = ILPVault.unwind.selector;
        am.setTargetFunctionRole(address(vault), unwind, LIQUIDATION_ROLE);
        bytes4[] memory tokenSelectors = new bytes4[](2);
        tokenSelectors[0] = IVaultToken.mint.selector;
        tokenSelectors[1] = IVaultToken.addValidProxy.selector;
        am.setTargetFunctionRole(address(vt), tokenSelectors, ADAPTER_ROLE);
        bytes4[] memory burn = new bytes4[](1);
        burn[0] = IVaultToken.burn.selector;
        am.setTargetFunctionRole(address(vt), burn, BURN_ROLE);
        am.grantRole(ADAPTER_ROLE, address(adapter), 0);
        am.grantRole(BURN_ROLE, address(adapter), 0);
        am.grantRole(BURN_ROLE, address(module), 0);
        am.grantRole(LIQUIDATION_ROLE, address(module), 0);
    }

    /// @dev Lists the pool's tokens on the Lend Spoke (the LPOracle's price Spoke), the debt asset on both Spokes and
    /// the vault token as a collateral reserve of the CDP Spoke with the LPOracle as its price source, makes the
    /// adapter a position manager of the CDP Spoke, and supplies the credit line, all through Aave's configurators.
    function _listOnAave() internal {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        bytes memory irData = abi.encode(InterestRateData(9000, 0, 400, 6000));
        IHubConfiguratorCalls hubCfg = IHubConfiguratorCalls(aave.hubConfigurator);
        ISpokeConfiguratorCalls spokeCfg = ISpokeConfiguratorCalls(aave.spokeConfigurator);
        feed0 = new BandTestFeed(8, 1e8);
        feed1 = new BandTestFeed(8, 1e8);

        vm.startPrank(aaveDao);
        priceReserve0 = _listOnLend(address(t0), address(feed0), irData);
        priceReserve1 = _listOnLend(address(t1), address(feed1), irData);
        uint256 lendDebtReserve = _listDebt(irData);
        vm.stopPrank();

        oracle = new LPOracle(
            ILPOracle.Params({
                lpVault: address(vault),
                marketId: MARKET,
                unitDecimals: 18,
                priceSpoke: aave.lendSpoke,
                reserveId0: priceReserve0,
                reserveId1: priceReserve1,
                description: "Avana TKA/TKB v3 full-range unit"
            })
        );

        vm.startPrank(aaveDao);
        vtAssetId =
            hubCfg.addAssetWithDecimals(aave.hub, address(vt), 18, aave.treasurySpoke, 0, aave.irStrategy, irData);
        hubCfg.addSpoke(aave.hub, aave.cdpSpoke, vtAssetId, HubSpokeConfig(maxCap, 0, maxRp, true, false));
        vtReserveId = spokeCfg.addReserve(
            aave.cdpSpoke,
            aave.hub,
            vtAssetId,
            address(oracle),
            SpokeReserveConfig(0, false, false, false, false),
            SpokeDynamicReserveConfig(CF_BPS, _vtMaxBonus(), 0)
        );
        spokeCfg.updateLiquidationConfig(aave.cdpSpoke, _liquidationConfig());
        ILifecycleSpokeConfigurator(aave.spokeConfigurator).updatePositionManager(aave.cdpSpoke, address(adapter), true);
        vm.stopPrank();

        debt.mint(daoTreasury, 1e24);
        vm.startPrank(daoTreasury);
        debt.approve(aave.lendSpoke, 1e24);
        IAaveV4Spoke(aave.lendSpoke).supply(lendDebtReserve, 1e24, daoTreasury);
        vm.stopPrank();
    }

    /// @dev Lists the debt asset, a separate $1 token, on the Hub and as a borrowable reserve of both Spokes; called
    /// inside the DAO's prank. Sets `debt` and `debtReserveId` and returns the Lend Spoke reserve the credit line is
    /// supplied to.
    function _listDebt(
        bytes memory irData
    ) internal virtual returns (uint256 lendDebtReserve) {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint40 maxCap = hubView.MAX_ALLOWED_SPOKE_CAP();
        uint24 maxRp = hubView.MAX_RISK_PREMIUM_THRESHOLD();
        IHubConfiguratorCalls hubCfg = IHubConfiguratorCalls(aave.hubConfigurator);
        ISpokeConfiguratorCalls spokeCfg = ISpokeConfiguratorCalls(aave.spokeConfigurator);
        debtPrice = new VaultTokenTestPriceSource(1e8);
        debt = new ClTestToken("DEBT", 18);
        uint256 debtAssetId =
            hubCfg.addAssetWithDecimals(aave.hub, address(debt), 18, aave.treasurySpoke, 0, aave.irStrategy, irData);
        hubCfg.addSpoke(aave.hub, aave.lendSpoke, debtAssetId, HubSpokeConfig(maxCap, 0, maxRp, true, false));
        hubCfg.addSpoke(aave.hub, aave.cdpSpoke, debtAssetId, HubSpokeConfig(0, 1_000_000, maxRp, true, false));
        lendDebtReserve = spokeCfg.addReserve(
            aave.lendSpoke,
            aave.hub,
            debtAssetId,
            address(debtPrice),
            SpokeReserveConfig(0, false, false, true, false),
            SpokeDynamicReserveConfig(0, 10_000, 0)
        );
        debtReserveId = spokeCfg.addReserve(
            aave.cdpSpoke,
            aave.hub,
            debtAssetId,
            address(debtPrice),
            SpokeReserveConfig(0, false, false, true, false),
            SpokeDynamicReserveConfig(0, 10_000, 0)
        );
    }

    /// @dev A pool token as a Lend Spoke reserve priced by `feed`; called inside the DAO's prank.
    function _listOnLend(
        address token,
        address feed,
        bytes memory irData
    ) internal returns (uint256 reserveId) {
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        uint256 assetId = IHubConfiguratorCalls(aave.hubConfigurator)
            .addAssetWithDecimals(aave.hub, token, 18, aave.treasurySpoke, 0, aave.irStrategy, irData);
        IHubConfiguratorCalls(aave.hubConfigurator)
            .addSpoke(
                aave.hub,
                aave.lendSpoke,
                assetId,
                HubSpokeConfig(hubView.MAX_ALLOWED_SPOKE_CAP(), 0, hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false)
            );
        reserveId = ISpokeConfiguratorCalls(aave.spokeConfigurator)
            .addReserve(
                aave.lendSpoke,
                aave.hub,
                assetId,
                feed,
                SpokeReserveConfig(0, false, false, true, false),
                SpokeDynamicReserveConfig(0, 10_000, 0)
            );
    }

    function _market() internal view returns (IRiskModule.Market memory m) {
        m.pool = bytes32(uint256(uint160(address(pool))));
        m.spoke = aave.cdpSpoke;
        m.vaultToken = address(vt);
        m.lpOracle = address(oracle);
        m.reserveId = vtReserveId;
        (m.priceReserveId0, m.priceReserveId1) = (priceReserve0, priceReserve1);
        m.bandLower = FULL_LOWER;
        m.bandUpper = FULL_UPPER;
        m.ltvBps = CF_BPS;
        m.unitDecimals = 18;
        m.kind = IRiskModule.MarketKind.FullRange;
        m.active = true;
    }

    function _constructInPlace(
        address at,
        bytes memory initCode
    ) internal returns (address) {
        vm.etch(at, initCode);
        (bool ok, bytes memory runtime) = at.call("");
        require(ok && runtime.length != 0, "constructor reverted");
        vm.etch(at, runtime);
        return at;
    }
}
