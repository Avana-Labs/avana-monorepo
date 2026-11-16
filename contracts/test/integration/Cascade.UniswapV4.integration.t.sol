// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RealStackUniswapV4Journeys} from "../utils/fixtures/RealStackUniswapV4Journeys.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CascadeUniswapV4IntegrationTest
/// @notice `TEST-218` on Uniswap v4 markets of the real stack: 16 accounts opened through the real AaveAdapter with
/// real v4 PositionManager NFTs, 12 in the USDC/USDT v4 market of the Stable Hub and 4 in the native ETH/USDC v4 market
/// of the Volatile Hub, each borrowing GHO at 94–98 % of the Lens's `previewBorrowMax`; the stable pool tokens fall 3–9
/// % on every feed and WETH 10–30 %, the v4 pools moved with them; then rounds in a fuzzed order where each account
/// below HF 1 is liquidated through the real LPVaultSwap with the Lens's parameters and some others repay a third of
/// their debt. Asserted: every account below HF 1 is liquidated within the run, each settlement balances and meets its
/// floor on `R + shortfall`, both vault tokens stay backed, LPVaultSwap and the LPVault keep nothing, and the Lock is
/// free.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 3
contract CascadeUniswapV4IntegrationTest is RealStackUniswapV4Journeys {
    uint256 internal constant N = 16;
    uint256 internal constant N_STABLE = 12;
    uint256 internal constant MAX_ROUNDS = 8;

    address[N] internal wallets;

    function setUp() public {
        _setUpV4Journeys();
        for (uint256 i = 0; i < N; ++i) {
            wallets[i] = makeAddr(string.concat("cascade", vm.toString(i)));
            uint256 m = _market(i);
            _v4PledgeUsd(wallets[i], m, i < N_STABLE ? 1000 + 40 * i : 5000);
            uint256 max = lens.previewBorrowMax(wallets[i], m, _reserve(i), _deadline());
            _borrowAs(wallets[i], m, _reserve(i), max * (94 + (i % 5)) / 100);
        }
    }

    function _market(
        uint256 i
    ) internal view returns (uint256) {
        return i < N_STABLE ? mS : mE;
    }

    function _reserve(
        uint256 i
    ) internal view returns (uint256) {
        return i < N_STABLE ? v4GhoReserveS : v4GhoReserveV;
    }

    function _proxy(
        uint256 i
    ) internal view returns (address) {
        return adapterC.proxyOf(wallets[i], _market(i));
    }

    function _eligible(
        uint256 i
    ) internal view returns (bool) {
        address spoke = _spokeOf(_market(i));
        address proxy = _proxy(i);
        return _hfOn(spoke, proxy) < 1e18 && _sharesOn(spoke, proxy, mkt[_market(i)].reserveId) != 0;
    }

    function _anyEligible() internal view returns (bool) {
        for (uint256 i = 0; i < N; ++i) {
            if (_eligible(i)) return true;
        }
        return false;
    }

    function _liquidate(
        uint256 i
    ) internal returns (bool) {
        LiquidationPreview memory p = lens.previewLiquidation(_proxy(i), _reserve(i), block.timestamp + 120);
        if (!p.aaveLiquidatable || !p.pricesUsable || p.params.debtToCover == 0) return false;
        p.params.maxShortfall = p.params.debtToCover / 20;
        LiquidationResult memory r = _liquidateOn(_spokeOf(_market(i)), keeper, p.params);
        assertEq(
            r.callerFunds + r.recovered + r.shortfall,
            r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut,
            "conservation"
        );
        assertGe(r.recovered + r.shortfall, r.minOut, "floor");
        assertLe(r.debtRepaid, r.callerFunds, "D <= Kf");
        return true;
    }

    // TEST-218 verifies: INV-045, INV-046, INV-074, SPEC-LIQ-021, REQ-SWAP-118, REQ-AMM-V4-004
    function testFuzz_TEST_218_v4Cascade(
        uint256 dropBps,
        uint256 ethDropBps,
        uint256 orderSeed
    ) public {
        dropBps = bound(dropBps, 300, 900);
        ethDropBps = bound(ethDropBps, 1000, 3000);
        uint256 p8 = 1e8 * (10_000 - dropBps) / 10_000;
        _publish(address(usdc), p8);
        _publish(address(weth), uint256(feedsOf[address(weth)][0].answer()) * (10_000 - ethDropBps) / 10_000);
        _depegUsdt4(p8);
        uint256 settled = 0;
        for (uint256 round = 0; round < MAX_ROUNDS && _anyEligible(); ++round) {
            uint256 start = uint256(keccak256(abi.encode(orderSeed, round))) % N;
            for (uint256 k = 0; k < N; ++k) {
                uint256 i = (start + k * 5) % N; // 5 is coprime with 16: a full permutation per round
                if (_eligible(i)) {
                    if (_liquidate(i)) ++settled;
                } else if (round == 0 && uint256(keccak256(abi.encode(orderSeed, i))) % 3 == 0) {
                    uint256 owed = _debtOn(_spokeOf(_market(i)), _proxy(i), _reserve(i));
                    if (owed > 3) _repayOn(makeAddr("anyPayer"), wallets[i], _market(i), _reserve(i), owed / 3, false);
                }
            }
        }
        assertFalse(_anyEligible(), "an account below HF 1 was left unliquidated");
        assertGt(settled, 0, "the fall made accounts liquidatable");
        _assertBacked(vtS);
        _assertBacked(vtE);
        assertEq(
            usdc.balanceOf(lpVaultSwap) + usdt.balanceOf(lpVaultSwap) + gho.balanceOf(lpVaultSwap)
                + weth.balanceOf(lpVaultSwap),
            0,
            "LPVaultSwap neutral"
        );
        assertEq(IERC20(vtS).balanceOf(lpVaultSwap) + IERC20(vtE).balanceOf(lpVaultSwap), 0, "no vault token kept");
        assertEq(v4Vault.balance, 0, "the LPVault never holds ETH");
        assertFalse(lock.isLocked(), "Lock free");
    }
}
