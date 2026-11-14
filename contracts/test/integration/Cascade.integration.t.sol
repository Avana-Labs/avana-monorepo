// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskStatus} from "../../src/amm/types/RiskStatus.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {CapView} from "../../src/types/CapView.sol";
import {IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title CascadeIntegrationTest
/// @notice TEST-218 on the real stack (`RealStackFlows`): 100 accounts (50 per market) opened through the real
/// AaveAdapter with real Uniswap v3 NFTs in two markets of the real Uniswap v3 LPVault (the full ranges of the 0.01 % and
/// 0.05 % USDC/USDT pools), each borrowing GHO at HF 1.02–1.06; outside LPs (the pools' own full-range liquidity) burn
/// 0–90 % of their liquidity; both pool tokens fall 3–9 % on every feed (inside the USD band, vault tokens -3 to -9 %);
/// then rounds in a fuzzed order where each account below HF 1 is liquidated through the real LPVaultSwap with the
/// Lens's parameters and each other account repays, exits debt-free or removes part of a debt-free record. Asserted:
/// after the LP removal Avana's pool share the Lens reports is the recomputed `poolUnits / depth` over the pool's real
/// liquidity (the LPVault's harmonic-mean depth over the TWAP window), and the real RiskModule refuses new borrowing
/// (`BreakerTripped` with `POOL_SHARE`) exactly when it is above `poolShareMaxBps` (the launch 10 %); every account
/// below HF 1 is liquidated within the run, every settlement meets its floor on `R + shortfall` with `D <= Kf`, an
/// account solvent at the bonus never loses health (`INV-076`), and no debt-free exit or repay reverts.
/// @dev Before the run each pool's outside liquidity is burned down to 19 times Avana's units in it, so Avana's share
/// starts at 5 % and crosses the 10 % cap once outside LPs remove more than about 53 % of what is left. A removal
/// is followed by the TWAP window (31 minutes) so the depth reads the new liquidity. Accounts hold 500–1,480 vault
/// tokens ($1,000–$2,960 at $2.00, CF 30 %); a probe account in market A (HF 3) checks the borrow gate. The
/// exposure-raising pledge half of the concentration gate is the RiskModule suites'. N is 100, not the stand-in suite's
/// 200: opening 200 accounts with real NFT mints, pledges and borrows exhausts Foundry's gas for one `setUp` call.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 3
contract CascadeIntegrationTest is RealStackFlows {
    uint256 internal constant N = 100;
    uint256 internal constant MAX_ROUNDS = 12;
    /// @dev The launch `poolShareMaxBps` (`FullStackDeploy.POOL_SHARE_MAX_BPS`).
    uint16 internal constant SHARE_CAP_BPS = POOL_SHARE_MAX_BPS;
    /// @dev Aave's maximum liquidation bonus times the collateral factor: 1.05 x 0.30.
    uint256 internal constant SOLVENT_AT_BONUS_HF = 0.315e18;

    uint256 internal mA;
    uint256 internal mB;
    address[] internal wallets;
    bytes32[] internal keys;
    address internal probe;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        mB = _addMarket(poolB);
        probe = makeAddr("probe");
        (, address probeProxy) = _pledgeAs(probe, mA, 1000e6);
        _borrowAs(probe, mA, ghoReserveId, 200e18);
        assertGt(_hf(probeProxy), 2.9e18, "probe at HF 3");
        for (uint256 i = 0; i < N; ++i) {
            uint256 m = _market(i);
            uint128 units = uint128(500e6 + (i % 50) * 20e6);
            address w = makeAddr(string(abi.encode("cascade", i)));
            (bytes32 k,) = _pledgeAs(w, m, units);
            // HF 1.02 to 1.06 at $2.00 and CF 30 %: debt = units x 2.00 x 0.30 / HF, in GHO (18 decimals).
            _borrowAs(w, m, ghoReserveId, uint256(units) * 1e12 * 60 / (102 + i % 5));
            wallets.push(w);
            keys.push(k);
        }
        // Outside LPs hold 19 times Avana's units in each pool: Avana's share starts at 5 %.
        _setOutside(poolA, 19 * coll.poolUnits(_poolKey(mA)));
        _setOutside(poolB, 19 * coll.poolUnits(_poolKey(mB)));
        _waitTwap();
    }

    function _market(
        uint256 i
    ) internal view returns (uint256) {
        return i % 2 == 0 ? mA : mB;
    }

    function _poolKey(
        uint256 marketId
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(V3, address(mkt[marketId].pool), bytes32(0)));
    }

    /// @dev The outside LPs' full-range liquidity in `p` (the fixture's pool actor).
    function _outside(
        IClPool p
    ) internal view returns (uint128 liquidity) {
        (int24 lower, int24 upper) = _fullRange(p);
        (bool ok, bytes memory ret) = address(p)
            .staticcall(
                abi.encodeWithSignature("positions(bytes32)", keccak256(abi.encodePacked(address(actor), lower, upper)))
            );
        require(ok, "pool positions");
        (liquidity) = abi.decode(ret, (uint128));
    }

    /// @dev The outside LPs burn their full-range liquidity in `p` down to `target`.
    function _setOutside(
        IClPool p,
        uint256 target
    ) internal {
        uint128 now_ = _outside(p);
        require(target <= now_, "outside liquidity");
        (int24 lower, int24 upper) = _fullRange(p);
        actor.burn(p, lower, upper, now_ - uint128(target));
    }

    /// @dev The TWAP window passes (the LPVault's depth is a harmonic mean over it); feeds republished, oracles poked.
    function _waitTwap() internal {
        vm.warp(block.timestamp + TWAP_WAIT);
        vm.roll(block.number + TWAP_WAIT / BLOCK_TIME);
        _refreshFeeds();
        _pokeAll();
    }

    /// @dev Outside LPs remove `removalBps` of their liquidity from both pools; the Lens's pool share and the
    /// RiskModule's borrow gate follow the real pool depth.
    function _removeDepth(
        uint256 removalBps
    ) internal {
        _setOutside(poolA, uint256(_outside(poolA)) * (10_000 - removalBps) / 10_000);
        _setOutside(poolB, uint256(_outside(poolB)) * (10_000 - removalBps) / 10_000);
        _waitTwap();
        uint256 units = coll.poolUnits(_poolKey(mA));
        RiskStatus memory rs = uniVault.riskStatus(mA, 1800);
        assertTrue(rs.depthAvailable, "depth available");
        assertApproxEqRel(rs.depthUnits, poolA.liquidity(), 1e14, "depth = the pool's liquidity over the window");
        CapView memory cv = lens.getCapHeadroom(mkt[mA].vaultToken, probe);
        assertEq(cv.poolShareMaxBps, SHARE_CAP_BPS, "Lens: the pool's cap");
        assertEq(cv.poolShareBps, (units * 10_000 + rs.depthUnits - 1) / rs.depthUnits, "Lens: share, rounded up");
        bool over = units * 10_000 > uint256(SHARE_CAP_BPS) * rs.depthUnits;
        (uint32 reasons,) = riskModule.getBreakerStatus(mA);
        assertEq(reasons & BreakerReasons.POOL_SHARE != 0, over, "POOL_SHARE live exactly above the cap");
        address proxy = adapterC.proxyOf(probe, mA);
        uint256 nonce = adapterC.borrowNonce(proxy);
        if (over) vm.expectPartialRevert(IRiskModuleErrors.BreakerTripped.selector);
        vm.prank(probe);
        adapterC.borrow(mA, ghoReserveId, 1e18, probe, _deadline(), 0, nonce);
    }

    function _liquidate(
        uint256 i,
        uint256 seed
    ) internal returns (bool settled) {
        address proxy = adapterC.proxyOf(wallets[i], _market(i));
        LiquidationPreview memory p = lens.previewLiquidation(proxy, ghoReserveId, block.timestamp + 60);
        assertTrue(p.aaveLiquidatable && p.pricesUsable && p.sharesEqualAssets, "every gate open");
        p.params.maxShortfall = p.params.debtToCover / 20;
        address caller = seed % 2 == 0 ? keeper : makeAddr("anyCaller");
        uint256 hfBefore = p.healthFactor;
        LiquidationResult memory r = _liquidateAs(caller, p.params);
        assertGe(r.recovered + r.shortfall, r.minOut, "floor on R + shortfall");
        assertLe(r.debtRepaid, r.callerFunds, "D <= Kf");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
        // INV-076: an account solvent at the bonus (HF >= LB x CF = 1.05 x 0.30) never loses health.
        if (hfBefore >= SOLVENT_AT_BONUS_HF && _debtOf(proxy, ghoReserveId) != 0) {
            assertGe(_hf(proxy), hfBefore, "INV-076");
        }
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
        uint256 credited = coll.getRecord(coll.recordIdOf(V3, keys[i])).credited;
        if (credited == 0) return;
        uint256 owed = _debtOf(proxy, ghoReserveId);
        uint256 kind = seed % 3;
        if (kind == 0) {
            if (owed != 0) {
                _repayVia(w, w, m, ghoReserveId, lens.quoteRepayAll(w, m, ghoReserveId, _deadline()), true);
            }
            _withdrawVia(w, m, keys[i], credited);
            assertEq(IERC721(address(nfpm)).ownerOf(uint256(keys[i])), w, "debt-free exit returned the NFT");
        } else if (kind == 1 && owed != 0) {
            _repayVia(makeAddr("anyPayer"), w, m, ghoReserveId, owed / 3 + 1, false);
        } else if (owed == 0 && credited > 2) {
            vm.prank(w);
            adapterC.removeLiquidity(m, _ref(keys[i]), uint128(credited / 2), new uint256[](2), _deadline(), 0);
        }
    }

    // TEST-218 verifies: INV-045, INV-046, INV-074, INV-076, INV-081, SPEC-LIQ-021, SPEC-BRK-002, REQ-SWAP-118, REQ-LENS-018, Q-241, Q-249, Q-251
    function testFuzz_TEST_218_cascadeAt100Accounts(
        uint256 removalBps,
        uint256 dropBps,
        uint256 orderSeed
    ) public {
        _removeDepth(bound(removalBps, 0, 9000));
        dropBps = bound(dropBps, 300, 900);
        _movePoolTokens(1e8 * (10_000 - dropBps) / 10_000);
        uint256 settled = 0;
        for (uint256 round = 0; round < MAX_ROUNDS && _anyEligible(); ++round) {
            uint256 start = uint256(keccak256(abi.encode(orderSeed, round))) % N;
            for (uint256 k = 0; k < N; ++k) {
                uint256 i = (start + k * 7) % N; // 7 is coprime with 100: a full permutation per round
                uint256 seed = uint256(keccak256(abi.encode(orderSeed, round, k)));
                address proxy = adapterC.proxyOf(wallets[i], _market(i));
                if (_hf(proxy) < 1e18 && _sharesOf(proxy, mkt[_market(i)].reserveId) != 0) {
                    if (_liquidate(i, seed)) ++settled;
                } else if (round == 0) {
                    _ownAction(i, seed);
                }
            }
        }
        assertFalse(_anyEligible(), "an account below HF 1 was left unliquidated");
        // A fall of 5 % or more takes every HF below 1.0526, the HF 1.02 accounts among them, under 1.
        if (dropBps >= 500) assertGt(settled, 0, "the fall made accounts liquidatable");
        address vtA = mkt[mA].vaultToken;
        address vtB = mkt[mB].vaultToken;
        assertEq(IERC20(vtA).totalSupply(), coll.getTotalCredited(vtA) + coll.getPending(vtA).units, "market A backed");
        assertEq(IERC20(vtB).totalSupply(), coll.getTotalCredited(vtB) + coll.getPending(vtB).units, "market B backed");
        assertEq(
            usdc.balanceOf(lpVaultSwap) + usdt.balanceOf(lpVaultSwap) + gho.balanceOf(lpVaultSwap),
            0,
            "LPVaultSwap neutral"
        );
        assertFalse(lock.isLocked(), "Lock free");
    }

    function _anyEligible() internal view returns (bool) {
        for (uint256 i = 0; i < N; ++i) {
            address proxy = adapterC.proxyOf(wallets[i], _market(i));
            if (_hf(proxy) < 1e18 && _sharesOf(proxy, mkt[_market(i)].reserveId) != 0) return true;
        }
        return false;
    }
}
