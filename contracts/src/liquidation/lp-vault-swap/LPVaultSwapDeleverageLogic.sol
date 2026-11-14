// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashSource} from "../../flash/IFlashSource.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
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
import {DeleverageRequest} from "./types/DeleverageRequest.sol";
import {LPVaultSwapImmutables} from "./types/LPVaultSwapImmutables.sol";
import {RouteMode} from "./types/RouteMode.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// The repayment loop makes at most MAX_REPAY_TRANSFERS (4) transfers to the flash source (REQ-SWAP-122); a revert
// reverts the deleverage.
// forge-lint: disable-start(calls-loop)
// FlashLoanUsed and Deleveraged report the premium and amounts known only after the loan; the body runs under the
// AaveAdapter's Lock, and onFlashLoan accepts only the registry's source inside the stored context (REQ-SWAP-013).
// forge-lint: disable-start(reentrancy-events)
/// @title LPVaultSwapDeleverageLogic
/// @notice Bodies of `deleverage` and its flash callback `onFlashLoan`, run by delegatecall from the LPVaultSwap
/// implementation in the proxy's storage: the swap side of the AaveAdapter's `repayWithCollateral`, the only LPVaultSwap
/// path that takes a flash loan.
/// @dev `deleverage` checks the caller and the Lock holder (`NotAdapter`), the market, the debt reserve, both price
/// rules and Hub shares, sizes `x` (SPEC-LIQ-020), checks the flash source (`FlashSourceIsHub`, `FlashLiquidityShort`,
/// `FlashFeeTooHigh`), opens a transient context bound to the hash of the encoded sizing context and calls
/// `flashLoan`. `onFlashLoan` checks the context and the measured principal `Fr`, repays `Fr` of the debt through the
/// AaveAdapter, has it release `units` to LPVaultSwap, swaps the released tokens at `sLeg = slippageAllowanceBps`,
/// requires `R >= x + φ`, brings the flash source up to `x + φ` by at most `MAX_REPAY_TRANSFERS` balance-delta
/// transfers and sends route residues and dust legs to the borrower's wallet. After `flashLoan` returns, `deleverage`
/// sends the debt asset left, measured by balance, to the wallet. No bonus, fee, keeper payout or escrow applies.
/// @custom:spec REQ-SWAP-013, REQ-SWAP-106, REQ-SWAP-116, REQ-SWAP-122, REQ-SWAP-124, REQ-FLASH-002, REQ-FLASH-004, REQ-FLASH-005, REQ-FLASH-006, REQ-FLASH-009, SPEC-LIQ-015, SPEC-LIQ-020, Q-255
// The selectors of ILPVaultSwapDeleverage and IFlashReceiver are served by LPVaultSwap, which delegates them here;
// this body inherits neither, since LPVaultSwap declares them.
// solhint-disable comprehensive-interface
// forge-lint: disable-next-item(missing-inheritance)
contract LPVaultSwapDeleverageLogic is LPVaultSwapSettlement, ILPVaultSwapLogic {
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Uint256Slot;
    using TransientSlot for TransientSlot.AddressSlot;
    using TransientSlot for TransientSlot.Bytes32Slot;

    /// @notice Value `onFlashLoan` returns: `keccak256("IFlashReceiver.onFlashLoan")`.
    bytes32 internal constant _ON_FLASH_LOAN_MAGIC = 0xc99b2efbd4a3126f78eb0b8a8822446a13d4407f62732d30b5cc5cb0f957115c;

    /// @notice Context states: none, a loan requested and awaiting the callback, the callback ran.
    uint256 private constant _STATE_NONE = 0;
    uint256 private constant _STATE_OPEN = 1;
    uint256 private constant _STATE_CALLED = 2;

    /// @notice ERC-7201 transient base slot of the deleverage context:
    /// `keccak256(abi.encode(uint256(keccak256("avana.lpvaultswap.deleverage")) - 1)) & ~bytes32(uint256(0xff))`. The
    /// state sits at the base; the context hash, flash source, asset, amount `F`, LPVaultSwap's balance before the
    /// loan, the recovery `R`, the premium and the debt repaid at the next eight slots.
    bytes32 private constant _STATE_SLOT = 0x2fedc8c0c549405a7945459f775cbb80cfe11288ab144f5ef2460ebaf39ee400;
    bytes32 private constant _HASH_SLOT = 0x2fedc8c0c549405a7945459f775cbb80cfe11288ab144f5ef2460ebaf39ee401;
    bytes32 private constant _SOURCE_SLOT = 0x2fedc8c0c549405a7945459f775cbb80cfe11288ab144f5ef2460ebaf39ee402;
    bytes32 private constant _ASSET_SLOT = 0x2fedc8c0c549405a7945459f775cbb80cfe11288ab144f5ef2460ebaf39ee403;
    bytes32 private constant _AMOUNT_SLOT = 0x2fedc8c0c549405a7945459f775cbb80cfe11288ab144f5ef2460ebaf39ee404;
    bytes32 private constant _BALANCE_SLOT = 0x2fedc8c0c549405a7945459f775cbb80cfe11288ab144f5ef2460ebaf39ee405;
    bytes32 private constant _RECOVERED_SLOT = 0x2fedc8c0c549405a7945459f775cbb80cfe11288ab144f5ef2460ebaf39ee406;
    bytes32 private constant _PREMIUM_SLOT = 0x2fedc8c0c549405a7945459f775cbb80cfe11288ab144f5ef2460ebaf39ee407;
    bytes32 private constant _REPAID_SLOT = 0x2fedc8c0c549405a7945459f775cbb80cfe11288ab144f5ef2460ebaf39ee408;

    /// @dev The sizing context `deleverage` passes through the flash source to its callback, bound by its hash.
    struct FlashContext {
        DeleverageRequest r;
        address hub;
        address asset;
        uint8 assetDecimals;
        uint256 assetPrice;
        uint256 slippage;
        uint256 allowance;
        uint256 maxFlashFeeBps;
        address[] tokens;
        uint8[] tokenDecimals;
        uint256[] prices;
        uint256 repayment;
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
        return (keccak256("LPVaultSwapDeleverageLogic"), _IMMUTABLES_HASH);
    }

    /// @notice Body of `deleverage`.
    /// @dev See `ILPVaultSwapDeleverage.deleverage`; the implementation forwards its calldata unchanged.
    /// @custom:spec REQ-SWAP-106, REQ-SWAP-116, REQ-FLASH-002, REQ-FLASH-005, REQ-FLASH-009
    function deleverage(
        DeleverageRequest calldata r
    ) external returns (uint256 debtRepaid, uint256 assetOut) {
        _onlyDelegated();
        if (msg.sender != _AAVE_ADAPTER || ILock(_LOCK).holder() != _AAVE_ADAPTER) revert NotAdapter();
        (debtRepaid, assetOut) = _runFlash(_prepare(r));
    }

    /// @dev Opens the context, takes the flash loan, reads the callback's results, clears the context, sends the debt
    /// asset left to the wallet and emits `Deleveraged`.
    /// @custom:spec REQ-SWAP-106, REQ-SWAP-013, SPEC-LIQ-020
    function _runFlash(
        FlashContext memory fc
    ) private returns (uint256 debtRepaid, uint256 assetOut) {
        address source = _checkSource(fc);
        IERC20 asset = IERC20(fc.asset);
        uint256 before = asset.balanceOf(address(this));
        bytes memory context = abi.encode(fc);
        _STATE_SLOT.asUint256().tstore(_STATE_OPEN);
        _HASH_SLOT.asBytes32().tstore(keccak256(context));
        _SOURCE_SLOT.asAddress().tstore(source);
        _ASSET_SLOT.asAddress().tstore(fc.asset);
        _AMOUNT_SLOT.asUint256().tstore(fc.repayment);
        _BALANCE_SLOT.asUint256().tstore(before);
        // The premium is the one the callback checked and stored (transient slot), not the return value.
        // forge-lint: disable-next-line(unused-return)
        IFlashSource(source).flashLoan(fc.asset, fc.repayment, fc.hub, context);
        if (_STATE_SLOT.asUint256().tload() != _STATE_CALLED) revert InvalidFlashCallback();
        uint256 recovered = _RECOVERED_SLOT.asUint256().tload();
        uint256 premium = _PREMIUM_SLOT.asUint256().tload();
        debtRepaid = _REPAID_SLOT.asUint256().tload();
        _clear();
        // SPEC-LIQ-020: the borrower receives R − x − φ, with x the debt the AaveAdapter repaid (the flash amount F,
        // less any part Aave returned unconsumed, which then stays the borrower's); `_settleLoan` already required
        // R ≥ F + φ. It is paid out of the balance change over the loan: a donation above it is not paid out, and a
        // transfer fee that made the source's repayment cost more (REQ-SWAP-122) comes out of it.
        uint256 afterLoan = asset.balanceOf(address(this));
        assetOut = Math.min(
            afterLoan - Math.min(afterLoan, before), SettlementMath.deleverageAssetOut(recovered, debtRepaid, premium)
        );
        if (assetOut != 0) asset.safeTransfer(fc.r.wallet, assetOut);
        // The flash source is the registry's, the Lock is the AaveAdapter's and the context is cleared above, so no
        // reentrant call can interleave with this log.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Deleveraged(
            fc.r.proxy, fc.r.marketId, fc.r.debtReserveId, fc.r.units, debtRepaid, recovered, premium, assetOut
        );
    }

    /// @notice Body of `onFlashLoan`.
    /// @dev See `IFlashReceiver.onFlashLoan` and REQ-SWAP-013; the implementation forwards its calldata unchanged.
    /// @custom:spec REQ-SWAP-013, REQ-SWAP-054, REQ-SWAP-106, REQ-SWAP-122, REQ-FLASH-004
    function onFlashLoan(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata data
    ) external returns (bytes32 magic) {
        _onlyDelegated();
        uint256 received = _checkCallback(asset, amount, data);
        FlashContext memory fc = abi.decode(data, (FlashContext));
        if (!SettlementMath.flashPremiumWithinCap(premium, amount, fc.maxFlashFeeBps)) revert FlashFeeTooHigh();
        _STATE_SLOT.asUint256().tstore(_STATE_CALLED);
        _PREMIUM_SLOT.asUint256().tstore(premium);
        _settleLoan(fc, received, amount + premium);
        emit FlashLoanUsed(fc.r.marketId, msg.sender, asset, amount, premium);
        magic = _ON_FLASH_LOAN_MAGIC;
    }

    /// @dev `InvalidFlashCallback` unless the context is open, the caller is the context's and the registry's flash
    /// source, the Lock is the AaveAdapter's, the data hashes to the context, the asset and amount match and the
    /// principal received `Fr` (balance rise since the loan was requested) is in `(0, amount]`. Returns `Fr`.
    /// @custom:spec REQ-SWAP-013, REQ-SWAP-054, REQ-SWAP-108
    function _checkCallback(
        address asset,
        uint256 amount,
        bytes calldata data
    ) private view returns (uint256 received) {
        if (
            _STATE_SLOT.asUint256().tload() != _STATE_OPEN || msg.sender != _SOURCE_SLOT.asAddress().tload()
                || msg.sender != IMarketRegistry(_MARKET_REGISTRY).flashSource()
                || ILock(_LOCK).holder() != _AAVE_ADAPTER || keccak256(data) != _HASH_SLOT.asBytes32().tload()
                || asset != _ASSET_SLOT.asAddress().tload() || amount != _AMOUNT_SLOT.asUint256().tload()
        ) revert InvalidFlashCallback();
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 snapshot = _BALANCE_SLOT.asUint256().tload();
        received = balance > snapshot ? balance - snapshot : 0;
        if (received == 0 || received > amount) revert InvalidFlashCallback();
    }

    /// @dev Inside the loan: repays `Fr` of the debt through the AaveAdapter, releases and swaps, requires
    /// `R >= x + φ`, repays the flash source by balance delta and sends residues and dust legs to the wallet.
    /// @custom:spec REQ-SWAP-106, REQ-SWAP-121, REQ-SWAP-122
    function _settleLoan(
        FlashContext memory fc,
        uint256 received,
        uint256 owed
    ) private {
        IERC20 asset = IERC20(fc.asset);
        asset.forceApprove(_AAVE_ADAPTER, received);
        uint256 repaid = IAaveAdapter(_AAVE_ADAPTER).deleverageRepay(fc.r.proxy, fc.r.debtReserveId, received);
        asset.forceApprove(_AAVE_ADAPTER, 0);
        _REPAID_SLOT.asUint256().tstore(repaid);
        (uint256 recovered, Tracked memory t) = _releaseAndSwap(fc);
        if (recovered < owed) revert DeleverageShortfall(recovered, owed);
        _RECOVERED_SLOT.asUint256().tstore(recovered);
        _repaySource(asset, owed);
        uint256[] memory residues = _residues(t);
        for (uint256 i = 0; i < t.count; ++i) {
            if (residues[i] != 0) IERC20(t.tokens[i]).safeTransfer(fc.r.wallet, residues[i]);
        }
    }

    /// @dev Market, debt reserve, price rules, Hub shares and the sizing of `x` (SPEC-LIQ-020).
    /// @custom:spec REQ-SWAP-106, SPEC-LIQ-020
    function _prepare(
        DeleverageRequest calldata r
    ) private returns (FlashContext memory fc) {
        Market memory m = _loadMarket(r.marketId);
        if (m.vaultToken != r.vaultToken || m.spoke != r.spoke) revert UnknownMarket();
        DebtReserveDef memory d = _loadDebtReserve(m.spoke, r.debtReserveId);
        _checkCollateralPrice(m.lpOracle);
        _checkDebtPrice(d, r.debtReserveId);
        _requireSharesEqualAssets(m.hub, m.hubAssetId);
        IParameterStore ps = IParameterStore(_PARAMETER_STORE);
        fc.r = r;
        fc.hub = m.hub;
        fc.asset = d.asset;
        fc.assetDecimals = d.decimals;
        fc.assetPrice = _debtPrice(m.spoke, r.debtReserveId, d);
        fc.slippage = ps.getMarketParams(r.marketId).slippageAllowanceBps;
        fc.allowance = ps.floorRoundingAllowance(d.asset);
        fc.maxFlashFeeBps = ps.maxFlashFeeBps();
        fc.tokens = m.tokens;
        fc.tokenDecimals = m.tokenDecimals;
        // Only the leg prices are used; the decimals come from the market record.
        // forge-lint: disable-next-line(unused-return)
        (fc.prices,,) = ILPOracle(m.lpOracle).getTokenPrices();
        uint256 value = SettlementMath.seizedValue(r.units, _collateralPrice(m), m.decimals, d.decimals, fc.assetPrice);
        uint256 cap = SettlementMath.deleverageCap(
            value, fc.slippage, _unitSum(_legArgs(fc, new uint256[](0))), fc.allowance, fc.maxFlashFeeBps
        );
        fc.repayment = SettlementMath.deleverageRepayment(
            IAaveV4Spoke(m.spoke).getUserTotalDebt(r.debtReserveId, r.proxy), cap, r.minDebtRepaid
        );
    }

    /// @dev The registry's flash source: `FlashSourceIsHub` if its lender is a recorded Hub, `FlashLiquidityShort` if
    /// it cannot lend `x`, `FlashFeeTooHigh` if its quote breaks the exact cap.
    /// @custom:spec REQ-FLASH-002, REQ-FLASH-005, REQ-FLASH-006, REQ-FLASH-009, REQ-SWAP-097, REQ-SWAP-099
    function _checkSource(
        FlashContext memory fc
    ) private view returns (address source) {
        IMarketRegistry mr = IMarketRegistry(_MARKET_REGISTRY);
        source = mr.flashSource();
        if (mr.isRecordedHub(IFlashSource(source).LENDER())) revert FlashSourceIsHub();
        uint256 available = IFlashSource(source).maxFlashLoan(fc.asset);
        if (fc.repayment > available) revert FlashLiquidityShort(available, fc.repayment);
        uint256 quote = IFlashSource(source).flashPremium(fc.asset, fc.repayment);
        if (!SettlementMath.flashPremiumWithinCap(quote, fc.repayment, fc.maxFlashFeeBps)) revert FlashFeeTooHigh();
    }

    /// @dev The AaveAdapter releases `units` to LPVaultSwap; the released tokens are swapped at `sLeg = s`; returns `R`
    /// over the release and the route calls, and the tracked residues.
    /// @custom:spec REQ-SWAP-106, REQ-SWAP-121, SPEC-LIQ-018
    function _releaseAndSwap(
        FlashContext memory fc
    ) private returns (uint256 recovered, Tracked memory t) {
        IERC20 asset = IERC20(fc.asset);
        uint256 n = fc.tokens.length;
        t = _snapshot(fc.tokens, fc.asset);
        uint256 r0 = asset.balanceOf(address(this));
        uint256[] memory mins = fc.r.minAmounts.length == 0 ? new uint256[](n) : fc.r.minAmounts;
        // The released amounts are measured as LPVaultSwap balance changes (REQ-SWAP-108), never read from returns.
        // forge-lint: disable-next-line(unused-return)
        IAaveAdapter(_AAVE_ADAPTER).deleverageRelease(fc.r.proxy, fc.r.position, fc.r.units, mins);
        _swapLegs(_legArgs(fc, _released(t, n)), t);
        uint256 r1 = asset.balanceOf(address(this));
        recovered = r1 > r0 ? r1 - r0 : 0;
    }

    /// @dev Leg inputs of `deleverage`: `sLeg = slippageAllowanceBps`, `PrimaryThenBackup`.
    function _legArgs(
        FlashContext memory fc,
        uint256[] memory amounts
    ) private pure returns (LegArgs memory l) {
        l = LegArgs({
            marketId: fc.r.marketId,
            asset: fc.asset,
            assetDecimals: fc.assetDecimals,
            assetPrice: fc.assetPrice,
            sLeg: fc.slippage,
            allowance: fc.allowance,
            mode: RouteMode.PrimaryThenBackup,
            tokens: fc.tokens,
            decimals: fc.tokenDecimals,
            prices: fc.prices,
            amounts: amounts
        });
    }

    /// @dev REQ-SWAP-122: at most `MAX_REPAY_TRANSFERS` times, read the source's balance, stop at `owed`, else send
    /// the difference; then `FlashRepayShort(balance, owed)` unless the source holds `owed`.
    /// @custom:spec REQ-SWAP-122, REQ-SWAP-124, REQ-SWAP-108
    function _repaySource(
        IERC20 asset,
        uint256 owed
    ) private {
        address source = msg.sender;
        for (uint256 k = 0; k < _MAX_REPAY_TRANSFERS; ++k) {
            uint256 held = asset.balanceOf(source);
            if (held >= owed) break;
            asset.safeTransfer(source, owed - held);
        }
        uint256 balance = asset.balanceOf(source);
        if (balance < owed) revert FlashRepayShort(balance, owed);
    }

    /// @dev Empties the transient context.
    function _clear() private {
        _STATE_SLOT.asUint256().tstore(_STATE_NONE);
        _HASH_SLOT.asBytes32().tstore(bytes32(0));
        _SOURCE_SLOT.asAddress().tstore(address(0));
        _ASSET_SLOT.asAddress().tstore(address(0));
        _AMOUNT_SLOT.asUint256().tstore(0);
        _BALANCE_SLOT.asUint256().tstore(0);
        _RECOVERED_SLOT.asUint256().tstore(0);
        _PREMIUM_SLOT.asUint256().tstore(0);
        _REPAID_SLOT.asUint256().tstore(0);
    }
}
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(reentrancy-events)
