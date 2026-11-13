// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapterCollateral} from "../../src/policy/aave-adapter/IAaveAdapterCollateral.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {FullStackMarkets} from "../utils/fixtures/FullStackMarkets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FullStackLiquidationIntegrationTest
/// @notice Liquidation cascades and one-sided unwinds on the full real stack (`FullStackMarkets`): the real
/// MarketRegistry's markets, routes and gates, the RiskModule's concentration gate on the ParameterStore's
/// `poolShareMaxBps`, the markets' real LPOracles as the AaveOracle sources, the real AaveAdapter and Collateralization,
/// on the real local Aave V4. LPVaultSwap is `LPVaultSwapMock`, which liquidates on the Spoke and settles through the
/// real Collateralization and AaveAdapter.
/// forge-config: default.isolate = false
contract FullStackLiquidationIntegrationTest is FullStackMarkets {
    uint256 internal mA;
    uint256 internal mB;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        mB = _addMarket(poolB);
    }

    function _liquidate(
        uint256 market,
        address proxy,
        uint256 debtToCover
    ) internal returns (bool ok) {
        (ok,) = address(swap)
            .call(
                abi.encodeCall(
                    swap.liquidate,
                    (
                        aave.cdpSpoke,
                        market,
                        mkt[market].vaultToken,
                        mkt[market].reserveId,
                        ghoReserveId,
                        proxy,
                        debtToCover,
                        2
                    )
                )
            );
    }

    // ─── TEST-218: cascade ───

    /// @notice Twelve $10,000 accounts in two markets, half opened at HF about 1.10 and half at about 1.04; outside LPs remove
    /// liquidity until Avana's share of each pool is above `poolShareMaxBps` (10 %), and the RiskModule then refuses a
    /// new borrow and an exposure-raising pledge in both markets while a debt-free account still withdraws; both pool
    /// tokens then fall 7 %. In random order, every account below HF 1 is liquidated (none halts: no stop of the 3.6
    /// matrix is in force), every account above HF 1 refuses a liquidation, and repays and debt-free withdrawals
    /// interleaved with the liquidations all succeed.
    // TEST-218 verifies: INV-045, INV-046, INV-074, SPEC-BRK-002, Q-241, Q-249, Q-251
    /// forge-config: default.fuzz.runs = 16
    function test_TEST_218_cascadeAcrossTwoMarkets(
        uint256 orderSeed
    ) public {
        uint256 n = 12;
        address[] memory wallets = new address[](n);
        address[] memory proxies = new address[](n);
        uint128 units = UNITS / 2;
        for (uint256 i = 0; i < n; ++i) {
            wallets[i] = makeAddr(string.concat("borrower ", vm.toString(i)));
            uint256 m = i % 2 == 0 ? mA : mB;
            (, proxies[i]) = _pledgeAs(wallets[i], m, units);
            // $10,000 at CF 30 %: $3,000 of borrowing power; HF 1.10 at $2,727, HF 1.04 at $2,884.
            _borrowAs(wallets[i], m, ghoReserveId, i < n / 2 ? 2727e18 : 2884e18);
        }
        (bytes32 freeKey,) = _pledgeAs(carol, mA, units);
        // Outside LPs remove liquidity: Avana's six or seven accounts of 5,000 whole tokens are 20 % or more of each pool.
        lpVault.setMarketDepth(mA, 150_000e6);
        lpVault.setMarketDepth(mB, 150_000e6);
        uint256[2] memory ms = [mA, mB];
        for (uint256 k = 0; k < 2; ++k) {
            uint256 nonce = adapterC.borrowNonce(proxies[k]);
            vm.prank(wallets[k]);
            (bool ok,) = adapter.call(
                abi.encodeCall(adapterC.borrow, (ms[k], ghoReserveId, 1e18, wallets[k], _deadline(), 0, nonce))
            );
            assertFalse(ok, "concentration gate refuses a new borrow");
            bytes32 key = _newKey();
            lpVault.mintPosition(key, wallets[k], ms[k], units);
            vm.prank(wallets[k]);
            (ok,) = adapter.call(abi.encodeCall(adapterC.pledge, (ms[k], _ref(key), _deadline())));
            assertFalse(ok, "and an exposure-raising pledge");
        }
        _publish(address(usdc), 93_000_000);
        _publish(address(usdt), 93_000_000);
        mkt[mA].oracle.poke();
        mkt[mB].oracle.poke();
        vm.prank(carol);
        IAaveAdapterCollateral(adapter).removeLiquidity(mA, _ref(freeKey), units / 2, _mins(), _deadline(), 0);
        uint256 liquidated = 0;
        for (uint256 j = 0; j < n; ++j) {
            uint256 i = (orderSeed % n + j * 5) % n;
            uint256 m = i % 2 == 0 ? mA : mB;
            uint256 hf = _hf(proxies[i]);
            uint256 owed = _debtOf(proxies[i], ghoReserveId);
            if (hf < 1e18) {
                assertTrue(_liquidate(m, proxies[i], owed / 2), "below HF 1: liquidated");
                assertLt(_debtOf(proxies[i], ghoReserveId), owed, "debt reduced");
                ++liquidated;
            } else {
                assertFalse(_liquidate(m, proxies[i], owed / 2), "above HF 1: not liquidatable");
                _fund(wallets[i], ghoReserveId, 10e18);
                vm.prank(wallets[i]);
                adapterC.repay(wallets[i], m, ghoReserveId, 10e18, false, _deadline());
            }
        }
        assertEq(liquidated, n / 2, "every account opened at HF 1.04 fell below 1 and was liquidated");
        uint128 rest = coll.getRecord(coll.recordIdOf(V3, freeKey)).credited;
        vm.prank(carol);
        adapterC.withdraw(mA, _ref(freeKey), rest, _deadline(), 0);
        assertEq(lpVault.ownerOf(freeKey), carol, "debt-free exit completed");
    }

    // ─── TEST-281: one-sided unwinds ───

    /// @notice A seizure at either range edge returns one token only (the unwind composition all USDC, then all USDT):
    /// for each, the MarketRegistry lists a usable primary route from that token into the repaid debt asset, so the
    /// whole amount is sold in one leg; a market whose routes leave one pool token without a route into a debt asset
    /// is refused at activation. The listed one-leg loss bound: in a constant-product route of depth `10 V`, one leg of
    /// `V` loses 9.09 %, above the market's `slippageAllowanceBps` (250), so only a depth of at least `39 V` lists.
    // TEST-281 verifies: REQ-SWAP-021, REQ-SWAP-025, SPEC-LIQ-005, Q-250
    function test_TEST_281_oneSidedUnwindsHaveAOneLegRoute() public {
        address[] memory toks = _poolTokens();
        for (uint256 side = 0; side < 2; ++side) {
            uint256 snap = vm.snapshotState();
            (, address proxy) = _pledgeAs(alice, mA, UNITS);
            _borrowAs(alice, mA, ghoReserveId, 5768e18);
            uint256[] memory rates = side == 0 ? _two(2e18, 0) : _two(0, 2e18);
            lpVault.bindMarket(mA, address(poolA), toks, rates, int24(-887_272), int24(887_272));
            _publish(address(usdc), 93_000_000);
            _publish(address(usdt), 93_000_000);
            mkt[mA].oracle.poke();
            address sold = toks[side];
            uint256 before = IERC20(sold).balanceOf(address(swap));
            uint256 other = IERC20(toks[1 - side]).balanceOf(address(swap));
            assertTrue(_liquidate(mA, proxy, 2000e18), "one-sided seizure settles");
            assertGt(IERC20(sold).balanceOf(address(swap)) - before, 0, "all of one token");
            assertEq(IERC20(toks[1 - side]).balanceOf(address(swap)), other, "none of the other");
            (address route, bool usable) = registry.getRoute(mA, sold, address(gho), 0);
            assertTrue(route != address(0) && usable, "a usable one-leg route from that token into GHO");
            vm.revertToState(snap);
        }
        MarketParams memory p = store.getMarketParams(mA);
        uint256 v = 1e18;
        assertGt(v * 1e4 / (10 * v + v), p.slippageAllowanceBps, "depth 10 V: one leg of V loses 9.09 %");
        assertLe(v * 1e4 / (39 * v + v), p.slippageAllowanceBps, "depth 39 V keeps it within the allowance");
    }
}
