// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {WorldAaveV3} from "./lib/WorldAaveV3.sol";
import {WorldAerodrome} from "./lib/WorldAerodrome.sol";
import {WorldFeeds} from "./lib/WorldFeeds.sol";
import {TestToken} from "./local/TestToken.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/console2.sol";

interface IUniswapV3FactoryAdmin {
    function enableFeeAmount(
        uint24 fee,
        int24 tickSpacing
    ) external;
    function createPool(
        address a,
        address b,
        uint24 fee
    ) external returns (address);
    function feeAmountTickSpacing(
        uint24 fee
    ) external view returns (int24);
}

interface IPoolInit {
    function initialize(
        uint160 sqrtPriceX96
    ) external;
    function increaseObservationCardinalityNext(
        uint16 n
    ) external;
}

interface ISlipstreamFactory {
    function createPool(
        address a,
        address b,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address);
}

interface IUniNpm {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(
        MintParams calldata p
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface ISlipNpm {
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
        MintParams calldata p
    ) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

/// @title DeployWorld
/// @notice Step 2 on test networks: the third-party world Avana runs against, built from pinned sources or local
/// stand-ins: test tokens of 6, 8 and 18 decimals, three movable USD feeds per token (primary, alternate, independent
/// second source), Uniswap v3 (core 5ea68a7 built alone so its pool init code hash is the canonical one, periphery 24ccf01:
/// factory, NonfungiblePositionManager, SwapRouter),
/// Aerodrome Slipstream (four position-manager generations: v1.0.0 for generations 0–2, main f8717fa for 3, each with its
/// factory and pool implementation), an Aave V3 market (origin v3.7.0, `WorldAaveV3`) listing every token with its
/// primary feed, flash loans enabled and `world.aaveV3SupplyUsd` dollars supplied, and every pool of the network's
/// `world.uniswapPools` and `world.slipstreamPools`, created at the feeds' price with full-range liquidity of `usd`
/// dollars from the deployer.
/// @dev Stand-ins (marked `standIn` in the output, listed in deployments/README.md): `TestToken` (and LINK, the OCR2
/// payment token). Output: `deployments-local/<network>/world.json`.
contract DeployWorld is WorldAerodrome, WorldFeeds, WorldAaveV3 {
    uint160 internal constant Q96 = 2 ** 96;
    int24 internal constant MAX_TICK = 887_272;

    struct TokenInfo {
        address token;
        uint8 decimals;
        uint256 price8;
    }

    mapping(bytes32 => TokenInfo) internal tokens;
    /// @notice The primary feed (`EACAggregatorProxy`) of each token, keyed by symbol hash.
    mapping(bytes32 => address) internal primaryFeed;
    string internal cfg;
    address internal me;
    address internal uniFactory;
    address internal uniNpm;

    function run() external {
        string memory network = _network();
        require(block.chainid != 1 && block.chainid != 8453, "the world is for test networks");
        cfg = vm.readFile(_configPath(network));
        vm.startBroadcast();
        (, me,) = vm.readCallers();
        deployer = me;
        _deployTokensAndFeeds();
        address weth = tokens[keccak256("WETH")].token;
        require(weth != address(0), "world.tokens needs WETH");
        _deployUniswap(weth);
        _deploySlipstream(weth);
        address flashPool = _deployAaveV3();
        _uniswapPools();
        _slipstreamPools();
        vm.stopBroadcast();
        vm.serializeAddress("world", "deployer", me);
        vm.serializeAddress("world", "uniswapV3Factory", uniFactory);
        vm.serializeAddress("world", "uniswapV3PositionManager", uniNpm);
        vm.serializeAddress("world", "slipstreamFactories", _arr(slipFactories));
        vm.serializeAddress("world", "slipstreamPositionManagers", _arr(slipNpms));
        vm.serializeAddress("world", "aerodromeVoter", voter);
        vm.serializeAddress("world", "aerodromeFactoryRegistry", factoryRegistry);
        vm.serializeAddress("world", "slipstreamGaugeFactories", _arr(slipGaugeFactories));
        vm.serializeAddress("world", "aaveV3Pool", flashPool);
        vm.serializeAddress("world", "aaveV3ACLManager", aaveV3.aclManager);
        vm.serializeAddress("world", "aaveV3PoolAddressesProvider", aaveV3.poolAddressesProvider);
        vm.serializeAddress("world", "aaveV3PoolConfigurator", aaveV3.poolConfiguratorProxy);
        vm.serializeAddress("world", "aaveV3Oracle", aaveV3.aaveOracle);
        string memory json = vm.serializeString("world", "external", _externalJson(flashPool));
        vm.createDir(string.concat(vm.projectRoot(), "/", OUTPUT_DIR, "/", network), true);
        vm.writeJson(json, _outputPath("world"));
        console2.log("world output", _outputPath("world"));
    }

    // ─── Tokens and feeds ───

    function _deployTokensAndFeeds() private {
        // LINK pays OCR2 transmitters; no payment is ever withdrawn on a test network.
        TestToken link = new TestToken("Test LINK", "LINK", 18, me);
        vm.serializeAddress("world", "link", address(link));
        _ocrSetup(_network(), address(link));
        uint256 n = _count(cfg, ".world.tokens");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".world.tokens[", vm.toString(i), "]");
            string memory sym = vm.parseJsonString(cfg, string.concat(k, ".symbol"));
            uint8 dec = uint8(vm.parseJsonUint(cfg, string.concat(k, ".decimals")));
            uint256 price = vm.parseJsonUint(cfg, string.concat(k, ".price8"));
            TestToken t = new TestToken(string.concat("Test ", sym), sym, dec, me);
            tokens[keccak256(bytes(sym))] = TokenInfo(address(t), dec, price);
            vm.serializeString("world", "tokens", vm.serializeAddress("tokens", sym, address(t)));
            // Primary, alternate and standby price routes, and the oracle-network second source, each its own feed:
            // the MarketRegistry refuses routes that share a feed and a second source inside a route.
            string[4] memory roles = ["primary", "alternate", "standby", "second"];
            string memory fk = string.concat("feeds.", sym);
            string memory one;
            for (uint256 j = 0; j < 4; ++j) {
                (address proxy, address aggregator) =
                    _deployFeed(string.concat(sym, " / USD ", roles[j]), int256(price), 1, int192(int256(1e18)));
                if (j == 0) primaryFeed[keccak256(bytes(sym))] = proxy;
                vm.serializeAddress(fk, string.concat(roles[j], "Aggregator"), aggregator);
                one = vm.serializeAddress(fk, roles[j], proxy);
            }
            string memory all = vm.serializeString("feeds", sym, one);
            vm.serializeString("world", "feeds", all);
        }
    }

    // ─── Uniswap v3 and Slipstream ───

    function _deployUniswap(
        address weth
    ) private {
        uniFactory = _deploy("UniswapV3Factory", _artifactIn("out-univ3", "UniswapV3Factory.sol", "UniswapV3Factory"));
        if (IUniswapV3FactoryAdmin(uniFactory).feeAmountTickSpacing(100) == 0) {
            IUniswapV3FactoryAdmin(uniFactory).enableFeeAmount(100, 1);
        }
        uniNpm = _deploy(
            "UniswapV3NonfungiblePositionManager",
            bytes.concat(
                _artifactIn("out-univ3-periphery", "NonfungiblePositionManager.sol", "NonfungiblePositionManager"),
                abi.encode(uniFactory, weth, address(0))
            )
        );
        address router = _deploy(
            "UniswapV3SwapRouter",
            bytes.concat(
                _artifactIn("out-univ3-periphery", "SwapRouter.sol", "SwapRouter"), abi.encode(uniFactory, weth)
            )
        );
        vm.serializeAddress("world", "uniswapV3SwapRouter", router);
    }

    function _deploySlipstream(
        address weth
    ) private {
        _aerodromeCore();
        for (uint256 g = 0; g < 4; ++g) {
            _slipstreamGeneration(g, weth);
        }
        address router = _deploy(
            "SlipstreamSwapRouter",
            bytes.concat(
                _artifactIn("out-slipstream-v1", "SwapRouter.sol", "SwapRouter"), abi.encode(slipFactories[0], weth)
            )
        );
        vm.serializeAddress("world", "slipstreamSwapRouter", router);
    }

    /// @notice The Aave V3 market, every token listed and supplied with `world.aaveV3SupplyUsd` dollars.
    function _deployAaveV3() private returns (address pool) {
        _aaveV3Market(me, primaryFeed[keccak256("WETH")]);
        pool = aaveV3.poolProxy;
        uint256 usd = vm.parseJsonUint(cfg, ".world.aaveV3SupplyUsd");
        uint256 n = _count(cfg, ".world.tokens");
        for (uint256 i = 0; i < n; ++i) {
            string memory sym = vm.parseJsonString(cfg, string.concat(".world.tokens[", vm.toString(i), "].symbol"));
            TokenInfo memory t = tokens[keccak256(bytes(sym))];
            _aaveV3List(t.token, sym, primaryFeed[keccak256(bytes(sym))]);
            uint256 amount = _amountForUsd(t, usd);
            TestToken(t.token).mint(me, amount);
            TestToken(t.token).approve(pool, amount);
            _aaveV3Supply(t.token, amount, me);
        }
        _aaveV3HandOver(me, vm.parseJsonAddress(cfg, ".aaveLocal.aaveDao"));
    }

    function _uniswapPools() private {
        uint256 n = _count(cfg, ".world.uniswapPools");
        string memory list = "{}";
        for (uint256 i = 0; i < n; ++i) {
            list = _uniswapPool(string.concat(".world.uniswapPools[", vm.toString(i), "]"));
        }
        vm.serializeString("world", "uniswapPools", list);
    }

    function _uniswapPool(
        string memory k
    ) private returns (string memory list) {
        (TokenInfo memory a, TokenInfo memory b) = _pair(k);
        uint24 fee = uint24(vm.parseJsonUint(cfg, string.concat(k, ".fee")));
        address pool = IUniswapV3FactoryAdmin(uniFactory).createPool(a.token, b.token, fee);
        IPoolInit(pool).initialize(_sqrtPrice(a, b));
        IPoolInit(pool)
            .increaseObservationCardinalityNext(uint16(vm.parseJsonUint(cfg, ".world.observationCardinality")));
        (uint256 a0, uint256 a1) = _fund(a, b, vm.parseJsonUint(cfg, string.concat(k, ".usd")), uniNpm);
        _mintUni(a.token, b.token, fee, a0, a1);
        list = vm.serializeAddress("uniswapPools", vm.parseJsonString(cfg, string.concat(k, ".name")), pool);
    }

    function _mintUni(
        address t0,
        address t1,
        uint24 fee,
        uint256 a0,
        uint256 a1
    ) private {
        int24 lo = _minTick(IUniswapV3FactoryAdmin(uniFactory).feeAmountTickSpacing(fee));
        IUniNpm(uniNpm).mint(IUniNpm.MintParams(t0, t1, fee, lo, -lo, a0, a1, 0, 0, me, block.timestamp + 1 days));
    }

    function _slipstreamPools() private {
        uint256 n = _count(cfg, ".world.slipstreamPools");
        string memory list = "{}";
        for (uint256 i = 0; i < n; ++i) {
            list = _slipstreamPool(string.concat(".world.slipstreamPools[", vm.toString(i), "]"));
        }
        vm.serializeString("world", "slipstreamPools", list);
    }

    function _slipstreamPool(
        string memory k
    ) private returns (string memory list) {
        (TokenInfo memory a, TokenInfo memory b) = _pair(k);
        int24 spacing = int24(int256(vm.parseJsonUint(cfg, string.concat(k, ".tickSpacing"))));
        uint256 g = vm.parseJsonUint(cfg, string.concat(k, ".generation"));
        address pool = ISlipstreamFactory(slipFactories[g]).createPool(a.token, b.token, spacing, _sqrtPrice(a, b));
        _gauge(g, pool);
        IPoolInit(pool)
            .increaseObservationCardinalityNext(uint16(vm.parseJsonUint(cfg, ".world.observationCardinality")));
        (uint256 a0, uint256 a1) = _fund(a, b, vm.parseJsonUint(cfg, string.concat(k, ".usd")), slipNpms[g]);
        _mintSlip(slipNpms[g], a.token, b.token, spacing, a0, a1);
        list = vm.serializeAddress("slipstreamPools", vm.parseJsonString(cfg, string.concat(k, ".name")), pool);
    }

    function _mintSlip(
        address npm,
        address t0,
        address t1,
        int24 spacing,
        uint256 a0,
        uint256 a1
    ) private {
        int24 lo = _minTick(spacing);
        ISlipNpm(npm).mint(ISlipNpm.MintParams(t0, t1, spacing, lo, -lo, a0, a1, 0, 0, me, block.timestamp + 1 days, 0));
    }

    // ─── Helpers ───

    /// @notice The pool's two tokens, sorted (token0 < token1).
    function _pair(
        string memory k
    ) private view returns (TokenInfo memory a, TokenInfo memory b) {
        a = tokens[keccak256(bytes(vm.parseJsonString(cfg, string.concat(k, ".a"))))];
        b = tokens[keccak256(bytes(vm.parseJsonString(cfg, string.concat(k, ".b"))))];
        require(a.token != address(0) && b.token != address(0), string.concat("unknown token in ", k));
        if (a.token > b.token) (a, b) = (b, a);
    }

    /// @notice `sqrt(price1per0 raw) × 2^96` from the feed prices: `raw1 / raw0 = (p0 / p1) × 10^(d1 − d0)`.
    function _sqrtPrice(
        TokenInfo memory t0,
        TokenInfo memory t1
    ) private pure returns (uint160) {
        uint256 num = t0.price8 * 10 ** t1.decimals;
        uint256 den = t1.price8 * 10 ** t0.decimals;
        return uint160(Math.sqrt(Math.mulDiv(num, uint256(1) << 192, den)));
    }

    function _amountForUsd(
        TokenInfo memory t,
        uint256 usd
    ) private pure returns (uint256) {
        return Math.mulDiv(usd * 1e8, 10 ** t.decimals, t.price8);
    }

    /// @notice Mints half of `usd` in each token to the deployer and approves the position manager.
    function _fund(
        TokenInfo memory a,
        TokenInfo memory b,
        uint256 usd,
        address npm
    ) private returns (uint256 a0, uint256 a1) {
        a0 = _amountForUsd(a, usd / 2);
        a1 = _amountForUsd(b, usd / 2);
        TestToken(a.token).mint(me, a0);
        TestToken(b.token).mint(me, a1);
        TestToken(a.token).approve(npm, a0);
        TestToken(b.token).approve(npm, a1);
    }

    function _minTick(
        int24 spacing
    ) private pure returns (int24) {
        return -(MAX_TICK / spacing) * spacing;
    }

    function _arr(
        address[4] memory x
    ) private pure returns (address[] memory out) {
        out = new address[](4);
        for (uint256 i = 0; i < 4; ++i) {
            out[i] = x[i];
        }
    }

    /// @notice `external` section for the manifest producer: group → name → {address, standIn}.
    function _externalJson(
        address flashPool
    ) private returns (string memory) {
        _ext("uniswap-v3", "UniswapV3Factory", uniFactory, false);
        string memory uni = _ext("uniswap-v3", "NonfungiblePositionManager", uniNpm, false);
        string memory slip;
        for (uint256 g = 0; g < 4; ++g) {
            _ext("slipstream", string.concat("CLFactory generation ", vm.toString(g)), slipFactories[g], false);
            slip = _ext(
                "slipstream",
                string.concat("NonfungiblePositionManager generation ", vm.toString(g)),
                slipNpms[g],
                false
            );
        }
        _ext("slipstream", "Aerodrome Voter", voter, false);
        _ext("slipstream", "Aerodrome FactoryRegistry", factoryRegistry, false);
        _ext("slipstream", "AERO", aero, false);
        for (uint256 g = 0; g < 4; ++g) {
            slip = _ext(
                "slipstream", string.concat("CLGaugeFactory generation ", vm.toString(g)), slipGaugeFactories[g], false
            );
        }
        _ext("aave-v3", "PoolAddressesProvider", aaveV3.poolAddressesProvider, false);
        _ext("aave-v3", "PoolConfigurator", aaveV3.poolConfiguratorProxy, false);
        _ext("aave-v3", "ACLManager", aaveV3.aclManager, false);
        _ext("aave-v3", "AaveOracle", aaveV3.aaveOracle, false);
        string memory aave3 = _ext("aave-v3", "Pool (flash loans)", flashPool, false);
        string memory toks;
        uint256 n = _count(cfg, ".world.tokens");
        for (uint256 i = 0; i < n; ++i) {
            string memory sym = vm.parseJsonString(cfg, string.concat(".world.tokens[", vm.toString(i), "].symbol"));
            toks = _ext("token", sym, tokens[keccak256(bytes(sym))].token, true);
        }
        vm.serializeString("external", "uniswap-v3", uni);
        vm.serializeString("external", "slipstream", slip);
        vm.serializeString("external", "aave-v3", aave3);
        return vm.serializeString("external", "token", toks);
    }

    function _ext(
        string memory group,
        string memory name,
        address a,
        bool standIn
    ) private returns (string memory) {
        string memory k = string.concat("ext.", group, ".", name);
        vm.serializeAddress(k, "address", a);
        string memory one = vm.serializeBool(k, "standIn", standIn);
        return vm.serializeString(string.concat("extgroup.", group), name, one);
    }
}
