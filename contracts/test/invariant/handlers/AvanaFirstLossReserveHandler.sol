// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {
    AvanaFirstLossReserveFixture,
    ICoverageHubSpokeCalls
} from "../../utils/fixtures/AvanaFirstLossReserveFixture.sol";
import {MockDebtAsset} from "../../utils/mocks/MockDebtAsset.sol";

/// @title AvanaFirstLossReserveHandler
/// @notice Deficit handler of the First-Loss Reserve suite on the real local Aave V4 Hub: two assets (GHO, 18 decimals,
/// and USDC, 6 decimals), each with its own First-Loss Reserve, and two drawing Spokes, the CDP Spoke (allowlisted on both
/// instances) and a second one the DAO adds to and removes from either allowlist. Actions record deficits (the
/// Spoke's `draw` then `reportDeficit`, as a liquidation that leaves no collateral does), accrue interest, fund either
/// reserve, change the allowlists and call `coverDeficit` with any instance, Spoke and `maxAmount`.
/// @dev Every coverage call is compared with SPEC-FLR-001 against the state read just before it: the amount, the
/// recorded deficit's fall `dRay`, and that nothing else moved. Ghosts count every departure and accumulate, per asset
/// and Spoke, the deficit recorded and the deficit eliminated, so the suite can check the Hub's records against them.
contract AvanaFirstLossReserveHandler is AvanaFirstLossReserveFixture {
    uint256 internal constant ASSETS = 2;
    uint256 internal constant SPOKES = 2;

    AvanaFirstLossReserve[ASSETS] internal _cs;
    MockDebtAsset[ASSETS] internal _tokens;
    uint256[ASSETS] internal _ids;
    address[SPOKES] internal _spokes;

    /// @notice Deficit recorded and eliminated so far, RAY units, per asset index and Spoke index.
    uint256[SPOKES][ASSETS] public reportedRay;
    uint256[SPOKES][ASSETS] public eliminatedRay;
    /// @notice Coverage paid per asset index, base units.
    uint256[ASSETS] public coveredSum;

    uint256 public coverCalls;
    uint256 public coverSuccesses;
    /// @notice A coverage above `ceil(deficitRay / RAY)`, the funded balance or `maxAmount`.
    uint256 public amountOverBound;
    /// @notice A coverage whose amount or deficit fall differs from SPEC-FLR-001.
    uint256 public amountMismatch;
    /// @notice A coverage that succeeded for a Spoke off the instance's allowlist, or with nothing to cover.
    uint256 public coveredWhenRefused;
    /// @notice A coverage that moved another asset's deficit, another Spoke's deficit or the other reserve.
    uint256 public crossEffect;
    /// @notice A refused coverage that changed a deficit or a reserve.
    uint256 public refusedChangedState;

    function init() external {
        _deployCoverage();
        _cs = [ghoCoverage, usdcCoverage];
        _tokens = [gho, usdc];
        _ids = [ghoAssetId, usdcAssetId];
        _spokes = [aave.cdpSpoke, otherSpoke];
        // Ordinary debt on both assets, so supply interest accrues to every added share as time passes.
        _draw(ghoAssetId, aave.cdpSpoke, 500_000e18);
        _draw(usdcAssetId, aave.cdpSpoke, 500_000e6);
    }

    function instance(
        uint256 a
    ) external view returns (AvanaFirstLossReserve) {
        return _cs[a];
    }

    function assetId(
        uint256 a
    ) external view returns (uint256) {
        return _ids[a];
    }

    function spokeAt(
        uint256 s
    ) external view returns (address) {
        return _spokes[s];
    }

    /// @notice A drawing Spoke draws `amount` whole units of an asset and reports them all as a deficit.
    function reportDeficit(
        uint256 seed,
        uint256 amount
    ) external {
        uint256 a = seed % ASSETS;
        uint256 s = (seed >> 8) % SPOKES;
        uint256 unit = 10 ** _tokens[a].decimals();
        amount = bound(amount, 1, 40_000) * unit;
        uint256 before = hub.getSpokeDeficitRay(_ids[a], _spokes[s]);
        vm.startPrank(_spokes[s]);
        try ICoverageHubSpokeCalls(aave.hub).draw(_ids[a], amount, _spokes[s]) {
            ICoverageHubSpokeCalls(aave.hub).reportDeficit(_ids[a], amount, IAaveV4Hub.PremiumDelta(0, 0, 0));
        } catch {}
        vm.stopPrank();
        reportedRay[a][s] += hub.getSpokeDeficitRay(_ids[a], _spokes[s]) - before;
    }

    /// @notice Time passes, so debt and supply interest accrue.
    function warp(
        uint256 seconds_
    ) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 30 days));
    }

    /// @notice Avana Labs funds one reserve.
    function fund(
        uint256 seed,
        uint256 amount
    ) external {
        uint256 a = seed % ASSETS;
        amount = bound(amount, 1, 50_000) * 10 ** _tokens[a].decimals();
        _fund(_cs[a], _tokens[a], avanaLabs, amount);
    }

    /// @notice The DAO adds the second Spoke to, or removes it from, one instance's allowlist.
    function setAllowlist(
        uint256 seed,
        bool allowed
    ) external {
        vm.prank(aaveGovernanceExecutor);
        _cs[seed % ASSETS].setAllowedBorrowSpoke(otherSpoke, allowed);
    }

    struct Snap {
        uint256[SPOKES][ASSETS] deficit;
        uint256[ASSETS] funded;
        uint256[ASSETS] totalCovered;
    }

    function _snap() internal view returns (Snap memory sn) {
        for (uint256 a = 0; a < ASSETS; ++a) {
            for (uint256 s = 0; s < SPOKES; ++s) {
                sn.deficit[a][s] = hub.getSpokeDeficitRay(_ids[a], _spokes[s]);
            }
            sn.funded[a] = _cs[a].fundedBalance();
            sn.totalCovered[a] = _cs[a].totalCovered();
        }
    }

    /// @notice `COVERAGE_ROLE` calls `coverDeficit` on instance `a` for Spoke `s` with any `maxAmount`.
    function cover(
        uint256 seed,
        uint256 maxAmount
    ) external {
        uint256 a = seed % ASSETS;
        uint256 s = (seed >> 8) % SPOKES;
        maxAmount = bound(maxAmount, 0, 200_000 * 10 ** _tokens[a].decimals());
        Snap memory pre = _snap();
        bool allowed = _cs[a].allowedBorrowSpoke(_spokes[s]);
        ++coverCalls;
        vm.prank(coverageCaller);
        try _cs[a].coverDeficit(_spokes[s], maxAmount) returns (uint256, uint256 covered) {
            ++coverSuccesses;
            _checkCovered(a, s, maxAmount, covered, allowed, pre);
        } catch {
            Snap memory post = _snap();
            if (keccak256(abi.encode(pre)) != keccak256(abi.encode(post))) ++refusedChangedState;
        }
    }

    function _checkCovered(
        uint256 a,
        uint256 s,
        uint256 maxAmount,
        uint256 covered,
        bool allowed,
        Snap memory pre
    ) internal {
        Snap memory post = _snap();
        uint256 d = pre.deficit[a][s];
        uint256 dUnits = (d + RAY - 1) / RAY;
        if (!allowed || d == 0) ++coveredWhenRefused;
        if (covered > dUnits || covered > pre.funded[a] || covered > maxAmount) ++amountOverBound;
        uint256 expected = _min(_min(maxAmount, dUnits), pre.funded[a]);
        uint256 dRay = expected < dUnits ? expected * RAY : d;
        if (covered != expected || post.deficit[a][s] + dRay != d) ++amountMismatch;
        if (post.totalCovered[a] != pre.totalCovered[a] + covered) ++amountMismatch;
        for (uint256 b = 0; b < ASSETS; ++b) {
            for (uint256 t = 0; t < SPOKES; ++t) {
                if ((b != a || t != s) && post.deficit[b][t] != pre.deficit[b][t]) ++crossEffect;
            }
            if (b != a && (post.funded[b] != pre.funded[b] || post.totalCovered[b] != pre.totalCovered[b])) {
                ++crossEffect;
            }
        }
        eliminatedRay[a][s] += d - post.deficit[a][s];
        coveredSum[a] += covered;
    }

    function _min(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256) {
        return x < y ? x : y;
    }
}
