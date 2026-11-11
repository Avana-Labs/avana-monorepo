// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/DriftReason.sol";
import {Market} from "../../types/Market.sol";
import {IMarketRegistryDriftLogic} from "./IMarketRegistryDriftLogic.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {SpokeDef} from "./types/SpokeDef.sol";

/// @title MarketRegistryDriftView
/// @notice The standard-Spoke settings drift view `spokeSettingsDrift` (REQ-CONFIG-076).
/// @dev Never reverts: every Aave read is a `try`, and a read that fails reports `ReserveIdentity` for its market (or
/// `SpokeImplementation` for the implementation slot), so a broken read fails closed. The implementation is the one
/// behind the Spoke proxy (its ERC-1967 slot and that code's hash), not the proxy's own code.
/// @custom:spec REQ-CONFIG-076, REQ-ADAPTER-028, REQ-ADAPTER-029, REQ-ADAPTER-030, Q-309, Q-378
// View calls in a loop over the Spoke's markets (Aave reserve reads in try blocks); a view, bounded by the markets
// timelock operations list.
// forge-lint: disable-start(calls-loop)
abstract contract MarketRegistryDriftView is MarketRegistryStorage {
    /// @dev First drift of a recorded Spoke: its implementation is not the approved one (`_spokeImplementation`), or one
    /// of its Active or Offboarding markets' reserves is on another Hub, holds another underlying or Hub asset ID than
    /// the market, has `receiveSharesEnabled`, a liquidation fee above 0 or a reinvestment controller on its Hub asset.
    /// `(0, None)` for an unknown Spoke or no drift.
    function _spokeDrift(
        address spoke
    ) internal view returns (uint256 marketId, DriftReason reason) {
        SpokeDef storage sp = _s().spokes[spoke];
        if (!sp.approved) return (0, DriftReason.None);
        (,, bool current) = _spokeImplementation(spoke);
        if (!current) return (0, DriftReason.SpokeImplementation);
        uint256[] storage ids = _s().marketsOfSpoke[spoke];
        for (uint256 i = 0; i < ids.length; ++i) {
            Market storage m = _s().markets[ids[i]];
            if (!_liquidatable(m.status)) continue;
            // The per-market reads run in the activation logic, which reads no registry storage (size limit).
            reason = IMarketRegistryDriftLogic(_driftLogic())
                .marketDrift(spoke, sp.hub, m.vaultToken, m.reserveId, m.hubAssetId);
            if (reason != DriftReason.None) return (ids[i], reason);
        }
        return (0, DriftReason.None);
    }

    /// @dev The logic contract that serves `marketDrift` (the activation logic).
    function _driftLogic() internal view virtual returns (address);
}
// forge-lint: disable-end(calls-loop)
