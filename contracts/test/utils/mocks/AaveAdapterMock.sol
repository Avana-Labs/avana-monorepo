// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../../src/custody/collateralization/ICollateralization.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapDeleverage} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapDeleverage.sol";
import {DeleverageRequest} from "../../../src/liquidation/lp-vault-swap/types/DeleverageRequest.sol";
import {ILock} from "../../../src/lock/lock/ILock.sol";
import {IAaveAdapterErrors} from "../../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "../../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {PositionProxy} from "../../../src/proxy/position-proxy/PositionProxy.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {IVaultToken} from "../../../src/vault-token/vault-token/IVaultToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AaveAdapterMock
/// @notice A stand-in for the chain's AaveAdapter (2.6) in the LPVaultSwap suites, built from `IAaveAdapterSettlement`
/// and `IAaveAdapterViews`: the vault token's `adapter()` and the Lock's AaveAdapter member. It creates real
/// PositionProxies, pledges through the real Collateralization (credit, mint, supply on the real CDP Spoke), borrows
/// through the proxy, burns seized units for LPVaultSwap (`burnSeized`), runs the two deleverage steps LPVaultSwap
/// calls back (`deleverageRepay`, `deleverageRelease`) inside a transient-style session, and drives
/// `repayWithCollateral` the way 2.6 orders it (Lock, session, `LPVaultSwap.deleverage`, both steps ran, health factor
/// not lowered, Lock released).
/// @dev The lead replaces it with the real AaveAdapter in the integration tests after the merge. Checks follow 2.6:
/// `burnSeized` and both deleverage steps revert `NotLPVaultSwap` unless the caller is LPVaultSwap and the Lock holder
/// is the expected member, `ZeroAmount` for zero units or amounts, `UnknownMarket` for a vault token the mock did not
/// bind to the market, `NoDeleverageSession` outside an open session or out of order.
contract AaveAdapterMock is IAaveAdapterErrors, IAaveAdapterEvents {
    using SafeERC20 for IERC20;

    struct Binding {
        address wallet;
        address spoke;
        uint256 marketId;
        address vaultToken;
        uint256 reserveId;
    }

    struct Session {
        bool open;
        address proxy;
        uint256 debtReserveId;
        bool repaid;
        bool released;
    }

    address public lock;
    address public lpVaultSwap;
    address public collateralization;

    mapping(address proxy => Binding) internal _binding;
    mapping(uint256 marketId => address vaultToken) public vaultTokenOf;
    Session internal _session;

    uint256 public burnCalls;
    uint256 public lastBurnUnits;
    uint256 public repayCalls;
    uint256 public releaseCalls;
    /// @notice When set, `deleverageRepay` re-enters LPVaultSwap with this calldata (a hostile adapter step).
    bytes public reenterData;
    /// @notice When true, `deleverageRepay` returns this share of the amount unconsumed to LPVaultSwap (bps).
    uint256 public refundBps;

    function setCore(
        address lock_,
        address lpVaultSwap_,
        address collateralization_
    ) external {
        (lock, lpVaultSwap, collateralization) = (lock_, lpVaultSwap_, collateralization_);
    }

    function bindMarket(
        uint256 marketId,
        address vaultToken
    ) external {
        vaultTokenOf[marketId] = vaultToken;
    }

    function setReenter(
        bytes calldata data
    ) external {
        reenterData = data;
    }

    function setRefundBps(
        uint256 bps
    ) external {
        refundBps = bps;
    }

    // ─── Accounts ───

    /// @notice Creates the PositionProxy of `(wallet, spoke, marketId)` with this mock as its AaveAdapter.
    function createProxy(
        address wallet,
        address spoke,
        uint256 marketId,
        uint256 reserveId
    ) external returns (address proxy) {
        proxy = address(new PositionProxy(address(this), wallet, spoke, marketId));
        _binding[proxy] = Binding(wallet, spoke, marketId, vaultTokenOf[marketId], reserveId);
    }

    /// @notice Pledges the custodied position `key` of `depositor` into `proxy` under the Lock: credit, mint, supply.
    function pledge(
        address proxy,
        address depositor,
        bytes32 key
    ) external returns (uint256 recordId, uint128 credited) {
        Binding memory b = _binding[proxy];
        ILock(lock).acquire();
        if (!IVaultToken(b.vaultToken).isValidProxy(proxy)) IVaultToken(b.vaultToken).addValidProxy(proxy);
        (recordId, credited) = ICollateralization(collateralization).pledge(depositor, proxy, b.vaultToken, key, false);
        IVaultToken(b.vaultToken).mint(proxy, credited);
        _exec(proxy, b.vaultToken, abi.encodeCall(IERC20.approve, (b.spoke, credited)));
        _exec(proxy, b.spoke, abi.encodeCall(IAaveV4Spoke.supply, (b.reserveId, credited, proxy)));
        _exec(proxy, b.spoke, abi.encodeCall(IAaveV4Spoke.setUsingAsCollateral, (b.reserveId, true, proxy)));
        ILock(lock).release();
    }

    /// @notice Borrows `amount` of `debtReserveId` on the proxy's account and sends it to `to`.
    function borrow(
        address proxy,
        uint256 debtReserveId,
        address asset,
        uint256 amount,
        address to
    ) external {
        Binding memory b = _binding[proxy];
        ILock(lock).acquire();
        _exec(proxy, b.spoke, abi.encodeCall(IAaveV4Spoke.borrow, (debtReserveId, amount, proxy)));
        _exec(proxy, asset, abi.encodeCall(IERC20.transfer, (to, amount)));
        ILock(lock).release();
    }

    // ─── IAaveAdapterViews ───

    function walletOf(
        address proxy
    ) external view returns (address wallet) {
        wallet = _binding[proxy].wallet;
    }

    // ─── IAaveAdapterSettlement ───

    function burnSeized(
        uint256 marketId,
        address vaultToken,
        uint256 units
    ) external {
        if (msg.sender != lpVaultSwap || ILock(lock).holder() != lpVaultSwap) revert NotLPVaultSwap();
        if (vaultTokenOf[marketId] != vaultToken) revert UnknownMarket(marketId);
        if (units == 0) revert ZeroAmount();
        ++burnCalls;
        lastBurnUnits = units;
        IVaultToken(vaultToken).burn(lpVaultSwap, units);
        emit SeizedUnitsBurned(marketId, vaultToken, units);
    }

    function deleverageRepay(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external returns (uint256 repaid) {
        _checkStep(proxy);
        if (_session.debtReserveId != debtReserveId || _session.repaid) revert NoDeleverageSession();
        if (amount == 0) revert ZeroAmount();
        ++repayCalls;
        _session.repaid = true;
        if (reenterData.length != 0) {
            (bool ok, bytes memory ret) = lpVaultSwap.call(reenterData);
            if (!ok) _bubble(ret);
        }
        Binding memory b = _binding[proxy];
        address asset = IAaveV4Spoke(b.spoke).getReserve(debtReserveId).underlying;
        uint256 before = IERC20(asset).balanceOf(proxy);
        IERC20(asset).safeTransferFrom(lpVaultSwap, proxy, amount);
        uint256 received = IERC20(asset).balanceOf(proxy) - before;
        uint256 toRepay = received - received * refundBps / 10_000;
        _exec(proxy, asset, abi.encodeCall(IERC20.approve, (b.spoke, toRepay)));
        _exec(proxy, b.spoke, abi.encodeCall(IAaveV4Spoke.repay, (debtReserveId, toRepay, proxy)));
        uint256 rest = IERC20(asset).balanceOf(proxy) - before;
        if (rest != 0) _exec(proxy, asset, abi.encodeCall(IERC20.transfer, (lpVaultSwap, rest)));
        repaid = received - rest;
    }

    function deleverageRelease(
        address proxy,
        PositionRef calldata position,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts, bool closed) {
        _checkStep(proxy);
        if (!_session.repaid || _session.released) revert NoDeleverageSession();
        if (units == 0) revert ZeroAmount();
        ++releaseCalls;
        _session.released = true;
        Binding memory b = _binding[proxy];
        _exec(proxy, b.spoke, abi.encodeCall(IAaveV4Spoke.withdraw, (b.reserveId, units, proxy)));
        IVaultToken(b.vaultToken).burn(proxy, units);
        (amounts, closed) = ICollateralization(collateralization)
            .releaseForDeleverage(proxy, b.vaultToken, position.positionKey, units, minAmounts);
    }

    // ─── repayWithCollateral (2.6 order) ───

    /// @notice The Adapter's repay with collateral: Lock, session, `LPVaultSwap.deleverage`, both steps ran, the health
    /// factor not lowered while debt remains, Lock released.
    function repayWithCollateral(
        address proxy,
        PositionRef calldata position,
        uint128 units,
        uint256 debtReserveId,
        uint256[] calldata minAmounts,
        uint256 minDebtRepaid
    ) external returns (uint256 debtRepaid, uint256 assetOut) {
        Binding memory b = _binding[proxy];
        ILock(lock).acquire();
        uint256 hfBefore = IAaveV4Spoke(b.spoke).getUserAccountData(proxy).healthFactor;
        _session = Session(true, proxy, debtReserveId, false, false);
        (debtRepaid, assetOut) = ILPVaultSwapDeleverage(lpVaultSwap)
            .deleverage(
                DeleverageRequest({
                    proxy: proxy,
                    wallet: b.wallet,
                    spoke: b.spoke,
                    marketId: b.marketId,
                    vaultToken: b.vaultToken,
                    position: position,
                    units: units,
                    debtReserveId: debtReserveId,
                    minAmounts: minAmounts,
                    minDebtRepaid: minDebtRepaid
                })
            );
        if (!_session.repaid || !_session.released) revert NoDeleverageSession();
        if (IAaveV4Spoke(b.spoke).getUserTotalDebt(debtReserveId, proxy) != 0) {
            uint256 hfAfter = IAaveV4Spoke(b.spoke).getUserAccountData(proxy).healthFactor;
            if (hfAfter < hfBefore) revert HealthFactorNotImproved(hfBefore, hfAfter);
        }
        delete _session;
        ILock(lock).release();
    }

    /// @notice Calls `LPVaultSwap.deleverage` with an arbitrary request while holding the Lock (no session checks).
    function deleverageRaw(
        DeleverageRequest calldata r
    ) external returns (uint256 debtRepaid, uint256 assetOut) {
        ILock(lock).acquire();
        _session = Session(true, r.proxy, r.debtReserveId, false, false);
        (debtRepaid, assetOut) = ILPVaultSwapDeleverage(lpVaultSwap).deleverage(r);
        delete _session;
        ILock(lock).release();
    }

    /// @notice Calls `LPVaultSwap.deleverage` without holding the Lock.
    function deleverageUnlocked(
        DeleverageRequest calldata r
    ) external returns (uint256, uint256) {
        return ILPVaultSwapDeleverage(lpVaultSwap).deleverage(r);
    }

    /// @notice Calls any LPVaultSwap function while holding the Lock as the AaveAdapter.
    function callUnderLock(
        bytes calldata data
    ) external returns (bytes memory ret) {
        ILock(lock).acquire();
        bool ok;
        (ok, ret) = lpVaultSwap.call(data);
        if (!ok) _bubble(ret);
        ILock(lock).release();
    }

    // ─── Internals ───

    function _checkStep(
        address proxy
    ) internal view {
        if (msg.sender != lpVaultSwap || ILock(lock).holder() != address(this)) revert NotLPVaultSwap();
        if (!_session.open || _session.proxy != proxy) revert NoDeleverageSession();
    }

    function _exec(
        address proxy,
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        return PositionProxy(proxy).execute(target, data);
    }

    function _bubble(
        bytes memory ret
    ) internal pure {
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }
}
