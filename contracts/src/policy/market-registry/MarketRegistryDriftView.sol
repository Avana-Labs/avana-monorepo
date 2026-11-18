// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/DriftReason.sol";
import {Market} from "../../types/Market.sol";
import {IMarketRegistryDriftLogic} from "./IMarketRegistryDriftLogic.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {SpokeDef} from "./types/SpokeDef.sol";

/// @title MarketRegistryDriftView
/// @notice The standard-Spoke settings drift view `spokeSettingsDrift`.
/// @dev Never reverts; a failed Aave read reports drift (fails closed).
// View calls in a loop over the Spoke's markets; bounded by the market count.
// forge-lint: disable-start(calls-loop)
abstract contract MarketRegistryDriftView is MarketRegistryStorage {
    /// @dev First drift of a recorded Spoke (implementation, then each liquidatable market); `(0, None)` if none.
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
            // Per-market reads run in the activation logic (code size limit).
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
