// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapter} from "../../src/AaveAdapter.sol";
import {LPOracle} from "../../src/LPOracle.sol";
import {LiquidationModule} from "../../src/LiquidationModule.sol";
import {VaultToken} from "../../src/VaultToken.sol";
import {IAaveV4Hub} from "../../src/dependencies/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/dependencies/aave/IAaveV4Spoke.sol";
import {UniswapV2Integration} from "../../src/integrations/UniswapV2Integration.sol";
import {UniswapV2Positions} from "../../src/integrations/UniswapV2Positions.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";
import {IVaultToken} from "../../src/interfaces/IVaultToken.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {AaveV4MarketTestBase, ILifecycleSpokeConfigurator} from "../utils/AaveV4MarketTestBase.sol";
import {ClTestToken} from "../utils/fixtures/ClPoolFixture.sol";
import {BandTestFeed} from "../utils/mocks/BandOracleMocks.sol";
import {LiquidationTestRiskModule} from "../utils/mocks/LiquidationTestMocks.sol";
import {MockUniswapV2Factory, MockUniswapV2Pair} from "../utils/mocks/UniswapV2Mocks.sol";
import {
    HubSpokeConfig,
    IHubConfiguratorCalls,
    ISpokeConfiguratorCalls,
    InterestRateData,
    SpokeDynamicReserveConfig,
    SpokeReserveConfig
} from "./VaultToken.AaveV4.integration.t.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Shared measurement: what a liquidation paid out of the borrower's LP, against the worth of the units Aave
/// seized, both at Aave's own prices.
abstract contract LiquidationWorthMeasure is AaveV4MarketTestBase {
    /// @dev 8-decimal USD worth of `seized` vault-token units at the price Aave used (the LPOracle answer).
    function _seizedWorth(
        uint256 seized
    ) internal view returns (uint256) {
        return Math.mulDiv(seized, uint256(oracle.latestAnswer()), 1e18);
    }

    /// @dev 8-decimal USD worth of everything the unwind took out of the borrower's LP (liquidator plus fee share).
    function _paidWorth(
        ILiquidationModule.LiquidationResult memory r
    ) internal view returns (uint256) {
        uint256 p0 = uint256(feed0.latestAnswer());
        uint256 p1 = uint256(feed1.latestAnswer());
        return Math.mulDiv(r.amount0 + r.fee0, p0, 1e18) + Math.mulDiv(r.amount1 + r.fee1, p1, 1e18);
    }
}

/// @notice A partial liquidation of a Uniswap v2 position pays the seized units' worth and leaves the fee growth since
/// the pledge with the borrower, as v3 and v4 leave their fees. Regression of the adversarial review's V2-FEE: the unwind
/// burned the record's share of its LP, fee growth included, and paid that growth to the liquidator.
/// @dev Pinned real Aave V4 (Hub, CDP Spoke, Lend Spoke, LiquidationLogic) through Aave's configurators; Avana's real
/// AaveAdapter, VaultToken, LPOracle, LiquidationModule, UniswapV2Integration and UniswapV2Positions. The pair is the
/// repository's 0.8 port of v2-core (`MockUniswapV2Pair`): the repo pins no v2-core build, and the port keeps v2-core's
/// mint, burn, swap and 0.3% fee-into-k arithmetic. Both pool tokens are $1 on Aave, so the pool stays at the fair
/// price and no impermanent loss enters the numbers.
contract LiquidationUniswapV2FeeGrowthTest is LiquidationWorthMeasure {
    MockUniswapV2Factory internal v2factory;
    MockUniswapV2Pair internal pair;
    UniswapV2Positions internal positions;
    UniswapV2Integration internal v2vault;

    /// @dev A $10,000 position: 5,000 of each $1 token.
    uint256 internal constant HALF = 5000e18;

    /// @dev sqrt(k) per LP at the liquidation over its value at the pledge, 1e18 = no growth.
    uint256 internal growth;
    /// @dev Worth of the borrower's record LP just before the liquidation, USD 1e8.
    uint256 internal lpWorthBefore;

    function setUp() public override {
        _deployAaveV4();
        spoke = IAaveV4Spoke(aave.cdpSpoke);
        ClTestToken a = new ClTestToken("TKA", 18);
        ClTestToken b = new ClTestToken("TKB", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        v2factory = new MockUniswapV2Factory();
        pair = MockUniswapV2Pair(v2factory.createPair(address(t0), address(t1)));
        positions = new UniswapV2Positions(address(v2factory));
        am = new AccessManager(address(this));
        v2vault = new UniswapV2Integration(address(am), address(positions), address(v2factory));
        v2vault.listMarket(MARKET, _word(address(pair)), ClTickMath.MIN_TICK, ClTickMath.MAX_TICK);
        rm = new LiquidationTestRiskModule(address(v2vault));
        module = new LiquidationModule(address(rm));
        rm.setLiquidationModule(address(module));
        rm.setFee(2000, feeRecipient);
        adapter = new AaveAdapter(address(rm));
        vt = new VaultToken(
            IVaultToken.Params({
                name: "Avana TKA/TKB Uniswap v2 Full Range",
                symbol: "avTK-v2",
                decimals: 18,
                marketId: MARKET,
                hub: aave.hub,
                liquidationModule: address(module),
                authority: address(am)
            })
        );
        _grantRolesV2();
        _listOnAaveV2();
        rm.setMarket(MARKET, _marketV2());

        // A deep pair of third-party liquidity: 1,000,000 of each token.
        _lp(makeAddr("seeder"), 1_000_000e18, 1_000_000e18);

        debt.mint(liquidator, 1e24);
        vm.prank(liquidator);
        debt.approve(address(module), type(uint256).max);
    }

    /// @dev Dave pledges $10,000 of v2 LP, the pair then earns `growthBps` of fees (real swaps; v2 fees compound
    /// into k), he borrows $7,900 against the $10,000 credit, and both tokens fall 5% on Aave (health factor ~0.96).
    /// Returns the liquidation result and the account.
    function _scenario(
        uint256 growthBps
    ) internal returns (ILiquidationModule.LiquidationResult memory r, address account, bytes32 key) {
        key = _wrapNew(dave, HALF, HALF);
        (, uint128 credit) = _pledge(dave, key);
        account = adapter.accountOf(dave, MARKET);
        assertApproxEqRel(credit, HALF, 1e12, "full-range v2 credit is the position's liquidity: 5,000e18 units");

        uint256 rootBefore = _rootPerLp();
        _tradeUntil(rootBefore * (10_000 + growthBps) / 10_000);
        _rebalance();
        growth = Math.mulDiv(_rootPerLp(), 1e18, rootBefore);
        console2.log("fee growth of sqrt(k) per LP since the pledge (1e18 = none)", growth);
        assertEq(v2vault.getPosition(key).credit, credit, "the record and the vault tokens stay at the pledge");

        _borrow(dave, 7900e18);
        feed0.set(0.95e8);
        feed1.set(0.95e8);
        uint256 hf = spoke.getUserAccountData(account).healthFactor;
        console2.log("health factor before the liquidation", hf);
        assertLt(hf, 1e18);
        assertGt(hf, 0.95e18, "a routine liquidation, far from an emptied account");

        lpWorthBefore = _lpWorth(key);
        vm.prank(liquidator);
        r = module.liquidate(_params(account, 1e24));
        assertGt(spoke.getUserSuppliedAssets(vtReserveId, account), 0, "partial: the account is not emptied");
    }

    /// @notice With 10% fee growth since the pledge, the liquidation takes the seized units' worth from the borrower's
    /// LP, as Aave's rule takes from a normal collateral; the growth on the unwound share stays in the position.
    function test_v2PartialLiquidation_leavesFeeGrowthWithBorrower() public {
        (ILiquidationModule.LiquidationResult memory r,, bytes32 key) = _scenario(1000);
        assertGt(growth, 1.1e18, "the pair earned 10% since the pledge");
        uint256 seizedWorth = _seizedWorth(r.seized);
        uint256 paidWorth = _paidWorth(r);
        uint256 left = _lpWorth(key);
        console2.log("worth of the seized units at Aave's price, USD 1e8", seizedWorth);
        console2.log("worth taken from the borrower's LP, USD 1e8", paidWorth);
        console2.log("borrower's LP before and after, USD 1e8", lpWorthBefore, left);
        assertApproxEqRel(paidWorth, seizedWorth, 0.001e18, "the unwind is worth what Aave seized, not more");
        assertApproxEqRel(left, lpWorthBefore - seizedWorth, 0.001e18, "the borrower keeps the rest, growth included");
    }

    /// @notice Control: with no fee growth the same liquidation pays the seized units' worth, to rounding.
    function test_v2PartialLiquidation_noGrowth_paysSeizedWorth() public {
        (ILiquidationModule.LiquidationResult memory r,,) = _scenario(0);
        uint256 seizedWorth = _seizedWorth(r.seized);
        uint256 paidWorth = _paidWorth(r);
        console2.log("no growth: seized worth, USD 1e8", seizedWorth);
        console2.log("no growth: paid worth, USD 1e8", paidWorth);
        assertApproxEqRel(paidWorth, seizedWorth, 0.001e18, "no growth: the unwind is worth what Aave seized");
    }

    // ─── Helpers ───

    /// @dev sqrt(k) per LP token (1e18 scale), what one LP's v2 liquidity grows with as fees compound.
    function _rootPerLp() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        return Math.mulDiv(Math.sqrt(uint256(r0) * r1), 1e18, pair.totalSupply());
    }

    /// @dev Round trips through the pair until sqrt(k) per LP reaches `target`: the fees stay in the reserves.
    function _tradeUntil(
        uint256 target
    ) internal {
        address trader = makeAddr("trader");
        for (uint256 i; i < 200 && _rootPerLp() < target; ++i) {
            _swap(trader, true, 500_000e18);
            _swap(trader, false, 500_000e18);
        }
        assertGe(_rootPerLp(), target, "fee growth reached");
    }

    /// @dev One swap that brings the pair back to equal reserves (the $1/$1 fair price), so the measured excess is
    /// fee growth alone and not the pool sitting off Aave's price.
    function _rebalance() internal {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (r0 == r1) return;
        bool zeroForOne = r0 < r1;
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        (uint256 lo, uint256 hi) = (0, rOut - rIn);
        for (uint256 i; i < 128 && lo < hi; ++i) {
            uint256 mid = (lo + hi) / 2;
            uint256 out = mid * 997 * rOut / (rIn * 1000 + mid * 997);
            if (rIn + mid < rOut - out) lo = mid + 1;
            else hi = mid;
        }
        if (lo != 0) _swap(makeAddr("arbitrageur"), zeroForOne, lo);
        (r0, r1,) = pair.getReserves();
        assertApproxEqRel(uint256(r0), uint256(r1), 1e12, "the pair is back at the fair price");
    }

    function _swap(
        address who,
        bool zeroForOne,
        uint256 amountIn
    ) internal {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 out = amountIn * 997 * rOut / (rIn * 1000 + amountIn * 997);
        (zeroForOne ? t0 : t1).mint(address(pair), amountIn);
        vm.prank(who);
        pair.swap(zeroForOne ? 0 : out, zeroForOne ? out : 0, who, "");
    }

    /// @dev Worth at Aave's prices of the LP the position's record still holds in the pair.
    function _lpWorth(
        bytes32 key
    ) internal view returns (uint256) {
        (, uint256 lp) = positions.positions(uint256(key));
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        return Math.mulDiv(Math.mulDiv(lp, r0, supply), uint256(feed0.latestAnswer()), 1e18)
            + Math.mulDiv(Math.mulDiv(lp, r1, supply), uint256(feed1.latestAnswer()), 1e18);
    }

    function _lp(
        address to,
        uint256 a0,
        uint256 a1
    ) internal returns (uint256) {
        t0.mint(address(pair), a0);
        t1.mint(address(pair), a1);
        return pair.mint(to);
    }

    function _wrapNew(
        address who,
        uint256 a0,
        uint256 a1
    ) internal returns (bytes32 key) {
        uint256 lp = _lp(who, a0, a1);
        vm.startPrank(who);
        pair.approve(address(positions), lp);
        key = bytes32(positions.wrap(address(pair), lp, who));
        positions.setApprovalForAll(address(v2vault), true);
        vm.stopPrank();
    }

    function _grantRolesV2() internal {
        bytes4[] memory vaultSelectors = new bytes4[](5);
        vaultSelectors[0] = ILPVault.pledge.selector;
        vaultSelectors[1] = ILPVault.addLiquidity.selector;
        vaultSelectors[2] = ILPVault.removeLiquidity.selector;
        vaultSelectors[3] = ILPVault.release.selector;
        vaultSelectors[4] = ILPVault.collectFees.selector;
        am.setTargetFunctionRole(address(v2vault), vaultSelectors, ADAPTER_ROLE);
        bytes4[] memory unwind = new bytes4[](1);
        unwind[0] = ILPVault.unwind.selector;
        am.setTargetFunctionRole(address(v2vault), unwind, LIQUIDATION_ROLE);
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

    /// @dev `_listOnAave` of the base, with the v2 LPVault behind the LPOracle.
    function _listOnAaveV2() internal {
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
                lpVault: address(v2vault),
                marketId: MARKET,
                unitDecimals: 18,
                priceSpoke: aave.lendSpoke,
                reserveId0: priceReserve0,
                reserveId1: priceReserve1,
                description: "Avana TKA/TKB v2 full-range unit"
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

    function _marketV2() internal view returns (IRiskModule.Market memory m) {
        m.pool = _word(address(pair));
        m.spoke = aave.cdpSpoke;
        m.vaultToken = address(vt);
        m.lpOracle = address(oracle);
        m.reserveId = vtReserveId;
        (m.priceReserveId0, m.priceReserveId1) = (priceReserve0, priceReserve1);
        m.bandLower = ClTickMath.MIN_TICK;
        m.bandUpper = ClTickMath.MAX_TICK;
        m.ltvBps = CF_BPS;
        m.unitDecimals = 18;
        m.kind = IRiskModule.MarketKind.FullRange;
        m.active = true;
    }

    function _word(
        address x
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(x)));
    }
}

/// @notice The same check on Uniswap v3 (the real pinned factory, pool and NFPM): the same liquidation after fee
/// accrual pays the seized units' worth and the fees stay with the borrower's NFT.
contract LiquidationUniswapV3FeeControlTest is LiquidationWorthMeasure {
    function test_v3PartialLiquidation_paysSeizedWorth_feesStayWithBorrower() public {
        (bytes32 key,) = _mintFull(dave, 5000e18);
        _pledge(dave, key);
        address account = adapter.accountOf(dave, MARKET);
        for (uint256 i; i < 20; ++i) {
            _trade();
        }
        (uint256 fees0, uint256 fees1) = vault.feesOf(key);
        assertGt(fees0 + fees1, 0, "the position earned fees");
        _borrow(dave, 7900e18);
        feed0.set(0.95e8);
        feed1.set(0.95e8);
        vm.prank(liquidator);
        ILiquidationModule.LiquidationResult memory r = module.liquidate(_params(account, 1e24));
        uint256 seizedWorth = _seizedWorth(r.seized);
        uint256 paidWorth = _paidWorth(r);
        console2.log("v3: seized worth, USD 1e8", seizedWorth);
        console2.log("v3: paid worth, USD 1e8", paidWorth);
        assertApproxEqRel(paidWorth, seizedWorth, 0.001e18, "v3 pays the seized worth");
        (uint256 after0, uint256 after1) = vault.feesOf(key);
        assertGe(after0 + after1, fees0 + fees1, "v3 fees stay with the borrower");
    }
}
