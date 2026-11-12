// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SlipstreamIntegration} from "../../src/amm/slipstream/SlipstreamIntegration.sol";
import {ClMarketConfig} from "../../src/amm/types/ClMarketConfig.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {ICLFactory} from "../../src/interfaces/external/aerodrome/ICLFactory.sol";
import {ICLPool} from "../../src/interfaces/external/aerodrome/ICLPool.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/external/aerodrome/INonfungiblePositionManager.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The Slipstream NPM `mint`, whose parameters end with `sqrtPriceX96` (selector `0xb5007d1f`), and the ERC-721
/// calls the test makes; identical on the four generations.
interface ISlipstreamMint {
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
}

/// @notice The gauge staking call.
interface ICLGaugeStake {
    function deposit(
        uint256 tokenId
    ) external;
}

/// @title SlipstreamIntegrationForkTest
/// @notice TEST-265 on a Base fork: the production Slipstream LPVault against the four live NPM and factory generations
/// (Initial, Gauge Caps, Gauges V3, Aero). Every generation's manager names its factory, a pool of every generation
/// lists only with its own generation, a freshly minted position of generation 0 and of generation 3 is pledged,
/// partially unwound at the live price, collects fees only, and returns; a gauge-staked NFT is refused. Runs at
/// `ForkConstants.BASE_FORK_BLOCK`; skipped without `RPC_BASE` or a pinned block.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract SlipstreamIntegrationForkTest`.
/// forge-config: default.isolate = false
contract SlipstreamIntegrationForkTest is AvanaTest {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal adapter = makeAddr("aaveAdapter");
    address internal coll = makeAddr("collateralization");
    address internal registry = makeAddr("marketRegistry");
    Lock internal lock;
    SlipstreamIntegration internal vault;
    address[4] internal npm = [
        0x827922686190790b37229fd06084350E74485b72,
        0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F,
        0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53,
        0x4857DB576eE0e45F10525eC59527BfD10beeC60b
    ];
    address[4] internal factory = [
        0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A,
        0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a,
        0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef,
        0x9CB220581b91b0C83223012FE69688b92aD07a76
    ];
    /// @dev One pool per generation, read on Base: WETH/USDC spacing 100 (generations 0 and 3), spacing 200
    /// (generation 1) and spacing 100 (generation 2).
    address[4] internal pools = [
        0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59,
        0x4618dFcbC52d9fbCd45Ec4A65fc61B5DA57Ad205,
        0x717e174d5dAe280802D1a2c15C1C0976561A3f61,
        0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24
    ];

    function setUp() public {
        string memory rpc = vm.envOr("RPC_BASE", string(""));
        uint256 blockNumber = ForkConstants.baseForkBlock();
        if (bytes(rpc).length == 0 || blockNumber == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, blockNumber);
        lock = new Lock(adapter, makeAddr("lpVaultSwap"));
        vault = new SlipstreamIntegration(2, coll, registry, address(lock), makeAddr("timelock"), npm, factory);
    }

    // TEST-265 verifies: REQ-AMM-SLIP-006, REQ-AMM-SLIP-007, REQ-AMM-SLIP-008, SPEC-AMM-SLIP-001, REQ-AMM-SLIP-015, REQ-AMM-SLIP-016, INV-017
    // TEST-116 verifies: REQ-AMM-SLIP-007, INV-017
    // Sources: 2.21 generation allowlist (each pair read on Base); the Aero generation's ABI fork check
    function test_TEST_265_everyGenerationListsOnlyItsOwnPools() public {
        for (uint256 g = 0; g < 4; ++g) {
            assertEq(INonfungiblePositionManager(npm[g]).factory(), factory[g]);
            ICLPool p = ICLPool(pools[g]);
            assertEq(p.nft(), npm[g]);
            assertEq(p.factory(), factory[g]);
            assertTrue(ICLFactory(factory[g]).poolImplementation() != address(0));
            int24 s = p.tickSpacing();
            int24 edge = (887_272 / s) * s;
            for (uint256 h = 0; h < 4; ++h) {
                if (h == g) continue;
                vm.prank(registry);
                vm.expectRevert(ILPVaultErrors.InvalidPool.selector);
                vault.bindMarket(100 + g * 4 + h, pools[g], bytes32(0), _shape(-edge, edge), _data(h, 1e8, 1e8));
            }
            vm.prank(registry);
            vault.bindMarket(1 + g, pools[g], bytes32(0), _shape(-edge, edge), _data(g, 1e8, 1e8));
            ClMarketConfig memory cfg = vault.clMarket(1 + g);
            assertEq(cfg.positionManager, npm[g]);
            assertEq(cfg.tickSpacing, s);
            assertEq(cfg.fee, 0);
            vault.checkReadSafe(1 + g);
            vm.prank(registry);
            vm.expectRevert(ILPVaultErrors.InvalidShape.selector);
            vault.bindMarket(200 + g, pools[g], bytes32(0), _shape(-edge - 1, edge), _data(g, 1e8, 1e8));
        }
    }

    // TEST-265 verifies: REQ-AMM-SLIP-001, REQ-AMM-SLIP-002, REQ-AMM-SLIP-003, REQ-AMM-SLIP-004, REQ-AMM-SLIP-011, REQ-VAULT-147, REQ-VAULT-149, SPEC-BACK-008, INV-002
    // TEST-116 verifies: REQ-VAULT-147, REQ-VAULT-149, SPEC-BACK-008
    // Sources: 5.1 TEST-264/TEST-265 (custody of a live NFT, unwind at the live price, fees only)
    function test_TEST_265_custodyOfAFreshPositionOnGenerations0And3() public {
        uint256[2] memory gens = [uint256(0), 3];
        for (uint256 k = 0; k < 2; ++k) {
            uint256 g = gens[k];
            uint256 marketId = 10 + g;
            int24 edge = (887_272 / int24(100)) * 100;
            vm.prank(registry);
            vault.bindMarket(marketId, pools[g], bytes32(0), _shape(-edge, edge), _data(g, 3000e8, 1e8));
            (uint256 id, uint128 l) = _mintFullRange(g, edge);
            bytes32 key = vault.positionKeyOf(uint8(g), id);
            assertFalse(vault.isStaked(marketId, id));
            assertEq(vault.validatePosition(marketId, alice, key), l);
            vm.prank(alice);
            ISlipstreamMint(npm[g]).approve(address(vault), id);
            _lockAs();
            vm.startPrank(coll);
            assertEq(vault.receivePosition(marketId, alice, key), l);
            assertEq(vault.unitsOf(key), l);
            uint256 before0 = IERC20(WETH).balanceOf(bob);
            uint256[] memory amounts = vault.unwind(key, l / 2, new uint256[](2), bob);
            assertEq(IERC20(WETH).balanceOf(bob) - before0, amounts[0], "the recipient receives the principal");
            assertEq(vault.unitsOf(key), l - l / 2);
            vault.collectFees(key, alice);
            assertEq(vault.unitsOf(key), l - l / 2, "fees never take principal");
            assertEq(vault.returnPosition(key), alice);
            vm.stopPrank();
            _unlockAs();
            assertEq(INonfungiblePositionManager(npm[g]).ownerOf(id), alice);
        }
    }

    // TEST-265 verifies: REQ-AMM-SLIP-009, REQ-AMM-SLIP-019, REQ-AMM-SLIP-010
    // Sources: 2.21 REQ-AMM-SLIP-009 (a staked NFT is refused; the Aero voter's isGauge is never called)
    function test_TEST_265_aGaugeStakedPositionIsRefusedOnTheAeroGeneration() public {
        int24 edge = (887_272 / int24(100)) * 100;
        vm.prank(registry);
        vault.bindMarket(13, pools[3], bytes32(0), _shape(-edge, edge), _data(3, 3000e8, 1e8));
        (uint256 id,) = _mintFullRange(3, edge);
        address gauge = ICLPool(pools[3]).gauge();
        vm.startPrank(alice);
        ISlipstreamMint(npm[3]).approve(gauge, id);
        try ICLGaugeStake(gauge).deposit(id) {}
        catch {
            vm.stopPrank();
            return; // a killed gauge takes no stake; nothing to refuse
        }
        vm.stopPrank();
        bytes32 key = vault.positionKeyOf(3, id);
        assertTrue(vault.isStaked(13, id));
        vm.expectRevert(ILPVaultErrors.NotTokenOwner.selector);
        vault.validatePosition(13, alice, key);
        vm.expectRevert(ILPVaultErrors.PositionEncumbered.selector);
        vault.validatePosition(13, gauge, key);
    }

    function _mintFullRange(
        uint256 g,
        int24 edge
    ) internal returns (uint256 id, uint128 l) {
        deal(WETH, alice, 1e18);
        deal(USDC, alice, 4000e6);
        vm.startPrank(alice);
        IERC20(WETH).approve(npm[g], type(uint256).max);
        IERC20(USDC).approve(npm[g], type(uint256).max);
        (id, l,,) = ISlipstreamMint(npm[g])
            .mint(
                ISlipstreamMint.MintParams(WETH, USDC, 100, -edge, edge, 1e17, 400e6, 0, 0, alice, block.timestamp, 0)
            );
        vm.stopPrank();
    }

    function _lockAs() internal {
        vm.prank(adapter);
        lock.acquire();
    }

    function _unlockAs() internal {
        vm.prank(adapter);
        lock.release();
    }

    function _shape(
        int24 lower,
        int24 upper
    ) internal pure returns (PositionShape memory) {
        return PositionShape(ShapeKind.TickRange, lower, upper);
    }

    function _data(
        uint256 g,
        uint256 p0,
        uint256 p1
    ) internal pure returns (bytes memory) {
        return abi.encode(g, p0, p1);
    }
}
