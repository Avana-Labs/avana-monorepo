// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {PauseState} from "../../types/PauseState.sol";
import {PriceState} from "../../types/PriceState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {PriceView} from "../../types/PriceView.sol";
import {LensBase} from "./LensBase.sol";
import {DebtPriceView} from "./types/DebtPriceView.sol";

/// @title LensPrice
/// @notice Price and pause views of the Lens: market and debt-reserve price states, and each Hub's pause state.
/// @dev Price states never make these views revert.
abstract contract LensPrice is LensBase {
    /// @dev LPOracle reason bit ALTERNATE_PAST_BORROW_AGE, which LPVaultSwap treats as Cached.
    uint256 internal constant ALTERNATE_PAST_BORROW_AGE = 1 << 12;

    function getPriceState(
        address vaultToken
    ) external view returns (PriceView memory v) {
        _unlocked();
        (, address lpOracle) = _lpOracleOf(vaultToken);
        PriceStateView memory ps = ILPOracle(lpOracle).getPriceState();
        (v.blockNumber, v.timestamp, v.vaultToken, v.feed) = (block.number, block.timestamp, vaultToken, lpOracle);
        (v.state, v.liquidationState, v.reasons) = (ps.state, _liquidationState(ps), ps.reasons);
        // forge-lint: disable-next-line(unsafe-typecast)
        v.price = ps.answer > 0 ? uint256(ps.answer) : 0;
        (v.acceptedPrice, v.acceptedAt) = ILPOracle(lpOracle).lastAcceptedPrice();
        v.inputs = _inputs(ps.tokens);
        v.tokenDeviationBps = new uint256[](ps.tokens.length);
        for (uint256 i = 0; i < ps.tokens.length; ++i) {
            v.tokenDeviationBps[i] = ps.tokens[i].deviationBps;
        }
        (v.disagreeSince, v.disagreementPauseActive, v.disagreementExpired) =
        (ps.disagreeSince, ps.disagreementPauseActive, ps.disagreementExpired);
        (v.recoveredAt, v.graceEndsAt) = (ps.recoveredAt, ps.graceEndsAt);
        v.graceHealthFactor = _store().graceHealthFactor();
        v.borrowAllowed = ps.borrowAllowed;
    }

    function getDebtPriceState(
        address spoke,
        uint256 debtReserveId
    ) external view returns (DebtPriceView memory v) {
        _unlocked();
        v = _debtView(spoke, _debtReserve(spoke, debtReserveId));
        (v.blockNumber, v.timestamp) = (block.number, block.timestamp);
    }

    function getApplicationState(
        address hub
    ) external view returns (PauseState state) {
        _unlocked();
        state = _registry().pauseState(hub);
    }

    function getPauseReason(
        address hub
    ) external view returns (uint8 reason) {
        _unlocked();
        reason = uint8(_registry().pauseReason(hub));
    }

    function _lpOracleOf(
        address vaultToken
    ) internal view returns (uint256 marketId, address lpOracle) {
        marketId = _registry().marketOfVaultToken(vaultToken);
        lpOracle = _market(marketId).lpOracle;
    }

    /// @dev The state LPVaultSwap applies when the market is seized (Expired, Cached or Drifting override the state).
    function _liquidationState(
        PriceStateView memory ps
    ) internal pure returns (PriceState s) {
        s = ps.state;
        if (ps.disagreementExpired) return PriceState.Expired;
        if (uint8(s) < uint8(PriceState.Cached) && ps.reasons & ALTERNATE_PAST_BORROW_AGE != 0) {
            return PriceState.Cached;
        }
        if (s == PriceState.Live && ps.disagreementPauseActive) s = PriceState.Drifting;
    }
}
