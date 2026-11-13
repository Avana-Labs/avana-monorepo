// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SlipstreamIntegration} from "../../src/amm/slipstream/SlipstreamIntegration.sol";
import {UniswapV3Integration} from "../../src/amm/uniswap-v3/UniswapV3Integration.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/external/uniswap/INonfungiblePositionManager.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {
    CollHubSpokeConfig,
    CollInterestRateData,
    CollPriceSource,
    CollSpokeDynamicReserveConfig,
    CollSpokeReserveConfig,
    CollateralizationFixture,
    ICollHubConfigurator,
    ICollSpokeConfigurator
} from "../utils/fixtures/CollateralizationFixture.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The real Collateralization, Lock, VaultTokenFactory and vault token on the local Aave V4, deployed on a
/// fork, with a production AMM integration bound to a live pool: the market and listing steps both fork suites share.
abstract contract CollateralizationForkBase is CollateralizationFixture {
    uint32 internal constant LIVE_INTEGRATION = 2;
    uint256 internal constant LIVE_MARKET = 5;

    VaultToken internal liveToken;
    uint256 internal liveReserve;
    address internal liveProxy = makeAddr("liveProxy");

    function _select(
        string memory rpcVar,
        uint256 blockNumber
    ) internal returns (bool ok) {
        string memory rpc = vm.envOr(rpcVar, string(""));
        if (bytes(rpc).length == 0 || blockNumber == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, blockNumber);
        return true;
    }

    function _listLive(
        address integration,
        address livePool,
        int24 edge,
        uint8 decimals
    ) internal {
        vm.prank(timelock);
        factory.registerIntegration(LIVE_INTEGRATION, integration);
        vm.prank(timelock);
        liveToken = VaultToken(
            factory.deployVaultToken(
                LIVE_INTEGRATION,
                livePool,
                bytes32(0),
                PositionShape(ShapeKind.TickRange, -edge, edge),
                aave.hub,
                aave.cdpSpoke,
                LIVE_MARKET,
                address(oracle),
                decimals,
                "Avana live",
                "avLIVE"
            )
        );
        IAaveV4Hub hubView = IAaveV4Hub(aave.hub);
        bytes memory irData = abi.encode(CollInterestRateData(9000, 0, 400, 6000));
        CollPriceSource price = new CollPriceSource(2e8);
        vm.startPrank(aaveDao);
        uint256 assetId = ICollHubConfigurator(aave.hubConfigurator)
            .addAssetWithDecimals(
                aave.hub, address(liveToken), decimals, aave.treasurySpoke, 0, aave.irStrategy, irData
            );
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(
                aave.hub,
                aave.cdpSpoke,
                assetId,
                CollHubSpokeConfig(
                    hubView.MAX_ALLOWED_SPOKE_CAP(), 0, hubView.MAX_RISK_PREMIUM_THRESHOLD(), true, false
                )
            );
        liveReserve = ICollSpokeConfigurator(aave.spokeConfigurator)
            .addReserve(
                aave.cdpSpoke,
                aave.hub,
                assetId,
                address(price),
                CollSpokeReserveConfig(0, false, false, false, false),
                CollSpokeDynamicReserveConfig(8000, 10_500, 0)
            );
        vm.stopPrank();
    }

    /// @dev The Adapter's pledge of `key` into the live market: custody, credit, mint and supply in one Lock session.
    function _pledgeLive(
        address depositor,
        bytes32 key
    ) internal returns (uint128 credited) {
        vm.startPrank(adapter);
        lock.acquire();
        if (!liveToken.isValidProxy(liveProxy)) liveToken.addValidProxy(liveProxy);
        (, credited) = coll.pledge(depositor, liveProxy, address(liveToken), key, false);
        liveToken.mint(liveProxy, credited);
        vm.stopPrank();
        vm.startPrank(liveProxy);
        liveToken.approve(aave.cdpSpoke, credited);
        IAaveV4Spoke(aave.cdpSpoke).supply(liveReserve, credited, liveProxy);
        vm.stopPrank();
        vm.prank(adapter);
        lock.release();
    }

    function _withdrawLive(
        bytes32 key,
        uint256 units
    ) internal {
        vm.prank(adapter);
        lock.acquire();
        vm.prank(liveProxy);
        IAaveV4Spoke(aave.cdpSpoke).withdraw(liveReserve, units, liveProxy);
        vm.startPrank(adapter);
        liveToken.burn(liveProxy, units);
        coll.release(liveProxy, address(liveToken), key, units);
        lock.release();
        vm.stopPrank();
    }
}

/// @title CollateralizationUniswapV3ForkTest
/// @notice TEST-264 through Collateralization on an Ethereum fork: a live Uniswap v3 USDC/USDT 0.01 % position minted
/// on the canonical NFPM is pledged through the real Collateralization into the production Uniswap v3 LPVault, credited
/// at its liquidity, and returned whole on withdrawal; a position on another range is refused. Skipped without
/// `RPC_MAINNET` or a pinned block.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract CollateralizationUniswapV3ForkTest`.
/// forge-config: default.isolate = false
contract CollateralizationUniswapV3ForkTest is CollateralizationForkBase {
    address internal constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant POOL = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;
    int24 internal constant FULL = 887_272;

    UniswapV3Integration internal v3;
    address internal t0;
    address internal t1;

    function setUp() public {
        if (!_select("RPC_MAINNET", ForkConstants.mainnetForkBlock())) return;
        _deployCollateralization();
        v3 = new UniswapV3Integration(
            LIVE_INTEGRATION, address(coll), marketRegistry, address(lock), timelock, NFPM, FACTORY, 12
        );
        vm.prank(marketRegistry);
        (address[] memory tokens, uint8 d) = v3.bindMarket(
            LIVE_MARKET, POOL, bytes32(0), PositionShape(ShapeKind.TickRange, -FULL, FULL), abi.encode(1e8, 1e8)
        );
        (t0, t1) = (tokens[0], tokens[1]);
        _listLive(address(v3), POOL, FULL, d);
    }

    function _mint(
        int24 lower,
        int24 upper
    ) internal returns (uint256 id, uint128 liquidity) {
        deal(t0, alice, 100_000e6);
        deal(t1, alice, 100_000e6);
        vm.startPrank(alice);
        IERC20(t0).approve(NFPM, type(uint256).max);
        IERC20(t1).approve(NFPM, type(uint256).max);
        (id, liquidity,,) = INonfungiblePositionManager(NFPM)
            .mint(
                INonfungiblePositionManager.MintParams(
                    t0, t1, 100, lower, upper, 100_000e6, 100_000e6, 0, 0, alice, block.timestamp
                )
            );
        INonfungiblePositionManager(NFPM).approve(address(v3), id);
        vm.stopPrank();
    }

    // TEST-264 verifies: REQ-VAULT-003, REQ-VAULT-103, REQ-COLL-024, REQ-AMM-V3-001
    function test_TEST_264_liveV3PositionPledgedAndReturnedThroughCollateralization() public {
        (uint256 id, uint128 liquidity) = _mint(-FULL, FULL);
        bytes32 key = bytes32(id);
        uint128 credited = _pledgeLive(alice, key);
        assertEq(credited, liquidity, "credited at the position's liquidity");
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(id), address(v3), "the LPVault holds the NFT");
        BackingRecord memory r = coll.getRecord(coll.recordIdOf(LIVE_INTEGRATION, key));
        assertEq(r.depositor, alice, "depositor of record");
        assertEq(r.proxy, liveProxy, "the account's proxy");
        assertEq(liveToken.totalSupply(), credited, "supply = credited");
        _withdrawLive(key, credited);
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(id), alice, "the NFT returns whole");
        assertEq(coll.recordIdOf(LIVE_INTEGRATION, key), 0, "record closed");
        assertEq(liveToken.totalSupply(), 0, "supply 0");
    }

    // TEST-264 verifies: REQ-VAULT-103, REQ-AMM-V3-002
    function test_TEST_264_liveV3PositionOnAnotherRangeRefused() public {
        (uint256 id,) = _mint(-100, 100);
        vm.startPrank(adapter);
        lock.acquire();
        liveToken.addValidProxy(liveProxy);
        vm.expectRevert();
        coll.pledge(alice, liveProxy, address(liveToken), bytes32(id), false);
        lock.release();
        vm.stopPrank();
        assertEq(INonfungiblePositionManager(NFPM).ownerOf(id), alice, "the NFT stays with its owner");
        assertEq(coll.recordIdOf(LIVE_INTEGRATION, bytes32(id)), 0, "no record");
    }
}

interface ISlipstreamForkMint {
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

    function approve(
        address to,
        uint256 tokenId
    ) external;

    function ownerOf(
        uint256 tokenId
    ) external view returns (address);
}

/// @title CollateralizationSlipstreamForkTest
/// @notice TEST-265 through Collateralization on a Base fork: a live Aerodrome Slipstream WETH/USDC position minted on
/// the Aero generation's NPM is pledged through the real Collateralization into the production Slipstream LPVault,
/// credited at its liquidity and returned whole on withdrawal. Skipped without `RPC_BASE` or a pinned block.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract CollateralizationSlipstreamForkTest`.
/// forge-config: default.isolate = false
contract CollateralizationSlipstreamForkTest is CollateralizationForkBase {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant POOL = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24;
    int24 internal constant EDGE = (887_272 / 100) * 100;

    SlipstreamIntegration internal slip;
    address[4] internal npm = [
        0x827922686190790b37229fd06084350E74485b72,
        0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F,
        0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53,
        0x4857DB576eE0e45F10525eC59527BfD10beeC60b
    ];
    address[4] internal factories = [
        0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A,
        0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a,
        0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef,
        0x9CB220581b91b0C83223012FE69688b92aD07a76
    ];

    function setUp() public {
        if (!_select("RPC_BASE", ForkConstants.baseForkBlock())) return;
        _deployCollateralization();
        slip = new SlipstreamIntegration(
            LIVE_INTEGRATION, address(coll), marketRegistry, address(lock), timelock, npm, factories
        );
        vm.prank(marketRegistry);
        (, uint8 d) = slip.bindMarket(
            LIVE_MARKET,
            POOL,
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -EDGE, EDGE),
            abi.encode(uint8(3), uint256(3000e8), uint256(1e8))
        );
        _listLive(address(slip), POOL, EDGE, d);
    }

    // TEST-265 verifies: REQ-VAULT-003, REQ-COLL-024, REQ-AMM-SLIP-001, REQ-AMM-SLIP-002
    function test_TEST_265_liveSlipstreamPositionPledgedAndReturnedThroughCollateralization() public {
        deal(WETH, alice, 1e18);
        deal(USDC, alice, 4000e6);
        vm.startPrank(alice);
        IERC20(WETH).approve(npm[3], type(uint256).max);
        IERC20(USDC).approve(npm[3], type(uint256).max);
        (uint256 id, uint128 liquidity,,) = ISlipstreamForkMint(npm[3])
            .mint(
                ISlipstreamForkMint.MintParams(
                    WETH, USDC, 100, -EDGE, EDGE, 1e18, 4000e6, 0, 0, alice, block.timestamp, 0
                )
            );
        ISlipstreamForkMint(npm[3]).approve(address(slip), id);
        vm.stopPrank();
        bytes32 key = slip.positionKeyOf(3, id);
        uint128 credited = _pledgeLive(alice, key);
        assertEq(credited, liquidity, "credited at the position's liquidity");
        assertEq(ISlipstreamForkMint(npm[3]).ownerOf(id), address(slip), "the LPVault holds the NFT");
        _withdrawLive(key, credited);
        assertEq(ISlipstreamForkMint(npm[3]).ownerOf(id), alice, "the NFT returns whole");
        assertEq(coll.recordIdOf(LIVE_INTEGRATION, key), 0, "record closed");
    }
}
