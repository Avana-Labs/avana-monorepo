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
/// @notice Read-only periphery view entry point for one chain. No Avana contract calls it.
/// @dev Forwards each view by STATICCALL to one of nine immutable modules. Immutable, no owner.
// Loops are bounded by governance listings, one page of at most LENS_MAX_PAGE records, or the caller's arrays.
// forge-lint: disable-start(calls-loop)
contract Lens is ILens {
    address private immutable _ACCOUNT_MODULE;
    address private immutable _MARKET_MODULE;
    address private immutable _PRICE_MODULE;
    address private immutable _LIQUIDATION_MODULE;
    address private immutable _RISK_MODULE_LENS;
    address private immutable _PREVIEW_MODULE;
    address private immutable _MARKETS_MODULE;
    address private immutable _POSITIONS_MODULE;
    address private immutable _SPEED_MODULE;
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
    /// @param modules The nine modules, in `MODULES()` order.
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

    /// @inheritdoc ILensAccount
    function predictProxy(
        address,
        uint256
    ) external view override returns (address proxy, bool deployed) {
        (proxy, deployed);
        _forward(_ACCOUNT_MODULE);
    }

    /// @inheritdoc ILensAccount
    function getAccount(
        address,
        uint256
    ) external view override returns (AccountView memory account) {
        account;
        _forward(_ACCOUNT_MODULE);
    }

    /// @inheritdoc ILensAccount
    function getAccounts(
        address,
        uint256[] calldata
    ) external view override returns (AccountView[] memory accounts) {
        accounts;
        _forward(_ACCOUNT_MODULE);
    }

    /// @inheritdoc ILensAccount
    function getRecords(
        address,
        uint256,
        uint256
    ) external view override returns (RecordView[] memory records) {
        records;
        _forward(_ACCOUNT_MODULE);
    }

    /// @inheritdoc ILensAccount
    function getEscrowClaimable(
        address,
        address[] calldata
    ) external view override returns (uint256[] memory amounts) {
        amounts;
        _forward(_ACCOUNT_MODULE);
    }

    /// @inheritdoc ILensMarket
    function checkBacking(
        address
    ) external view override returns (BackingView memory backing) {
        backing;
        _forward(_MARKET_MODULE);
    }

    /// @inheritdoc ILensMarket
    function checkRecordBacking(
        address,
        uint256,
        uint256
    ) external view override returns (RecordBackingView[] memory records) {
        records;
        _forward(_MARKET_MODULE);
    }

    /// @inheritdoc ILensMarket
    function getPendingSettlement(
        address
    ) external view override returns (PendingView memory pending) {
        pending;
        _forward(_MARKET_MODULE);
    }

    /// @inheritdoc ILensMarket
    function getCapHeadroom(
        address,
        address
    ) external view override returns (CapView memory caps) {
        caps;
        _forward(_MARKET_MODULE);
    }

    /// @inheritdoc ILensLiquidation
    function getPriceState(
        address
    ) external view override returns (PriceView memory priceView) {
        priceView;
        _forward(_PRICE_MODULE);
    }

    /// @inheritdoc ILensLiquidation
    function getDebtPriceState(
        address,
        uint256
    ) external view override returns (DebtPriceView memory priceView) {
        priceView;
        _forward(_PRICE_MODULE);
    }

    /// @inheritdoc ILensLiquidation
    function getApplicationState(
        address
    ) external view override returns (PauseState state) {
        state;
        _forward(_PRICE_MODULE);
    }

    /// @inheritdoc ILensLiquidation
    function getPauseReason(
        address
    ) external view override returns (uint8 reason) {
        reason;
        _forward(_PRICE_MODULE);
    }

    /// @inheritdoc ILensLiquidation
    function previewLiquidation(
        address,
        uint256,
        uint256
    ) external view override returns (LiquidationPreview memory preview) {
        preview;
        _forward(_LIQUIDATION_MODULE);
    }

    /// @inheritdoc ILensRisk
    function getBreakerStatus(
        uint256
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        (reasons, reopensAt);
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensRisk
    function getDebtBreakerStatus(
        address,
        uint256
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        (reasons, reopensAt);
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensRisk
    function isFrozenAddress(
        address
    ) external view override returns (bool frozen) {
        frozen;
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensRisk
    function getTailCoverage(
        address,
        address
    ) external view override returns (TailCoverageView memory coverage) {
        coverage;
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensRisk
    function uncoveredDeficit(
        address,
        address
    ) external view override returns (uint256 uncovered) {
        uncovered;
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensRisk
    function getHubAssetExposure(
        address,
        address
    ) external view override returns (HubAssetExposureView memory view_) {
        view_;
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensPreview
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
    function previewRecredit(
        uint256,
        bytes32
    ) external view override returns (uint128 added, uint256 usdCharge, bool rescueOnly) {
        (added, usdCharge, rescueOnly);
        _forward(_PREVIEW_MODULE);
    }

    /// @inheritdoc ILensPreview
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

    /// @inheritdoc ILensMarkets
    function getMarkets(
        uint256,
        uint256
    ) external view override returns (MarketView[] memory markets) {
        markets;
        _forward(_MARKETS_MODULE);
    }

    /// @inheritdoc ILensMarkets
    function getMarket(
        uint256
    ) external view override returns (MarketView memory market) {
        market;
        _forward(_MARKETS_MODULE);
    }

    /// @inheritdoc ILensMarkets
    function getDebtReserve(
        address,
        uint256
    ) external view override returns (DebtReserveView memory reserve) {
        reserve;
        _forward(_MARKETS_MODULE);
    }

    /// @inheritdoc ILensMarkets
    function getDebtReserves(
        address
    ) external view override returns (DebtReserveView[] memory reserves) {
        reserves;
        _forward(_MARKETS_MODULE);
    }

    /// @inheritdoc ILensPositions
    function getAccountRisk(
        address,
        uint256
    ) external view override returns (AccountRiskView memory risk) {
        risk;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensPositions
    function previewPledge(
        address,
        uint256,
        bytes32
    ) external view override returns (PledgePreviewView memory pledge) {
        pledge;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensPositions
    function previewWithdraw(
        address,
        uint256,
        bytes32,
        uint256
    ) external view override returns (WithdrawPreview memory withdrawal) {
        withdrawal;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensFees
    function getPositionFees(
        uint256,
        bytes32
    ) external view override returns (PositionFeesView memory fees) {
        fees;
        _forward(_MARKETS_MODULE);
    }

    /// @inheritdoc ILensFees
    function getAccountFees(
        address,
        uint256
    ) external view override returns (PositionFeesView[] memory fees) {
        fees;
        _forward(_MARKETS_MODULE);
    }

    /// @inheritdoc ILensActions
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
    function previewPledgeAfter(
        address,
        uint256,
        bytes32
    ) external view override returns (ActionPreview memory preview) {
        preview;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensActions
    function previewWithdrawAfter(
        address,
        uint256,
        bytes32
    ) external view override returns (ActionPreview memory preview) {
        preview;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensSizing
    function previewMaxWithdraw(
        address,
        uint256,
        uint256
    ) external view override returns (RemovalSizing memory sizing) {
        sizing;
        _forward(_POSITIONS_MODULE);
    }

    /// @inheritdoc ILensSizing
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
    function previewCloseAccount(
        address,
        uint256,
        uint256
    ) external view override returns (CloseAccountView memory close) {
        close;
        _forward(_ACCOUNT_MODULE);
    }

    /// @inheritdoc ILensHubAssets
    function getHubAsset(
        address,
        uint256
    ) external view override returns (HubAssetView memory asset) {
        asset;
        _forward(_RISK_MODULE_LENS);
    }

    /// @inheritdoc ILensSpeed
    function getBorrowSpeed(
        uint256,
        uint256
    ) external view override returns (BorrowSpeedView memory speed) {
        speed;
        _forward(_SPEED_MODULE);
    }

    /// @inheritdoc ILensSpeed
    function getPledgeSpeed(
        uint256
    ) external view override returns (SpeedView memory pledge) {
        pledge;
        _forward(_SPEED_MODULE);
    }

    /// @inheritdoc ILens
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
    function LENS_MAX_PAGE() external pure override returns (uint256 maxPage) {
        maxPage = LensConstants.LENS_MAX_PAGE;
    }

    /// @inheritdoc ILens
    function LENS_DUST_MARGIN_BPS() external pure override returns (uint256 marginBps) {
        marginBps = LensConstants.LENS_DUST_MARGIN_BPS;
    }

    /// @inheritdoc ILens
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc ILens
    function PROXY_MANAGER() external view override returns (address proxyManager) {
        proxyManager = _PROXY_MANAGER;
    }

    /// @inheritdoc ILens
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc ILens
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc ILens
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    /// @inheritdoc ILens
    function PARAMETER_STORE() external view override returns (address parameterStore) {
        parameterStore = _PARAMETER_STORE;
    }

    /// @inheritdoc ILens
    function RISK_MODULE() external view override returns (address riskModule) {
        riskModule = _RISK_MODULE;
    }

    /// @inheritdoc ILens
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc ILens
    function PAYOUT_ESCROW() external view override returns (address payoutEscrow) {
        payoutEscrow = _PAYOUT_ESCROW;
    }

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
