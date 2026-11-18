// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaTimelock} from "../../../src/governance/timelock/IAvanaTimelock.sol";
import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title ParameterStoreHandler
/// @notice Actor handler of the ParameterStore governance-drift suite (TEST-225): the timelock tightens, loosens and
/// sets market, cap, feed-age and chain values; the Joint Configuration Safe tightens; strangers try every class;
/// time moves. Inputs are
/// bounded around the interesting edges and every call may revert. Ghosts count each success that broke its rule
/// (direction, step, spacing, caller), so the invariants also see what a single call did, not only the end state.
contract ParameterStoreHandler is CommonBase, StdUtils {
    IParameterStore public immutable STORE;
    address public immutable TIMELOCK;
    address public immutable STEWARD;
    address public immutable HUB;
    address public immutable USDC;
    address public immutable USDT;
    address public immutable FEED;
    uint256 public immutable M;

    // Ghosts
    uint256 public wrongDirection;
    uint256 public stepEscaped;
    uint256 public spacingEscaped;
    uint256 public strangerWrites;
    uint256 public stewardLoosened;
    uint256 public successes;
    mapping(bytes32 key => uint256 at) public lastLoosening;

    constructor(
        IParameterStore store,
        address timelock,
        address steward,
        address hub,
        address usdc,
        address usdt,
        address feed,
        uint256 marketId
    ) {
        (STORE, TIMELOCK, STEWARD, HUB) = (store, timelock, steward, hub);
        (USDC, USDT, FEED, M) = (usdc, usdt, feed, marketId);
    }

    function _as(
        address who,
        bytes memory data
    ) internal returns (bool ok) {
        vm.prank(who);
        (ok,) = address(STORE).call(data);
        if (ok) ++successes;
    }

    function _tightener(
        bool steward
    ) internal view returns (address) {
        return steward ? STEWARD : TIMELOCK;
    }

    function _key(
        bytes32 name,
        bytes32 scope
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(name, scope));
    }

    /// @dev Records a step-limited loosening and checks it against the one before it on the same key.
    function _spaced(
        bytes32 key
    ) internal {
        uint256 last = lastLoosening[key];
        if (last != 0 && block.timestamp < last + IAvanaTimelock(TIMELOCK).normalDelay()) ++spacingEscaped;
        lastLoosening[key] = block.timestamp;
    }

    // ─── Time ───

    function warp(
        uint256 dt
    ) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 6 days));
    }

    // ─── Market caps ───

    function tightenMarketCap(
        uint256 v,
        bool steward
    ) external {
        uint256 old = STORE.marketUsdCap(M);
        v = bound(v, 0, old + 1);
        if (_as(_tightener(steward), abi.encodeCall(STORE.tightenMarketUsdCap, (M, v))) && v >= old) ++wrongDirection;
    }

    function loosenMarketCap(
        uint256 v
    ) external {
        uint256 old = STORE.marketUsdCap(M);
        v = bound(v, old > 0 ? old - 1 : 0, _loosenCeiling(old));
        if (_as(TIMELOCK, abi.encodeCall(STORE.loosenMarketUsdCap, (M, v)))) {
            if (v <= old) ++wrongDirection;
            if (_capStepBroken(old, v)) ++stepEscaped;
            _spaced(_key("marketUsdCap", bytes32(M)));
        }
    }

    function tightenSlice(
        uint256 v,
        bool steward
    ) external {
        uint256 old = STORE.topUpSliceUsd(M);
        v = bound(v, 0, old + 1);
        if (_as(_tightener(steward), abi.encodeCall(STORE.tightenTopUpSliceUsd, (M, v))) && v >= old) ++wrongDirection;
    }

    function loosenSlice(
        uint256 v
    ) external {
        uint256 old = STORE.topUpSliceUsd(M);
        uint256 cap = STORE.marketUsdCap(M);
        uint256 base = cap / 10 > old ? cap / 10 : old;
        v = bound(v, old, base + base / 2 + 2);
        if (_as(TIMELOCK, abi.encodeCall(STORE.loosenTopUpSliceUsd, (M, v)))) {
            if (v <= old) ++wrongDirection;
            if (v * 10_000 > base * 15_000) ++stepEscaped;
            _spaced(_key("topUpSliceUsd", bytes32(M)));
        }
    }

    function tightenTokenCap(
        uint256 v,
        bool steward
    ) external {
        uint256 old = STORE.tokenUsdCap(HUB, USDC);
        v = bound(v, 0, old + 1);
        if (_as(_tightener(steward), abi.encodeCall(STORE.tightenTokenUsdCap, (HUB, USDC, v))) && v >= old) {
            ++wrongDirection;
        }
    }

    function loosenTokenCap(
        uint256 v
    ) external {
        uint256 old = STORE.tokenUsdCap(HUB, USDC);
        v = bound(v, old, _loosenCeiling(old));
        if (_as(TIMELOCK, abi.encodeCall(STORE.loosenTokenUsdCap, (HUB, USDC, v)))) {
            if (_capStepBroken(old, v)) ++stepEscaped;
            _spaced(_key("tokenUsdCap", keccak256(abi.encode(HUB, USDC))));
        }
    }

    /// @dev Just above the largest loosening the store admits: 1.5x the old value, or the $1,000 reopen base.
    function _loosenCeiling(
        uint256 old
    ) internal pure returns (uint256) {
        uint256 step = old + old / 2 + 2;
        return step > 1000e8 + 2 ? step : 1000e8 + 2;
    }

    /// @dev A market or token cap loosening breaks its rule when it is above both the $1,000 reopen base
    /// (USD_CAP_REOPEN_BASE) and 1.5x the old value (REQ-PSTORE-017).
    function _capStepBroken(
        uint256 old,
        uint256 v
    ) internal pure returns (bool) {
        return v > 1000e8 && v * 10_000 > old * 15_000;
    }

    // ─── Market risk values ───

    function tightenSlippage(
        uint16 v,
        bool steward
    ) external {
        uint16 old = STORE.getMarketParams(M).slippageAllowanceBps;
        v = uint16(bound(v, 0, uint256(old) + 1));
        if (_as(_tightener(steward), abi.encodeCall(STORE.tightenSlippageAllowanceBps, (M, v))) && v >= old) {
            ++wrongDirection;
        }
    }

    function loosenSlippage(
        uint16 v
    ) external {
        uint16 old = STORE.getMarketParams(M).slippageAllowanceBps;
        v = uint16(bound(v, old, uint256(old) + 30));
        if (_as(TIMELOCK, abi.encodeCall(STORE.loosenSlippageAllowanceBps, (M, v)))) {
            if (v > uint256(old) + 25) ++stepEscaped;
            _spaced(_key("slippageAllowanceBps", bytes32(M)));
        }
    }

    function setSlippageFloor(
        uint16 v
    ) external {
        _as(TIMELOCK, abi.encodeCall(STORE.setSlippageAllowanceMinBps, (M, uint16(bound(v, 0, 200)))));
    }

    function tightenPledge(
        uint256 v,
        bool steward
    ) external {
        uint256 old = STORE.minPledgeUsd(M);
        v = bound(v, old > 0 ? old - 1 : 0, 100_001e8);
        if (_as(_tightener(steward), abi.encodeCall(STORE.tightenMinPledgeUsd, (M, v))) && v <= old) {
            ++wrongDirection;
        }
    }

    function loosenPledge(
        uint256 v
    ) external {
        uint256 old = STORE.minPledgeUsd(M);
        v = bound(v, 0, old + 1);
        if (_as(TIMELOCK, abi.encodeCall(STORE.loosenMinPledgeUsd, (M, v))) && v >= old) ++wrongDirection;
    }

    // ─── Feed ages ───

    function tightenBorrowAge(
        uint32 v,
        bool steward
    ) external {
        uint32 old = STORE.borrowPriceMaxAge(FEED);
        v = uint32(bound(v, 0, uint256(old) + 1));
        if (_as(_tightener(steward), abi.encodeCall(STORE.tightenBorrowPriceMaxAge, (FEED, v))) && v >= old) {
            ++wrongDirection;
        }
    }

    function setBorrowAge(
        uint32 v
    ) external {
        _as(TIMELOCK, abi.encodeCall(STORE.setBorrowPriceMaxAge, (FEED, uint32(bound(v, 0, 90_000)))));
    }

    // ─── Chain values ───

    function setFlashFee(
        uint16 v
    ) external {
        _as(TIMELOCK, abi.encodeCall(STORE.setMaxFlashFeeBps, (uint16(bound(v, 0, 120)))));
    }

    function tightenFlashFee(
        uint16 v,
        bool steward
    ) external {
        uint16 old = STORE.maxFlashFeeBps();
        v = uint16(bound(v, 0, uint256(old) + 1));
        if (_as(_tightener(steward), abi.encodeCall(STORE.tightenMaxFlashFeeBps, (v))) && v >= old) ++wrongDirection;
    }

    function gateRecovery(
        uint64 v,
        bool tighten,
        bool steward
    ) external {
        uint64 old = STORE.gateRecoverySeconds();
        v = uint64(bound(v, 500, 7300));
        if (tighten) {
            if (_as(_tightener(steward), abi.encodeCall(STORE.tightenGateRecoverySeconds, (v))) && v <= old) {
                ++wrongDirection;
            }
        } else if (_as(TIMELOCK, abi.encodeCall(STORE.loosenGateRecoverySeconds, (v))) && v >= old) {
            ++wrongDirection;
        }
    }

    function shortfall(
        uint16 v,
        bool tighten,
        bool steward
    ) external {
        uint16 old = STORE.maxShortfallBps();
        v = uint16(bound(v, 0, 5100));
        if (tighten) {
            if (_as(_tightener(steward), abi.encodeCall(STORE.tightenMaxShortfallBps, (v))) && v >= old) {
                ++wrongDirection;
            }
        } else if (_as(TIMELOCK, abi.encodeCall(STORE.loosenMaxShortfallBps, (v))) && v <= old) {
            ++wrongDirection;
        }
    }

    // ─── Strangers and the steward outside its lane ───

    function strangerCalls(
        uint256 seed,
        uint256 v
    ) external {
        address who = address(uint160(bound(seed, 1, type(uint64).max)) + 0x1000);
        bytes[6] memory calls = [
            abi.encodeCall(STORE.tightenMarketUsdCap, (M, bound(v, 1, 1e20))),
            abi.encodeCall(STORE.loosenMarketUsdCap, (M, bound(v, 1, 1e20))),
            abi.encodeCall(STORE.setBorrowPriceMaxAge, (FEED, uint32(bound(v, 1, 88_200)))),
            abi.encodeCall(STORE.setPoolRiskFactor, (M, uint16(bound(v, 1, 9000)))),
            abi.encodeCall(STORE.setAvanaFeeShareBps, (uint16(bound(v, 0, 5000)))),
            abi.encodeCall(STORE.grantRole, (bytes32(0), who))
        ];
        if (_as(who, calls[v % calls.length])) ++strangerWrites;
    }

    function stewardLoosens(
        uint256 v,
        uint8 which
    ) external {
        bytes[4] memory calls = [
            abi.encodeCall(STORE.loosenMarketUsdCap, (M, bound(v, 1, 1e20))),
            abi.encodeCall(STORE.loosenSlippageAllowanceBps, (M, uint16(bound(v, 0, 200)))),
            abi.encodeCall(STORE.setMaxFlashFeeBps, (uint16(bound(v, 0, 100)))),
            abi.encodeCall(STORE.setSlippageAllowanceMinBps, (M, uint16(bound(v, 0, 100))))
        ];
        if (_as(STEWARD, calls[which % calls.length])) ++stewardLoosened;
    }

    // ─── Views for the invariants ───

    function params() external view returns (MarketParams memory) {
        return STORE.getMarketParams(M);
    }
}
