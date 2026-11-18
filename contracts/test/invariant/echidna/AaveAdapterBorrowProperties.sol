// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapterUserLogic} from "../../../src/policy/aave-adapter/AaveAdapterUserLogic.sol";
import {PauseState} from "../../../src/types/MarketTypes.sol";
import {PositionRef} from "../../../src/types/PositionTypes.sol";
import {AaveAdapterPathHarness, BorActor, BorToken} from "./AaveAdapterPathStandIns.sol";

/// @title AaveAdapterBorrowProperties
/// @notice Echidna and Medusa properties of the borrow path (2.6, 3.1–3.3): the production `AaveAdapterUserLogic`
/// (`pledge`, `borrow`, `repay`) run by delegatecall from this harness, which stands at the AaveAdapter's address with
/// the Adapter's storage, with the real `Lock` and real `PositionProxy`s, over `BorWorld` (Spoke, Hub, MarketRegistry,
/// VaultTokenFactory, ProxyManager, Collateralization and the RiskModule's borrow-side checks). Three wallets pledge
/// LP positions, borrow USDC up to and past their room, repay themselves or through a third party; prices move,
/// interest accrues, the pause state and the freeze change. Between transactions: every borrow left HF at least
/// `max(1, hard floor, minHealthFactor)` (INV-025); every borrow sent exactly its amount to the receiver and the proxy
/// kept nothing (INV-020); no borrow completed under a pause or for a frozen wallet (INV-024); every funded repay
/// completed, in every pause state, and spent exactly what the Spoke booked (INV-081); each account's debt is what it
/// borrowed and accrued less what it repaid; supplied units equal credited units and the vault token's supply
/// (INV-003, INV-008); the Adapter and the proxies hold no token and no allowance (INV-021); the Lock is free.
/// @dev The AaveAdapter router with its four logic contracts and the real Aave V4 exceed the 49,152-byte initcode
/// limit, so this harness takes the router's place for the selectors of `AaveAdapterUserLogic`, and the withdrawal
/// logic has its own harness (`AaveAdapterWithdrawProperties`). The RiskModule is a stand-in applying the production
/// `RiskModuleMath.requiredHealthFactor`; `RiskModuleBorrowLogic` and the real Aave V4 run in the Foundry suites
/// (`FullStack.invariant.t.sol`, `AaveAdapter.invariant.t.sol`). Entry points take small selectors mapped to concrete
/// cases; amounts come from the harness state. `tried` and `done` count calls per entry point: 0 `pledgeLp`,
/// 1 `borrowDebt`, 2 `repayDebt`.
contract AaveAdapterBorrowProperties is AaveAdapterPathHarness {
    address internal immutable USER;

    constructor() {
        USER = address(new AaveAdapterUserLogic(_adapterImmutables()));
    }

    function _logicFor(
        bytes4 s
    ) internal view override returns (address) {
        if (
            s == AaveAdapterUserLogic.pledge.selector || s == AaveAdapterUserLogic.borrow.selector
                || s == AaveAdapterUserLogic.repay.selector
        ) return USER;
        return address(0);
    }

    // ─── Entry points ───

    /// @notice Wallet `who` pledges a position of 1, 5, 20 or 100 vault tokens (`size`), credited in full.
    function pledgeLp(
        uint8 who,
        uint8 size
    ) external {
        ++tried[0];
        uint256 i = _index(who);
        uint256 s = size & 3;
        uint256 units = s == 0 ? 1e18 : (s == 1 ? 5e18 : (s == 2 ? 20e18 : 100e18));
        bytes32 key = keccak256(abi.encode(i, ++keyNonce));
        W.setNextCredit(units);
        bool ok = _call(
            _wallet(i),
            abi.encodeCall(AaveAdapterUserLogic.pledge, (MARKET, PositionRef(INTEGRATION, key), block.timestamp))
        );
        W.setNextCredit(0);
        if (!ok) return;
        ++done[0];
        keys[i][keyNonce % MAX_KEYS] = key;
        credited[i] += units;
        address p = _proxyOf(i);
        _ensure(BAD_SUPPLY, W.supplied(p) == credited[i] && W.creditOf(p, key) == units && VT.balanceOf(p) == 0);
    }

    /// @notice Wallet `who` borrows `frac` (25 %, 50 %, 90 % or 120 %) of its room to the required HF, with
    /// `minHealthFactor` 0, 1.2, 1.5 or 1 (`minHf`); the receiver is the wallet.
    function borrowDebt(
        uint8 who,
        uint8 frac,
        uint8 minHf
    ) external {
        ++tried[1];
        uint256 i = _index(who);
        address p = _proxyOf(i);
        if (p == address(0)) return;
        uint256 m = _minHf(minHf);
        uint256 amount = _borrowAmount(p, _required(m), frac);
        BorActor w = _wallet(i);
        uint256 before = USDC.balanceOf(address(w));
        bool gated = W.state() != PauseState.None || W.isFrozenAddress(address(w));
        if (!_borrow(w, p, amount, m)) return;
        ++done[1];
        booked[i] += amount;
        // INV-024: no borrow under a pause or for a frozen wallet.
        _ensure(BAD_GATE, !gated);
        // INV-025: HF after the borrow is at least max(1, hard floor, minHealthFactor).
        _ensure(BAD_HEALTH, W.healthFactor(p) >= _required(m));
        // INV-020: the receiver got exactly the amount; the proxy keeps nothing.
        _ensure(BAD_FORWARD, USDC.balanceOf(address(w)) == before + amount && USDC.balanceOf(p) == 0);
    }

    /// @dev `frac` (25 %, 50 %, 90 % or 120 %) of the room: the debt at which HF equals `req`, less the debt now.
    function _borrowAmount(
        address p,
        uint256 req,
        uint8 frac
    ) internal view returns (uint256 amount) {
        uint256 maxDebt = W.supplied(p) * W.price() / 1e18 * 8000 * 1e14 / (req * 100);
        uint256 d = W.debt(p);
        uint256 room = maxDebt > d ? maxDebt - d : 0;
        uint256 f = frac & 3;
        amount = f == 0 ? room / 4 : (f == 1 ? room / 2 : (f == 2 ? room * 9 / 10 : room * 12 / 10 + 1));
        if (amount == 0) amount = 1;
    }

    /// @dev `borrow` by wallet `w` to itself at the proxy's current nonce.
    function _borrow(
        BorActor w,
        address p,
        uint256 amount,
        uint256 minHf
    ) internal returns (bool) {
        return _call(
            w,
            abi.encodeCall(
                AaveAdapterUserLogic.borrow,
                (MARKET, DEBT_RESERVE, amount, address(w), block.timestamp, minHf, _s().borrowNonce[p])
            )
        );
    }

    /// @notice A repay of wallet `who`'s debt by the wallet or by a third party (`thirdParty`): a quarter, half, all
    /// with `repayAll`, or twice the debt as the cap (`frac`). A repay never reads the pause state or the freeze.
    function repayDebt(
        uint8 who,
        uint8 frac,
        bool thirdParty
    ) external {
        ++tried[2];
        uint256 i = _index(who);
        address p = _proxyOf(i);
        if (p == address(0)) return;
        uint256 d = W.debt(p);
        if (d == 0) return;
        uint256 f = frac & 3;
        uint256 cap = f == 0 ? d / 4 + 1 : (f == 1 ? d / 2 + 1 : (f == 2 ? d : 2 * d));
        BorActor payer = thirdParty ? PAYER : _wallet(i);
        USDC.mint(address(payer), cap);
        payer.exec(address(USDC), abi.encodeCall(BorToken.approve, (address(this), cap)));
        uint256 before = USDC.balanceOf(address(payer));
        bool ok = _call(
            payer,
            abi.encodeCall(
                AaveAdapterUserLogic.repay, (address(_wallet(i)), MARKET, DEBT_RESERVE, cap, f == 2, block.timestamp)
            )
        );
        payer.exec(address(USDC), abi.encodeCall(BorToken.approve, (address(this), 0)));
        // INV-081: a funded repay completes in every pause state and for a frozen wallet.
        _ensure(BAD_REPAY, ok);
        ++done[2];
        uint256 spent = before - USDC.balanceOf(address(payer));
        booked[i] -= spent;
        _ensure(BAD_REPAY, spent <= cap && W.debt(p) == d - spent && USDC.balanceOf(p) == 0);
    }

    // ─── Properties ───

    /// @notice INV-020: every borrow sent exactly its amount to the receiver.
    function property_borrowForwardsExactly() external view returns (bool) {
        return violations & BAD_FORWARD == 0;
    }

    /// @notice INV-024: no borrow completed under a pause or for a frozen wallet.
    function property_borrowGatedByStops() external view returns (bool) {
        return violations & BAD_GATE == 0;
    }

    /// @notice INV-081: every funded repay completed and spent at most its cap, exactly what the Spoke booked.
    function property_repayAlwaysOpen() external view returns (bool) {
        return violations & BAD_REPAY == 0;
    }
}
