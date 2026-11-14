// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ClFeeGrowthPool, ClFeeTrackingNpm} from "./ClFeeGrowthMocks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice Uniswap v3 pool stand-in with the immutables, the 7-field `slot0`, `liquidity` and `observe` of v3-core.
/// @dev Deployed by `MockV3Factory` with CREATE2 and no constructor arguments (it reads them from the factory, as the
/// v3 `UniswapV3PoolDeployer` does), so every pool shares one init code hash. Fee growth (`feeGrowthGlobal*X128`, the
/// 8-field `ticks`) comes from `ClFeeGrowthPool`.
contract MockV3Pool is ClFeeGrowthPool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    uint160 public sqrtPriceX96 = uint160(ClPriceMath.Q96);
    int24 public tick;
    uint16 public observationCardinality = 1;
    bool public unlocked = true;
    uint128 public liquidity = 1e18;

    int56[2] public tickCumulatives;
    uint160[2] public secondsPerLiquidity;
    bool public observeReverts;

    constructor() {
        (factory, token0, token1, fee, tickSpacing) = MockV3Factory(msg.sender).parameters();
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, observationCardinality, observationCardinality, 0, unlocked);
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
        uint32[] calldata secondsAgos
    ) external view returns (int56[] memory tc, uint160[] memory spl) {
        require(!observeReverts, "OLD");
        tc = new int56[](2);
        spl = new uint160[](2);
        (tc[0], tc[1]) = (tickCumulatives[0], tickCumulatives[1]);
        (spl[0], spl[1]) = (secondsPerLiquidity[0], secondsPerLiquidity[1]);
        // As in v3-core, two reads of the same instant return the same accumulators (a zero delta).
        if (secondsAgos.length == 2 && secondsAgos[0] == secondsAgos[1]) (tc[0], spl[0]) = (tc[1], spl[1]);
    }

    /// @notice v3-core `ticks`: only `feeGrowthOutside0X128` and `feeGrowthOutside1X128` are kept.
    function ticks(
        int24 t
    ) external view returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        uint256[2] memory o = _feeGrowthOutside[t];
        return (0, 0, o[0], o[1], 0, 0, 0, o[0] != 0 || o[1] != 0);
    }

    function _currentTick() internal view override returns (int24) {
        return tick;
    }
}

/// @notice Uniswap v3 factory stand-in: deploys `MockV3Pool` at the CREATE2 address of `(token0, token1, fee)` and
/// answers `getPool` in either token order; `register` maps a key to any address (a non-canonical pool).
contract MockV3Factory {
    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
    }

    Parameters public parameters;

    /// @notice Init code hash of the pools this factory deploys (the harness's stand-in for the canonical hash).
    function poolInitCodeHash() external pure returns (bytes32) {
        return keccak256(type(MockV3Pool).creationCode);
    }
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee,
        int24 spacing
    ) external returns (address pool) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        parameters = Parameters(address(this), t0, t1, fee, spacing);
        pool = address(new MockV3Pool{salt: keccak256(abi.encode(t0, t1, fee))}());
        delete parameters;
        getPool[t0][t1][fee] = pool;
        getPool[t1][t0][fee] = pool;
    }

    function register(
        address tokenA,
        address tokenB,
        uint24 fee,
        address pool
    ) external {
        getPool[tokenA][tokenB][fee] = pool;
        getPool[tokenB][tokenA][fee] = pool;
    }
}

/// @notice Uniswap v3 NonfungiblePositionManager stand-in on OpenZeppelin ERC-721: the 12-field `positions`, a
/// permissionless `increaseLiquidity`, `decreaseLiquidity` priced at the pool's `slot0` with the v3 slippage check, and
/// `collect` paying owed tokens from its own balance, each restricted to the owner or an approved address. With
/// `setTrackFees(true)` it also runs the canonical fee update (`ClFeeTrackingNpm`).
contract MockNFPM is ERC721, ClFeeTrackingNpm {
    struct Position {
        address token0;
        address token1;
        uint24 fee;
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
    /// @dev When set, `decreaseLiquidity` returns these amounts and skips its slippage check (a non-canonical manager).
    bool public overrideAmounts;
    uint256 public override0;
    uint256 public override1;
    uint256 public decreaseCalls;
    uint256 public collectCalls;

    constructor(
        address factory_
    ) ERC721("Uniswap V3 Positions NFT-V1", "UNI-V3-POS") {
        factory = factory_;
    }

    function mint(
        address to,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external returns (uint256 tokenId) {
        tokenId = nextId++;
        _positions[tokenId] = Position(token0, token1, fee, tickLower, tickUpper, liquidity, 0, 0);
        _mint(to, tokenId);
        _snapshotFees(tokenId);
    }

    function positions(
        uint256 tokenId
    )
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        // Encoded in two static halves (one ABI word per field), which keeps the legacy code generator within its stack.
        bytes memory out = abi.encodePacked(_positionHead(tokenId), _positionTail(tokenId));
        assembly ("memory-safe") {
            return(add(out, 32), mload(out))
        }
    }

    function _positionHead(
        uint256 tokenId
    ) internal view returns (bytes memory) {
        Position storage p = _positions[tokenId];
        require(p.token0 != address(0), "Invalid token ID");
        return abi.encode(uint96(0), address(0), p.token0, p.token1, p.fee, p.tickLower);
    }

    function _positionTail(
        uint256 tokenId
    ) internal view returns (bytes memory) {
        Position storage p = _positions[tokenId];
        return abi.encode(p.tickUpper, p.liquidity, _feeLast[tokenId][0], _feeLast[tokenId][1], p.owed0, p.owed1);
    }

    /// @notice Anyone may add liquidity to any position, as on the canonical manager.
    function increaseLiquidity(
        uint256 tokenId,
        uint128 liquidity
    ) external {
        _updateFees(tokenId, false);
        _positions[tokenId].liquidity += liquidity;
    }

    /// @notice Accrues fees (or principal owed at pledge) to a position and funds them.
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
        require(_isAuthorized(_ownerOf(params.tokenId), msg.sender, params.tokenId), "Not approved");
        require(params.liquidity > 0, "liquidity");
        _updateFees(params.tokenId, false);
        Position storage p = _positions[params.tokenId];
        p.liquidity -= params.liquidity;
        decreaseCalls++;
        if (overrideAmounts) {
            (amount0, amount1) = (override0, override1);
        } else {
            address pool = MockV3Factory(factory).getPool(p.token0, p.token1, p.fee);
            (amount0, amount1) = ClPriceMath.amountsForLiquidity(
                MockV3Pool(pool).sqrtPriceX96(),
                ClPriceMath.sqrtRatioAtTick(p.tickLower),
                ClPriceMath.sqrtRatioAtTick(p.tickUpper),
                params.liquidity
            );
            require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "Price slippage check");
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
        require(_isAuthorized(_ownerOf(params.tokenId), msg.sender, params.tokenId), "Not approved");
        _updateFees(params.tokenId, true);
        Position storage p = _positions[params.tokenId];
        amount0 = p.owed0 < params.amount0Max ? p.owed0 : params.amount0Max;
        amount1 = p.owed1 < params.amount1Max ? p.owed1 : params.amount1Max;
        p.owed0 -= uint128(amount0);
        p.owed1 -= uint128(amount1);
        collectCalls++;
        if (amount0 > 0) IERC20(p.token0).transfer(params.recipient, amount0);
        if (amount1 > 0) IERC20(p.token1).transfer(params.recipient, amount1);
    }

    function _feePosition(
        uint256 tokenId
    ) internal view override returns (address pool, int24 lower, int24 upper, uint128 liquidity) {
        Position storage p = _positions[tokenId];
        pool = MockV3Factory(factory).getPool(p.token0, p.token1, p.fee);
        (lower, upper, liquidity) = (p.tickLower, p.tickUpper, p.liquidity);
    }

    function _creditFees(
        uint256 tokenId,
        uint128 amount0,
        uint128 amount1
    ) internal override {
        Position storage p = _positions[tokenId];
        unchecked {
            p.owed0 += amount0;
            p.owed1 += amount1;
        }
        MintableToken(p.token0).mint(address(this), amount0);
        MintableToken(p.token1).mint(address(this), amount1);
    }
}

/// @notice Open-mint ERC-20 with chosen decimals and an optional hook that calls a target on every transfer (an
/// ERC-777-style token re-entering mid-collect, TEST-222).
contract MintableToken is ERC20 {
    uint8 private immutable DECIMALS;
    address public hookTarget;
    bytes public hookData;
    bool public hookReverted;
    bytes public hookResult;

    constructor(
        string memory symbol_,
        uint8 decimals_
    ) ERC20(symbol_, symbol_) {
        DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function setHook(
        address target,
        bytes calldata data
    ) external {
        (hookTarget, hookData) = (target, data);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        super._update(from, to, value);
        if (hookTarget != address(0) && from != address(0)) {
            address target = hookTarget;
            hookTarget = address(0);
            (bool ok, bytes memory ret) = target.call(hookData);
            (hookReverted, hookResult) = (!ok, ret);
        }
    }
}

/// @notice Token without `decimals()` (listing refusal).
contract NoDecimalsToken {}

/// @notice ERC-721 holder that forwards nothing; used as a wallet that accepts `safeTransferFrom`.
contract NftHolder is IERC721Receiver {
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice ERC-721 that is not the canonical NFPM, for `UnsupportedNft`.
contract OtherNft is ERC721 {
    constructor() ERC721("Other", "OTH") {}

    function mint(
        address to,
        uint256 id
    ) external {
        _mint(to, id);
    }
}
