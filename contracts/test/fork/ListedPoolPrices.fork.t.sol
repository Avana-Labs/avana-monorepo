// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV4PoolManager} from "../../src/dependencies/uniswap-v4/IUniswapV4PoolManager.sol";
import {UniswapV4State} from "../../src/integrations/UniswapV4State.sol";
import {LPPriceMath} from "../../src/libraries/LPPriceMath.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice The reads this test makes of Aave V3's AaveOracle, Chainlink, the pools, their factories and StateView.
interface IForkAaveOracle {
    function getAssetPrice(
        address asset
    ) external view returns (uint256);
}

interface IForkFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IForkClPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IForkV3Factory {
    function getPool(
        address a,
        address b,
        uint24 fee
    ) external view returns (address);
}

interface IForkClFactory {
    function getPool(
        address a,
        address b,
        int24 tickSpacing
    ) external view returns (address);
}

interface IForkStateView {
    function getSlot0(
        bytes32 poolId
    ) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

/// @title ListedPoolPricesForkTest
/// @notice For every pool the deployment config lists (`script/deploy/config/anvil.json`: Uniswap v3 and v4 on
/// Ethereum, Slipstream generation 0 on Base, the same pairs and fee tiers or tick spacings), the LPOracle's fair
/// square-root price `LPPriceMath.sqrtPriceX96` of Aave's own token prices is close to the pool's own square-root
/// price. Aave's prices are Aave V3's AaveOracle on each chain, whose sources (CAPO adapters for the stablecoins and
/// wstETH, Chainlink ETH/USD) are the ones Aave governance sets on Aave V4's AaveOracle, which the LPOracle reads;
/// Base's Aave V3 market has no USDT, so USDT there is Chainlink's USDT/USD feed. For the v4 pools Avana's own
/// `extsload` read of the PoolManager (`UniswapV4State.slot0`) must also equal Uniswap's StateView.
/// Tolerance: 50 bps on the square root, so about 1% on the price. A pool sits off the oracle by up to its fee tier
/// (1 or 5 bps) before arbitrage pays, and the feeds move only past their deviation thresholds (0.5% ETH/USD and 0.25%
/// USDC/USD and USDT/USD on Ethereum, 0.15% ETH/USD and 0.3% USDT/USD on Base), so up to about 0.8% on the price
/// between updates; wstETH adds the stETH market discount to its exchange rate (usually under 0.2%). 1% bounds all of
/// that, while the faults hunted are far larger: wrong decimals or token order are off by powers of ten, a wrong feed
/// by its whole price.
/// Forks at `ForkConstants`' pinned block of the chain when one is set, else at the latest block; skipped without
/// `RPC_MAINNET` or `RPC_BASE`.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract ListedPoolPricesForkTest`.
contract ListedPoolPricesForkTest is AvanaTest {
    uint256 internal constant SQRT_TOLERANCE_BPS = 50;

    // Ethereum.
    address internal constant ETH_AAVE_ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant V4_STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address internal constant ETH_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETH_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ETH_WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // Base.
    address internal constant BASE_AAVE_ORACLE = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;
    address internal constant SLIPSTREAM_FACTORY_0 = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address internal constant BASE_USDT_USD = 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant BASE_WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;

    bool internal onBase;

    /// @notice USDC-USDT-100, WETH-USDC-500 and wstETH-WETH-100 on Uniswap v3; USDC-USDT-v4-100, ETH-USDC-v4-500 and
    /// wstETH-ETH-v4-100 on Uniswap v4 (hookless, tick spacings 1, 10 and 1).
    function test_ethereumListedPools() public {
        if (!_fork(vm.envOr("RPC_MAINNET", string("")), ForkConstants.mainnetForkBlock())) return;
        _checkClPool("USDC-USDT-100", IForkV3Factory(V3_FACTORY).getPool(ETH_USDC, ETH_USDT, 100));
        _checkClPool("WETH-USDC-500", IForkV3Factory(V3_FACTORY).getPool(ETH_WETH, ETH_USDC, 500));
        _checkClPool("wstETH-WETH-100", IForkV3Factory(V3_FACTORY).getPool(ETH_WSTETH, ETH_WETH, 100));
        _checkV4Pool("USDC-USDT-v4-100", ETH_USDC, ETH_USDT, 100, 1);
        _checkV4Pool("ETH-USDC-v4-500", address(0), ETH_USDC, 500, 10);
        _checkV4Pool("wstETH-ETH-v4-100", address(0), ETH_WSTETH, 100, 1);
    }

    /// @notice USDC-USDT-cl1, WETH-USDC-cl100 and wstETH-WETH-cl1 on Slipstream generation 0.
    function test_baseListedPools() public {
        if (!_fork(vm.envOr("RPC_BASE", string("")), ForkConstants.baseForkBlock())) return;
        onBase = true;
        _checkClPool("USDC-USDT-cl1-g0", IForkClFactory(SLIPSTREAM_FACTORY_0).getPool(BASE_USDC, BASE_USDT, 1));
        _checkClPool("WETH-USDC-cl100-g0", IForkClFactory(SLIPSTREAM_FACTORY_0).getPool(BASE_WETH, BASE_USDC, 100));
        _checkClPool("wstETH-WETH-cl1-g0", IForkClFactory(SLIPSTREAM_FACTORY_0).getPool(BASE_WSTETH, BASE_WETH, 1));
    }

    function _fork(
        string memory rpc,
        uint256 pin
    ) internal returns (bool) {
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        return true;
    }

    /// @dev A Uniswap v3 or Slipstream pool: the first word of `slot0` is the square-root price either way.
    function _checkClPool(
        string memory name,
        address pool
    ) internal view {
        assertTrue(pool.code.length > 0, string.concat(name, ": pool deployed"));
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        require(ok && ret.length >= 32, "slot0");
        _compare(name, IForkClPool(pool).token0(), IForkClPool(pool).token1(), abi.decode(ret, (uint160)));
    }

    function _checkV4Pool(
        string memory name,
        address currency0,
        address currency1,
        uint24 fee,
        int24 spacing
    ) internal view {
        bytes32 id = keccak256(abi.encode(currency0, currency1, fee, spacing, address(0)));
        (uint160 s,) = UniswapV4State.slot0(IUniswapV4PoolManager(V4_POOL_MANAGER), id);
        (uint160 lens,,,) = IForkStateView(V4_STATE_VIEW).getSlot0(id);
        assertGt(s, 0, string.concat(name, ": pool initialized"));
        assertEq(s, lens, string.concat(name, ": Avana's extsload read differs from StateView"));
        _compare(name, currency0, currency1, s);
    }

    /// @dev `|oracle − pool| ≤ pool · SQRT_TOLERANCE_BPS / 10^4` on the square-root prices.
    function _compare(
        string memory name,
        address token0,
        address token1,
        uint160 poolSqrt
    ) internal view {
        uint160 oracleSqrt =
            LPPriceMath.sqrtPriceX96(_price(token0), _price(token1), _decimals(token0), _decimals(token1));
        uint256 diff = oracleSqrt > poolSqrt ? oracleSqrt - poolSqrt : poolSqrt - oracleSqrt;
        assertLe(
            diff * 10_000, uint256(poolSqrt) * SQRT_TOLERANCE_BPS, string.concat(name, ": sqrt price off the oracle")
        );
    }

    /// @dev The 8-decimal USD price Aave serves for `token` (native ETH as WETH), Chainlink USDT/USD for Base USDT.
    function _price(
        address token
    ) internal view returns (uint256 p) {
        if (onBase) {
            if (token == BASE_USDT) {
                (, int256 answer,,,) = IForkFeed(BASE_USDT_USD).latestRoundData();
                assertGt(answer, 0);
                // Positive, checked above.
                // forge-lint: disable-next-line(unsafe-typecast)
                return uint256(answer);
            }
            p = IForkAaveOracle(BASE_AAVE_ORACLE).getAssetPrice(token);
        } else {
            p = IForkAaveOracle(ETH_AAVE_ORACLE).getAssetPrice(token == address(0) ? ETH_WETH : token);
        }
        assertGt(p, 0);
        assertLe(p, LPPriceMath.MAX_PRICE);
    }

    function _decimals(
        address token
    ) internal view returns (uint8) {
        return token == address(0) ? 18 : IERC20Metadata(token).decimals();
    }
}
