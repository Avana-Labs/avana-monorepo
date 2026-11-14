// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaFirstLossReserve} from "../../coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {ILock} from "../../lock/lock/ILock.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {IAaveAdapter} from "../../policy/aave-adapter/IAaveAdapter.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {IParameterStore} from "../../policy/parameter-store/IParameterStore.sol";
import {Market} from "../../types/Market.sol";
import {ILPVaultSwapLogic} from "./ILPVaultSwapLogic.sol";
import {LPVaultSwapSettlement} from "./LPVaultSwapSettlement.sol";
import {LPVaultSwapStorage} from "./LPVaultSwapStorage.sol";
import {SettlementMath} from "./SettlementMath.sol";
import {LPVaultSwapImmutables} from "./types/LPVaultSwapImmutables.sol";
import {RouteMode} from "./types/RouteMode.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// PendingSettlementForwarded reports amounts known only after the release, the routes and the funding; the body runs
// under the Lock (REQ-SWAP-002).
// forge-lint: disable-start(reentrancy-events)
/// @title LPVaultSwapPendingLogic
/// @notice Body of `settlePending`, run by delegatecall from the LPVaultSwap implementation in the proxy's storage:
/// burns vault tokens an earlier implementation seized and never settled against Collateralization's pending balance,
/// swaps the released tokens into the market's settlement asset at the pending floor and adds the proceeds to the
/// First-Loss Reserve of the settlement reserve's (funding Hub, asset), carrying an amount worth less than one Hub share.
/// @dev The caller supplies nothing and receives nothing. Before the Lock: `UnknownMarket`, `InvalidFeeRecipient`,
/// `LockHeld(holder)`, then the view reads of the pending units and LPVaultSwap's vault-token balance (`NothingPending`)
/// and the settlement reserve (`UnknownDebtReserve`). Under the Lock: price rules (no grace), burn and release, legs at
/// `s_P`, `minPending`, funding or carry, residues to `feeRecipient`.
/// @custom:spec REQ-SWAP-066, REQ-SWAP-068, REQ-SWAP-070, REQ-SWAP-071, REQ-SWAP-092, SPEC-LIQ-014, Q-201, Q-211, Q-338
// Each function carries the body of a selector LPVaultSwap declares and delegates here; this contract inherits no
// LPVaultSwap interface piece, since each piece also declares functions another logic contract serves.
// solhint-disable comprehensive-interface
contract LPVaultSwapPendingLogic is LPVaultSwapSettlement, ILPVaultSwapLogic {
    using SafeERC20 for IERC20;

    /// @dev Working values of one pending settlement.
    struct Pend {
        Market m;
        DebtReserveDef d;
        address coverage;
        address feeRecipient;
        uint256 units;
        uint256 minPending;
        uint256 recovered;
        uint256 funded;
        uint256 carried;
        uint256[] amounts;
        uint8[] routeUsed;
        Tracked t;
    }

    /// @notice Fixes the implementation immutables; they must equal the implementation's.
    /// @param im The per-chain addresses and the keeper floor.
    /// @custom:spec REQ-SWAP-040
    constructor(
        LPVaultSwapImmutables memory im
    ) LPVaultSwapStorage(im) {}

    /// @inheritdoc ILPVaultSwapLogic
    /// @custom:spec REQ-SWAP-040
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("LPVaultSwapPendingLogic"), _IMMUTABLES_HASH);
    }

    /// @notice Body of `settlePending`.
    /// @dev See `ILPVaultSwapLiquidation.settlePending`; the implementation forwards its calldata unchanged.
    /// @custom:spec REQ-SWAP-002, REQ-SWAP-003, REQ-SWAP-066, REQ-SWAP-068, REQ-LOCK-007
    function settlePending(
        uint256 marketId,
        uint256 debtReserveId
    ) external returns (uint256 units, uint256[] memory amounts, uint256 added) {
        _onlyDelegated();
        Pend memory c = _preLock(marketId, debtReserveId);
        ILock(_LOCK).acquire();
        _checkCollateralPrice(c.m.lpOracle);
        _checkDebtPrice(c.d, debtReserveId);
        _releaseAndSwap(c, marketId, debtReserveId);
        if (c.recovered < c.minPending) revert RecoveryBelowFloor();
        _fundCoverage(c);
        uint256[] memory residues = _residues(c.t);
        for (uint256 i = 0; i < c.t.count; ++i) {
            _deliver(c.t.tokens[i], c.feeRecipient, residues[i]);
        }
        emit PendingSettlementForwarded(
            msg.sender,
            marketId,
            c.m.vaultToken,
            c.units,
            c.amounts,
            c.d.asset,
            c.recovered,
            c.minPending,
            c.coverage,
            c.routeUsed,
            c.funded,
            c.carried
        );
        ILock(_LOCK).release();
        (units, amounts, added) = (c.units, c.amounts, c.recovered);
    }

    /// @dev The checks before the Lock and the view reads they need (REQ-SWAP-066, REQ-LOCK-007).
    /// @custom:spec REQ-SWAP-066, REQ-SWAP-068, REQ-MREG-033
    function _preLock(
        uint256 marketId,
        uint256 debtReserveId
    ) private view returns (Pend memory c) {
        c.m = _loadMarket(marketId);
        c.feeRecipient = IParameterStore(_PARAMETER_STORE).feeRecipient();
        if (c.feeRecipient == address(0)) revert InvalidFeeRecipient();
        address holder = ILock(_LOCK).holder();
        if (holder != address(0)) revert LockHeld(holder);
        uint256 pending = ICollateralization(_COLLATERALIZATION).getPending(c.m.vaultToken).units;
        uint256 held = IERC20(c.m.vaultToken).balanceOf(address(this));
        c.units = held < pending ? held : pending;
        if (c.units == 0) revert NothingPending();
        IMarketRegistry mr = IMarketRegistry(_MARKET_REGISTRY);
        if (debtReserveId != mr.settlementReserve(marketId)) revert UnknownDebtReserve(debtReserveId);
        c.d = mr.getDebtReserve(c.m.spoke, debtReserveId);
        c.coverage = mr.firstLossReserveOf(c.d.fundingHub, c.d.asset);
    }

    /// @dev Burn and release measured as deltas, the pending floor and the legs at `s_P`, then `R` in the settlement
    /// asset over the burn, the release and the route calls.
    /// @custom:spec REQ-SWAP-044, REQ-SWAP-045, REQ-SWAP-092, REQ-SWAP-121, SPEC-LIQ-014, SPEC-LIQ-018
    function _releaseAndSwap(
        Pend memory c,
        uint256 marketId,
        uint256 debtReserveId
    ) private {
        IERC20 asset = IERC20(c.d.asset);
        uint256 n = c.m.tokens.length;
        c.t = _snapshot(c.m.tokens, c.d.asset);
        uint256 r0 = asset.balanceOf(address(this));
        IAaveAdapter(_AAVE_ADAPTER).burnSeized(marketId, c.m.vaultToken, c.units);
        // The released amounts are measured as LPVaultSwap balance changes (REQ-SWAP-108), never read from returns.
        // forge-lint: disable-next-line(unused-return)
        ICollateralization(_COLLATERALIZATION).settlePending(c.m.vaultToken, c.units);
        c.amounts = _released(c.t, n);
        LegArgs memory l = _legArgs(c, marketId, debtReserveId);
        uint256 valueP = 0;
        for (uint256 i = 0; i < n; ++i) {
            valueP += SettlementMath.pendingLegValue(
                c.amounts[i], l.prices[i], l.decimals[i], l.assetDecimals, l.assetPrice
            );
        }
        c.minPending = SettlementMath.recoveryFloor(valueP, l.sLeg, _unitSum(l), l.allowance);
        c.routeUsed = _swapLegs(l, c.t);
        uint256 r1 = asset.balanceOf(address(this));
        c.recovered = r1 > r0 ? r1 - r0 : 0;
    }

    /// @dev Leg inputs of `settlePending`: `sLeg = s_P = min(slippageAllowanceBps, 30)`, `PrimaryThenBackup`.
    function _legArgs(
        Pend memory c,
        uint256 marketId,
        uint256 debtReserveId
    ) private view returns (LegArgs memory l) {
        IParameterStore ps = IParameterStore(_PARAMETER_STORE);
        // Only the leg prices are used; the decimals come from the market record.
        // forge-lint: disable-next-line(unused-return)
        (uint256[] memory prices,,) = ILPOracle(c.m.lpOracle).getTokenPrices();
        l = LegArgs({
            marketId: marketId,
            asset: c.d.asset,
            assetDecimals: c.d.decimals,
            assetPrice: _debtPrice(c.m.spoke, debtReserveId, c.d),
            sLeg: SettlementMath.pendingSlippage(ps.getMarketParams(marketId).slippageAllowanceBps),
            allowance: ps.floorRoundingAllowance(c.d.asset),
            mode: RouteMode.PrimaryThenBackup,
            tokens: c.m.tokens,
            decimals: c.m.tokenDecimals,
            prices: prices,
            amounts: c.amounts
        });
    }

    /// @dev Funds `Rt = R + carry` into the First-Loss Reserve when it is worth at least one Hub share, with an exact
    /// approval reset to 0 and the balance falling by exactly `Rt` (`FundingMismatch`); otherwise carries `Rt`.
    /// A `fund` that reverts (no First-Loss Reserve recorded, or a finite Hub add cap that is full) reverts the whole
    /// settlement on purpose (LIQ-I3): the units stay pending and any caller retries once governance acts, while
    /// carrying a larger `Rt` would leave LPVaultSwap holding more than one Hub share (`REQ-SWAP-070`). Neither case
    /// arises from Avana's own configuration (the First-Loss Reserve is write-once and required before a debt reserve is
    /// enabled; its add cap is unlimited, `REQ-FLR-007`), and liquidation never calls this path.
    /// @custom:spec REQ-SWAP-070, REQ-SWAP-077, REQ-FLR-038
    function _fundCoverage(
        Pend memory c
    ) private {
        Layout storage l = _s();
        address asset = c.d.asset;
        uint256 total = c.recovered + l.carry[asset];
        if (total != 0 && IAaveV4Hub(c.d.fundingHub).previewAddByAssets(c.d.hubAssetId, total) != 0) {
            l.carry[asset] = 0;
            uint256 before = IERC20(asset).balanceOf(address(this));
            IERC20(asset).forceApprove(c.coverage, total);
            // The First-Loss Reserve pulls exactly the amount; the pull is checked as LPVaultSwap balance fall right after.
            // forge-lint: disable-next-line(unused-return)
            IAvanaFirstLossReserve(c.coverage).fund(total);
            IERC20(asset).forceApprove(c.coverage, 0);
            uint256 afterFunding = IERC20(asset).balanceOf(address(this));
            if (afterFunding > before || before - afterFunding != total) revert FundingMismatch();
            c.funded = total;
        } else {
            l.carry[asset] = total;
            c.carried = total;
        }
    }
}
// forge-lint: disable-end(reentrancy-events)
