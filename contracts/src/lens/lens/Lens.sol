// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedView} from "../../policy/risk-module/types/SpeedView.sol";
import {CapView} from "../../types/CapView.sol";
import {PauseState} from "../../types/PauseState.sol";
import {PendingView} from "../../types/PendingView.sol";
import {PriceView} from "../../types/PriceView.sol";
import {ILens} from "./ILens.sol";
import {ILensAccount} from "./ILensAccount.sol";
import {ILensActions} from "./ILensActions.sol";
import {ILensFees} from "./ILensFees.sol";
import {ILensHubAssets} from "./ILensHubAssets.sol";
import {ILensLiquidation} from "./ILensLiquidation.sol";
import {ILensMarket} from "./ILensMarket.sol";
import {ILensMarkets} from "./ILensMarkets.sol";
import {ILensPositions} from "./ILensPositions.sol";
import {ILensPreview} from "./ILensPreview.sol";
import {ILensRisk} from "./ILensRisk.sol";
import {ILensSizing} from "./ILensSizing.sol";
import {ILensSpeed} from "./ILensSpeed.sol";
import {LensBase} from "./LensBase.sol";
import {LensConstants} from "./LensConstants.sol";
import {AccountRiskView} from "./types/AccountRiskView.sol";
import {AccountView} from "./types/AccountView.sol";
import {ActionPreview} from "./types/ActionPreview.sol";
import {BackingView} from "./types/BackingView.sol";
import {BorrowSpeedView} from "./types/BorrowSpeedView.sol";
import {CloseAccountView} from "./types/CloseAccountView.sol";
import {DebtPriceView} from "./types/DebtPriceView.sol";
import {DebtReserveView} from "./types/DebtReserveView.sol";
import {DeleverageSizing} from "./types/DeleverageSizing.sol";
import {HubAssetExposureView} from "./types/HubAssetExposureView.sol";
import {HubAssetView} from "./types/HubAssetView.sol";
import {LiquidationPreview} from "./types/LiquidationPreview.sol";
import {MarketView} from "./types/MarketView.sol";
import {PledgePreviewView} from "./types/PledgePreviewView.sol";
import {PositionFeesView} from "./types/PositionFeesView.sol";
import {RecordBackingView} from "./types/RecordBackingView.sol";
import {RecordView} from "./types/RecordView.sol";
import {RemovalSizing} from "./types/RemovalSizing.sol";
import {TailCoverageView} from "./types/TailCoverageView.sol";
import {WithdrawPreview} from "./types/WithdrawPreview.sol";

/// @title Lens
/// @notice The chain's read-only periphery view contract: account, market, price, risk and liquidation state gathered
/// in one call, and previews sized to stay valid until a transaction's deadline. No Avana contract calls it or relies
/// on what it returns.
/// @dev The single address consumers call. Each view is forwarded by STATICCALL, with the caller's calldata
/// unchanged, to one of nine immutable modules (each serving one or more interface pieces or parts of them), and the module's return data or revert data is returned unchanged;
/// the split keeps each deployed contract within EIP-170. Immutable: no proxy, no storage beyond the module and core
/// addresses fixed in the constructor, no owner, no role, no event, no state-changing function, and every external
/// function is `view`. The modules check the Lock, so every view reverts with `Locked()` while an Avana call holds
/// it. A new Lens is a new deployment of the nine modules and this entry point, recorded in the manifest.
/// @custom:spec REQ-LENS-001, REQ-LENS-002, REQ-LENS-003, REQ-LENS-004, REQ-LENS-005, REQ-LENS-006, REQ-LENS-007, REQ-LENS-020, REQ-LENS-025, REQ-LENS-040, REQ-LENS-050, REQ-LENS-051, REQ-LENS-052, REQ-LENS-053, REQ-LENS-054, REQ-LENS-055, REQ-LENS-056, REQ-LENS-057, REQ-LENS-058, REQ-LENS-059, REQ-LENS-061, Q-119, Q-226, Q-319
// View calls in loops over listings bounded by governance (Spokes, debt reserves, markets, pool tokens), one
// page of at most LENS_MAX_PAGE records or the caller's own arrays (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
contract Lens is ILens {
    /// @dev `LensAccountModule`: `ILensAccount`.
    address private immutable _ACCOUNT_MODULE;
    /// @dev `LensMarketModule`: `ILensMarket`.
    address private immutable _MARKET_MODULE;
    /// @dev `LensPriceModule`: the price and pause views of `ILensLiquidation`.
    address private immutable _PRICE_MODULE;
    /// @dev `LensLiquidationModule`: `ILensLiquidation.previewLiquidation`.
    address private immutable _LIQUIDATION_MODULE;
    /// @dev `LensRiskModule`: `ILensRisk`.
    address private immutable _RISK_MODULE_LENS;
    /// @dev `LensPreviewModule`: `ILensPreview`.
    address private immutable _PREVIEW_MODULE;
    /// @dev `LensMarketsModule`: `ILensMarkets`.
    address private immutable _MARKETS_MODULE;
    /// @dev `LensPositionsModule`: `ILensPositions`.
    address private immutable _POSITIONS_MODULE;
    /// @dev `LensSpeedModule`: `ILensSpeed`.
    address private immutable _SPEED_MODULE;
    /// @dev Core addresses, equal in the nine modules.
    address private immutable _COLLATERALIZATION;
    address private immutable _PROXY_MANAGER;
    address private immutable _ADAPTER;
    address private immutable _LOCK;
    address private immutable _MARKET_REGISTRY;
    address private immutable _PARAMETER_STORE;
    address private immutable _RISK_MODULE;
    address private immutable _LP_VAULT_SWAP;
    address private immutable _PAYOUT_ESCROW;

    /// @notice Fixes the nine modules; their core addresses must agree.
    /// @param modules `LensAccountModule`, `LensMarketModule`, `LensPriceModule`, `LensLiquidationModule`,
    /// `LensRiskModule`, `LensPreviewModule`, `LensMarketsModule`, `LensPositionsModule`, `LensSpeedModule`, in that
    /// order.
    /// @custom:spec REQ-LENS-001, REQ-LENS-002, REQ-LENS-040
    constructor(
        address[9] memory modules
    ) {
        bytes32 core = _core(modules[0]);
        bool same = true;
        for (uint256 i = 1; i < 9; ++i) {
            if (_core(modules[i]) != core) same = false;
        }
        if (!same) revert InvalidModules();
        (_ACCOUNT_MODULE, _MARKET_MODULE, _PRICE_MODULE) = (modules[0], modules[1], modules[2]);
        (_LIQUIDATION_MODULE, _RISK_MODULE_LENS, _PREVIEW_MODULE) = (modules[3], modules[4], modules[5]);
        (_MARKETS_MODULE, _POSITIONS_MODULE, _SPEED_MODULE) = (modules[6], modules[7], modules[8]);
        LensBase m = LensBase(modules[0]);
        (_COLLATERALIZATION, _PROXY_MANAGER, _ADAPTER) = (m.COLLATERALIZATION(), m.PROXY_MANAGER(), m.ADAPTER());
        (_LOCK, _MARKET_REGISTRY, _PARAMETER_STORE) = (m.LOCK(), m.MARKET_REGISTRY(), m.PARAMETER_STORE());
        (_RISK_MODULE, _LP_VAULT_SWAP, _PAYOUT_ESCROW) = (m.RISK_MODULE(), m.LP_VAULT_SWAP(), m.PAYOUT_ESCROW());
    }

    // ---------------------------------------------------------------------------------------------- ILensAccount

    /// @inheritdoc ILensAccount
    /// @custom:spec REQ-LENS-008
    function predictProxy(
        address,
        uint256
    ) external view override returns (address proxy, bool deployed) {
        (proxy, deployed);
        _forward(_ACCOUNT_MODULE);
    }

    /// @inheritdoc ILensAccount
    /// @custom:spec REQ-LENS-009, REQ-LENS-010
    function getAccount(
        address,
        uint256
    ) external view override returns (AccountView memory account) {
        account;
        _forward(_ACCOUNT_MODULE);
    }

    /// @inheritdoc ILensAccount
    /// @custom:spec REQ-LENS-040
    function getAccounts(
        address,
        uint256[] calldata
    ) external view override returns (AccountView[] memory accounts) {
        accounts;
        _forward(_ACCOUNT_MODULE);
    }

    /// @inheritdoc ILensAccount
    /// @custom:spec REQ-LENS-011, REQ-LENS-023, REQ-LENS-024
    function getRecords(
        address,
        uint256,
        uint256
    ) external view override returns (RecordView[] memory records) {
        records;
        _forward(_ACCOUNT_MODULE);
    }

    /// @inheritdoc ILensAccount
    /// @custom:spec REQ-LENS-027
    function getEscrowClaimable(
        address,
        address[] calldata
    ) external view override returns (uint256[] memory amounts) {
        amounts;
        _forward(_ACCOUNT_MODULE);
    }

    // ----------------------------------------------------------------------------------------------- ILensMarket

    /// @inheritdoc ILensMarket
    /// @custom:spec REQ-LENS-012, REQ-LENS-013
    function checkBacking(
        address
    ) external view override returns (BackingView memory backing) {
        backing;
        _forward(_MARKET_MODULE);
    }

    /// @inheritdoc ILensMarket
    /// @custom:spec REQ-LENS-014, REQ-LENS-023, REQ-LENS-024
    function checkRecordBacking(
        address,
        uint256,
        uint256
    ) external view override returns (RecordBackingView[] memory records) {
        records;
        _forward(_MARKET_MODULE);
    }

    /// @inheritdoc ILensMarket
    /// @custom:spec REQ-LENS-026
    function getPendingSettlement(
        address
    ) external view override returns (PendingView memory pending) {
        pending;
        _forward(_MARKET_MODULE);
    }

    /// @inheritdoc ILensMarket
    /// @custom:spec REQ-LENS-018, REQ-LENS-019
    function getCapHeadroom(
        address,
        address
    ) external view override returns (CapView memory caps) {
        caps;
        _forward(_MARKET_MODULE);
    }

    // ------------------------------------------------------------------------------------------ ILensLiquidation

    /// @inheritdoc ILensLiquidation
    /// @custom:spec REQ-LENS-015
    function getPriceState(
        address
    ) external view override returns (PriceView memory priceView) {
        priceView;
        _forward(_PRICE_MODULE);
    }

    /// @inheritdoc ILensLiquidation
    /// @custom:spec REQ-LENS-030, REQ-LENS-032
    function getDebtPriceState(
        address,
        uint256
    ) external view override returns (DebtPriceView memory priceView) {
        priceView;
        _forward(_PRICE_MODULE);
    }

    /// @inheritdoc ILensLiquidation
    /// @custom:spec REQ-LENS-031
    function getApplicationState(
        address
    ) external view override returns (PauseState state) {
        state;
        _forward(_PRICE_MODULE);
    }

    /// @inheritdoc ILensLiquidation
    /// @custom:spec REQ-LENS-031
    function getPauseReason(
        address
    ) external view override returns (uint8 reason) {
        reason;
        _forward(_PRICE_MODULE);
    }

    /// @inheritdoc ILensLiquidation
    /// @custom:spec REQ-LENS-016, REQ-LENS-017, REQ-LENS-028, REQ-LENS-029, REQ-LENS-032, REQ-LENS-033
    function previewLiquidation(
        address,
        uint256,
        uint256
    ) external view override returns (LiquidationPreview memory preview) {
        preview;
        _forward(_LIQUIDATION_MODULE);
    }

    // ------------------------------------------------------------------------------------------------- ILensRisk

    /// @inheritdoc ILensRisk
    /// @custom:spec REQ-LENS-037
    function getBreakerStatus(
        uint256
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        (reasons, reopensAt);
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensRisk
    /// @custom:spec REQ-LENS-037
    function getDebtBreakerStatus(
        address,
        uint256
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        (reasons, reopensAt);
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensRisk
    /// @custom:spec REQ-LENS-037
    function isFrozenAddress(
        address
    ) external view override returns (bool frozen) {
        frozen;
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensRisk
    /// @custom:spec REQ-LENS-034, REQ-LENS-039
    function getTailCoverage(
        address,
        address
    ) external view override returns (TailCoverageView memory coverage) {
        coverage;
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensRisk
    /// @custom:spec REQ-LENS-042
    function uncoveredDeficit(
        address,
        address
    ) external view override returns (uint256 uncovered) {
        uncovered;
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensRisk
    /// @custom:spec REQ-LENS-043
    function getHubAssetExposure(
        address,
        address
    ) external view override returns (HubAssetExposureView memory view_) {
        view_;
        _forward(_RISK_MODULE_LENS);
    }

    // ---------------------------------------------------------------------------------------------- ILensPreview

    /// @inheritdoc ILensPreview
    /// @custom:spec REQ-LENS-035, REQ-LENS-041
    function previewBorrowMax(
        address,
        uint256,
        uint256,
        uint256
    ) external view override returns (uint256 amount) {
        amount;
        _forward(_PREVIEW_MODULE);
    }

    /// @inheritdoc ILensPreview
    /// @custom:spec REQ-LENS-044
    function previewBorrowRecommended(
        address,
        uint256,
        uint256,
        uint256
    ) external view override returns (uint256 recommended, uint256 maximum) {
        (recommended, maximum);
        _forward(_PREVIEW_MODULE);
    }

    /// @inheritdoc ILensPreview
    /// @custom:spec REQ-LENS-036
    function quoteRepayAll(
        address,
        uint256,
        uint256,
        uint256
    ) external view override returns (uint256 maxRepaySpend) {
        maxRepaySpend;
        _forward(_PREVIEW_MODULE);
    }

    /// @inheritdoc ILensPreview
    /// @custom:spec REQ-LENS-038
    function previewRecredit(
        uint256,
        bytes32
    ) external view override returns (uint128 added, uint256 usdCharge, bool rescueOnly) {
        (added, usdCharge, rescueOnly);
        _forward(_PREVIEW_MODULE);
    }

    /// @inheritdoc ILensPreview
    /// @custom:spec REQ-LENS-038
    function previewRepayWithCollateral(
        address,
        uint256,
        bytes32,
        uint128,
        uint256
    ) external view override returns (uint256 debtRepaid, uint256 debtAssetToWallet, uint256 healthFactorAfter) {
        (debtRepaid, debtAssetToWallet, healthFactorAfter);
        _forward(_PREVIEW_MODULE);
    }

    // ---------------------------------------------------------------------------------------------- ILensMarkets

    /// @inheritdoc ILensMarkets
    /// @custom:spec REQ-LENS-045
    function getMarkets(
        uint256,
        uint256
    ) external view override returns (MarketView[] memory markets) {
        markets;
        _forward(_MARKETS_MODULE);
    }

    /// @inheritdoc ILensMarkets
    /// @custom:spec REQ-LENS-045
    function getMarket(
        uint256
    ) external view override returns (MarketView memory market) {
        market;
        _forward(_MARKETS_MODULE);
    }

    /// @inheritdoc ILensMarkets
    /// @custom:spec REQ-LENS-046
    function getDebtReserve(
        address,
        uint256
    ) external view override returns (DebtReserveView memory reserve) {
        reserve;
        _forward(_MARKETS_MODULE);
    }

    /// @inheritdoc ILensMarkets
    /// @custom:spec REQ-LENS-046
    function getDebtReserves(
        address
    ) external view override returns (DebtReserveView[] memory reserves) {
        reserves;
        _forward(_MARKETS_MODULE);
    }

    // -------------------------------------------------------------------------------------------- ILensPositions

    /// @inheritdoc ILensPositions
    /// @custom:spec REQ-LENS-047
    function getAccountRisk(
        address,
        uint256
    ) external view override returns (AccountRiskView memory risk) {
        risk;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensPositions
    /// @custom:spec REQ-LENS-048
    function previewPledge(
        address,
        uint256,
        bytes32
    ) external view override returns (PledgePreviewView memory pledge) {
        pledge;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensPositions
    /// @custom:spec REQ-LENS-049
    function previewWithdraw(
        address,
        uint256,
        bytes32,
        uint256
    ) external view override returns (WithdrawPreview memory withdrawal) {
        withdrawal;
        _forward(_POSITIONS_MODULE);
    }

    // ------------------------------------------------------------------------------------------------- ILensFees

    /// @inheritdoc ILensFees
    /// @custom:spec REQ-LENS-050
    function getPositionFees(
        uint256,
        bytes32
    ) external view override returns (PositionFeesView memory fees) {
        fees;
        _forward(_MARKETS_MODULE);
    }

    /// @inheritdoc ILensFees
    /// @custom:spec REQ-LENS-051
    function getAccountFees(
        address,
        uint256
    ) external view override returns (PositionFeesView[] memory fees) {
        fees;
        _forward(_MARKETS_MODULE);
    }

    // ---------------------------------------------------------------------------------------------- ILensActions

    /// @inheritdoc ILensActions
    /// @custom:spec REQ-LENS-052
    function previewBorrowAfter(
        address,
        uint256,
        uint256,
        uint256
    ) external view override returns (ActionPreview memory preview) {
        preview;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensActions
    /// @custom:spec REQ-LENS-052
    function previewRepayAfter(
        address,
        uint256,
        uint256,
        uint256
    ) external view override returns (ActionPreview memory preview) {
        preview;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensActions
    /// @custom:spec REQ-LENS-053
    function previewPledgeAfter(
        address,
        uint256,
        bytes32
    ) external view override returns (ActionPreview memory preview) {
        preview;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensActions
    /// @custom:spec REQ-LENS-053
    function previewWithdrawAfter(
        address,
        uint256,
        bytes32
    ) external view override returns (ActionPreview memory preview) {
        preview;
        _forward(_POSITIONS_MODULE);
    }

    // ----------------------------------------------------------------------------------------------- ILensSizing

    /// @inheritdoc ILensSizing
    /// @custom:spec REQ-LENS-054
    function previewMaxWithdraw(
        address,
        uint256,
        uint256
    ) external view override returns (RemovalSizing memory sizing) {
        sizing;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensSizing
    /// @custom:spec REQ-LENS-055
    function previewDeleverageTo(
        address,
        uint256,
        bytes32,
        uint256,
        uint256
    ) external view override returns (DeleverageSizing memory sizing) {
        sizing;
        _forward(_PRICE_MODULE);
    }

    /// @inheritdoc ILensSizing
    /// @custom:spec REQ-LENS-056
    function previewCloseAccount(
        address,
        uint256,
        uint256
    ) external view override returns (CloseAccountView memory close) {
        close;
        _forward(_ACCOUNT_MODULE);
    }

    // -------------------------------------------------------------------------------------------- ILensHubAssets

    /// @inheritdoc ILensHubAssets
    /// @custom:spec REQ-LENS-058, REQ-LENS-059
    function getHubAsset(
        address,
        uint256
    ) external view override returns (HubAssetView memory asset) {
        asset;
        _forward(_RISK_MODULE_LENS);
    }

    // ------------------------------------------------------------------------------------------------------ ILensSpeed

    /// @inheritdoc ILensSpeed
    /// @custom:spec REQ-LENS-061
    function getBorrowSpeed(
        uint256,
        uint256
    ) external view override returns (BorrowSpeedView memory speed) {
        speed;
        _forward(_SPEED_MODULE);
    }

    /// @inheritdoc ILensSpeed
    /// @custom:spec REQ-LENS-061
    function getPledgeSpeed(
        uint256
    ) external view override returns (SpeedView memory pledge) {
        pledge;
        _forward(_SPEED_MODULE);
    }

    // ------------------------------------------------------------------------------------------------------ ILens

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-001, REQ-LENS-002
    function MODULES() external view override returns (address[9] memory modules) {
        modules = [
            _ACCOUNT_MODULE,
            _MARKET_MODULE,
            _PRICE_MODULE,
            _LIQUIDATION_MODULE,
            _RISK_MODULE_LENS,
            _PREVIEW_MODULE,
            _MARKETS_MODULE,
            _POSITIONS_MODULE,
            _SPEED_MODULE
        ];
    }

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-020
    function LENS_MAX_PAGE() external pure override returns (uint256 maxPage) {
        maxPage = LensConstants.LENS_MAX_PAGE;
    }

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-028
    function LENS_DUST_MARGIN_BPS() external pure override returns (uint256 marginBps) {
        marginBps = LensConstants.LENS_DUST_MARGIN_BPS;
    }

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-001
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-001
    function PROXY_MANAGER() external view override returns (address proxyManager) {
        proxyManager = _PROXY_MANAGER;
    }

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-001
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-001
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-001
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-001
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-001
    function RISK_MODULE() external view override returns (address riskModule) {
        riskModule = _RISK_MODULE;
    }

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-001
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc ILens
    /// @custom:spec REQ-LENS-001
    function PAYOUT_ESCROW() external view override returns (address payoutEscrow) {
        payoutEscrow = _PAYOUT_ESCROW;
    }

    // ---------------------------------------------------------------------------------------------------- private

    /// @dev Hash of a module's nine core addresses.
    function _core(
        address module
    ) private view returns (bytes32) {
        LensBase m = LensBase(module);
        return keccak256(
            abi.encode(
                m.COLLATERALIZATION(),
                m.PROXY_MANAGER(),
                m.ADAPTER(),
                m.LOCK(),
                m.MARKET_REGISTRY(),
                m.PARAMETER_STORE(),
                m.RISK_MODULE(),
                m.LP_VAULT_SWAP(),
                m.PAYOUT_ESCROW()
            )
        );
    }

    /// @dev STATICCALLs `module` with this call's calldata and ends the call with the module's return data, or reverts
    /// with its revert data. The module is one of the nine immutables, never caller input.
    /// @custom:spec REQ-LENS-001, REQ-LENS-007
    function _forward(
        address module
    ) private view {
        // Raw forwarding keeps the module's ABI encoding byte for byte and its revert data unchanged.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := staticcall(gas(), module, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            if iszero(ok) { revert(ptr, returndatasize()) }
            return(ptr, returndatasize())
        }
    }
}
// forge-lint: disable-end(calls-loop)
