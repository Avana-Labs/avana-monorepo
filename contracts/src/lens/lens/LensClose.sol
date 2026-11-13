// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {SettlementMath} from "../../liquidation/lp-vault-swap/SettlementMath.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {Market} from "../../types/Market.sol";
import {LensConstants} from "./LensConstants.sol";
import {LensDeleverage} from "./LensDeleverage.sol";
import {CloseAccountView, DebtClose, RecordClose} from "./types/CloseAccountView.sol";
import {RecordRemoval} from "./types/RemovalSizing.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensClose
/// @notice `ILensSizing.previewCloseAccount`: every debt an account repays, with its repay-all spend cap, and every record
/// it withdraws to close.
/// @dev Bounded by the Spoke's enabled debt reserves and the 16 records of an account-market.
/// @custom:spec REQ-LENS-056, REQ-LENS-036
// View calls in loops over the Spoke's debt reserves and the at most 16 records of one account-market (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensClose is LensDeleverage {
    /// @notice `ILensSizing.previewCloseAccount`.
    /// @custom:spec REQ-LENS-056, REQ-LENS-036, REQ-LENS-005, REQ-LENS-006
    function previewCloseAccount(
        address wallet,
        uint256 marketId,
        uint256 deadline
    ) external view returns (CloseAccountView memory v) {
        _unlocked();
        Market memory m = _market(marketId);
        bool deployed;
        (v.proxy, deployed) = _proxy(wallet, marketId, m.spoke);
        (v.blockNumber, v.timestamp) = (block.number, block.timestamp);
        if (!deployed) return v;
        v.debts = _debtCloses(m, v.proxy, deadline);
        RecordRemoval[] memory rs = _removals(m, v.proxy);
        // forge-lint: disable-next-line(unused-return)
        (uint256[] memory prices,,) = ILPOracle(m.lpOracle).getTokenPrices();
        bool priced = true;
        for (uint256 i = 0; i < prices.length; ++i) {
            if (prices[i] == 0) priced = false;
        }
        v.records = new RecordClose[](rs.length);
        for (uint256 i = 0; i < rs.length; ++i) {
            (v.records[i].positionKey, v.records[i].units) = (rs[i].positionKey, rs[i].units);
            if (priced && rs[i].units > 0) {
                // forge-lint: disable-next-line(unused-return)
                (v.records[i].amounts,) = IAmmIntegration(m.integration).composition(marketId, rs[i].units, prices);
            } else {
                v.records[i].amounts = new uint256[](m.tokens.length);
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev One entry per debt reserve the account owes on, with the repay-all spend cap of REQ-LENS-036.
    /// @custom:spec REQ-LENS-056, REQ-LENS-036
    function _debtCloses(
        Market memory m,
        address proxy,
        uint256 deadline
    ) internal view returns (DebtClose[] memory out) {
        uint256[] memory ids = _registry().getDebtReserveIds(m.spoke);
        uint256[] memory totals = new uint256[](ids.length);
        uint256 n = 0;
        for (uint256 i = 0; i < ids.length; ++i) {
            totals[i] = IAaveV4Spoke(m.spoke).getUserTotalDebt(ids[i], proxy);
            if (totals[i] > 0) ++n;
        }
        out = new DebtClose[](n);
        if (n == 0) return out;
        uint256 premium = IAaveV4Spoke(m.spoke).getUserAccountData(proxy).riskPremium;
        uint256 bps = SettlementMath.BPS;
        n = 0;
        for (uint256 i = 0; i < ids.length; ++i) {
            if (totals[i] == 0) continue;
            DebtReserveDef memory def = _registry().getDebtReserve(m.spoke, ids[i]);
            uint256 growth = _growth(_rate(def, premium), deadline);
            out[n++] = DebtClose({
                reserveId: ids[i],
                asset: def.asset,
                total: totals[i],
                maxRepaySpend: Math.mulDiv(
                    totals[i], growth * (bps + LensConstants.REPAY_ALL_MARGIN_BPS), RAY_UNIT * bps, Math.Rounding.Ceil
                )
            });
        }
    }
}
// forge-lint: disable-end(calls-loop)
