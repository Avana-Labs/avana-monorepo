// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {MarketDynamicCap} from "../../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {Test} from "forge-std/Test.sol";

/// @title ParameterStoreDynamicCapHandler
/// @notice Random dynamic borrow cap tightenings and loosenings by the timelock, the Joint Configuration Safe and a
/// stranger against the real ParameterStore. After each call the handler records whether a stored value changed and
/// in which direction, so the suite can check that no call moved a value the wrong way for its role.
/// @dev Steered: three calls in four write a valid value moved from the stored one in the call's own direction (by a
/// seed-derived fraction of the room left), so the role rules decide the outcome; the fourth writes an arbitrary value,
/// which is mostly invalid or in the wrong direction and must be refused. Callers are the timelock one time in two, the
/// Safe three times in eight and the stranger one time in eight. On a steered call the first write of a never-written
/// value is a loosening by the timelock (only a loosening can set it), and the Safe tightens (it may not loosen).
contract ParameterStoreDynamicCapHandler is Test {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    IParameterStore internal store;
    address internal timelock;
    address internal safe;
    address internal stranger = makeAddr("stranger");
    uint256 internal marketId;

    uint256 public wrongDirection;
    uint256 public strangerWrites;
    uint256 public stewardLoosenings;
    uint256 public writes;

    /// @dev Bounds of ParameterStoreCapRules: interval 1 hour to 7 days, alpha up to 10,000 bps.
    uint32 internal constant INTERVAL_MIN = 3600;
    uint32 internal constant INTERVAL_MAX = 604_800;
    uint16 internal constant ALPHA_MAX = 10_000;

    constructor(
        IParameterStore s,
        address tl,
        address steward,
        uint256 m
    ) {
        (store, timelock, safe, marketId) = (s, tl, steward, m);
    }

    function _arbitrary(
        uint256 seed
    ) internal pure returns (MarketDynamicCap memory v) {
        v.capInterval = uint32(3500 + (seed % 610_000));
        v.capAlphaBps = uint16((seed >> 24) % 10_100);
        v.capBufferMin = uint96((seed >> 56) % 1e16);
        v.capBufferMax = uint96((seed >> 112) % 1e16);
    }

    /// @dev `x` moved toward `to` by `f` percent of the distance (either direction).
    function _toward(
        uint256 x,
        uint256 to,
        uint256 f
    ) internal pure returns (uint256) {
        return x <= to ? x + (to - x) * f / 100 : x - (x - to) * f / 100;
    }

    /// @dev An interval `f` % tighter (longer) or looser (shorter) than `old`; a never-written interval loosens to
    /// any valid one.
    function _interval(
        uint32 old,
        bool loosen,
        uint256 f
    ) internal pure returns (uint32) {
        if (old == 0) return loosen ? uint32(INTERVAL_MIN + f * (INTERVAL_MAX - INTERVAL_MIN) / 100) : 0;
        // Within [INTERVAL_MIN, INTERVAL_MAX], so it fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(_toward(old, loosen ? INTERVAL_MIN : INTERVAL_MAX, f));
    }

    /// @dev A valid value moved from `old` in the call's direction: tighter lengthens the interval and lowers alpha and
    /// both bounds, looser does the opposite; the minimum stays at or below the maximum.
    function _step(
        MarketDynamicCap memory old,
        bool loosen,
        uint256 h
    ) internal pure returns (MarketDynamicCap memory v) {
        uint256 f = 1 + (h >> 8) % 100;
        v.capInterval = _interval(old.capInterval, loosen, f);
        // Alpha within ALPHA_MAX and amounts within 1e16 (or their old values), so the casts fit.
        // forge-lint: disable-next-line(unsafe-typecast)
        v.capAlphaBps = uint16(_toward(old.capAlphaBps, loosen ? ALPHA_MAX : 0, f));
        // forge-lint: disable-next-line(unsafe-typecast)
        v.capBufferMax = uint96(_toward(old.capBufferMax, loosen ? 1e16 : 0, f));
        // forge-lint: disable-next-line(unsafe-typecast)
        v.capBufferMin = uint96(_toward(old.capBufferMin, loosen ? v.capBufferMax : 0, f));
        if (v.capBufferMin > v.capBufferMax) v.capBufferMin = v.capBufferMax;
    }

    function _who(
        uint8 role
    ) internal view returns (address) {
        uint8 r = role % 8;
        return r < 4 ? timelock : r < 7 ? safe : stranger;
    }

    /// @dev The caller and direction of a steered call: an unset value (`capInterval == 0`) is first loosened by the
    /// timelock, and the Safe only tightens.
    function _steer(
        address who,
        bool loosen,
        uint32 oldInterval
    ) internal view returns (address, bool) {
        if (oldInterval == 0) return (timelock, true);
        return who == safe ? (who, false) : (who, loosen);
    }

    /// @notice A dynamic borrow cap change: tighten or loosen, by one of three callers.
    function market(
        uint256 seed,
        uint8 role,
        bool loosen
    ) external {
        address who = _who(role);
        MarketDynamicCap memory old = store.marketDynamicCap(marketId);
        uint256 h = uint256(keccak256(abi.encode(seed)));
        if (h % 4 != 0) (who, loosen) = _steer(who, loosen, old.capInterval);
        MarketDynamicCap memory v = h % 4 == 0 ? _arbitrary(seed) : _step(old, loosen, h);
        vm.prank(who);
        (bool ok,) = address(store)
            .call(
                loosen
                    ? abi.encodeCall(IParameterStore.loosenMarketDynamicCap, (marketId, v))
                    : abi.encodeCall(IParameterStore.tightenMarketDynamicCap, (marketId, v))
            );
        MarketDynamicCap memory now_ = store.marketDynamicCap(marketId);
        if (keccak256(abi.encode(old)) == keccak256(abi.encode(now_))) revert Skipped();
        ++writes;
        if (!ok) ++wrongDirection;
        if (who == stranger) ++strangerWrites;
        if (who == safe && loosen) ++stewardLoosenings;
        bool tighter = now_.capInterval >= old.capInterval && old.capInterval != 0
            && now_.capAlphaBps <= old.capAlphaBps && now_.capBufferMin <= old.capBufferMin
            && now_.capBufferMax <= old.capBufferMax;
        bool looser = (old.capInterval == 0 || now_.capInterval <= old.capInterval)
            && now_.capAlphaBps >= old.capAlphaBps && now_.capBufferMin >= old.capBufferMin
            && now_.capBufferMax >= old.capBufferMax;
        if (loosen ? !looser : !tighter) ++wrongDirection;
    }
}
