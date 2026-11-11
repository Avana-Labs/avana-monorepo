// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaTimelockViews} from "../../../src/governance/timelock/IAvanaTimelockViews.sol";
import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/MarketParams.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title ParameterStoreHandler
/// @notice Actor handler of the ParameterStore governance-drift suite (TEST-225): the timelock tightens, loosens and
/// sets market, cap, tolerance, feed-age and chain values; the Joint Configuration Safe tightens; a guardian switches
/// the second source to its standby and the timelock restores it; strangers try every class; time moves. Inputs are
/// bounded around the interesting edges and every call may revert. Ghosts count each success that broke its rule
/// (direction, step, spacing, caller), so the invariants also see what a single call did, not only the end state.
contract ParameterStoreHandler is CommonBase, StdUtils {
    IParameterStore public immutable STORE;
    address public immutable TIMELOCK;
    address public immutable STEWARD;
    address public immutable GUARDIAN;
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
        address guardian,
        address hub,
        address usdc,
        address usdt,
        address feed,
        uint256 marketId
    ) {
        (STORE, TIMELOCK, STEWARD, GUARDIAN, HUB) = (store, timelock, steward, guardian, hub);
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
        if (last != 0 && block.timestamp < last + IAvanaTimelockViews(TIMELOCK).normalDelay()) ++spacingEscaped;
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
        v = bound(v, old > 0 ? old - 1 : 0, old + old / 2 + 2);
        if (_as(TIMELOCK, abi.encodeCall(STORE.loosenMarketUsdCap, (M, v)))) {
            if (v <= old) ++wrongDirection;
            if (v * 10_000 > old * 15_000) ++stepEscaped;
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
        v = bound(v, old, old + old / 2 + 2);
        if (_as(TIMELOCK, abi.encodeCall(STORE.loosenTokenUsdCap, (HUB, USDC, v)))) {
            if (v * 10_000 > old * 15_000) ++stepEscaped;
            _spaced(_key("tokenUsdCap", keccak256(abi.encode(HUB, USDC))));
        }
    }

    function loosenDepositorCap(
        uint256 v
    ) external {
        uint256 old = STORE.depositorUsdCap(HUB);
        v = bound(v, old, old + old / 2 + 2);
        if (_as(TIMELOCK, abi.encodeCall(STORE.loosenDepositorUsdCap, (HUB, v)))) {
            if (v * 10_000 > old * 15_000) ++stepEscaped;
            _spaced(_key("depositorUsdCap", bytes32(uint256(uint160(HUB)))));
        }
    }

    function tightenDepositorCap(
        uint256 v,
        bool steward
    ) external {
        uint256 old = STORE.depositorUsdCap(HUB);
        v = bound(v, 0, old + 1);
        if (_as(_tightener(steward), abi.encodeCall(STORE.tightenDepositorUsdCap, (HUB, v))) && v >= old) {
            ++wrongDirection;
        }
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

    function tightenHardFloor(
        uint256 v,
        bool steward
    ) external {
        uint256 old = STORE.hardHealthFloor(M);
        v = bound(v, 0.99e18, 1.26e18);
        if (_as(_tightener(steward), abi.encodeCall(STORE.tightenHardHealthFloor, (M, v))) && v <= old) {
            ++wrongDirection;
        }
    }

    function loosenHardFloor(
        uint256 v
    ) external {
        uint256 old = STORE.hardHealthFloor(M);
        v = bound(v, 0.95e18, 1.26e18);
        if (_as(TIMELOCK, abi.encodeCall(STORE.loosenHardHealthFloor, (M, v)))) {
            uint256 stored = STORE.hardHealthFloor(M);
            if (stored >= old) ++wrongDirection;
            if (old - (stored == 0 ? 1e18 : stored) > 0.03e18) ++stepEscaped;
            _spaced(_key("hardHealthFloor", bytes32(M)));
        }
    }

    function tightenConsistency(
        uint16 v,
        bool steward
    ) external {
        uint16 old = STORE.getMarketParams(M).consistencyToleranceBps;
        v = uint16(bound(v, 0, uint256(old) + 1));
        if (_as(_tightener(steward), abi.encodeCall(STORE.tightenConsistencyToleranceBps, (M, v))) && v >= old) {
            ++wrongDirection;
        }
    }

    function setConsistency(
        uint16 v
    ) external {
        _as(TIMELOCK, abi.encodeCall(STORE.setConsistencyToleranceBps, (M, uint16(bound(v, 0, 300)))));
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

    // ─── Tolerances and feed ages ───

    function tightenTolerance(
        uint16 v,
        bool steward,
        bool usdt
    ) external {
        address token = usdt ? USDT : USDC;
        uint16 old = STORE.feedAgreementToleranceBps(token);
        v = uint16(bound(v, 50, uint256(old) + 1));
        if (_as(_tightener(steward), abi.encodeCall(STORE.tightenFeedAgreementToleranceBps, (token, v))) && v >= old) {
            ++wrongDirection;
        }
    }

    function setTolerance(
        uint16 v,
        bool usdt
    ) external {
        _as(
            TIMELOCK,
            abi.encodeCall(STORE.setFeedAgreementToleranceBps, (usdt ? USDT : USDC, uint16(bound(v, 50, 400))))
        );
    }

    function setMargin(
        uint16 v
    ) external {
        _as(TIMELOCK, abi.encodeCall(STORE.setFeedAgreementMarginBps, (uint16(bound(v, 0, 300)))));
    }

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

    function setGrace(
        uint256 hf,
        uint32 duration
    ) external {
        _as(TIMELOCK, abi.encodeCall(STORE.setGraceHealthFactor, (bound(hf, 0.85e18, 1.01e18))));
        _as(TIMELOCK, abi.encodeCall(STORE.setGraceDuration, (uint32(bound(duration, 0, 8000)))));
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

    function poolShare(
        uint16 v,
        bool tighten,
        bool ofPool
    ) external {
        v = uint16(bound(v, 0, 10_100));
        if (tighten) {
            _as(
                STEWARD,
                ofPool
                    ? abi.encodeCall(STORE.tightenPoolShareMaxBpsOf, (M, v))
                    : abi.encodeCall(STORE.tightenPoolShareMaxBps, (v))
            );
        } else {
            _as(
                TIMELOCK,
                ofPool
                    ? abi.encodeCall(STORE.loosenPoolShareMaxBpsOf, (M, v))
                    : abi.encodeCall(STORE.loosenPoolShareMaxBps, (v))
            );
        }
    }

    // ─── Second source ───

    function switchToStandby() external {
        _as(GUARDIAN, abi.encodeCall(STORE.useStandbySecondSource, (USDC)));
    }

    function restoreSource() external {
        _as(TIMELOCK, abi.encodeCall(STORE.restoreSecondSource, (USDC)));
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
            abi.encodeCall(STORE.setGraceDuration, (uint32(bound(v, 0, 7200)))),
            abi.encodeCall(STORE.useStandbySecondSource, (USDC)),
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

    function standbyKind() external view returns (SecondSourceKind) {
        SecondSource memory s = STORE.standbySecondSource(USDC);
        return s.kind;
    }
}
