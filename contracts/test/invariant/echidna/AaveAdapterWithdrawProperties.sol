// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapterExitLogic} from "../../../src/policy/aave-adapter/AaveAdapterExitLogic.sol";
import {AdapterAccount} from "../../../src/policy/aave-adapter/types/AdapterAccount.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {PositionRef} from "../../../src/types/PositionRef.sol";
import {AaveAdapterPathHarness} from "./AaveAdapterPathStandIns.sol";

/// @title AaveAdapterWithdrawProperties
/// @notice Echidna and Medusa properties of the withdrawal path (2.6, 3.4): the production `AaveAdapterExitLogic`
/// (`withdraw`) run by delegatecall from this harness, which stands at the AaveAdapter's address with the Adapter's
/// storage, with the real `Lock` and real `PositionProxy`s, over `BorWorld`. Accounts are seeded with records and
/// debt at HF 1.3–2.0 or debt-free (the pledge and borrow steps are `AaveAdapterBorrowProperties`'); wallets withdraw
/// part or all of a record, or half of what is free at the requirement; prices fall below the requirement, interest
/// accrues, debt is cleared, the pause state and the freeze change. Between transactions: no withdrawal with debt left
/// HF below `max(1, hard floor, minHealthFactor)`, so no collateral leaves an account below the requirement (INV-025);
/// no withdrawal with debt completed under a pause or for a frozen wallet (INV-024); every debt-free withdrawal within
/// the record completed, in every pause state (INV-081); supplied units equal credited units and the vault token's
/// supply (INV-003, INV-008); the Adapter and the proxies hold no token and no allowance (INV-021); the Lock is free.
/// @dev See `AaveAdapterPathHarness` and `AaveAdapterBorrowProperties` for the stand-ins and why the harness takes the
/// router's place. `tried` and `done` count calls per entry point: 0 `seedPosition`, 1 `withdrawLp`.
contract AaveAdapterWithdrawProperties is AaveAdapterPathHarness {
    uint256 internal constant BAD_EXIT = 32;

    address internal immutable EXIT;

    constructor() {
        EXIT = address(new AaveAdapterExitLogic(_adapterImmutables()));
        _seed(0, 20e18, 15_000);
        _seed(1, 5e18, 13_000);
    }

    function _logicFor(
        bytes4 s
    ) internal view override returns (address) {
        return s == AaveAdapterExitLogic.withdraw.selector ? EXIT : address(0);
    }

    /// @dev A record of `units` for account `i`, with debt putting the addition at `hfBps` / 10⁴ (none for 0), its
    /// proxy created and registered as `pledge` registers it.
    function _seed(
        uint256 i,
        uint256 units,
        uint256 hfBps
    ) internal {
        address wallet = address(_wallet(i));
        address p = _proxyOf(i);
        if (p == address(0)) {
            p = W.deployProxy(wallet, address(W), MARKET);
            Layout storage l = _s();
            l.proxyOf[wallet][MARKET] = p;
            l.walletOf[p] = wallet;
            l.accountOf[p] =
                AdapterAccount({spoke: address(W), marketId: MARKET, vaultToken: address(VT), reserveId: 0});
        }
        uint256 d = hfBps == 0 ? 0 : units * W.price() / 1e18 * 8000 / (hfBps * 100);
        bytes32 key = keccak256(abi.encode(i, ++keyNonce));
        W.seed(p, key, units, d);
        keys[i][keyNonce % MAX_KEYS] = key;
        credited[i] += units;
        booked[i] += d;
    }

    // ─── Entry points ───

    /// @notice A new record for account `who`: 1, 5, 20 or 100 vault tokens (`size`) with debt at HF 1.3, 1.5 or 2.0
    /// for the addition, or none (`health`).
    function seedPosition(
        uint8 who,
        uint8 size,
        uint8 health
    ) external {
        ++tried[0];
        uint256 s = size & 3;
        uint256 h = health & 3;
        _seed(
            _index(who),
            s == 0 ? 1e18 : (s == 1 ? 5e18 : (s == 2 ? 20e18 : 100e18)),
            h == 0 ? 13_000 : (h == 1 ? 15_000 : (h == 2 ? 20_000 : 0))
        );
        ++done[0];
    }

    /// @notice Account `who`'s debt is repaid in full outside the logic under test, so its next withdrawals are
    /// debt-free.
    function clearDebt(
        uint8 who
    ) external {
        uint256 i = _index(who);
        address p = _proxyOf(i);
        if (p == address(0)) return;
        W.clearDebt(p);
        booked[i] = 0;
    }

    /// @notice Wallet `who` withdraws from one of its records (`slot`): 10 %, 50 % or all of the record, or, with
    /// debt, half of the units free at the requirement for `minHealthFactor` (`minHf`).
    function withdrawLp(
        uint8 who,
        uint8 slot,
        uint8 frac,
        uint8 minHf
    ) external {
        ++tried[1];
        uint256 i = _index(who);
        address p = _proxyOf(i);
        bytes32 key = keys[i][slot & 3];
        uint256 c = W.creditOf(p, key);
        if (c == 0) return;
        uint256 m = _minHf(minHf);
        bool hadDebt = W.debt(p) != 0;
        uint256 units = _withdrawUnits(p, c, _required(m), frac);
        if (units == 0) return;
        bool gated = W.state() == PauseState.Paused || W.isFrozenAddress(address(_wallet(i)));
        bool ok = _call(
            _wallet(i),
            abi.encodeCall(
                AaveAdapterExitLogic.withdraw, (MARKET, PositionRef(INTEGRATION, key), units, block.timestamp, m)
            )
        );
        // INV-081: a debt-free withdrawal within the record completes in every pause state and for a frozen wallet.
        _ensure(BAD_EXIT, ok || hadDebt);
        if (!ok) return;
        ++done[1];
        credited[i] -= units;
        if (hadDebt) {
            // INV-024: a withdrawal that leaves debt needs no pause and an unfrozen wallet.
            _ensure(BAD_GATE, !gated);
            // INV-025: no collateral leaves an account with debt below the requirement.
            _ensure(BAD_HEALTH, W.healthFactor(p) >= _required(m));
        }
        _ensure(BAD_SUPPLY, W.supplied(p) == credited[i] && VT.balanceOf(p) == 0);
    }

    /// @dev 10 %, 50 % or all of a record of `c` units, or, with debt and `frac` 3, half of the units above what the
    /// debt needs at `req` (HF = supplied × price × CF / (debt × 10¹²) in the Spoke's units, so the debt needs
    /// `req × debt × 10⁶ / (price × CF)` units, rounded up), at most the record.
    function _withdrawUnits(
        address p,
        uint256 c,
        uint256 req,
        uint8 frac
    ) internal view returns (uint256 units) {
        uint256 d = W.debt(p);
        uint256 f = frac & 3;
        units = f == 0 ? c / 10 : (f == 1 ? c / 2 : c);
        if (f == 3 && d != 0) {
            uint256 need = req * d * 1e6 / (W.price() * 8000) + 1;
            uint256 sup = W.supplied(p);
            uint256 free = sup > need ? sup - need : 0;
            units = free / 2 < c ? free / 2 : c;
        }
    }

    // ─── Properties ───

    /// @notice INV-024: no withdrawal that left debt completed under a pause or for a frozen wallet.
    function property_withdrawalWithDebtGatedByStops() external view returns (bool) {
        return violations & BAD_GATE == 0;
    }

    /// @notice INV-081: every debt-free withdrawal within its record completed.
    function property_debtFreeWithdrawalAlwaysOpen() external view returns (bool) {
        return violations & BAD_EXIT == 0;
    }
}
