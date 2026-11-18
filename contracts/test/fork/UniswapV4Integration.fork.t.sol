// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV4Integration} from "../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {UniswapV4State} from "../../src/amm/uniswap-v4/UniswapV4State.sol";
import {ILPVaultBase} from "../../src/custody/lp-vault/ILPVaultBase.sol";
import {
    IUniswapV4PoolManager,
    UniswapV4PoolKey
} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The canonical v4 PositionManager calls the test makes.
interface IV4ForkPosm {
    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 deadline
    ) external payable;
    function nextTokenId() external view returns (uint256);
    function approve(
        address to,
        uint256 tokenId
    ) external;
    function ownerOf(
        uint256 tokenId
    ) external view returns (address);
}

interface IV4ForkPermit2 {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}

interface IV4ForkUnlock {
    function unlock(
        bytes calldata data
    ) external returns (bytes memory);
}

/// @notice Calls the LPVault's read guard from inside the PoolManager's `unlock` callback.
contract V4ForkUnlockProbe {
    address internal immutable _PM;
    bytes4 public probed;
    bool public ran;

    constructor(
        address pm
    ) {
        _PM = pm;
    }

    function probe(
        IUniswapV4Integration vault,
        uint256 marketId
    ) external {
        IV4ForkUnlock(_PM).unlock(abi.encode(vault, marketId));
    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(msg.sender == _PM, "pool manager");
        (IUniswapV4Integration vault, uint256 marketId) = abi.decode(data, (IUniswapV4Integration, uint256));
        ran = true;
        try vault.checkReadSafe(marketId) {}
        catch (bytes memory reason) {
            probed = bytes4(reason);
        }
        return "";
    }
}

/// @title UniswapV4IntegrationForkTest
/// @notice `TEST-331` for the Uniswap v4 LPVault on the Ethereum fork, against the canonical PoolManager,
/// PositionManager and Permit2 and the hookless native ETH/USDC 0.05 % pool (tick spacing 10) that the unit tests replace
/// with the local v4 world, with the WETH/USDC 0.05 % Uniswap v3 pool as reference: a position minted with ether at the
/// market's exact range is validated and received with its liquidity as the credited units, another range is refused;
/// `unwind` of half the units with zero minimums pays the oracle-free composition at `slot0` to the recipient as WETH
/// and USDC (the ether taken, wrapped and swept in the same PositionManager batch) and leaves the LPVault no ether;
/// `collectFees` leaves the units; inside a real PoolManager `unlock` the read guard reverts `PoolLocked` (the
/// `exttload` of `Lock.IS_UNLOCKED_SLOT`), and passes outside it; the position goes back to its depositor. Logs the
/// gas of each LPVault call on the fork. Forks at the pinned Ethereum block when one is set, else at the latest
/// block; skipped without `RPC_MAINNET`.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract UniswapV4IntegrationForkTest`.
/// forge-config: default.isolate = false
contract UniswapV4IntegrationForkTest is AvanaTest {
    using SafeERC20 for IERC20;

    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant V3_WETH_USDC_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 internal constant MARKET = 1;
    int24 internal constant SPACING = 10;
    /// @dev v4-periphery `Actions` and `ActionConstants.MSG_SENDER`.
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant SETTLE_PAIR = 0x0d;
    uint8 internal constant SWEEP = 0x14;
    address internal constant MSG_SENDER = address(1);

    address internal adapter = makeAddr("aaveAdapter");
    address internal coll = makeAddr("collateralization");
    address internal registry = makeAddr("marketRegistry");
    address internal recipient = makeAddr("recipient");
    Lock internal lock;
    IUniswapV4Integration internal vault;
    UniswapV4PoolKey internal key;
    bytes32 internal poolId;
    int24 internal lower;
    int24 internal upper;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = ForkConstants.mainnetForkBlock();
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        lock = new Lock(adapter, makeAddr("lpVaultSwap"));
        vault = IUniswapV4Integration(
            deployCode(
                "UniswapV4Integration.sol:UniswapV4Integration",
                abi.encode(uint32(1), coll, registry, address(lock), makeAddr("timelock"), POSM, V3_FACTORY, 12)
            )
        );
        key = UniswapV4PoolKey(address(0), USDC, 500, SPACING, address(0));
        poolId = keccak256(abi.encode(key));
        (uint160 sqrtP, int24 tick) = UniswapV4State.slot0(IUniswapV4PoolManager(POOL_MANAGER), poolId);
        assertGt(sqrtP, 0, "the ETH/USDC 0.05% v4 pool is initialized");
        int24 base = (tick / SPACING) * SPACING;
        (lower, upper) = (base - 100 * SPACING, base + 100 * SPACING);
        // ETH in USD (8 decimals) at the pool's price: sqrtP^2 / 2^192 USDC units per wei, times 10^12 and 10^8.
        uint256 ethPrice = Math.mulDiv(Math.mulDiv(sqrtP, sqrtP, 1 << 96), 1e20, 1 << 96);
        vm.prank(registry);
        vault.bindMarket(
            MARKET,
            address(0),
            poolId,
            PositionShape(ShapeKind.TickRange, lower, upper),
            abi.encode(key, V3_WETH_USDC_500, ethPrice, uint256(1e8))
        );
        vm.label(address(vault), "UniswapV4LPVault");
    }

    // TEST-341 verifies: REQ-AMM-V4-001, REQ-AMM-V4-003, REQ-AMM-V4-004, REQ-AMM-V4-007, SPEC-AMM-V4-003
    // TEST-116 verifies: REQ-AMM-CORE-005, REQ-AMM-CORE-007, REQ-AMM-CORE-008; shared: this is the Uniswap v4 integration's run on its chain's fork through the AMM integration interface (exact range received, other ranges refused, removal)
    function test_TEST_341_uniswapV4CustodyNativeRemovalAndReadGuard() public {
        uint128 l = 1e15;
        uint256 id = _mint(alice, lower, upper, l);
        bytes32 positionKey = bytes32(id);

        // Any other range of the same pool is refused.
        uint256 other = _mint(alice, lower - SPACING, upper, l);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultBase.RangeMismatch.selector, lower - SPACING, upper));
        vault.validatePosition(MARKET, alice, bytes32(other));

        // Received at the exact range: the credited units are the position's liquidity in the market's unit.
        uint128 units = vault.validatePosition(MARKET, alice, positionKey);
        assertGt(units, 0, "units credited");
        vm.prank(alice);
        IV4ForkPosm(POSM).approve(address(vault), id);
        _lock();
        vm.prank(coll);
        uint256 g = gasleft();
        assertEq(vault.receivePosition(MARKET, alice, positionKey), units);
        emit log_named_uint("fork gas: receivePosition", g - gasleft());
        _unlock();
        assertEq(IV4ForkPosm(POSM).ownerOf(id), address(vault));

        // Half the units with zero minimums: WETH and USDC to the recipient, no ether left in the LPVault.
        uint128 half = units / 2;
        uint256 w0 = IERC20(WETH).balanceOf(recipient);
        uint256 u0 = IERC20(USDC).balanceOf(recipient);
        _lock();
        vm.prank(coll);
        g = gasleft();
        uint256[] memory out = vault.unwind(positionKey, half, new uint256[](2), recipient);
        emit log_named_uint("fork gas: unwind half, native ETH", g - gasleft());
        _unlock();
        assertGt(out[0], 0, "ether out, as WETH");
        assertGt(out[1], 0, "USDC out");
        assertEq(IERC20(WETH).balanceOf(recipient) - w0, out[0], "WETH to the recipient");
        assertEq(IERC20(USDC).balanceOf(recipient) - u0, out[1], "USDC to the recipient");
        assertEq(address(vault).balance, 0, "the LPVault keeps no ether");
        assertEq(vault.unitsOf(positionKey), units - half);

        // Fees never take principal.
        _lock();
        vm.prank(coll);
        g = gasleft();
        vault.collectFees(positionKey, alice);
        emit log_named_uint("fork gas: collectFees, native ETH", g - gasleft());
        _unlock();
        assertEq(vault.unitsOf(positionKey), units - half, "fees never take principal");

        // The PoolManager's unlock blocks the LPVault's reads; outside it they pass.
        V4ForkUnlockProbe probe = new V4ForkUnlockProbe(POOL_MANAGER);
        probe.probe(vault, MARKET);
        assertTrue(probe.ran());
        assertEq(probe.probed(), ILPVaultBase.PoolLocked.selector, "PoolLocked inside unlock");
        vault.checkReadSafe(MARKET);

        _lock();
        vm.prank(coll);
        assertEq(vault.returnPosition(positionKey), alice);
        _unlock();
        assertEq(IV4ForkPosm(POSM).ownerOf(id), alice);
    }

    // ─── Helpers ───

    /// @dev Mints `liquidity` on `[lo, hi]` to `owner` through the canonical PositionManager, paid with ether and
    /// USDC through Permit2; the ether left is swept back.
    function _mint(
        address owner,
        int24 lo,
        int24 hi,
        uint128 liquidity
    ) internal returns (uint256 id) {
        vm.deal(owner, 1000 ether);
        deal(USDC, owner, 10_000_000e6);
        vm.startPrank(owner);
        IERC20(USDC).forceApprove(PERMIT2, type(uint256).max);
        IV4ForkPermit2(PERMIT2).approve(USDC, POSM, type(uint160).max, type(uint48).max);
        id = IV4ForkPosm(POSM).nextTokenId();
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, lo, hi, uint256(liquidity), type(uint128).max, type(uint128).max, owner, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(address(0), MSG_SENDER);
        IV4ForkPosm(POSM).modifyLiquidities{value: 100 ether}(
            abi.encode(abi.encodePacked(MINT_POSITION, SETTLE_PAIR, SWEEP), params), block.timestamp
        );
        vm.stopPrank();
        assertEq(IV4ForkPosm(POSM).ownerOf(id), owner, "minted");
    }

    function _lock() internal {
        vm.prank(adapter);
        lock.acquire();
    }

    function _unlock() internal {
        vm.prank(adapter);
        lock.release();
    }
}
