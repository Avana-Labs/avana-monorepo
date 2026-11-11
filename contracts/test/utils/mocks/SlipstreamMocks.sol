// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {MintableToken} from "./UniswapV3Mocks.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice Slipstream pool stand-in, deployed by `MockCLFactory` as an EIP-1167 clone of one implementation and
/// initialized once, as Slipstream's `CLFactory` does: the immutables of `ICLPoolConstants` (`factory`, `token0`,
/// `token1`, `tickSpacing`, `nft`, `gauge`), the 6-field `slot0`, a settable dynamic `fee`, `liquidity` and `observe`.
contract MockCLPool {
    address public factory;
    address public token0;
    address public token1;
    int24 public tickSpacing;
    address public nft;
    address internal _gauge;
    uint24 public fee;

    uint160 public sqrtPriceX96;
    int24 public tick;
    uint16 public observationCardinality;
    bool public unlocked;
    uint128 public liquidity;

    int56[2] public tickCumulatives;
    uint160[2] public secondsPerLiquidity;
    bool public observeReverts;
    bool public gaugeReverts;

    function initialize(
        address factory_,
        address token0_,
        address token1_,
        int24 tickSpacing_,
        address nft_,
        uint24 fee_
    ) external {
        require(factory == address(0), "initialized");
        (factory, token0, token1, tickSpacing, nft, fee) = (factory_, token0_, token1_, tickSpacing_, nft_, fee_);
        sqrtPriceX96 = uint160(ClPriceMath.Q96);
        observationCardinality = 1;
        unlocked = true;
        liquidity = 1e18;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (sqrtPriceX96, tick, 0, observationCardinality, observationCardinality, unlocked);
    }

    function gauge() external view returns (address) {
        require(!gaugeReverts, "gauge");
        return _gauge;
    }

    function setGauge(
        address g
    ) external {
        _gauge = g;
    }

    /// @notice A pool whose `gauge()` reverts (a gauge read that fails counts as no gauge).
    function setGaugeReverts(
        bool on
    ) external {
        gaugeReverts = on;
    }

    function setFee(
        uint24 f
    ) external {
        fee = f;
    }

    function setPrice(
        int24 tick_
    ) external {
        tick = tick_;
        sqrtPriceX96 = ClPriceMath.sqrtRatioAtTick(tick_);
    }

    function setUnlocked(
        bool on
    ) external {
        unlocked = on;
    }

    function setLiquidity(
        uint128 l
    ) external {
        liquidity = l;
    }

    function setObservations(
        uint16 cardinality,
        int56 tc0,
        int56 tc1,
        uint160 spl0,
        uint160 spl1,
        bool reverts
    ) external {
        observationCardinality = cardinality;
        tickCumulatives = [tc0, tc1];
        secondsPerLiquidity = [spl0, spl1];
        observeReverts = reverts;
    }

    function observe(
        uint32[] calldata
    ) external view returns (int56[] memory tc, uint160[] memory spl) {
        require(!observeReverts, "OLD");
        tc = new int56[](2);
        spl = new uint160[](2);
        (tc[0], tc[1]) = (tickCumulatives[0], tickCumulatives[1]);
        (spl[0], spl[1]) = (secondsPerLiquidity[0], secondsPerLiquidity[1]);
    }
}

/// @notice Leaf voter stand-in of the Aero generation: `isGauge(address)` reverts, as observed on Base.
contract MockLeafVoter {
    function isGauge(
        address
    ) external pure returns (bool) {
        revert("isGauge");
    }
}

/// @notice Slipstream `CLFactory` stand-in: deploys pools as EIP-1167 clones of `poolImplementation`, looks them up
/// by tick spacing in either token order, enables spacings through `tickSpacingToFee`, and names a leaf voter whose
/// `isGauge` reverts. `register` maps a key to any address (a non-canonical pool).
contract MockCLFactory {
    address public immutable poolImplementation;
    address public immutable voter;
    address public nft;
    mapping(address => mapping(address => mapping(int24 => address))) public getPool;
    mapping(int24 => uint24) public tickSpacingToFee;

    constructor() {
        poolImplementation = address(new MockCLPool());
        voter = address(new MockLeafVoter());
        tickSpacingToFee[1] = 100;
        tickSpacingToFee[50] = 500;
        tickSpacingToFee[100] = 500;
        tickSpacingToFee[200] = 3000;
        tickSpacingToFee[2000] = 10_000;
    }

    function setNft(
        address nft_
    ) external {
        nft = nft_;
    }

    function enableTickSpacing(
        int24 spacing,
        uint24 fee
    ) external {
        tickSpacingToFee[spacing] = fee;
    }

    function createPool(
        address tokenA,
        address tokenB,
        int24 spacing
    ) external returns (address pool) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pool = Clones.cloneDeterministic(poolImplementation, keccak256(abi.encode(t0, t1, spacing)));
        MockCLPool(pool).initialize(address(this), t0, t1, spacing, nft, tickSpacingToFee[spacing]);
        getPool[t0][t1][spacing] = pool;
        getPool[t1][t0][spacing] = pool;
    }

    function register(
        address tokenA,
        address tokenB,
        int24 spacing,
        address pool
    ) external {
        getPool[tokenA][tokenB][spacing] = pool;
        getPool[tokenB][tokenA][spacing] = pool;
    }
}

/// @notice Slipstream NonfungiblePositionManager stand-in on OpenZeppelin ERC-721: the 12-field `positions` with
/// `int24 tickSpacing` in field 5, `factory()`, a permissionless `increaseLiquidity`, `decreaseLiquidity` priced at
/// the pool's `slot0` with the slippage check, `collect` paying owed tokens from its own balance, and `burn` of an
/// empty position, each restricted to the owner or an approved address, as on the canonical manager.
contract MockSlipstreamNPM is ERC721 {
    struct Position {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    address public immutable factory;
    uint256 public nextId = 1;
    mapping(uint256 => Position) internal _positions;
    bool public overrideAmounts;
    uint256 public override0;
    uint256 public override1;
    uint256 public decreaseCalls;
    uint256 public collectCalls;

    constructor(
        address factory_
    ) ERC721("Slipstream Position NFT v1", "AERO-CL-POS") {
        factory = factory_;
    }

    function mint(
        address to,
        address token0,
        address token1,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external returns (uint256 tokenId) {
        tokenId = nextId++;
        _positions[tokenId] = Position(token0, token1, tickSpacing, tickLower, tickUpper, liquidity, 0, 0);
        _mint(to, tokenId);
    }

    /// @notice Mints a chosen token ID (overlapping IDs across generations).
    function mintId(
        uint256 tokenId,
        address to,
        address token0,
        address token1,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external {
        _positions[tokenId] = Position(token0, token1, tickSpacing, tickLower, tickUpper, liquidity, 0, 0);
        _mint(to, tokenId);
    }

    function positions(
        uint256 tokenId
    )
        external
        view
        returns (uint96, address, address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Position memory p = _positions[tokenId];
        require(p.token0 != address(0), "Invalid token ID");
        return (
            0,
            address(0),
            p.token0,
            p.token1,
            p.tickSpacing,
            p.tickLower,
            p.tickUpper,
            p.liquidity,
            0,
            0,
            p.owed0,
            p.owed1
        );
    }

    function increaseLiquidity(
        uint256 tokenId,
        uint128 liquidity
    ) external {
        _positions[tokenId].liquidity += liquidity;
    }

    function accrue(
        uint256 tokenId,
        uint128 amount0,
        uint128 amount1
    ) external {
        Position storage p = _positions[tokenId];
        p.owed0 += amount0;
        p.owed1 += amount1;
        MintableToken(p.token0).mint(address(this), amount0);
        MintableToken(p.token1).mint(address(this), amount1);
    }

    function setOverride(
        bool on,
        uint256 a0,
        uint256 a1
    ) external {
        (overrideAmounts, override0, override1) = (on, a0, a1);
    }

    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1) {
        require(_isAuthorized(_ownerOf(params.tokenId), msg.sender, params.tokenId), "NA");
        require(params.liquidity > 0, "liquidity");
        Position storage p = _positions[params.tokenId];
        p.liquidity -= params.liquidity;
        decreaseCalls++;
        if (overrideAmounts) {
            (amount0, amount1) = (override0, override1);
        } else {
            address pool = MockCLFactory(factory).getPool(p.token0, p.token1, p.tickSpacing);
            (amount0, amount1) = ClPriceMath.amountsForLiquidity(
                MockCLPool(pool).sqrtPriceX96(),
                ClPriceMath.sqrtRatioAtTick(p.tickLower),
                ClPriceMath.sqrtRatioAtTick(p.tickUpper),
                params.liquidity
            );
            require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "PSC");
        }
        p.owed0 += uint128(amount0);
        p.owed1 += uint128(amount1);
        MintableToken(p.token0).mint(address(this), amount0);
        MintableToken(p.token1).mint(address(this), amount1);
    }

    function collect(
        CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1) {
        require(params.amount0Max > 0 || params.amount1Max > 0, "caps");
        require(_isAuthorized(_ownerOf(params.tokenId), msg.sender, params.tokenId), "NA");
        Position storage p = _positions[params.tokenId];
        amount0 = p.owed0 < params.amount0Max ? p.owed0 : params.amount0Max;
        amount1 = p.owed1 < params.amount1Max ? p.owed1 : params.amount1Max;
        p.owed0 -= uint128(amount0);
        p.owed1 -= uint128(amount1);
        collectCalls++;
        if (amount0 > 0) IERC20(p.token0).transfer(params.recipient, amount0);
        if (amount1 > 0) IERC20(p.token1).transfer(params.recipient, amount1);
    }

    /// @notice Burns an empty position; owner or approved only, as on the canonical manager.
    function burn(
        uint256 tokenId
    ) external payable {
        require(_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId), "NA");
        Position storage p = _positions[tokenId];
        require(p.liquidity == 0 && p.owed0 == 0 && p.owed1 == 0, "NC");
        delete _positions[tokenId];
        _burn(tokenId);
    }
}

/// @notice Slipstream `CLGauge` stand-in: `deposit` stakes an NFT of its pool from its owner (the gauge then owns it),
/// `withdraw` returns it to its staker, and `getReward` pays AERO to the staker of a staked NFT.
contract MockCLGauge is IERC721Receiver {
    address public immutable pool;
    MockSlipstreamNPM public immutable nft;
    MintableToken public immutable rewardToken;
    mapping(uint256 => address) public stakerOf;

    constructor(
        address pool_,
        MockSlipstreamNPM nft_,
        MintableToken rewardToken_
    ) {
        (pool, nft, rewardToken) = (pool_, nft_, rewardToken_);
    }

    function deposit(
        uint256 tokenId
    ) external {
        require(nft.ownerOf(tokenId) == msg.sender, "NA");
        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        stakerOf[tokenId] = msg.sender;
    }

    function withdraw(
        uint256 tokenId
    ) external {
        require(stakerOf[tokenId] == msg.sender, "NA");
        delete stakerOf[tokenId];
        nft.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    function getReward(
        uint256 tokenId
    ) external {
        require(stakerOf[tokenId] == msg.sender, "NA");
        rewardToken.mint(msg.sender, 1e18);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
