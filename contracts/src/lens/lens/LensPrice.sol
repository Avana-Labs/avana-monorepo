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
/// @notice Price and pause views of the Lens: a market's price state with served and accepted prices and every
/// input's age against both age limits, a debt reserve's price state, and each Hub's pause state and reason.
/// @dev Price states never make these views revert: the LPOracle and DebtOracle views never revert on a state, and the
/// Lens adds no check that could.
/// @custom:spec REQ-LENS-007, REQ-LENS-015, REQ-LENS-030, REQ-LENS-031, REQ-LENS-032
abstract contract LensPrice is LensBase {
    /// @dev LPOracle market reason bit 12, ALTERNATE_PAST_BORROW_AGE: a serving alternate leg older than its
    /// `borrowPriceMaxAge`, which LPVaultSwap treats as Cached.
    uint256 internal constant ALTERNATE_PAST_BORROW_AGE = 1 << 12;

    /// @notice `ILensLiquidation.getPriceState`: a market's price state report, served and accepted prices and every
    /// input against both age limits.
    /// @custom:spec REQ-LENS-015, REQ-LENS-007, REQ-LENS-005, REQ-LENS-006
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

    /// @notice `ILensLiquidation.getDebtPriceState`: a debt reserve's Aave price source, price and freshness;
    /// `UnknownDebtReserve` outside the MarketRegistry's enabled set.
    /// @custom:spec REQ-LENS-030, REQ-LENS-032, REQ-LENS-007, REQ-LENS-005, REQ-LENS-006
    function getDebtPriceState(
        address spoke,
        uint256 debtReserveId
    ) external view returns (DebtPriceView memory v) {
        _unlocked();
        v = _debtView(spoke, _debtReserve(spoke, debtReserveId));
        (v.blockNumber, v.timestamp) = (block.number, block.timestamp);
    }

    /// @notice `ILensLiquidation.getApplicationState`: a Hub's pause state held by the MarketRegistry.
    /// @custom:spec REQ-LENS-031, REQ-LENS-006
    function getApplicationState(
        address hub
    ) external view returns (PauseState state) {
        _unlocked();
        state = _registry().pauseState(hub);
    }

    /// @notice `ILensLiquidation.getPauseReason`: a Hub's pause reason as its `PauseReason` ordinal.
    /// @custom:spec REQ-LENS-031, REQ-LENS-006
    function getPauseReason(
        address hub
    ) external view returns (uint8 reason) {
        _unlocked();
        reason = uint8(_registry().pauseReason(hub));
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev The vault token's market and its LPOracle.
    function _lpOracleOf(
        address vaultToken
    ) internal view returns (uint256 marketId, address lpOracle) {
        marketId = _registry().marketOfVaultToken(vaultToken);
        lpOracle = _market(marketId).lpOracle;
    }

    /// @dev The state LPVaultSwap applies when the market is seized: Expired once a disagreement has passed
    /// `disagreementPauseMax`, Cached when a serving alternate leg is older than its `borrowPriceMaxAge`, Drifting while
    /// a disagreement pause holds a Live market, else the price state.
    /// @custom:spec REQ-LENS-015, REQ-SWAP-008, REQ-ORACLE-090
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
