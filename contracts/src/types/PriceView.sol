// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceInput} from "../lens/lens/types/PriceInput.sol";
import {PriceState} from "./PriceState.sol";

/// @notice Price state report of one market.
/// @dev `price` is the served `latestAnswer()` (USD per whole vault token, 8 decimals) in every state: the accepted
/// price while Live, Drifting or Cached, the LP price from the lower route answers during a disagreement, 1 while
/// Expired; `acceptedPrice` and `acceptedAt` are `lastAcceptedPrice()`, used by the Lens for caps, minimum pledge and
/// re-credit; `reasons` is the LPOracle market reason bitmap; `tokenDeviationBps[i]` is the primary-versus-alternate
/// deviation of token i in pool order; `disagreeSince`, `disagreementPauseActive` and `disagreementExpired` describe a
/// feed disagreement; `liquidationState` is the state LPVaultSwap applies (a disagreement past `disagreementPauseMax`
/// reads as Expired); the grace latch is `recoveredAt`, `graceEndsAt = recoveredAt + graceDuration` and
/// `graceHealthFactor` (WAD); `borrowAllowed` reports the sequencer and second-source gates.
/// @custom:spec REQ-LENS-015, Q-247, Q-370, Q-323
struct PriceView {
    uint256 blockNumber;
    uint256 timestamp;
    address vaultToken;
    address feed;
    PriceState state;
    PriceState liquidationState;
    uint256 reasons;
    uint256 price;
    uint256 acceptedPrice;
    uint256 acceptedAt;
    PriceInput[] inputs;
    uint256[] tokenDeviationBps;
    uint256 disagreeSince;
    bool disagreementPauseActive;
    bool disagreementExpired;
    uint256 recoveredAt;
    uint256 graceEndsAt;
    uint256 graceHealthFactor;
    bool borrowAllowed;
}
