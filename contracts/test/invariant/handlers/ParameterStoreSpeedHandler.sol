// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreSpeed} from "../../../src/policy/parameter-store/IParameterStoreSpeed.sol";
import {MarketSpeedLimits} from "../../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../../src/policy/parameter-store/types/SpeedLimit.sol";
import {Test} from "forge-std/Test.sol";

/// @title ParameterStoreSpeedHandler
/// @notice Random speed-limit tightenings and loosenings by the timelock, the Joint Configuration Safe and a stranger
/// against the real ParameterStore (TEST-325). After each call the handler records whether a stored value changed and
/// in which direction, so the suite can check that no call moved a value the wrong way for its role.
contract ParameterStoreSpeedHandler is Test {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    IParameterStore internal store;
    address internal timelock;
    address internal safe;
    address internal stranger = makeAddr("stranger");
    uint256 internal marketId;
    address internal hub;
    address internal asset;

    uint256 public wrongDirection;
    uint256 public strangerWrites;
    uint256 public stewardLoosenings;
    uint256 public writes;

    constructor(
        IParameterStore s,
        address tl,
        address steward,
        uint256 m,
        address h,
        address a
    ) {
        (store, timelock, safe, marketId, hub, asset) = (s, tl, steward, m, h, a);
    }

    function _market(
        uint256 seed
    ) internal pure returns (MarketSpeedLimits memory v) {
        v.window = uint32(3500 + (seed % 610_000));
        v.borrowRateBps = uint16((seed >> 24) % 10_100);
        v.pledgeRateBps = uint16((seed >> 40) % 10_100);
        uint96 a = uint96((seed >> 56) % 1e16);
        uint96 b = uint96((seed >> 112) % 1e16);
        (v.borrowMinUsd, v.borrowMaxUsd) = (a, b);
        (v.pledgeMinUsd, v.pledgeMaxUsd) = (a / 2, b);
    }

    function _debt(
        uint256 seed
    ) internal pure returns (SpeedLimit memory v) {
        v.window = uint32(3500 + (seed % 610_000));
        v.rateBps = uint16((seed >> 24) % 10_100);
        v.min = uint96((seed >> 56) % 1e24);
        v.max = uint96((seed >> 128) % 1e24);
    }

    function _who(
        uint8 role
    ) internal view returns (address) {
        return role % 3 == 0 ? timelock : role % 3 == 1 ? safe : stranger;
    }

    function _changed(
        bytes memory before,
        bytes memory afterwards
    ) internal pure returns (bool) {
        return keccak256(before) != keccak256(afterwards);
    }

    /// @notice A market speed-limit change: tighten or loosen, by one of three callers.
    function market(
        uint256 seed,
        uint8 role,
        bool loosen
    ) external {
        address who = _who(role);
        MarketSpeedLimits memory old = store.marketSpeedLimits(marketId);
        MarketSpeedLimits memory v = _market(seed);
        vm.prank(who);
        (bool ok,) = address(store)
            .call(
                loosen
                    ? abi.encodeCall(IParameterStoreSpeed.loosenMarketSpeedLimits, (marketId, v))
                    : abi.encodeCall(IParameterStoreSpeed.tightenMarketSpeedLimits, (marketId, v))
            );
        MarketSpeedLimits memory now_ = store.marketSpeedLimits(marketId);
        if (!_changed(abi.encode(old), abi.encode(now_))) revert Skipped();
        ++writes;
        if (!ok) ++wrongDirection;
        if (who == stranger) ++strangerWrites;
        if (who == safe && loosen) ++stewardLoosenings;
        bool tighter = now_.window >= old.window && old.window != 0 && now_.borrowRateBps <= old.borrowRateBps
            && now_.pledgeRateBps <= old.pledgeRateBps && now_.borrowMinUsd <= old.borrowMinUsd
            && now_.borrowMaxUsd <= old.borrowMaxUsd && now_.pledgeMinUsd <= old.pledgeMinUsd
            && now_.pledgeMaxUsd <= old.pledgeMaxUsd;
        bool looser = (old.window == 0 || now_.window <= old.window) && now_.borrowRateBps >= old.borrowRateBps
            && now_.pledgeRateBps >= old.pledgeRateBps && now_.borrowMinUsd >= old.borrowMinUsd
            && now_.borrowMaxUsd >= old.borrowMaxUsd && now_.pledgeMinUsd >= old.pledgeMinUsd
            && now_.pledgeMaxUsd >= old.pledgeMaxUsd;
        if (loosen ? !looser : !tighter) ++wrongDirection;
    }

    /// @notice A (Hub, asset) speed-limit change: tighten or loosen, by one of three callers.
    function debt(
        uint256 seed,
        uint8 role,
        bool loosen
    ) external {
        address who = _who(role);
        SpeedLimit memory old = store.debtSpeedLimit(hub, asset);
        SpeedLimit memory v = _debt(seed);
        vm.prank(who);
        (bool ok,) = address(store)
            .call(
                loosen
                    ? abi.encodeCall(IParameterStoreSpeed.loosenDebtSpeedLimit, (hub, asset, v))
                    : abi.encodeCall(IParameterStoreSpeed.tightenDebtSpeedLimit, (hub, asset, v))
            );
        SpeedLimit memory now_ = store.debtSpeedLimit(hub, asset);
        if (!_changed(abi.encode(old), abi.encode(now_))) revert Skipped();
        ++writes;
        if (!ok) ++wrongDirection;
        if (who == stranger) ++strangerWrites;
        if (who == safe && loosen) ++stewardLoosenings;
        bool tighter = now_.window >= old.window && old.window != 0 && now_.rateBps <= old.rateBps
            && now_.min <= old.min && now_.max <= old.max;
        bool looser = (old.window == 0 || now_.window <= old.window) && now_.rateBps >= old.rateBps
            && now_.min >= old.min && now_.max >= old.max;
        if (loosen ? !looser : !tighter) ++wrongDirection;
    }
}
