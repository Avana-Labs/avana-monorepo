// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {CapView} from "../../src/types/CapView.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";

/// @title CascadeIntegrationTest
/// @notice TEST-218 on the deployed stack: 200 accounts (100 per market) opened at HF 1.10 through the real AaveAdapter
/// in two markets of one LPVault; outside LPs remove 0–90 % of the pool depth; both vault prices fall 5–40 %; then rounds
/// in a fuzzed order where each account below HF 1 is liquidated through the real LPVaultSwap with the Lens's
/// parameters and each other account repays, exits debt-free or removes part of a debt-free record. Asserted: after the
/// LP removal Avana's pool share the Lens reports is the recomputed `poolUnits / depth`, and the real RiskModule refuses
/// new borrowing (`BreakerTripped` with `POOL_SHARE`) exactly when it is above `poolShareMaxBps` (10 %); every account
/// below HF 1 is liquidated within the run, every settlement meets its floor on `R + shortfall` with `D <= Kf`, an
/// account solvent at the bonus never loses health (`INV-076`), and no debt-free exit or repay reverts.
/// @dev Gas: opening the 200 accounts and each fuzz run's cascade cost about 206M gas together, within Foundry's
/// per-call limit with `isolate = false`. The exposure-raising pledge half of the concentration gate runs in
/// Collateralization's `checkPledge`, which this fixture keeps on the RiskModule stand-in; it is the RiskModule suites'.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 3
contract CascadeIntegrationTest is IntegrationFlows {
    uint256 internal constant N = 200;
    uint256 internal constant MAX_ROUNDS = 12;
    uint16 internal constant SHARE_CAP_BPS = 1000;

    address[] internal wallets;
    bytes32[] internal keys;
    uint256 internal unitsA;
    uint256 internal unitsB;

    function setUp() public {
        _deployIntegration();
        for (uint256 i = 0; i < N; ++i) {
            uint256 m = i % 2 == 0 ? MARKET_ID : MARKET_B;
            uint128 units = uint128(1000e6 + (i % 50) * 60e6);
            address w = makeAddr(string(abi.encode("cascade", i)));
            // HF 1.10 at $2.10 and CF 80 %: debt = units x 2.10 x 0.80 / 1.10 (both 6 decimals).
            (, bytes32 k) = _openAccount(w, m, units, uint256(units) * 168 / 110, P_VAULT);
            wallets.push(w);
            keys.push(k);
            if (m == MARKET_ID) unitsA += units;
            else unitsB += units;
        }
        // Avana's share of the (shared) depth starts at 5 % of the larger market's units.
        vault.setDepth((unitsA > unitsB ? unitsA : unitsB) * 20, true);
        store.setPoolShare(keccak256(abi.encode(INTEGRATION, pool, bytes32(0))), SHARE_CAP_BPS);
        store.setPoolShare(keccak256(abi.encode(INTEGRATION, poolB, bytes32(0))), SHARE_CAP_BPS);
    }

    function _market(
        uint256 i
    ) internal pure returns (uint256) {
        return i % 2 == 0 ? MARKET_ID : MARKET_B;
    }

    /// @dev Outside LPs remove `removalBps` of the depth; the Lens's pool share and the RiskModule's borrow gate follow.
    function _removeDepth(
        uint256 removalBps
    ) internal {
        uint256 depth = vault.depth() * (10_000 - removalBps) / 10_000;
        vault.setDepth(depth, true);
        CapView memory cv = lens.getCapHeadroom(vt, wallets[0]);
        assertEq(cv.poolShareMaxBps, SHARE_CAP_BPS, "Lens: the pool's cap");
        assertEq(cv.poolShareBps, (unitsA * 10_000 + depth - 1) / depth, "Lens: share recomputed, rounded up");
        bool over = unitsA * 10_000 > uint256(SHARE_CAP_BPS) * depth;
        (uint32 reasons,) = rm.getBreakerStatus(MARKET_ID);
        assertEq(reasons & BreakerReasons.POOL_SHARE != 0, over, "POOL_SHARE live exactly above the cap");
        address proxy = adapterC.proxyOf(wallets[0], MARKET_ID);
        uint256 nonce = adapterC.borrowNonce(proxy);
        if (over) vm.expectPartialRevert(IRiskModuleErrors.BreakerTripped.selector);
        vm.prank(wallets[0]);
        adapterC.borrow(MARKET_ID, usdcReserveId, 1e6, wallets[0], _deadline(), 0, nonce);
    }

    function _liquidate(
        uint256 i,
        uint256 seed
    ) internal returns (bool settled) {
        address proxy = adapterC.proxyOf(wallets[i], _market(i));
        LiquidationPreview memory p = lens.previewLiquidation(proxy, usdcReserveId, block.timestamp + 60);
        assertTrue(p.aaveLiquidatable && p.pricesUsable && p.sharesEqualAssets, "every gate open");
        p.params.maxShortfall = p.params.debtToCover / 20;
        address caller = seed % 2 == 0 ? keeper : makeAddr("anyCaller");
        uint256 hfBefore = p.healthFactor;
        LiquidationResult memory r = _liquidateAs(caller, p.params);
        assertGe(r.recovered + r.shortfall, r.minOut, "floor on R + shortfall");
        assertLe(r.debtRepaid, r.callerFunds, "D <= Kf");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
        // INV-076: an account solvent at the bonus (HF >= LB x CF = 1.05 x 0.80) never loses health.
        if (hfBefore >= 0.84e18 && _debtOf(proxy, usdcReserveId) != 0) assertGe(_hf(proxy), hfBefore, "INV-076");
        settled = true;
    }

    /// @dev A healthy account's own action: repay all and exit debt-free, repay part, or remove part debt-free. None
    /// may revert.
    function _ownAction(
        uint256 i,
        uint256 seed
    ) internal {
        uint256 m = _market(i);
        address w = wallets[i];
        address proxy = adapterC.proxyOf(w, m);
        uint256 credited = coll.getRecord(coll.recordIdOf(INTEGRATION, keys[i])).credited;
        if (credited == 0) return;
        uint256 owed = _debtOf(proxy, usdcReserveId);
        uint256 kind = seed % 3;
        if (kind == 0) {
            if (owed != 0) {
                _repayVia(w, w, m, usdcReserveId, lens.quoteRepayAll(w, m, usdcReserveId, _deadline()), true);
            }
            _withdrawVia(w, m, keys[i], credited);
            assertEq(vault.ownerOf(keys[i]), w, "debt-free exit returned the position");
        } else if (kind == 1 && owed != 0) {
            _repayVia(makeAddr("anyPayer"), w, m, usdcReserveId, owed / 3 + 1, false);
        } else if (owed == 0 && credited > 2) {
            vm.prank(w);
            adapterC.removeLiquidity(m, _ref(keys[i]), uint128(credited / 2), new uint256[](2), _deadline(), 0);
        }
    }

    // TEST-218 verifies: INV-045, INV-046, INV-074, INV-076, INV-081, SPEC-LIQ-021, SPEC-BRK-002, REQ-SWAP-118, REQ-LENS-018, Q-241, Q-249, Q-251
    function testFuzz_TEST_218_cascadeAt200Accounts(
        uint256 removalBps,
        uint256 dropBps,
        uint256 orderSeed
    ) public {
        _removeDepth(bound(removalBps, 0, 9000));
        dropBps = bound(dropBps, 500, 4000);
        _setPrice(MARKET_ID, P_VAULT * (10_000 - dropBps) / 10_000);
        _setPrice(MARKET_B, P_VAULT * (10_000 - dropBps) / 10_000);
        uint256 settled = 0;
        for (uint256 round = 0; round < MAX_ROUNDS && _anyEligible(); ++round) {
            uint256 start = uint256(keccak256(abi.encode(orderSeed, round))) % N;
            for (uint256 k = 0; k < N; ++k) {
                uint256 i = (start + k * 7) % N; // 7 is coprime with 200: a full permutation per round
                uint256 seed = uint256(keccak256(abi.encode(orderSeed, round, k)));
                address proxy = adapterC.proxyOf(wallets[i], _market(i));
                if (_hf(proxy) < 1e18 && _suppliedOf(proxy, _market(i)) != 0) {
                    if (_liquidate(i, seed)) ++settled;
                } else if (round == 0) {
                    _ownAction(i, seed);
                }
            }
        }
        assertFalse(_anyEligible(), "an account below HF 1 was left unliquidated");
        if (dropBps > 1000) assertGt(settled, 0, "the fall made accounts liquidatable");
        assertEq(token.totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "market A backed");
        assertEq(tokenB.totalSupply(), coll.getTotalCredited(vtB) + coll.getPending(vtB).units, "market B backed");
        assertEq(usdc.balanceOf(lpVaultSwap) + usdt.balanceOf(lpVaultSwap), 0, "LPVaultSwap neutral");
        assertFalse(lock.isLocked(), "Lock free");
    }

    function _anyEligible() internal view returns (bool) {
        for (uint256 i = 0; i < N; ++i) {
            address proxy = adapterC.proxyOf(wallets[i], _market(i));
            if (_hf(proxy) < 1e18 && _suppliedOf(proxy, _market(i)) != 0) return true;
        }
        return false;
    }
}
