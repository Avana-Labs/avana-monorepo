// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SlipstreamIntegration} from "../../src/integrations/SlipstreamIntegration.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {AmmParityChecks} from "../utils/AmmParityChecks.sol";
import {ClPoolActor, ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

/// @notice Slipstream's `NonfungiblePositionManager.mint` (its MintParams carry the tick spacing and an initial price).
interface ISlipstreamNpmMint {
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

    function setApprovalForAll(
        address operator,
        bool approved
    ) external;
}

/// @notice The Slipstream factory and pool calls the test makes.
interface ISlipstreamFactoryAndPool {
    function createPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address pool);

    function setGaugeAndPositionManager(
        address gauge,
        address nft
    ) external;

    function feeGrowthGlobal0X128() external view returns (uint256);

    function feeGrowthGlobal1X128() external view returns (uint256);

    function unstakedFee() external view returns (uint24);
}

/// @notice The Voter's part Slipstream reads: its factory registry, and each pool's gauge and whether it is alive
/// (a live gauge turns on the unstaked fee, which every position held outside the gauge pays, Avana's included).
contract SlipstreamVoterStub {
    address public immutable factoryRegistry;
    address public immutable gauge;

    constructor(
        address registry,
        address gauge_
    ) {
        (factoryRegistry, gauge) = (registry, gauge_);
    }

    function gauges(
        address
    ) external view returns (address) {
        return gauge;
    }

    function isAlive(
        address
    ) external pure returns (bool) {
        return true;
    }
}

/// @notice The FactoryRegistry's part a pool reads: the gauge factory allowed to set its gauge and position manager.
contract SlipstreamRegistryStub {
    address public immutable gaugeFactory;

    constructor(
        address gaugeFactory_
    ) {
        gaugeFactory = gaugeFactory_;
    }

    function factoriesToPoolFactory(
        address
    ) external view returns (address, address) {
        return (address(0), gaugeFactory);
    }
}

/// @notice The Slipstream LPVault on the real pinned Slipstream contracts, v1.0.0 (37eead2) for generations 0 to 2 and
/// main (f8717fa) for generation 3: CLFactory, the CLPool implementation and NonfungiblePositionManager built from
/// `dependencies/` with Slipstream's own settings. Only the Voter and FactoryRegistry are stand-ins, with a live gauge,
/// so the unstaked fee applies as on Base.
contract LPVaultSlipstreamIntegrationTest is AmmParityChecks {
    using stdStorage for StdStorage;

    uint64 internal constant ADAPTER_ROLE = 11;
    int24 internal constant SPACING = 100;
    int24 internal constant BAND_LOWER = -6000;
    int24 internal constant BAND_UPPER = 6000;
    uint256 internal constant MARKET = 1;

    struct Run {
        uint8 g;
        address npm;
        address pool;
        bytes32 keyA;
        bytes32 keyB;
        uint256 idA;
        uint256 idB;
        int24[4] edges;
    }

    StdStorage internal store;
    address[4] internal factories;
    address[4] internal npms;
    SlipstreamIntegration internal vault;
    AccessManager internal am;
    ClPoolActor internal actor;
    ClTestToken internal t0;
    ClTestToken internal t1;

    address internal gaugeFactory = makeAddr("gaugeFactory");
    address internal gauge = makeAddr("gauge");
    address internal adapter = makeAddr("adapter");
    address internal lp = makeAddr("lp");
    address internal account = makeAddr("account");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        ClTestToken a = new ClTestToken("TKA", 18);
        ClTestToken b = new ClTestToken("TKB", 18);
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        address voter = address(new SlipstreamVoterStub(address(new SlipstreamRegistryStub(gaugeFactory)), gauge));
        for (uint256 g = 0; g < 4; ++g) {
            string memory out = g == 3 ? "out-slipstream-main" : "out-slipstream-v1";
            address impl = deployCode(string.concat(out, "/CLPool.sol/CLPool.json"));
            factories[g] = g == 3
                ? deployCode(string.concat(out, "/CLFactory.sol/CLFactory.json"), abi.encode(voter, factories[2], impl))
                : deployCode(string.concat(out, "/CLFactory.sol/CLFactory.json"), abi.encode(voter, impl));
            npms[g] = deployCode(
                string.concat(out, "/NonfungiblePositionManager.sol/NonfungiblePositionManager.json"),
                abi.encode(factories[g], makeAddr("WETH9"), address(0), "Slipstream Position NFT v1", "AERO-CL-POS")
            );
        }
        am = new AccessManager(address(this));
        vault = new SlipstreamIntegration(address(am), npms, factories);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = ILPVault.pledge.selector;
        selectors[1] = ILPVault.addLiquidity.selector;
        selectors[2] = ILPVault.removeLiquidity.selector;
        selectors[3] = ILPVault.release.selector;
        selectors[4] = ILPVault.collectFees.selector;
        am.setTargetFunctionRole(address(vault), selectors, ADAPTER_ROLE);
        am.grantRole(ADAPTER_ROLE, adapter, 0);

        actor = new ClPoolActor();
        t0.mint(address(actor), type(uint128).max);
        t1.mint(address(actor), type(uint128).max);
        t0.mint(lp, 1e30);
        t1.mint(lp, 1e30);
        vm.startPrank(lp);
        for (uint256 g = 0; g < 4; ++g) {
            t0.approve(npms[g], type(uint256).max);
            t1.approve(npms[g], type(uint256).max);
            ISlipstreamNpmMint(npms[g]).setApprovalForAll(address(vault), true);
        }
        t0.approve(address(vault), type(uint256).max);
        t1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Bug hunted: Avana's own fee-growth arithmetic (`NfpmLPVault._uncollectedFees` over Slipstream's
    /// ten-word `ticks()` and six-word `slot0()`), the amounts its oracle uses or the floor credit drifting from the
    /// real Slipstream pool and position manager, of either generation's code, with the unstaked fee taken from
    /// every swap. A random sequence of swaps crosses the position's and the band's ticks in both directions (stopping
    /// exactly on a tick and one tick to either side), with top-ups and partial removals in between, and the pool's
    /// global fee growth optionally starts at 2^256 − 10^36 so it wraps mid-run. After every step, for a position
    /// inside the band and one on exactly the band: fees and principal equal what the manager pays, to the wei, and
    /// the credit's band amounts are worth at most the principal at the pool's price.
    /// forge-config: default.fuzz.runs = 256
    /// forge-config: ci.fuzz.runs = 1000
    function testFuzz_parity_feesPrincipalAndCreditMatchTheSlipstreamManager(
        uint256 seed,
        bool mainGeneration,
        bool wrapGrowth
    ) public {
        Run memory run;
        run.g = mainGeneration ? 3 : 1;
        run.npm = npms[run.g];
        run.pool = _pool(run.g, wrapGrowth);
        assertEq(ISlipstreamFactoryAndPool(run.pool).unstakedFee(), 100_000, "the unstaked fee applies");

        int24 lo = int24(int256(seed % 120)) * SPACING - 6000;
        int24 hi = lo + SPACING + int24(int256((seed >> 16) % uint256(int256((BAND_UPPER - lo) / SPACING)))) * SPACING;
        hi = hi > BAND_UPPER ? BAND_UPPER : hi;
        run.edges = [lo, hi, BAND_LOWER, BAND_UPPER];
        (run.keyA, run.idA,) = _mint(run.g, lo, hi);
        uint128 lB;
        (run.keyB, run.idB, lB) = _mint(run.g, BAND_LOWER, BAND_UPPER);
        vm.startPrank(adapter);
        vault.pledge(lp, account, MARKET, run.keyA);
        assertEq(vault.pledge(lp, account, MARKET, run.keyB), lB, "a position on exactly the band is credited L");
        vm.stopPrank();

        for (uint256 i = 0; i < 8; ++i) {
            _step(run, uint256(keccak256(abi.encode(seed, i))));
            _checkNfpmParity(vault, run.npm, run.pool, run.keyA, run.idA, MARKET);
            _checkNfpmParity(vault, run.npm, run.pool, run.keyB, run.idB, MARKET);
        }
        // The view is what a real collect pays, not only what a rolled-back one does.
        _swapTo(run.pool, ClTickMath.getSqrtPriceAtTick(_target(seed >> 40, run.edges)));
        (uint256 v0, uint256 v1) = vault.feesOf(run.keyA);
        address owner = makeAddr("parityOwner");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = run.keyA;
        vm.prank(adapter);
        vault.collectFees(account, keys, owner);
        assertEq(t0.balanceOf(owner), v0, "token0 paid as viewed");
        assertEq(t1.balanceOf(owner), v1, "token1 paid as viewed");
    }

    /// @dev One random step: a swap to a target (three times in five), a top-up or a removal of a third.
    function _step(
        Run memory run,
        uint256 r
    ) internal {
        bytes32 k = (r >> 8) % 2 == 0 ? run.keyA : run.keyB;
        uint256 action = r % 5;
        if (action < 3) {
            _swapTo(run.pool, ClTickMath.getSqrtPriceAtTick(_target(r >> 16, run.edges)));
        } else if (action == 3) {
            vm.prank(adapter);
            vault.addLiquidity(k, lp, 1e17, 1e17, 0, 0);
        } else {
            uint128 l = vault.getPosition(k).liquidity / 3;
            if (l > 0) {
                vm.prank(adapter);
                vault.removeLiquidity(k, l, 0, 0, recipient);
            }
        }
    }

    /// @dev A pool of generation `g` at price 1 with its gauge and position manager set, full-range liquidity from the
    /// actor, listed as `MARKET`.
    function _pool(
        uint8 g,
        bool wrapGrowth
    ) internal returns (address p) {
        p = ISlipstreamFactoryAndPool(factories[g])
            .createPool(address(t0), address(t1), SPACING, ClTickMath.getSqrtPriceAtTick(0));
        vm.prank(gaugeFactory);
        ISlipstreamFactoryAndPool(p).setGaugeAndPositionManager(gauge, npms[g]);
        if (wrapGrowth) {
            store.target(p).sig("feeGrowthGlobal0X128()").checked_write(type(uint256).max - 1e36);
            store.target(p).sig("feeGrowthGlobal1X128()").checked_write(type(uint256).max - 1e36);
        }
        actor.mint(IClPool(p), -887_200, 887_200, 1e18);
        vault.listMarket(MARKET, bytes32(uint256(uint160(p))), BAND_LOWER, BAND_UPPER);
    }

    function _mint(
        uint8 g,
        int24 lower,
        int24 upper
    ) internal returns (bytes32 key, uint256 tokenId, uint128 liquidity) {
        vm.prank(lp);
        (tokenId, liquidity,,) = ISlipstreamNpmMint(npms[g])
            .mint(
                ISlipstreamNpmMint.MintParams({
                    token0: address(t0),
                    token1: address(t1),
                    tickSpacing: SPACING,
                    tickLower: lower,
                    tickUpper: upper,
                    amount0Desired: 1e18,
                    amount1Desired: 1e18,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: lp,
                    deadline: block.timestamp,
                    sqrtPriceX96: 0
                })
            );
        key = vault.positionKeyOf(g, tokenId);
    }

    /// @dev Swaps the pool to `target` with unlimited input.
    function _swapTo(
        address p,
        uint160 target
    ) internal {
        uint160 now_ = _poolSqrtPrice(p);
        if (target == now_) return;
        actor.swap(IClPool(p), target < now_, type(int128).max, target);
    }

    /// @dev A swap target: one of the edges or a tick in [-9000, 9000], then moved by -1, 0 or +1 tick.
    function _target(
        uint256 r,
        int24[4] memory edges
    ) internal pure returns (int24 t) {
        uint256 idx = r % 5;
        t = idx < 4 ? edges[idx] : int24(int256((r >> 8) % 18_001)) - 9000;
        t += int24(int256((r >> 40) % 3)) - 1;
    }
}
