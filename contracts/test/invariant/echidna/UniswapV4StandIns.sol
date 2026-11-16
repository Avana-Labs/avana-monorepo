// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {UniswapV4PoolKey} from "../../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Minimal ERC-20 of the v4 stand-ins: 6 decimals, open mint, a total supply (read at listing,
/// `REQ-AMM-V4-009`) and a blocklist: a mint to a blocklisted address reverts, as a token's transfer to it would.
contract V4StandInToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public blocked;
    uint256 public totalSupply;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function setBlocked(
        address who,
        bool on
    ) external {
        blocked[who] = on;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        require(!blocked[to], "blocklisted");
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @notice Stands in for the reference Uniswap v3 factory and its pool of the two tokens at once: `getPool` returns
/// this contract for its own pair and fee, and it answers `token0`, `token1` and `fee` (`REQ-AMM-V4-007`).
contract V4StandInReference {
    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 500;

    constructor(
        address a,
        address b
    ) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getPool(
        address a,
        address b,
        uint24 f
    ) external view returns (address) {
        return a == token0 && b == token1 && f == fee ? address(this) : address(0);
    }
}

/// @notice Stands in for the Uniswap v4 PoolManager and PositionManager in one contract (so a harness stays under
/// EIP-3860's initcode limit). The PoolManager side keeps pool state in v4-core's slot layout (pool state at
/// `keccak256(abi.encode(poolId, 6))`: `slot0`, the two global fee growths, then `ticks` at +4 and `positions` at +6)
/// and serves it through `extsload`, so the LPVault's `UniswapV4State` reads it as on the real PoolManager; ticks keep
/// no fee growth outside, so fee growth inside a range is the global growth while the price is in it. The
/// PositionManager side mints NFTs with v4's packed `PositionInfo` (pool id's upper 200 bits, upper and lower tick,
/// subscriber flag), checks ownership or approval like solmate's ERC-721, and runs `modifyLiquidities` batches of
/// `DECREASE_LIQUIDITY` (principal at `slot0` rounded down, as v4-core removes, plus the fees `Position.update`
/// credits; minimums on the principal only) and `TAKE_PAIR` (each non-zero credit minted to the recipient, as
/// v4-periphery skips a zero take); a batch must settle every credit.
contract V4StandInManager {
    bytes32 internal constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant MASK_UPPER_200_BITS = type(uint256).max << 56;
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant TAKE_PAIR = 0x11;

    address public immutable WETH9;
    uint256 public nextTokenId = 1;
    mapping(bytes32 slot => bytes32 value) internal _words;
    mapping(uint256 id => address owner) internal _owner;
    mapping(uint256 id => address spender) public getApproved;
    mapping(uint256 id => UniswapV4PoolKey key) internal _keys;
    mapping(uint256 id => uint256 info) internal _info;

    constructor(
        address weth
    ) {
        WETH9 = weth;
    }

    // ─── PoolManager ───

    function poolManager() external view returns (address) {
        return address(this);
    }

    function extsload(
        bytes32 slot
    ) external view returns (bytes32) {
        return _words[slot];
    }

    function extsload(
        bytes32 start,
        uint256 n
    ) external view returns (bytes32[] memory values) {
        values = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            values[i] = _words[bytes32(uint256(start) + i)];
        }
    }

    /// @notice The PoolManager is never unlocked here.
    function exttload(
        bytes32
    ) external pure returns (bytes32) {
        return bytes32(0);
    }

    function poolSlot(
        bytes32 poolId
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(poolId, uint256(6)));
    }

    function positionSlot(
        bytes32 poolId,
        bytes32 positionId
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(positionId, bytes32(uint256(poolSlot(poolId)) + 6)));
    }

    function initialize(
        bytes32 poolId,
        int24 tick
    ) external {
        _words[poolSlot(poolId)] = bytes32(uint256(ClPriceMath.sqrtRatioAtTick(tick)) | uint256(uint24(tick)) << 160);
    }

    /// @notice Adds to the pool's global fee growths (fees per unit of liquidity, Q128).
    function accrue(
        bytes32 poolId,
        uint256 g0,
        uint256 g1
    ) external {
        bytes32 s = poolSlot(poolId);
        unchecked {
            _words[bytes32(uint256(s) + 1)] = bytes32(uint256(_words[bytes32(uint256(s) + 1)]) + g0);
            _words[bytes32(uint256(s) + 2)] = bytes32(uint256(_words[bytes32(uint256(s) + 2)]) + g1);
        }
    }

    function slot0(
        bytes32 poolId
    ) public view returns (uint160 sqrtPriceX96, int24 tick) {
        uint256 w = uint256(_words[poolSlot(poolId)]);
        // forge-lint: disable-next-line(unsafe-typecast)
        (sqrtPriceX96, tick) = (uint160(w), int24(int256(w >> 160)));
    }

    /// @notice `Pool.getFeeGrowthInside` with no growth outside any tick.
    function feeGrowthInside(
        bytes32 poolId,
        int24 lower,
        int24 upper
    ) public view returns (uint256, uint256) {
        (, int24 tick) = slot0(poolId);
        if (tick < lower || tick >= upper) return (0, 0);
        bytes32 s = poolSlot(poolId);
        return (uint256(_words[bytes32(uint256(s) + 1)]), uint256(_words[bytes32(uint256(s) + 2)]));
    }

    /// @notice The fees the position of `id` would be credited now.
    function feesOwed(
        uint256 id
    ) public view returns (uint256 f0, uint256 f1) {
        (bytes32 poolId, int24 lower, int24 upper, bytes32 pos) = _locate(id);
        (uint128 liq, uint256 l0, uint256 l1) = _position(pos);
        if (liq == 0) return (0, 0);
        (uint256 g0, uint256 g1) = feeGrowthInside(poolId, lower, upper);
        unchecked {
            (g0, g1) = (g0 - l0, g1 - l1);
        }
        return (Math.mulDiv(g0, liq, Q128), Math.mulDiv(g1, liq, Q128));
    }

    function liquidityOf(
        uint256 id
    ) external view returns (uint128 liq) {
        (,,, bytes32 pos) = _locate(id);
        (liq,,) = _position(pos);
    }

    // ─── PositionManager ───

    function mint(
        address to,
        UniswapV4PoolKey calldata key,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        bool subscribed
    ) external returns (uint256 id) {
        id = nextTokenId++;
        _owner[id] = to;
        _keys[id] = key;
        bytes32 poolId = keccak256(abi.encode(key));
        _info[id] = (uint256(poolId) & MASK_UPPER_200_BITS) | uint256(uint24(upper)) << 32
            | uint256(uint24(lower)) << 8 | (subscribed ? 1 : 0);
        (uint256 g0, uint256 g1) = feeGrowthInside(poolId, lower, upper);
        (,,, bytes32 pos) = _locate(id);
        _setPosition(pos, liquidity, g0, g1);
    }

    function getPoolAndPositionInfo(
        uint256 id
    ) external view returns (UniswapV4PoolKey memory, uint256) {
        return (_keys[id], _info[id]);
    }

    function ownerOf(
        uint256 id
    ) public view returns (address o) {
        o = _owner[id];
        require(o != address(0), "NOT_MINTED");
    }

    function approve(
        address to,
        uint256 id
    ) external {
        require(msg.sender == ownerOf(id), "NOT_AUTHORIZED");
        getApproved[id] = to;
    }

    function transferFrom(
        address from,
        address to,
        uint256 id
    ) public {
        require(ownerOf(id) == from && to != address(0), "WRONG_FROM");
        require(msg.sender == from || msg.sender == getApproved[id], "NOT_AUTHORIZED");
        _owner[id] = to;
        delete getApproved[id];
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id
    ) external {
        transferFrom(from, to, id);
        require(
            IV4StandInReceiver(to).onERC721Received(msg.sender, from, id, "")
                == IV4StandInReceiver.onERC721Received.selector,
            "UNSAFE_RECIPIENT"
        );
    }

    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 deadline
    ) external payable {
        require(block.timestamp <= deadline, "DeadlinePassed");
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        uint256 c0;
        uint256 c1;
        for (uint256 i = 0; i < actions.length; ++i) {
            uint8 action = uint8(actions[i]);
            if (action == DECREASE_LIQUIDITY) {
                (uint256 id, uint256 liq, uint128 min0, uint128 min1,) =
                    abi.decode(params[i], (uint256, uint256, uint128, uint128, bytes));
                require(msg.sender == _owner[id] || msg.sender == getApproved[id], "NotApproved");
                (uint256 a0, uint256 a1) = _decrease(id, liq, min0, min1);
                (c0, c1) = (c0 + a0, c1 + a1);
            } else if (action == TAKE_PAIR) {
                (address t0, address t1, address to) = abi.decode(params[i], (address, address, address));
                if (c0 > 0) V4StandInToken(t0).mint(to, c0);
                if (c1 > 0) V4StandInToken(t1).mint(to, c1);
                (c0, c1) = (0, 0);
            } else {
                revert("UnsupportedAction");
            }
        }
        require(c0 == 0 && c1 == 0, "CurrencyNotSettled");
    }

    // ─── Internal ───

    function _decrease(
        uint256 id,
        uint256 liq,
        uint128 min0,
        uint128 min1
    ) internal returns (uint256 a0, uint256 a1) {
        (a0, a1) = _principalOf(id, liq);
        require(a0 >= min0 && a1 >= min1, "MinimumAmountInsufficient");
        (uint256 f0, uint256 f1) = feesOwed(id);
        _shrink(id, liq);
        (a0, a1) = (a0 + f0, a1 + f1);
    }

    function _principalOf(
        uint256 id,
        uint256 liq
    ) internal view returns (uint256, uint256) {
        (bytes32 poolId, int24 lower, int24 upper, bytes32 pos) = _locate(id);
        (uint128 have,,) = _position(pos);
        require(liq <= have, "liquidity");
        return _principal(poolId, lower, upper, liq);
    }

    /// @dev Removes `liq` from the position and moves its fee checkpoint to the growth inside now.
    function _shrink(
        uint256 id,
        uint256 liq
    ) internal {
        (bytes32 poolId, int24 lower, int24 upper, bytes32 pos) = _locate(id);
        (uint128 have,,) = _position(pos);
        (uint256 g0, uint256 g1) = feeGrowthInside(poolId, lower, upper);
        // forge-lint: disable-next-line(unsafe-typecast)
        _setPosition(pos, have - uint128(liq), g0, g1);
    }

    /// @dev The amounts removing `liq` releases at `slot0`, rounded down.
    function _principal(
        bytes32 poolId,
        int24 lower,
        int24 upper,
        uint256 liq
    ) internal view returns (uint256, uint256) {
        (uint160 sqrtPriceX96,) = slot0(poolId);
        uint160 sa = ClPriceMath.sqrtRatioAtTick(lower);
        uint160 sb = ClPriceMath.sqrtRatioAtTick(upper);
        // forge-lint: disable-next-line(unsafe-typecast)
        return ClPriceMath.amountsForLiquidity(sqrtPriceX96, sa, sb, uint128(liq));
    }

    /// @dev The pool id, ticks and position slot of `id` (owner this contract, salt `bytes32(id)`).
    function _locate(
        uint256 id
    ) internal view returns (bytes32 poolId, int24 lower, int24 upper, bytes32 pos) {
        uint256 info = _info[id];
        poolId = keccak256(abi.encode(_keys[id]));
        // forge-lint: disable-next-line(unsafe-typecast)
        (lower, upper) = (int24(int256(info >> 8)), int24(int256(info >> 32)));
        pos = positionSlot(poolId, keccak256(abi.encodePacked(address(this), lower, upper, bytes32(id))));
    }

    function _position(
        bytes32 pos
    ) internal view returns (uint128 liq, uint256 l0, uint256 l1) {
        // forge-lint: disable-next-line(unsafe-typecast)
        liq = uint128(uint256(_words[pos]));
        (l0, l1) = (uint256(_words[bytes32(uint256(pos) + 1)]), uint256(_words[bytes32(uint256(pos) + 2)]));
    }

    function _setPosition(
        bytes32 pos,
        uint128 liq,
        uint256 l0,
        uint256 l1
    ) internal {
        _words[pos] = bytes32(uint256(liq));
        _words[bytes32(uint256(pos) + 1)] = bytes32(l0);
        _words[bytes32(uint256(pos) + 2)] = bytes32(l1);
    }
}

interface IV4StandInReceiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}
