// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationSeizure} from "../../../src/custody/collateralization/ICollateralizationSeizure.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapErrors} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {DeleverageRequest} from "../../../src/liquidation/lp-vault-swap/types/DeleverageRequest.sol";
import {ILock} from "../../../src/lock/lock/ILock.sol";
import {IAaveAdapterSettlement} from "../../../src/policy/aave-adapter/IAaveAdapterSettlement.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintableToken {
    function mint(
        address to,
        uint256 amount
    ) external;
}

/// @title LPVaultSwapMock
/// @notice LPVaultSwap as the AaveAdapter sees it (spec 2.11, `ILPVaultSwapDeleverage` and the Adapter-facing steps of
/// a liquidation and a pending settlement), until the real contract replaces it in the integration tests.
/// @dev `deleverage` checks `msg.sender == adapter` and that the Adapter holds the Lock (`NotAdapter`), flash-borrows
/// `flashAmount` of the debt asset (minted, standing in for the IFlashSource; 0 means the account's whole debt on the
/// reserve), calls `deleverageRepay` then `deleverageRelease` with the request's own arguments, converts the released
/// tokens into the debt asset at `recoveredPerUnit` debt-asset base units per vault-token unit (minted, standing in for
/// the routes), repays the flash loan and its premium `premium` and sends the rest to the wallet; `DeleverageTooSmall`
/// below `minDebtRepaid` and `DeleverageShortfall` when the conversion cannot cover the loan. `mode` makes it deviate as a
/// faulty or hostile implementation would. The liquidation helpers run the seizure steps of 2.11 under the Lock.
contract LPVaultSwapMock is ILPVaultSwapErrors {
    enum Mode {
        Normal,
        SkipRepay,
        SkipRelease,
        RepayTwice,
        ReleaseTwice,
        ReleaseFirst,
        WrongProxy,
        WrongUnits,
        WeakMinimums,
        WrongReserve,
        ZeroRepay,
        ReenterAdapter,
        ReleaseOtherProxy,
        CustomRelease
    }

    address public immutable ADAPTER;
    address public lock;
    address public collateralization;
    Mode public mode;
    uint256 public flashAmount;
    uint256 public recoveredPerUnit;
    uint256 public premium;
    address public otherProxy;
    bytes public reentryData;
    bytes public reentryError;
    uint256 public deleverageCalls;
    /// @dev `CustomRelease`: the arguments `deleverageRelease` is called with instead of the request's.
    address public relProxy;
    bytes32 public relKey;
    uint32 public relIntegration;
    uint128 public relUnits;
    uint256[] internal _relMins;
    /// @dev The committed-operator count the RiskModule reads (REQ-RISK liquidation halt); 0 halts liquidation.
    uint256 public activeKeeperCount = 1;
    /// @dev `LOCK.holder()` read right after both callbacks returned (REQ-LOCK-030: no inner callee releases it).
    address public holderAfterCallbacks;
    DeleverageRequest internal _last;

    constructor(
        address adapter
    ) {
        ADAPTER = adapter;
    }

    function wire(
        address lock_,
        address collateralization_
    ) external {
        lock = lock_;
        collateralization = collateralization_;
    }

    function setActiveKeeperCount(
        uint256 n
    ) external {
        activeKeeperCount = n;
    }

    function setCustomRelease(
        address proxy,
        uint32 integrationId,
        bytes32 key,
        uint128 units,
        uint256[] calldata mins
    ) external {
        (relProxy, relIntegration, relKey, relUnits) = (proxy, integrationId, key, units);
        _relMins = mins;
    }

    function setMode(
        Mode m
    ) external {
        mode = m;
    }

    function setDeleverage(
        uint256 flash,
        uint256 perUnit,
        uint256 premium_
    ) external {
        flashAmount = flash;
        recoveredPerUnit = perUnit;
        premium = premium_;
    }

    function setOtherProxy(
        address p
    ) external {
        otherProxy = p;
    }

    function setReentry(
        bytes calldata data
    ) external {
        reentryData = data;
    }

    function lastRequest() external view returns (DeleverageRequest memory) {
        return _last;
    }

    // ─── Repay with collateral (ILPVaultSwapDeleverage) ───

    function deleverage(
        DeleverageRequest calldata r
    ) external returns (uint256 debtRepaid, uint256 debtAssetOut) {
        if (msg.sender != ADAPTER || ILock(lock).holder() != ADAPTER) revert NotAdapter();
        ++deleverageCalls;
        _last = r;
        address asset = IAaveV4Spoke(r.spoke).getReserve(r.debtReserveId).underlying;
        uint256 flash =
            flashAmount != 0 ? flashAmount : IAaveV4Spoke(r.spoke).getUserTotalDebt(r.debtReserveId, r.proxy);
        IMintableToken(asset).mint(address(this), flash);
        IERC20(asset).approve(ADAPTER, flash);
        if (mode == Mode.ReenterAdapter) {
            (bool ok, bytes memory err) = ADAPTER.call(reentryData);
            require(!ok, "reentry succeeded");
            reentryError = err;
        }
        if (mode == Mode.ReleaseFirst) _release(r);
        if (mode != Mode.SkipRepay) {
            debtRepaid = _repay(r, flash);
            if (mode == Mode.RepayTwice) _repay(r, flash);
        }
        if (mode != Mode.SkipRelease && mode != Mode.ReleaseFirst) {
            _release(r);
            if (mode == Mode.ReleaseTwice) _release(r);
        }
        IERC20(asset).approve(ADAPTER, 0);
        holderAfterCallbacks = ILock(lock).holder();
        if (debtRepaid < r.minDebtRepaid) revert DeleverageTooSmall(debtRepaid, r.minDebtRepaid);
        uint256 recovered = recoveredPerUnit * r.units;
        IMintableToken(asset).mint(address(this), recovered);
        // The flash loan and its premium leave LPVaultSwap; the rest is the wallet's.
        uint256 held = IERC20(asset).balanceOf(address(this));
        if (held < flash + premium) revert DeleverageShortfall(held, flash + premium);
        IERC20(asset).transfer(address(0xdead), flash + premium);
        debtAssetOut = held - flash - premium;
        if (debtAssetOut != 0) IERC20(asset).transfer(r.wallet, debtAssetOut);
    }

    function _repay(
        DeleverageRequest calldata r,
        uint256 flash
    ) internal returns (uint256 spent) {
        address proxy = mode == Mode.WrongProxy ? otherProxy : r.proxy;
        uint256 reserve = mode == Mode.WrongReserve ? r.debtReserveId + 1 : r.debtReserveId;
        uint256 amount = mode == Mode.ZeroRepay ? 0 : flash;
        spent = IAaveAdapterSettlement(ADAPTER).deleverageRepay(proxy, reserve, amount);
    }

    function _release(
        DeleverageRequest calldata r
    ) internal {
        if (mode == Mode.CustomRelease) {
            IAaveAdapterSettlement(ADAPTER)
                .deleverageRelease(relProxy, PositionRef(relIntegration, relKey), relUnits, _relMins);
            return;
        }
        address proxy = mode == Mode.ReleaseOtherProxy ? otherProxy : r.proxy;
        uint128 units = mode == Mode.WrongUnits ? r.units - 1 : r.units;
        uint256[] memory mins = r.minAmounts;
        if (mode == Mode.WeakMinimums) mins = new uint256[](r.minAmounts.length);
        IAaveAdapterSettlement(ADAPTER).deleverageRelease(proxy, r.position, units, mins);
    }

    // ─── Liquidation steps (2.11) ───

    /// @notice An honest liquidation: Lock, `beginSeizure`, `liquidationCall` paying `debtToCover`, `burnSeized`,
    /// `settleSeizure`, release. Returns the units seized.
    function liquidate(
        address spoke,
        uint256 marketId,
        address vaultToken,
        uint256 collateralReserveId,
        uint256 debtReserveId,
        address proxy,
        uint256 debtToCover,
        uint256 tokenCount
    ) external returns (uint256 seized) {
        ILock(lock).acquire();
        ICollateralizationSeizure(collateralization).beginSeizure(proxy, vaultToken);
        seized = _seize(spoke, collateralReserveId, debtReserveId, proxy, debtToCover, vaultToken);
        if (seized != 0) IAaveAdapterSettlement(ADAPTER).burnSeized(marketId, vaultToken, seized);
        ICollateralizationSeizure(collateralization).settleSeizure(proxy, vaultToken, seized, new uint256[](tokenCount));
        ILock(lock).release();
    }

    /// @notice A non-conforming liquidation that keeps the seized units and calls nothing in Avana.
    function seizeAndKeep(
        address spoke,
        address vaultToken,
        uint256 collateralReserveId,
        uint256 debtReserveId,
        address proxy,
        uint256 debtToCover
    ) external returns (uint256 seized) {
        seized = _seize(spoke, collateralReserveId, debtReserveId, proxy, debtToCover, vaultToken);
    }

    /// @notice A `burnSeized` under LPVaultSwap's Lock that is never settled (an orphan burn, which opens a gap).
    function burnUnderLock(
        uint256 marketId,
        address vaultToken,
        uint256 units
    ) external {
        ILock(lock).acquire();
        IAaveAdapterSettlement(ADAPTER).burnSeized(marketId, vaultToken, units);
        ILock(lock).release();
    }

    /// @notice `burnSeized` without holding the Lock.
    function burnWithoutLock(
        uint256 marketId,
        address vaultToken,
        uint256 units
    ) external {
        IAaveAdapterSettlement(ADAPTER).burnSeized(marketId, vaultToken, units);
    }

    /// @notice Pending settlement: Lock, `burnSeized`, Collateralization `settlePending`, release.
    function settlePending(
        uint256 marketId,
        address vaultToken,
        uint256 units
    ) external {
        ILock(lock).acquire();
        IAaveAdapterSettlement(ADAPTER).burnSeized(marketId, vaultToken, units);
        ICollateralizationSeizure(collateralization).settlePending(vaultToken, units);
        ILock(lock).release();
    }

    /// @notice A call to `target` made while LPVaultSwap holds the Lock (a deleverage callback outside a session).
    function callUnderLock(
        address target,
        bytes calldata data
    ) external returns (bytes memory err) {
        ILock(lock).acquire();
        bool ok;
        (ok, err) = target.call(data);
        ILock(lock).release();
        require(!ok, "call succeeded");
    }

    /// @notice A call to `target` made with no Lock held.
    function callUnlocked(
        address target,
        bytes calldata data
    ) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }

    function _seize(
        address spoke,
        uint256 collateralReserveId,
        uint256 debtReserveId,
        address proxy,
        uint256 debtToCover,
        address vaultToken
    ) internal returns (uint256 seized) {
        address asset = IAaveV4Spoke(spoke).getReserve(debtReserveId).underlying;
        IMintableToken(asset).mint(address(this), debtToCover);
        IERC20(asset).approve(spoke, debtToCover);
        uint256 before = IERC20(vaultToken).balanceOf(address(this));
        IAaveV4Spoke(spoke).liquidationCall(collateralReserveId, debtReserveId, proxy, debtToCover, false);
        IERC20(asset).approve(spoke, 0);
        seized = IERC20(vaultToken).balanceOf(address(this)) - before;
    }
}
