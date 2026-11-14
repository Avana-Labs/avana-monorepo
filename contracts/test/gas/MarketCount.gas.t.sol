// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensMarkets} from "../../src/lens/lens/ILensMarkets.sol";
import {ILensRisk} from "../../src/lens/lens/ILensRisk.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {IMarketRegistryListing} from "../../src/policy/market-registry/IMarketRegistryListing.sol";
import {TokenDef} from "../../src/policy/market-registry/types/TokenDef.sol";
import {IParameterStoreAdmin} from "../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {GasCalibration} from "../utils/GasCalibration.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";

/// @title MarketCountGasTest
/// @notice Calibration of `MAX_MARKET_COUNT` (`REQ-MREG-034`) on the real stack (`RealStackFlows`): every Avana and
/// Aave V4 contract real, each market a real LPOracleCL over a real Uniswap v3 USDC/USDT pool of one of the four
/// standard fee tiers (each further market a narrower tick range of one of them), listed, routed and activated as the
/// listing payloads do it. At 1, 16, 32 and 64 markets the suite measures, each as its own transaction
/// (`isolate = true`, `GasCalibration._txGas`: intrinsic gas included, every account and slot cold), every operation
/// whose cost grows with the market count: the ParameterStore's chain-wide re-check through its costliest setter
/// (`setFeedAgreementMarginBps`, the sizing operation of `REQ-MREG-034`), the registry's re-check of a shared token's
/// routes (`setPriceSource` of USDC, held by every market), the permissionless `RiskModule.pokeConfig` of the CDP Spoke,
/// a user's `pledge` and `borrow` (whose market breaker walks the Spoke's markets for configuration drift), the
/// registry's `spokeSettingsDrift`, the Lens's `getTailCoverage` and one `getMarkets` page of up to 16 markets. The
/// figures are recorded with `vm.snapshotValue` (group `MarketCount`) and checked against the per-transaction gas
/// limit and the 50 % sizing budget of `REQ-MREG-034`.
/// @dev Every market here shares USDC and USDT and their one-leg routes, and every four markets share a pool, so a
/// token's routes, feeds and second source are cold only for the first market the walk reaches: the figures are a lower
/// bound for markets of distinct tokens on two-leg routes, which the per-chain fork sizing of `REQ-MREG-034` covers.
/// forge-config: default.isolate = true
contract MarketCountGasTest is RealStackFlows, GasCalibration {
    /// @notice `REQ-MREG-034`: the re-check at `MAX_MARKET_COUNT` uses at most half the per-transaction gas limit.
    uint256 internal constant RECHECK_BUDGET = TX_GAS_CAP / 2;
    /// @dev Markets per `getMarkets` page measured.
    uint256 internal constant PAGE = 16;

    IClPool[] internal pools;
    uint16 internal margin;
    /// @dev Tick spacings by which `_fullRange` narrows the range of the market being listed (0: the full range).
    int24 internal inset;

    function setUp() public {
        _setUpFullStack();
        // The four standard Uniswap v3 fee tiers of USDC/USDT (the integration accepts only their standard spacings):
        // the fixture's 0.01 % and 0.05 % pools and 0.3 % and 1 % pools created and aged as `_deployPools` ages those.
        (ClTestToken t0, ClTestToken t1) = address(usdc) < address(usdt) ? (usdc, usdt) : (usdt, usdc);
        pools.push(poolA);
        pools.push(poolB);
        pools.push(_createPool(t0, t1, 3000, 1e8, 1e8, 151, 1e15));
        pools.push(_createPool(t0, t1, 10_000, 1e8, 1e8, 151, 1e15));
        _touch(pools[2]);
        _touch(pools[3]);
        vm.warp(block.timestamp + 7200);
        vm.roll(block.number + 7200 / BLOCK_TIME);
        _refreshFeeds();
        usdcOracle.poke();
        margin = store.feedAgreementMarginBps();
    }

    /// @dev Market `i` (from 0) is pool `i % 4` on its full range narrowed by `i / 4` tick spacings at each end, so
    /// every market has its own key, vault token, LPOracle and Aave reserve.
    function _fullRange(
        IClPool p
    ) internal view override returns (int24 lower, int24 upper) {
        (lower, upper) = super._fullRange(p);
        int24 d = inset * p.tickSpacing();
        (lower, upper) = (lower + d, upper - d);
    }

    struct Row {
        uint256 recheck;
        uint256 priceSource;
        uint256 pokeConfig;
        uint256 drift;
        uint256 tailCoverage;
        uint256 marketsPage;
        uint256 pledge;
        uint256 borrow;
    }

    function _measure(
        uint256 n
    ) internal returns (Row memory r) {
        // Alternate the margin so every re-check writes.
        margin = margin == 0 ? 1 : margin - 1;
        r.recheck = _txGas(
            address(timelock), address(store), abi.encodeCall(IParameterStoreAdmin.setFeedAgreementMarginBps, (margin))
        );
        TokenDef memory t = registry.getToken(address(usdc));
        r.priceSource = _txGas(
            address(timelock),
            address(registry),
            abi.encodeCall(
                IMarketRegistryListing.setPriceSource, (address(usdc), t.primaryRoute, t.alternateRoute, t.standbyRoute)
            )
        );
        r.pokeConfig =
            _txGas(keeper, address(riskModule), abi.encodeCall(IRiskModuleChecks.pokeConfig, (aave.cdpSpoke)));
        r.drift =
            _txGas(keeper, address(registry), abi.encodeCall(IMarketRegistryHubs.spokeSettingsDrift, (aave.cdpSpoke)));
        r.tailCoverage =
            _txGas(keeper, address(lens), abi.encodeCall(ILensRisk.getTailCoverage, (aave.hub, address(gho))));
        // One page of at most `PAGE` markets: an app pages the view, and a 200-market page is far past any RPC gas cap.
        r.marketsPage = _txGas(keeper, address(lens), abi.encodeCall(ILensMarkets.getMarkets, (0, PAGE)));
        string memory k = vm.toString(n);
        // A new wallet's first pledge into market 1 (its PositionProxy deployed) and first GHO borrow: both run the
        // market breaker, which walks every market of the Spoke for configuration drift.
        address wallet = makeAddr(string.concat("borrower ", k));
        vm.pauseGasMetering();
        bytes32 key = _mintPosition(wallet, 1, UNITS);
        vm.resumeGasMetering();
        r.pledge = _txGas(wallet, address(adapterC), abi.encodeCall(adapterC.pledge, (1, _ref(key), _deadline())));
        address proxy = adapterC.proxyOf(wallet, 1);
        r.borrow = _txGas(
            wallet,
            address(adapterC),
            abi.encodeCall(
                adapterC.borrow, (1, ghoReserveId, 1000e18, wallet, _deadline(), 0, adapterC.borrowNonce(proxy))
            )
        );
        vm.snapshotValue("MarketCount", string.concat("pledge_", k), r.pledge);
        vm.snapshotValue("MarketCount", string.concat("borrow_", k), r.borrow);
        emit log_named_uint(string.concat("markets ", k, ": pledge (new wallet)"), r.pledge);
        emit log_named_uint(string.concat("markets ", k, ": borrow (first)"), r.borrow);
        vm.snapshotValue("MarketCount", string.concat("setFeedAgreementMarginBps_", k), r.recheck);
        vm.snapshotValue("MarketCount", string.concat("setPriceSource_USDC_", k), r.priceSource);
        vm.snapshotValue("MarketCount", string.concat("pokeConfig_", k), r.pokeConfig);
        vm.snapshotValue("MarketCount", string.concat("spokeSettingsDrift_", k), r.drift);
        vm.snapshotValue("MarketCount", string.concat("getTailCoverage_", k), r.tailCoverage);
        vm.snapshotValue("MarketCount", string.concat("getMarkets_page16_", k), r.marketsPage);
        emit log_named_uint(string.concat("markets ", k, ": setFeedAgreementMarginBps"), r.recheck);
        emit log_named_uint(string.concat("markets ", k, ": setPriceSource(USDC)"), r.priceSource);
        emit log_named_uint(string.concat("markets ", k, ": pokeConfig(CDP Spoke)"), r.pokeConfig);
        emit log_named_uint(string.concat("markets ", k, ": spokeSettingsDrift"), r.drift);
        emit log_named_uint(string.concat("markets ", k, ": getTailCoverage(GHO)"), r.tailCoverage);
        emit log_named_uint(string.concat("markets ", k, ": getMarkets(0, 16)"), r.marketsPage);
    }

    // TEST-295 verifies: REQ-MREG-034, REQ-PSTORE-009
    /// @notice Gas of every market-count-bound operation at 1, 16, 32 and 64 real markets.
    function test_TEST_295_marketCountCalibration() public {
        uint256[4] memory at = [uint256(1), 16, 32, 64];
        Row[4] memory rows;
        uint256 next = 0;
        for (uint256 i = 0; i < MAX_MARKETS; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            inset = int24(int256(i / 4));
            // Listing 64 real markets is far beyond the test's gas limit; only the measured calls are metered.
            vm.pauseGasMetering();
            _addMarket(pools[i % 4]);
            vm.resumeGasMetering();
            inset = 0;
            if (next < 4 && registry.marketCount() == at[next]) {
                vm.pauseGasMetering();
                _pokeAll();
                vm.resumeGasMetering();
                rows[next] = _measure(at[next]);
                ++next;
            }
        }
        assertEq(next, 4, "every checkpoint measured");
        // Per-market slopes from 1 to 64 markets and the largest count each governance re-check fits in the budget.
        uint256 recheckSlope = (rows[3].recheck - rows[0].recheck) / 63;
        uint256 priceSourceSlope = (rows[3].priceSource - rows[0].priceSource) / 63;
        emit log_named_uint("setFeedAgreementMarginBps: gas per market", recheckSlope);
        emit log_named_uint("setPriceSource(USDC): gas per market", priceSourceSlope);
        emit log_named_uint("pokeConfig: gas per market", (rows[3].pokeConfig - rows[0].pokeConfig) / 63);
        emit log_named_uint("getTailCoverage: gas per market", (rows[3].tailCoverage - rows[0].tailCoverage) / 63);
        emit log_named_uint("pledge: gas per market", (rows[3].pledge - rows[0].pledge) / 63);
        emit log_named_uint("borrow: gas per market", (rows[3].borrow - rows[0].borrow) / 63);
        emit log_named_uint(
            "largest count with setFeedAgreementMarginBps within the budget",
            1 + (RECHECK_BUDGET - rows[0].recheck) / recheckSlope
        );
        emit log_named_uint(
            "largest count with setPriceSource within the budget",
            1 + (RECHECK_BUDGET - rows[0].priceSource) / priceSourceSlope
        );
        // At 16 markets every governance re-check is within the 50 % budget of REQ-MREG-034 and every permissionless
        // path within half the per-transaction limit.
        assertLe(rows[1].recheck, RECHECK_BUDGET, "setFeedAgreementMarginBps at 16 markets");
        assertLe(rows[1].priceSource, RECHECK_BUDGET, "setPriceSource at 16 markets");
        assertLe(rows[1].pokeConfig, TX_GAS_CAP / 2, "pokeConfig at 16 markets");
        assertLe(rows[1].tailCoverage, TX_GAS_CAP / 2, "getTailCoverage at 16 markets");
        assertLe(rows[1].pledge, TX_GAS_CAP / 2, "pledge at 16 markets");
        assertLe(rows[1].borrow, TX_GAS_CAP / 2, "borrow at 16 markets");
        // The costs grow with the market count, so the walk is what the limit bounds.
        for (uint256 i = 1; i < 4; ++i) {
            assertGt(rows[i].recheck, rows[i - 1].recheck, "the re-check grows with the market count");
        }
    }
}
