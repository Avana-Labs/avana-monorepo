// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {WindDownState} from "../../../src/policy/market-registry/types/WindDownState.sol";
import {Market} from "../../../src/types/Market.sol";
import {MarketDef} from "../../../src/types/MarketDef.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPOracleMock} from "../../utils/mocks/MarketRegistryMocks.sol";

/// @title MarketRegistryLifecycleHandler
/// @notice Lifecycle handler of the market-registry suite: on six fixed shapes of the USDC/USDT pool it lists,
/// relists, activates, cancels, offboards, steps the wind-down and closes markets, with time warps and debt switched
/// on and off. A model of REQ-CONFIG-042, REQ-CONFIG-048, REQ-MREG-015, REQ-MREG-030 and REQ-CONFIG-080 predicts each
/// call's success, the resulting status and the wind-down threshold; ghosts count every departure.
/// @dev The handler owns its world (it is the fixture), so the suite reads the registry through `reg()`.
contract MarketRegistryLifecycleHandler is MarketRegistryFixture {
    uint256 public constant SHAPES = 6;
    uint64 internal constant NOTICE = 5 days;
    uint64 internal constant STEP = 1 days;
    uint64 internal constant RAMP = 30 days;

    struct Slot {
        address vaultToken;
        address lpOracle;
        uint256 id;
        MarketStatus status;
        bool prepared;
        uint64 offboardedAt;
        uint64 lastStepAt;
        uint16 startLt;
        uint16 lt;
        bool debt;
    }

    Slot[SHAPES] internal _slots;
    /// @dev Hash of each slot's identity fields at its first listing, and of its Aave identifiers at activation.
    bytes32[SHAPES] internal _identity;
    bytes32[SHAPES] internal _reserveIdentity;
    uint256 public listed;

    uint256 public calls;
    uint256 public outcomeMismatch;
    uint256 public statusMismatch;
    uint256 public ltMismatch;
    uint256 public idMismatch;
    uint256 public identityChanged;
    mapping(bytes32 action => uint256) public successes;

    function init() external {
        _setUpWorld();
    }

    function reg() external view returns (MarketRegistry) {
        return registry;
    }

    function spokeAddr() external view returns (address) {
        return address(spoke);
    }

    function hubAddr() external view returns (address) {
        return address(hub);
    }

    function slot(
        uint256 i
    ) external view returns (Slot memory) {
        return _slots[i];
    }

    function keyOf(
        uint256 i
    ) external view returns (bytes32) {
        return factory.marketKeyOf(V3, pool, bytes32(0), _shapeOf(i));
    }

    function assetOf(
        uint256 i
    ) public pure returns (uint256) {
        return 100 + i;
    }

    function _shapeOf(
        uint256 i
    ) internal pure returns (PositionShape memory) {
        int24 w = int24(int256(10 * (i + 1)));
        return PositionShape(ShapeKind.TickRange, -w, w);
    }

    function _check(
        bytes32 action,
        bool ok,
        bool expected,
        uint256 i
    ) internal {
        ++calls;
        if (ok != expected) ++outcomeMismatch;
        if (ok) ++successes[action];
        Slot storage s = _slots[i];
        if (s.id != 0 && registry.getMarket(s.id).status != s.status) ++statusMismatch;
    }

    /// @dev REQ-CONFIG-008: the fields fixed at listing (no timestamps, status or activation identifiers).
    function identityOf(
        uint256 id
    ) public view returns (bytes32) {
        Market memory m = registry.getMarket(id);
        bytes memory a = abi.encode(m.chainId, m.hub, m.spoke, m.integrationId, m.integration, m.pool, m.poolId);
        bytes memory b = abi.encode(m.shape, m.tokens, m.tokenDecimals, m.vaultToken, m.decimals, m.lpOracle);
        return keccak256(abi.encode(a, b));
    }

    function reserveIdentityOf(
        uint256 id
    ) public view returns (bytes32) {
        Market memory m = registry.getMarket(id);
        return keccak256(abi.encode(m.hubAssetId, m.reserveId));
    }

    function identityAt(
        uint256 i
    ) external view returns (bytes32 listing, bytes32 reserve) {
        return (_identity[i], _reserveIdentity[i]);
    }

    // ─── Actions ───

    function list(
        uint256 seed
    ) external {
        uint256 i = seed % SHAPES;
        Slot storage s = _slots[i];
        PositionShape memory sh = _shapeOf(i);
        if (s.vaultToken == address(0)) {
            (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(registry.marketCount() + 1, sh);
            (s.vaultToken, s.lpOracle) = (vt, address(o));
        }
        MarketDef memory d = _marketDef(s.vaultToken, s.lpOracle);
        d.shape = sh;
        bool expected = s.status == MarketStatus.None || s.status == MarketStatus.Cancelled;
        vm.prank(address(timelock));
        try registry.listCollateralMarket(d) returns (uint256 id) {
            if (s.id == 0) {
                ++listed;
                if (id != listed) ++idMismatch;
                s.id = id;
                _identity[i] = identityOf(id);
            } else {
                if (id != s.id) ++idMismatch;
                // A relisting writes the same identity again.
                if (identityOf(id) != _identity[i]) ++identityChanged;
            }
            s.status = MarketStatus.Registered;
            _check("list", true, expected, i);
        } catch {
            _check("list", false, expected, i);
        }
    }

    function activate(
        uint256 seed
    ) external {
        uint256 i = seed % SHAPES;
        Slot storage s = _slots[i];
        if (s.id == 0) return;
        if (s.status == MarketStatus.Registered) _prepare(i);
        bool expected = s.status == MarketStatus.Registered;
        vm.prank(address(timelock));
        try registry.activateMarket(s.id) {
            s.status = MarketStatus.Active;
            _reserveIdentity[i] = reserveIdentityOf(s.id);
            _check("activate", true, expected, i);
        } catch {
            _check("activate", false, expected, i);
        }
    }

    function cancel(
        uint256 seed
    ) external {
        uint256 i = seed % SHAPES;
        Slot storage s = _slots[i];
        if (s.id == 0) return;
        bool expected = s.status == MarketStatus.Registered;
        vm.prank(address(timelock));
        try registry.cancelRegistration(s.id) {
            s.status = MarketStatus.Cancelled;
            _check("cancel", true, expected, i);
        } catch {
            _check("cancel", false, expected, i);
        }
    }

    function offboard(
        uint256 seed,
        uint16 cfSeed
    ) external {
        uint256 i = seed % SHAPES;
        Slot storage s = _slots[i];
        if (s.id == 0) return;
        bool expected = s.status == MarketStatus.Active;
        // The Aave DAO may have moved the collateral factor since activation.
        uint16 cf = uint16(bound(cfSeed, 1, 8000));
        if (expected) _setCf(i, cf);
        vm.prank(address(timelock));
        try registry.setMarketOffboarding(s.id) {
            s.status = MarketStatus.Offboarding;
            s.offboardedAt = uint64(block.timestamp);
            s.lastStepAt = 0;
            (s.startLt, s.lt) = (cf, cf);
            _check("offboard", true, expected, i);
        } catch {
            _check("offboard", false, expected, i);
        }
    }

    function step(
        uint256 seed
    ) external {
        uint256 i = seed % SHAPES;
        Slot storage s = _slots[i];
        if (s.id == 0) return;
        bool expected = s.status == MarketStatus.Offboarding;
        uint64 start = s.offboardedAt + NOTICE;
        uint64 next = start;
        if (s.lastStepAt != 0 && s.lastStepAt + STEP > next) next = s.lastStepAt + STEP;
        uint64 nowTs = uint64(block.timestamp);
        expected = expected && nowTs >= next;
        try registry.stepWindDown(s.id) {
            if (nowTs < start) {
                ++ltMismatch;
            } else {
                uint16 want = _ramp(s.startLt, nowTs - start);
                if (registry.windDownState(s.id).currentLtBps != want) ++ltMismatch;
                (s.lastStepAt, s.lt) = (nowTs, want);
            }
            _check("step", true, expected, i);
        } catch {
            _check("step", false, expected, i);
        }
    }

    function close(
        uint256 seed,
        bool debt
    ) external {
        uint256 i = seed % SHAPES;
        Slot storage s = _slots[i];
        if (s.id == 0) return;
        collat.setHasDebt(s.vaultToken, debt);
        s.debt = debt;
        bool expected = s.status == MarketStatus.Offboarding && block.timestamp >= s.offboardedAt + NOTICE && !debt;
        vm.prank(makeAddr("anyone"));
        try registry.closeMarket(s.id) {
            s.status = MarketStatus.Closed;
            _check("close", true, expected, i);
        } catch {
            _check("close", false, expected, i);
        }
    }

    function warp(
        uint256 secondsSeed
    ) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1 hours, 10 days));
    }

    // ─── Model helpers ───

    function _ramp(
        uint16 startLt,
        uint64 elapsed
    ) internal pure returns (uint16) {
        if (startLt <= 5000) return startLt;
        uint256 span = elapsed < RAMP ? elapsed : RAMP;
        return uint16(startLt - (uint256(startLt - 5000) * span) / RAMP);
    }

    /// @dev The Aave payload, ParameterStore values and routes of slot `i` (Hub asset and Spoke reserve 100 + i).
    function _prepare(
        uint256 i
    ) internal {
        Slot storage s = _slots[i];
        uint256 a = assetOf(i);
        if (!s.prepared) {
            hub.setAsset(s.vaultToken, a);
            hub.setSpokeConfig(a, address(spoke), 2_000_000, 0);
            IAaveV4Spoke.Reserve memory r;
            (r.underlying, r.hub, r.assetId, r.decimals) = (s.vaultToken, address(hub), uint16(a), 18);
            IAaveV4Spoke.ReserveConfig memory c;
            IAaveV4Spoke.DynamicReserveConfig memory d;
            (d.collateralFactor, d.maxLiquidationBonus) = (7000, 10_500);
            spoke.setReserve(a, r, c, d);
            spoke.setLiquidationConfig(1.1e18, 5000);
            ps.setLiquidationExpectations(address(spoke), 1.1e18, 200);
            ps.setMarket(s.id, 9500, 10e8, 1_000_000e8, 100_000e8, 1e8);
            s.prepared = true;
        }
        _setCf(i, 7000);
        // A relisting starts a new route epoch, so the routes are set for every activation.
        _setRoutesInto(s.id, address(gho));
    }

    function _setCf(
        uint256 i,
        uint16 cf
    ) internal {
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (cf, 10_500);
        spoke.setDynamic(assetOf(i), d);
    }

    function windDownOf(
        uint256 i
    ) external view returns (WindDownState memory) {
        return registry.windDownState(_slots[i].id);
    }
}
