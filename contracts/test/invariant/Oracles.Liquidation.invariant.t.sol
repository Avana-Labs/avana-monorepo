// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {RealOraclesFixture} from "../utils/fixtures/RealOraclesFixture.sol";
import {OracleFeedMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";

/// @title OraclesLiquidationInvariantTest
/// @notice The oracles' side of the multi-actor suite (5.1 `TEST-215`), of its liquidation postconditions
/// (`TEST-104`) and of the oracle invariant (`TEST-105`), on the real concentrated-liquidity LPOracle of a WETH/USDC
/// market on a real Uniswap v3 pool and the real USDC DebtOracle. Environment handlers move every feed (drifts,
/// jumps of up to -99 % and +99 %, depegs), stop or break feeds, push a primary and its alternate apart, move the
/// pool's spot price, switch token1's alternate to its standby route and warp time by up to 14 days. A liquidation
/// handler asks LPVaultSwap's two oracle rules after a poke and, when they admit a seizure or a USDC repayment, checks
/// it against the handler's own record of every feed (the ground truth): a valid route for each collateral token,
/// routes that agree, a fresh and agreeing USDC route.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = true
contract OraclesLiquidationInvariantTest is RealOraclesFixture {
    OracleEnvHandler internal handler;

    function setUp() public {
        _deployClMarket(_ethUsdc());
        _deployUsdcDebtOracle();
        OracleFeedMock standbyFeed = _feed("standby", price1);
        handler = new OracleEnvHandler(this, [p0Feed, a0Feed, s0Feed, p1Feed, a1Feed, s1Feed, standbyFeed]);
        targetContract(address(handler));
    }

    // ─── Views the handler reads through the fixture ───

    function lpOracle() external view returns (LPOracleCL) {
        return oracle;
    }

    function clPool() external view returns (address) {
        return address(pool);
    }

    function token1Address() external view returns (address) {
        return address(token1);
    }

    function listingPrices() external view returns (uint256, uint256) {
        return (price0, price1);
    }

    function debtOracleForHandler() external view returns (IDebtOracle) {
        return debtOracle;
    }

    function debtFeeds() external view returns (MockAggregator, MockAggregator, MockAggregator) {
        return (dPrimary, dAltUsdcEth, dAltEthUsd);
    }

    /// @notice Runs LPVaultSwap's collateral and USDC rules for the handler.
    function gates() external returns (bool seizable, bool repayable) {
        (seizable, repayable) = (_seizable(oracle), _repayable());
    }

    /// @notice Moves the pool's spot to `target` with unlimited input.
    function swapTo(
        uint160 target
    ) external {
        _swapTo(pool, target);
    }

    /// @notice Switches token1's alternate slot to `standby` (the guardian's switch) and bumps its route version.
    function useStandby(
        address standby
    ) external {
        registry.setRoutes(address(token1), _one(address(p1Feed)), _one(standby), RouteSlot.Alternate);
        registry.bumpVersion(address(token1));
    }

    // ─── TEST-104 ───

    // TEST-104 verifies: INV-030, INV-059, INV-087, REQ-SWAP-008, REQ-SWAP-091
    // Sources: 5.1 TEST-104 (LPOracle and DebtOracle part: every completed liquidation met its oracle preconditions:
    // the seized market fresh, agreeing and not Cached or Expired, no persistent disagreement, the repaid USDC reserve's
    // DebtOracle Live within liquidationPriceMaxAge)
    /// @notice Every seizure the oracles admitted had, per the handler's own feed record, a valid route for each
    /// collateral token with the two routes agreeing when both read; every USDC repayment they admitted had a fresh
    /// USDC route with the two routes agreeing when both read.
    function invariant_TEST_104_admittedLiquidationsMetTheirOraclePreconditions() public view {
        assertEq(handler.seizureViolations(), 0, handler.lastViolation());
        assertEq(handler.repayViolations(), 0, handler.lastViolation());
    }

    // ─── TEST-105 ───

    // TEST-105 verifies: INV-031, INV-055, INV-056, INV-087, SPEC-ORC-017, SPEC-ORC-018
    // Sources: 5.1 TEST-105 (the LPOracle and DebtOracle answers after every handler call)
    /// @notice After every handler call `latestAnswer()` of the LPOracle and of the DebtOracle is at least 1 and equals
    /// the reported answer; an LPOracle that is not failed serves at most its fresh price, a Cached one its accepted
    /// price and an Expired one 1; a DebtOracle that is not Live serves at least its accepted price; no leg is reported
    /// newer than its feed's latest round; and the standby switch restarted the stored disagreement start.
    function invariant_TEST_105_answersByState() public view {
        LPOracleCL o = oracle;
        PriceStateView memory v = o.getPriceState();
        int256 a = o.latestAnswer();
        assertEq(a, v.answer, "latestAnswer is the reported answer");
        assertGe(a, 1, "LPOracle below 1");
        if (v.state == PriceState.Cached) assertEq(v.answer, v.acceptedAnswer, "Cached serves the accepted price");
        if (v.state == PriceState.Expired) assertEq(v.answer, 1, "Expired serves 1");
        if ((v.state == PriceState.Live || v.state == PriceState.Drifting) && v.freshAnswer >= 1) {
            assertLe(v.answer, v.freshAnswer, "served above the fresh price");
        }
        for (uint256 i = 0; i < v.tokens.length; ++i) {
            for (uint256 k = 0; k < 2; ++k) {
                address f = v.tokens[i].legFeeds[k];
                if (f != address(0)) {
                    assertLe(v.tokens[i].legUpdatedAt[k], OracleFeedMock(f).updatedAt(), "leg newer than its round");
                }
            }
        }
        DebtPriceView memory d = debtOracle.getPriceState();
        assertEq(debtOracle.latestAnswer(), d.answer, "DebtOracle latestAnswer");
        assertGe(d.answer, 1, "DebtOracle below 1");
        if (d.state != PriceState.Live) assertGe(uint256(d.answer), d.acceptedAnswer, "not Live: below accepted");
        assertEq(handler.standbyViolations(), 0, "a standby switch kept an old disagreement start");
    }

    // ─── TEST-215 ───

    // TEST-215 verifies: INV-087, INV-055, INV-059, INV-072, INV-075
    // Sources: 5.1 TEST-215 (the oracle actors and environment handlers: price paths, feed staleness, route
    // disagreement, pool manipulation, the guardian's standby switch, time warps up to 14 days)
    /// @notice Under every handler sequence: no view or poke of either oracle reverted; stress valuation holds (an
    /// Expired LPOracle values the collateral at 1, an Expired DebtOracle serves its stress price, at least its
    /// accepted price); a borrow is allowed only on a Live price within its borrow age; and spot moves never changed a
    /// served collateral price within the block they happened in.
    function invariant_TEST_215_oracleInvariantsUnderEveryActor() public view {
        assertEq(handler.oracleReverts(), 0, "an oracle view or poke reverted");
        assertEq(handler.spotMovedPrice(), 0, "a spot move changed the served price");
        PriceStateView memory v = oracle.getPriceState();
        if (v.state == PriceState.Expired) assertEq(v.answer, 1, "Expired collateral counts as 0");
        if (v.borrowAllowed) {
            assertEq(uint8(v.state), uint8(PriceState.Live), "borrow on a price that is not Live");
            assertLe(v.servedAge, v.borrowPriceMaxAge, "borrow past the borrow age");
        }
        DebtPriceView memory d = debtOracle.getPriceState();
        if (d.state == PriceState.Expired) {
            assertEq(uint256(d.answer), d.stressAnswer, "Expired debt serves its stress price");
            assertGe(d.stressAnswer, d.acceptedAnswer, "stress price below the accepted price");
        }
        if (d.borrowAllowed) assertEq(uint8(d.state), uint8(PriceState.Live), "debt borrow on a price not Live");
    }
}

/// @notice The environment and liquidation actors over the two real oracles; keeps the ground truth of every feed.
contract OracleEnvHandler {
    uint256 internal constant LEG_AGE = 88_200;
    uint256 internal constant ETH_USD_AGE = 5400;
    uint256 internal constant T_LP = 150;
    uint256 internal constant T_USDC = 225;

    OraclesLiquidationInvariantTest internal immutable F;
    LPOracleCL internal immutable O;
    // Feeds 0..5: token0 primary, alternate, second source; token1 primary, alternate, second source; 6: the standby.
    OracleFeedMock[7] internal feeds;
    int256[7] internal price;
    uint256[7] internal at;
    bool[7] internal down;
    uint256[2] internal base;
    uint256 internal alt1 = 4;
    // USDC feeds: 0 primary USDC/USD, 1 USDC/ETH, 2 ETH/USD.
    MockAggregator[3] internal debt;
    int256[3] internal debtPrice;
    uint256[3] internal debtAt;
    bool[3] internal debtDown;

    uint256 public seizureViolations;
    uint256 public repayViolations;
    uint256 public standbyViolations;
    uint256 public oracleReverts;
    uint256 public spotMovedPrice;
    uint256 public seizures;
    string public lastViolation;

    // Cheatcodes at the standard address.
    VmLike internal constant VM = VmLike(address(uint160(uint256(keccak256("hevm cheat code")))));

    constructor(
        OraclesLiquidationInvariantTest fixture,
        OracleFeedMock[7] memory f
    ) {
        F = fixture;
        O = fixture.lpOracle();
        feeds = f;
        (base[0], base[1]) = fixture.listingPrices();
        for (uint256 i = 0; i < 7; ++i) {
            (, price[i],, at[i],) = f[i].latestRoundData();
        }
        (MockAggregator p, MockAggregator ue, MockAggregator eu) = fixture.debtFeeds();
        debt = [p, ue, eu];
        for (uint256 i = 0; i < 3; ++i) {
            (, debtPrice[i],, debtAt[i],) = debt[i].latestRoundData();
        }
    }

    // ─── Environment ───

    /// @notice Time passes: up to two days, and one call in sixteen up to 14 days.
    function warp(
        uint256 dt
    ) external {
        dt = dt % 16 == 0 ? _bound(dt, 1, 14 days) : _bound(dt, 1, 2 days);
        VM.warp(block.timestamp + dt);
        VM.roll(block.number + 1 + dt / 12);
    }

    /// @notice A new round on one feed at `factor` (1 % to 199 %) of its token's listing price.
    function publish(
        uint256 which,
        uint256 factorBps
    ) external {
        uint256 i = which % 7;
        uint256 p = base[i == 6 ? 1 : i / 3] * _bound(factorBps, 100, 19_900) / 10_000;
        _push(i, int256(p));
    }

    /// @notice A coherent move of one token: every feed of it to the same price (drift, jump or depeg).
    function move(
        uint256 token,
        uint256 factorBps
    ) external {
        uint256 t = token % 2;
        uint256 p = base[t] * _bound(factorBps, 100, 19_900) / 10_000;
        for (uint256 k = 0; k < 3; ++k) {
            _push(t * 3 + k, int256(p));
        }
        if (t == 1) _push(6, int256(p));
    }

    /// @notice A feed stops answering, or answers again.
    function toggle(
        uint256 which
    ) external {
        uint256 i = which % 7;
        down[i] = !down[i];
        feeds[i].setMode(feeds[i].latestRoundData.selector, down[i] ? ReadMode.Revert : ReadMode.Normal);
    }

    /// @notice The pool's spot moves to between a quarter and four times the oracle price, in the same block as a
    /// read: the served price must not move with it.
    function swap(
        uint256 k
    ) external {
        int256 before = O.latestAnswer();
        (uint160 s,,,,,,) = IPoolSlot0(F.clPool()).slot0();
        uint256 target = uint256(s) * _bound(k, 32, 128) / 64;
        if (target <= ClPriceMath.MIN_SQRT_RATIO || target >= ClPriceMath.MAX_SQRT_RATIO) return;
        F.swapTo(uint160(target));
        if (O.latestAnswer() != before) ++spotMovedPrice;
    }

    /// @notice The guardian switches token1's alternate slot to its standby; the next poke must restart the stored
    /// disagreement start (or clear it).
    function standby() external {
        if (alt1 == 6) return;
        F.useStandby(address(feeds[6]));
        alt1 = 6;
        _pokeLp();
        uint64 since = O.getPriceState().disagreeSince;
        if (since != 0 && since != block.timestamp) ++standbyViolations;
    }

    /// @notice A new round on one USDC feed at 50 % to 150 % of its current answer.
    function publishDebt(
        uint256 which,
        uint256 factorBps
    ) external {
        uint256 i = which % 3;
        int256 p = debtPrice[i] * int256(_bound(factorBps, 5000, 15_000)) / 10_000;
        if (p < 1) p = 1;
        debt[i].push(p, block.timestamp);
        (debtPrice[i], debtAt[i]) = (p, block.timestamp);
    }

    /// @notice Every USDC feed publishes its current answer now.
    function refreshDebt() external {
        for (uint256 i = 0; i < 3; ++i) {
            debt[i].push(debtPrice[i], block.timestamp);
            debtAt[i] = block.timestamp;
        }
    }

    /// @notice A keeper pokes both oracles.
    function poke() external {
        _pokeLp();
        try F.debtOracleForHandler().poke{gas: 5_000_000}() {}
        catch {
            ++oracleReverts;
        }
    }

    // ─── Liquidation ───

    /// @notice A liquidation of the WETH/USDC market repaying USDC or GHO: LPVaultSwap's oracle rules after a poke,
    /// checked against the ground truth whenever they admit it.
    function liquidate() external {
        (bool seizable, bool repayable) = F.gates();
        if (seizable) {
            ++seizures;
            for (uint256 t = 0; t < 2; ++t) {
                uint256 p = t * 3;
                uint256 a = t == 0 ? 1 : alt1;
                bool vp = _valid(p);
                bool va = _valid(a);
                if (!vp && !va) _seizureViolation("seized with no valid route");
                if (vp && va && _dev(price[p], price[a]) > T_LP) _seizureViolation("seized while routes disagree");
            }
        }
        if (repayable) {
            bool vp = _debtValid(0, LEG_AGE);
            bool va = _debtValid(1, LEG_AGE) && _debtValid(2, ETH_USD_AGE);
            if (!vp && !va) _repayViolation("USDC repaid with no fresh route");
            if (vp && va) {
                int256 alt = debtPrice[1] * debtPrice[2] / 1e18;
                if (_dev(debtPrice[0], alt) > T_USDC) _repayViolation("USDC repaid while its routes disagree");
            }
        }
    }

    // ─── Internal ───

    function _push(
        uint256 i,
        int256 p
    ) internal {
        feeds[i].push(p, block.timestamp);
        (price[i], at[i]) = (p, block.timestamp);
    }

    function _pokeLp() internal {
        try O.poke{gas: 5_000_000}() {}
        catch {
            ++oracleReverts;
        }
    }

    function _valid(
        uint256 i
    ) internal view returns (bool) {
        return !down[i] && price[i] > 0 && at[i] <= block.timestamp && block.timestamp - at[i] <= LEG_AGE;
    }

    function _debtValid(
        uint256 i,
        uint256 age
    ) internal view returns (bool) {
        return !debtDown[i] && debtPrice[i] > 0 && block.timestamp - debtAt[i] <= age;
    }

    function _dev(
        int256 x,
        int256 y
    ) internal pure returns (uint256) {
        uint256 a = uint256(x);
        uint256 b = uint256(y);
        uint256 lo = a < b ? a : b;
        if (lo == 0) return type(uint256).max;
        return (a > b ? a - b : b - a) * 10_000 / lo;
    }

    function _seizureViolation(
        string memory why
    ) internal {
        ++seizureViolations;
        lastViolation = why;
    }

    function _repayViolation(
        string memory why
    ) internal {
        ++repayViolations;
        lastViolation = why;
    }

    function _bound(
        uint256 x,
        uint256 lo,
        uint256 hi
    ) internal pure returns (uint256) {
        return lo + x % (hi - lo + 1);
    }
}

interface VmLike {
    function warp(
        uint256
    ) external;

    function roll(
        uint256
    ) external;
}

interface IPoolSlot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}
