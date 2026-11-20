// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../src/integrations/shared/ClTickMath.sol";
import {UniswapV2Integration} from "../../src/integrations/uniswap-v2/UniswapV2Integration.sol";
import {UniswapV2Positions} from "../../src/integrations/uniswap-v2/UniswapV2Positions.sol";
import {ILPVault} from "../../src/vault/interfaces/ILPVault.sol";
import {MockUniswapV2Factory, MockUniswapV2Pair} from "./mocks/UniswapV2Mocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

interface IMintable {
    function mint(
        address to,
        uint256 amount
    ) external;
}

/// @notice A v2 factory and pair, the position wrapper and the Uniswap v2 LPVault with its Full range market listed.
abstract contract UniswapV2TestBase is Test {
    uint64 internal constant ADAPTER_ROLE = 11;
    uint256 internal constant FULL = 1;

    MockUniswapV2Factory internal factory;
    MockUniswapV2Pair internal pair;
    UniswapV2Positions internal positions;
    UniswapV2Integration internal vault;
    AccessManager internal am;
    address internal t0;
    address internal t1;

    address internal adapter = makeAddr("adapter");
    address internal user = makeAddr("user");
    address internal other = makeAddr("other");
    address internal account = makeAddr("account");
    address internal recipient = makeAddr("recipient");
    address internal attacker = makeAddr("attacker");

    /// @dev Deploys everything on the tokens `a` and `b` and seeds the pair with `seed0`/`seed1` from a third party.
    function _deploy(
        address a,
        address b,
        uint256 seed0,
        uint256 seed1
    ) internal {
        (t0, t1) = a < b ? (a, b) : (b, a);
        factory = new MockUniswapV2Factory();
        pair = MockUniswapV2Pair(factory.createPair(t0, t1));
        positions = new UniswapV2Positions(address(factory));
        am = new AccessManager(address(this));
        vault = new UniswapV2Integration(address(am), address(positions), address(factory));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = ILPVault.pledge.selector;
        selectors[1] = ILPVault.removeLiquidity.selector;
        selectors[2] = ILPVault.release.selector;
        selectors[3] = ILPVault.collectFees.selector;
        selectors[4] = ILPVault.unwind.selector;
        selectors[5] = ILPVault.addLiquidity.selector;
        am.setTargetFunctionRole(address(vault), selectors, ADAPTER_ROLE);
        am.grantRole(ADAPTER_ROLE, adapter, 0);
        vault.listMarket(FULL, _word(address(pair)), ClTickMath.MIN_TICK, ClTickMath.MAX_TICK);
        _lp(makeAddr("seeder"), seed0, seed1);
        vm.prank(user);
        positions.setApprovalForAll(address(vault), true);
        vm.prank(other);
        positions.setApprovalForAll(address(vault), true);
        vm.prank(attacker);
        positions.setApprovalForAll(address(vault), true);
    }

    /// @dev Adds `a0`/`a1` to the pair and mints the LP to `to`.
    function _lp(
        address to,
        uint256 a0,
        uint256 a1
    ) internal returns (uint256 lp) {
        IMintable(t0).mint(address(pair), a0);
        IMintable(t1).mint(address(pair), a1);
        lp = pair.mint(to);
    }

    /// @dev `who` wraps `lp` of its LP into a new position.
    function _wrap(
        address who,
        uint256 lp
    ) internal returns (bytes32 key) {
        vm.startPrank(who);
        pair.approve(address(positions), lp);
        key = bytes32(positions.wrap(address(pair), lp, who));
        vm.stopPrank();
    }

    /// @dev `who` gets LP for `a0`/`a1`, wraps it and pledges it to the Full range market.
    function _position(
        address who,
        uint256 a0,
        uint256 a1
    ) internal returns (bytes32 key, uint128 credit) {
        key = _wrap(who, _lp(who, a0, a1));
        vm.prank(adapter);
        credit = vault.pledge(who, account, FULL, key);
    }

    /// @dev Swaps `amountIn` of token0 (or token1) through the pair for the most the k check allows.
    function _swap(
        address who,
        bool zeroForOne,
        uint256 amountIn
    ) internal {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 out = amountIn * 997 * rOut / (rIn * 1000 + amountIn * 997);
        if (out == 0) return;
        IMintable(zeroForOne ? t0 : t1).mint(address(pair), amountIn);
        vm.prank(who);
        pair.swap(zeroForOne ? 0 : out, zeroForOne ? out : 0, who, "");
    }

    function _held(
        bytes32 key
    ) internal view returns (uint256 lp) {
        (, lp) = positions.positions(uint256(key));
    }

    function _bal(
        address token,
        address who
    ) internal view returns (uint256) {
        return IERC20(token).balanceOf(who);
    }

    function _word(
        address a
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
