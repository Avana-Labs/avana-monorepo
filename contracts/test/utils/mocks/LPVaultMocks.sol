// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPVault} from "../../../src/LPVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Mintable 18-decimal test token.
contract LPVaultTestToken is ERC20 {
    constructor(
        string memory symbol
    ) ERC20(symbol, symbol) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @notice A position manager with a linear price model: one unit of liquidity holds one unit of each token. Fees
/// are owed per position and either stay owed on a decrease (NFPM style) or are paid out with it (v4 style).
contract MockPositionManager is ERC721 {
    struct Pos {
        bytes32 pool;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 owed0;
        uint256 owed1;
    }

    IERC20 public immutable TOKEN0;
    IERC20 public immutable TOKEN1;
    mapping(uint256 tokenId => Pos pos) public pos;
    uint256 public nextId = 1;
    bool public feesOnDecrease;
    /// @dev A call made from inside `decrease`, to test the LPVault's guard.
    address public reenterTarget;
    bytes public reenterData;

    constructor(
        IERC20 token0,
        IERC20 token1
    ) ERC721("Positions", "POS") {
        (TOKEN0, TOKEN1) = (token0, token1);
    }

    function setFeesOnDecrease(
        bool on
    ) external {
        feesOnDecrease = on;
    }

    function setReenter(
        address target,
        bytes calldata data
    ) external {
        (reenterTarget, reenterData) = (target, data);
    }

    function mint(
        address to,
        bytes32 pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external returns (uint256 tokenId) {
        tokenId = nextId++;
        pos[tokenId] = Pos(pool, tickLower, tickUpper, liquidity, 0, 0);
        _mint(to, tokenId);
    }

    /// @dev Liquidity added by anyone, as the v3 NFPM allows; the tokens are minted, not pulled.
    function donateLiquidity(
        uint256 tokenId,
        uint128 liquidity
    ) external {
        pos[tokenId].liquidity += liquidity;
    }

    /// @dev Owed fees, backed by minted tokens.
    function accrue(
        uint256 tokenId,
        uint256 fee0,
        uint256 fee1
    ) external {
        LPVaultTestToken(address(TOKEN0)).mint(address(this), fee0);
        LPVaultTestToken(address(TOKEN1)).mint(address(this), fee1);
        pos[tokenId].owed0 += fee0;
        pos[tokenId].owed1 += fee1;
    }

    function increase(
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1
    ) external returns (uint128 liquidity, uint256 used0, uint256 used1) {
        require(_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId), "not approved");
        liquidity = uint128(amount0 < amount1 ? amount0 : amount1);
        (used0, used1) = (liquidity, liquidity);
        TOKEN0.transferFrom(msg.sender, address(this), used0);
        TOKEN1.transferFrom(msg.sender, address(this), used1);
        pos[tokenId].liquidity += liquidity;
    }

    function decrease(
        uint256 tokenId,
        uint128 liquidity
    ) external returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1) {
        require(_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId), "not approved");
        if (reenterTarget != address(0)) {
            (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        Pos storage p = pos[tokenId];
        p.liquidity -= liquidity;
        (amount0, amount1) = (liquidity, liquidity);
        LPVaultTestToken(address(TOKEN0)).mint(msg.sender, amount0);
        LPVaultTestToken(address(TOKEN1)).mint(msg.sender, amount1);
        if (feesOnDecrease) (fee0, fee1) = _pay(p, msg.sender);
    }

    function collect(
        uint256 tokenId
    ) external returns (uint256 fee0, uint256 fee1) {
        require(_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId), "not approved");
        return _pay(pos[tokenId], msg.sender);
    }

    function _pay(
        Pos storage p,
        address to
    ) private returns (uint256 fee0, uint256 fee1) {
        (fee0, fee1) = (p.owed0, p.owed1);
        (p.owed0, p.owed1) = (0, 0);
        if (fee0 != 0) TOKEN0.transfer(to, fee0);
        if (fee1 != 0) TOKEN1.transfer(to, fee1);
    }
}

/// @notice The LPVault on the mock position manager; pools are registered by the test.
contract MockLPVault is LPVault {
    struct PoolInfo {
        address token0;
        address token1;
        int24 tickSpacing;
    }

    MockPositionManager public immutable PM;
    mapping(bytes32 pool => PoolInfo info) public pools;

    constructor(
        address authority,
        MockPositionManager pm
    ) LPVault(authority) {
        PM = pm;
    }

    function setPool(
        bytes32 pool,
        int24 tickSpacing
    ) external {
        pools[pool] = PoolInfo(address(PM.TOKEN0()), address(PM.TOKEN1()), tickSpacing);
    }

    function _nft(
        bytes32 positionKey
    ) internal view override returns (IERC721, uint256) {
        return (IERC721(address(PM)), uint256(positionKey));
    }

    function _readPosition(
        bytes32 positionKey
    ) internal view override returns (bytes32 pool, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        (pool, tickLower, tickUpper, liquidity,,) = PM.pos(uint256(positionKey));
    }

    function _poolInfo(
        bytes32 pool
    ) internal view override returns (address token0, address token1, int24 tickSpacing) {
        PoolInfo memory info = pools[pool];
        if (info.token0 == address(0)) revert InvalidPool(pool);
        return (info.token0, info.token1, info.tickSpacing);
    }

    function _increase(
        Market storage m,
        bytes32 positionKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256,
        uint256
    ) internal override returns (uint128 liquidity, uint256 amount0, uint256 amount1, uint256, uint256) {
        IERC20(m.token0).approve(address(PM), amount0Desired);
        IERC20(m.token1).approve(address(PM), amount1Desired);
        (liquidity, amount0, amount1) = PM.increase(uint256(positionKey), amount0Desired, amount1Desired);
        return (liquidity, amount0, amount1, 0, 0);
    }

    function _decrease(
        Market storage,
        bytes32 positionKey,
        uint128 liquidity,
        uint256,
        uint256
    ) internal override returns (uint256, uint256, uint256, uint256) {
        return PM.decrease(uint256(positionKey), liquidity);
    }

    function _collect(
        Market storage,
        bytes32 positionKey
    ) internal override returns (uint256, uint256) {
        return PM.collect(uint256(positionKey));
    }

    function _uncollectedFees(
        Market storage,
        bytes32 positionKey
    ) internal view override returns (uint256 amount0, uint256 amount1) {
        (,,,, amount0, amount1) = PM.pos(uint256(positionKey));
    }
}
