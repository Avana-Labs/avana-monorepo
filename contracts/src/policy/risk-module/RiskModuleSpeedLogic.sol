// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {Market} from "../../types/Market.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {DebtReserveDef} from "../market-registry/types/DebtReserveDef.sol";
import {MarketSpeedLimits} from "../parameter-store/types/MarketSpeedLimits.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {IRiskModuleSpeedLogic} from "./IRiskModuleSpeedLogic.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {SpeedLimitMath} from "./SpeedLimitMath.sol";
import {BorrowSpeedInputs} from "./types/BorrowSpeedInputs.sol";
import {RiskModuleImmutables} from "./types/RiskModuleImmutables.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RiskModuleSpeedLogic
/// @notice The reads of the speed limits (Q-411): the market window's base, the USD debt of the market's CDP Spoke at
/// the AaveOracle price of each of its debt reserves; the debt window's base, the asset every CDP Spoke the
/// MarketRegistry records owes the funding Hub; the borrow's USD charge; the parameters from the ParameterStore; and the
/// pledge window's base, the market's booked value from Collateralization's counters.
/// @dev Stateless and view-only: it writes nothing and makes only static calls. Its loops run over the MarketRegistry's
/// Spokes and a Spoke's debt reserves, both bounded by timelock listings. The RiskModule proxy holds and writes the
/// windows (REQ-RISK-095).
/// @custom:spec REQ-RISK-092, REQ-RISK-093, REQ-RISK-097, SPEC-CAP-012, SPEC-CAP-013, Q-411
// View calls in loops over the registry's Spokes and a Spoke's debt reserves, bounded by listings.
// forge-lint: disable-start(calls-loop)
contract RiskModuleSpeedLogic is RiskModuleBase, IRiskModuleSpeedLogic {
    /// @notice Fixes the implementation immutables.
    /// @param im The per-chain Avana addresses, equal to the RiskModule's.
    /// @custom:spec REQ-RISK-002
    constructor(
        RiskModuleImmutables memory im
    ) RiskModuleBase(im) {}

    /// @inheritdoc IRiskModuleLogic
    /// @custom:spec REQ-RISK-002
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModuleSpeedLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModuleSpeedLogic
    /// @custom:spec REQ-RISK-092, SPEC-CAP-013
    function borrowInputs(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external view override returns (BorrowSpeedInputs memory inputs) {
        // The account's Spoke is the market's Spoke; the borrow logic checked it before this read.
        // forge-lint: disable-next-line(unused-return)
        (, uint256 marketId) = _account(proxy);
        inputs = _inputs(marketId, debtReserveId, amount);
    }

    /// @inheritdoc IRiskModuleSpeedLogic
    /// @custom:spec REQ-RISK-097
    function borrowInputsOf(
        uint256 marketId,
        uint256 debtReserveId
    ) external view override returns (BorrowSpeedInputs memory inputs) {
        inputs = _inputs(marketId, debtReserveId, 0);
    }

    /// @inheritdoc IRiskModuleSpeedLogic
    /// @custom:spec REQ-RISK-093, REQ-RISK-097
    function pledgeInputsOf(
        uint256 marketId
    ) external view override returns (MarketSpeedLimits memory limits, uint256 bookedUsd) {
        Market memory m = _market(marketId);
        if (m.vaultToken == address(0)) revert MarketNotActive(marketId);
        limits = _store().marketSpeedLimits(marketId);
        PledgeCounters memory c = ICollateralizationViews(_COLLATERALIZATION).getCounters(m.vaultToken, address(0));
        bookedUsd = uint256(c.regularUsed) + c.sliceUsed;
    }

    /// @dev Keys, charge, bases and parameters of reserve `r` in market `marketId` (REQ-RISK-092, SPEC-CAP-013).
    function _inputs(
        uint256 marketId,
        uint256 r,
        uint256 amount
    ) internal view returns (BorrowSpeedInputs memory inputs) {
        Market memory m = _market(marketId);
        if (m.vaultToken == address(0)) revert MarketNotActive(marketId);
        address spoke = m.spoke;
        DebtReserveDef memory def = _registry().getDebtReserve(spoke, r);
        address oracle = IAaveV4Spoke(spoke).ORACLE();
        inputs.marketId = marketId;
        inputs.hub = def.fundingHub;
        inputs.asset = def.asset;
        inputs.debtKey = keccak256(abi.encode(def.fundingHub, def.asset));
        if (amount != 0) {
            inputs.amountUsd = SpeedLimitMath.usdOf(amount, IAaveV4Oracle(oracle).getReservePrice(r), def.decimals);
        }
        inputs.marketBase = _spokeDebtUsd(spoke, oracle);
        inputs.debtBase = _owedToHub(def.fundingHub, def.hubAssetId);
        inputs.market = _store().marketSpeedLimits(marketId);
        inputs.debt = _store().debtSpeedLimit(def.fundingHub, def.asset);
    }

    /// @dev `D_m = Σ_r ⌊owed(r) × price8(r) / 10^dec(r)⌋` over the Spoke's debt reserves, each owed amount read from
    /// the reserve's funding Hub; a reserve the Spoke owes nothing on is skipped without a price read.
    function _spokeDebtUsd(
        address spoke,
        address oracle
    ) internal view returns (uint256 usd) {
        uint256[] memory ids = _registry().getDebtReserveIds(spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            DebtReserveDef memory d = _registry().getDebtReserve(spoke, ids[i]);
            uint256 owed = IAaveV4Hub(d.fundingHub).getSpokeTotalOwed(d.hubAssetId, spoke);
            if (owed == 0) continue;
            usd += Math.mulDiv(owed, IAaveV4Oracle(oracle).getReservePrice(ids[i]), 10 ** d.decimals);
        }
    }

    /// @dev `D_ha = Σ_s hub.getSpokeTotalOwed(assetId, s)` over the MarketRegistry's Spokes listed on the Hub asset.
    function _owedToHub(
        address hub,
        uint256 assetId
    ) internal view returns (uint256 owed) {
        address[] memory spokes = _registry().getSpokes();
        for (uint256 i = 0; i < spokes.length; ++i) {
            if (!IAaveV4Hub(hub).isSpokeListed(assetId, spokes[i])) continue;
            owed += IAaveV4Hub(hub).getSpokeTotalOwed(assetId, spokes[i]);
        }
    }
}
// forge-lint: disable-end(calls-loop)
