// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStore} from "./IParameterStore.sol";
import {IParameterStoreLoosen} from "./IParameterStoreLoosen.sol";
import {IParameterStoreTighten} from "./IParameterStoreTighten.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";
import {MarketDynamicCap} from "./types/ParameterStoreTypes.sol";

/// @title ParameterStoreForwardRisk
/// @notice The tighten and loosen setters of the market, Hub, cap, feed and route parameters.
abstract contract ParameterStoreForwardRisk is ParameterStoreRouter, IParameterStore {
    /// @inheritdoc IParameterStore
    function marketDynamicCap(
        uint256 marketId
    ) external view override returns (MarketDynamicCap memory terms) {
        terms = _s().marketDynamicCap[marketId];
    }

    /// @inheritdoc IParameterStore
    function tightenMarketDynamicCap(
        uint256,
        MarketDynamicCap calldata
    ) external override restricted {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function loosenMarketDynamicCap(
        uint256,
        MarketDynamicCap calldata
    ) external override restricted {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenSlippageAllowanceBps(
        uint256,
        uint16
    ) external override restricted {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenFloorRoundingAllowance(
        address,
        uint256
    ) external override restricted {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenBorrowPriceMaxAge(
        address,
        uint32
    ) external override restricted {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenPoolRiskFactor(
        uint256,
        uint16
    ) external override restricted {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenRouteDepthThreshold(
        uint256,
        address,
        address,
        uint8,
        uint256
    ) external override restricted {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenMarketUsdCap(
        uint256,
        uint256
    ) external override restricted {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenTopUpSliceUsd(
        uint256,
        uint256
    ) external override restricted {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenTokenUsdCap(
        address,
        address,
        uint256
    ) external override restricted {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenMinPledgeUsd(
        uint256,
        uint256
    ) external override restricted {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenSlippageAllowanceBps(
        uint256,
        uint16
    ) external override restricted {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenFloorRoundingAllowance(
        address,
        uint256
    ) external override restricted {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenRouteDepthThreshold(
        uint256,
        address,
        address,
        uint8,
        uint256
    ) external override restricted {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenMarketUsdCap(
        uint256,
        uint256
    ) external override restricted {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenTopUpSliceUsd(
        uint256,
        uint256
    ) external override restricted {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenTokenUsdCap(
        address,
        address,
        uint256
    ) external override restricted {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenMinPledgeUsd(
        uint256,
        uint256
    ) external override restricted {
        _forward(_LOOSEN_LOGIC);
    }
}
