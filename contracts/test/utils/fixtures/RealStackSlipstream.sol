// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {RiskTier} from "../../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../../src/policy/market-registry/types/SpokeDef.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {AerodromeVoterStub} from "../mocks/AerodromeVoterStub.sol";
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
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice The Slipstream `CLFactory` and `CLGaugeFactory` functions the fixture calls.
interface ISlipFactoryAdmin {
    function createPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address pool);

    function setNonfungiblePositionManager(
        address nft
    ) external;
}

/// @notice The Aerodrome `FactoryRegistry` function the fixture calls.
interface IFactoryRegistryAdmin {
    function approve(
        address poolFactory,
        address votingRewardsFactory,
        address gaugeFactory
    ) external;
}

/// @notice Slipstream's `NonfungiblePositionManager.mint` (its `MintParams` carry the tick spacing and a price).
interface ISlipPositionManager {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    function mint(
        MintParams calldata params
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @title RealStackSlipstream
/// @notice `RealStackVolatile` with the second AMM integration, Aerodrome Slipstream, built as the world deployment
/// builds it (`script/deploy/lib/WorldAerodrome.sol`): four Slipstream generations from the vendored builds (v1.0.0 in
/// `out-slipstream-v1/` for generations 0 to 2, main in `out-slipstream-main/` for generation 3), each with its pool
/// implementation, `CLFactory`, `NonfungiblePositionManager`, `CLGauge` implementation and `CLGaugeFactory`, its path
/// approved in the real Aerodrome `FactoryRegistry`; every pool gets its real gauge from the gauge factory, which gives
/// the pool its `nft()`. The real `SlipstreamIntegration` over the four generations is registered as integration 2
/// (VaultTokenFactory and MarketRegistry, its eight AMM contracts recorded and finalized), with a CDP Spoke of its own
/// on each Hub ("slipstream-stable" on the Stable LP Hub, "slipstream-volatile" on the Volatile LP Hub, from Aave's Spoke
/// batch and role procedure), each with USDC (its DebtOracle) and GHO (fixed $1.00) debt reserves drawing on the Hub's
/// existing assets, First-Loss Reserves and credit lines. Markets are listed with `_addClMarket` and priced by real
/// `LPOracleCL`s with the six-word `slot0` layout.
/// @dev Stand-in beyond `RealStackVolatile`: Aerodrome's Voter and Minter (`AerodromeVoterStub`: read at construction
/// and the caller of `createGauge`); voting, emissions and gauge rewards are out of scope.
abstract contract RealStackSlipstream is RealStackVolatile {
    uint32 internal constant SLIP = 2;
    string internal constant SPOKE_CDP_SLIPSTREAM_STABLE = "slipstream-stable";
    string internal constant SPOKE_CDP_SLIPSTREAM_VOLATILE = "slipstream-volatile";

    address[4] internal slipFactories;
    address[4] internal slipNpms;
    address[4] internal slipGaugeFactories;
    AerodromeVoterStub internal aeroVoter;
    address internal slipVault;
    address internal slipSpokeS;
    address internal slipSpokeV;
    uint256 internal slipUsdcReserveS;
    uint256 internal slipGhoReserveS;
    uint256 internal slipUsdcReserveV;
    uint256 internal slipGhoReserveV;
    /// @dev Per Slipstream pool, its generation.
    mapping(address pool => uint8 generation) internal slipGenerationOf;

    /// @notice The Volatile Hub (`_setUpVolatile`), the four Slipstream generations, the Slipstream LPVault and its two
    /// CDP Spokes with their USDC and GHO debt reserves.
    function _setUpSlipstream() internal {
        _setUpVolatile();
        _deploySlipstreamAmm();
        _registerSlipstream();
        slipSpokeS = _slipSpoke(aave.hub, SPOKE_CDP_SLIPSTREAM_STABLE, RiskTier.Stable);
        slipSpokeV = _slipSpoke(hubV, SPOKE_CDP_SLIPSTREAM_VOLATILE, RiskTier.Volatile);
        slipUsdcReserveS = _slipDebt(aave.hub, slipSpokeS, usdc, usdcAssetId, address(usdcOracle), false);
        slipGhoReserveS = _slipDebt(aave.hub, slipSpokeS, gho, ghoAssetId, address(ghoPrice), true);
        slipUsdcReserveV = _slipDebt(hubV, slipSpokeV, usdc, usdcAssetIdV, address(usdcOracle), false);
        slipGhoReserveV = _slipDebt(hubV, slipSpokeV, gho, ghoAssetIdV, address(ghoPrice), true);
    }

    // ─── Aerodrome Slipstream ───

    function _deploySlipstreamAmm() private {
        ClTestToken aero = new ClTestToken("AERO", 18);
        address votingRewards = makeAddr("Aerodrome.VotingRewardsFactory");
        address registryAddr = deployCode(
            "out-aerodrome/FactoryRegistry.sol/FactoryRegistry.json",
            abi.encode(
                makeAddr("Aerodrome.PoolFactory"),
                votingRewards,
                makeAddr("Aerodrome.GaugeFactory"),
                makeAddr("Aerodrome.ManagedRewardsFactory")
            )
        );
        aeroVoter = new AerodromeVoterStub(registryAddr, address(aero));
        for (uint256 g = 0; g < 4; ++g) {
            _slipstreamGeneration(g);
            IFactoryRegistryAdmin(registryAddr).approve(slipFactories[g], votingRewards, slipGaugeFactories[g]);
        }
        vm.label(registryAddr, "Aerodrome.FactoryRegistry");
        vm.label(address(aeroVoter), "Aerodrome.Voter(stand-in)");
    }

    /// @dev Generation `g`: pool implementation, `CLFactory`, position manager, gauge implementation and gauge factory.
    /// The main build's factory names the previous generation's as its legacy factory, and its gauge factory takes an
    /// emission admin, a default emission cap (100 bps) and the previous generation's gauge factory.
    function _slipstreamGeneration(
        uint256 g
    ) private {
        string memory out = g == 3 ? "out-slipstream-main/" : "out-slipstream-v1/";
        string memory n = vm.toString(g);
        address poolImpl = deployCode(string.concat(out, "CLPool.sol/CLPool.json"));
        slipFactories[g] = deployCode(
            string.concat(out, "CLFactory.sol/CLFactory.json"),
            g == 3
                ? abi.encode(address(aeroVoter), slipFactories[2], poolImpl)
                : abi.encode(address(aeroVoter), poolImpl)
        );
        slipNpms[g] = deployCode(
            string.concat(out, "NonfungiblePositionManager.sol/NonfungiblePositionManager.json"),
            abi.encode(slipFactories[g], makeAddr("WETH9"), address(0), "Slipstream Position NFT v1", "AERO-CL-POS")
        );
        address gaugeImpl = deployCode(string.concat(out, "CLGauge.sol/CLGauge.json"));
        slipGaugeFactories[g] = deployCode(
            string.concat(out, "CLGaugeFactory.sol/CLGaugeFactory.json"),
            g == 3
                ? abi.encode(address(aeroVoter), gaugeImpl, address(this), uint256(100), slipGaugeFactories[2])
                : abi.encode(address(aeroVoter), gaugeImpl)
        );
        ISlipFactoryAdmin(slipGaugeFactories[g]).setNonfungiblePositionManager(slipNpms[g]);
        vm.label(slipFactories[g], string.concat("Slipstream.CLFactory.", n));
        vm.label(slipNpms[g], string.concat("Slipstream.PositionManager.", n));
    }

    /// @dev The real `SlipstreamIntegration`, registered in the VaultTokenFactory and the MarketRegistry with its four
    /// position managers and factories recorded and the record finalized.
    function _registerSlipstream() private {
        slipVault = deployCode(
            "SlipstreamIntegration.sol:SlipstreamIntegration",
            abi.encode(
                SLIP, address(coll), address(registry), address(lock), address(timelock), slipNpms, slipFactories
            )
        );
        vm.label(slipVault, "SlipstreamIntegration");
        address[] memory amm = new address[](8);
        for (uint256 g = 0; g < 4; ++g) {
            (amm[g], amm[4 + g]) = (slipNpms[g], slipFactories[g]);
        }
        vm.startPrank(address(timelock));
        vtFactory.registerIntegration(SLIP, slipVault);
        registry.registerIntegration(SLIP, slipVault, makeAddr("slipPricing"));
        registry.recordIntegrationContracts(SLIP, amm);
        registry.finalizeIntegrationContracts(SLIP);
        vm.stopPrank();
    }

    // ─── CDP Spokes and debt reserves ───

    /// @dev A CDP Spoke `label` on `hub` for Slipstream at `tier`: Aave's Spoke batch and role procedure (the fixture
    /// holds the AccessManager admin role only while it runs), its implementation hash approved and the Spoke recorded,
    /// its liquidation expectations, then the Aave DAO's liquidation configuration.
    function _slipSpoke(
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
        _setupSpokeRoles(spoke);
        vm.startPrank(address(timelock));
        registry.approveSpokeCodeHash(impl.codehash);
        registry.deployCdpSpoke(
            SpokeDef({
                approved: false, hub: hub, integrationId: SLIP, riskTier: tier, implementation: impl, aaveOracle: oracle
            })
        );
        store.setLiquidationExpectations(spoke, TARGET_HEALTH_FACTOR, 200);
        vm.stopPrank();
        vm.prank(aaveDao);
        ICollSpokeConfigurator(aave.spokeConfigurator)
            .updateLiquidationConfig(spoke, CollSpokeLiquidationConfig(1.1e18, 0.95e18, 5000));
        vm.label(spoke, string.concat("Aave.Spoke.", label));
    }

    /// @dev Aave's role procedure for `spoke`, the fixture holding the AccessManager admin role only while it runs.
    function _setupSpokeRoles(
        address spoke
    ) private {
        vm.prank(aaveDao);
        IAccessManager(aave.accessManager).grantRole(0, address(this), 0);
        (bool ok, bytes memory data) =
            aave.roles.delegatecall(abi.encodeCall(IAvanaAaveV4Roles.setupSpoke, (aave.accessManager, spoke)));
        _bubble(ok, data);
        IAccessManager(aave.accessManager).renounceRole(0, address(this));
    }

    /// @dev `asset` (Hub asset `assetId` of `hub`) as a borrowable reserve of `spoke` priced by `source`, drawing up to
    /// `DEBT_DRAW_CAP`, enabled with the Hub's First-Loss Reserve of the asset.
    function _slipDebt(
        address hub,
        address spoke,
        ClTestToken asset,
        uint256 assetId,
        address source,
        bool fixedPrice
    ) private returns (uint256 reserveId) {
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

    // ─── Pools, markets and positions ───

    /// @notice A real Slipstream pool of `a`/`b` and `spacing` on generation `g`, created at the tokens' published prices
    /// with its real gauge, an observation buffer of 151 slots and `liquidity` on its full range held by outside LPs.
    /// Call `_ageNewPools` once the pools of a suite exist.
    function _newSlipPool(
        uint8 g,
        ClTestToken a,
        ClTestToken b,
        int24 spacing,
        uint128 liquidity
    ) internal returns (IClPool p) {
        (ClTestToken t0, ClTestToken t1) = address(a) < address(b) ? (a, b) : (b, a);
        uint160 sqrtP =
            ClPriceMath.oracleSqrtPrice(_usdPrice(address(t0)), _usdPrice(address(t1)), t0.decimals(), t1.decimals());
        p = IClPool(ISlipFactoryAdmin(slipFactories[g]).createPool(address(t0), address(t1), spacing, sqrtP));
        aeroVoter.createGauge(slipGaugeFactories[g], address(p));
        p.increaseObservationCardinalityNext(151);
        t0.mint(address(actor), type(uint128).max);
        t1.mint(address(actor), type(uint128).max);
        slipGenerationOf[address(p)] = g;
        _seedFullRange(p, liquidity);
        vm.label(address(p), string.concat("CLPool ", t0.symbol(), "/", t1.symbol()));
    }

    /// @dev `liquidity` on the full range of `p`, held by the pool actor (outside LPs).
    function _seedFullRange(
        IClPool p,
        uint128 liquidity
    ) private {
        (int24 lower, int24 upper) = _fullRange(p);
        actor.mint(p, lower, upper, liquidity);
    }

    /// @notice Lists and activates the full range of the Slipstream pool `p` on the Slipstream Spoke of its tier (the
    /// Stable Spoke when both tokens are USD stables), CF `cf`.
    function _addSlipMarket(
        IClPool p,
        uint16 cf
    ) internal returns (uint256 id) {
        bool stable = _isStable(p.token0()) && _isStable(p.token1());
        id = _addClMarket(
            p,
            cf,
            ClSite({
                integrationId: SLIP,
                lpVault: slipVault,
                hub: stable ? aave.hub : hubV,
                spoke: stable ? slipSpokeS : slipSpokeV,
                ir: stable ? aave.irStrategy : irV,
                slot0Words: 6,
                generation: slipGenerationOf[address(p)]
            })
        );
    }

    /// @notice A full-range NFT in the Slipstream market `marketId` minted by `wallet` on its generation's position
    /// manager from about `usd` dollars (half in each token at the published prices), approved to the LPVault and
    /// pledged through the Adapter.
    function _slipPledgeUsd(
        address wallet,
        uint256 marketId,
        uint256 usd
    ) internal returns (bytes32 key, address proxy) {
        key = _slipMintUsd(wallet, marketId, usd);
        vm.prank(wallet);
        (proxy,,) = adapterC.pledge(marketId, PositionRef(SLIP, key), _deadline());
    }

    /// @notice The NFT of `_slipPledgeUsd`, minted and approved to the LPVault but not pledged; its key carries the
    /// generation in the top byte.
    function _slipMintUsd(
        address wallet,
        uint256 marketId,
        uint256 usd
    ) internal returns (bytes32 key) {
        IClPool p = mkt[marketId].pool;
        uint8 g = slipGenerationOf[address(p)];
        (ClTestToken t0, ClTestToken t1) = (ClTestToken(p.token0()), ClTestToken(p.token1()));
        uint256 a0 = usd * 10 ** t0.decimals() * 1e8 / (2 * _usdPrice(address(t0)));
        uint256 a1 = usd * 10 ** t1.decimals() * 1e8 / (2 * _usdPrice(address(t1)));
        t0.mint(wallet, a0);
        t1.mint(wallet, a1);
        vm.startPrank(wallet);
        t0.approve(slipNpms[g], a0);
        t1.approve(slipNpms[g], a1);
        uint256 tokenId = _slipMint(wallet, p, g, a0, a1);
        IERC721(slipNpms[g]).approve(slipVault, tokenId);
        vm.stopPrank();
        key = bytes32((uint256(g) << 248) | tokenId);
    }

    function _slipMint(
        address wallet,
        IClPool p,
        uint8 g,
        uint256 a0,
        uint256 a1
    ) private returns (uint256 tokenId) {
        (int24 lower, int24 upper) = _fullRange(p);
        (tokenId,,,) = ISlipPositionManager(slipNpms[g])
            .mint(
                ISlipPositionManager.MintParams({
                    token0: p.token0(),
                    token1: p.token1(),
                    tickSpacing: p.tickSpacing(),
                    tickLower: lower,
                    tickUpper: upper,
                    amount0Desired: a0,
                    amount1Desired: a1,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: wallet,
                    deadline: block.timestamp,
                    sqrtPriceX96: 0
                })
            );
    }
}
