# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""ERC-20 ledger shared by every token in the model.

Every movement of value goes through `transfer`, `mint` or `burn`, so per-token conservation
(sum of balances == total supply) holds by construction and every supply change is logged.

Token edge cases (Q-217, Q-271, Q-278):
  * every token reverts on a zero-amount transfer, mint or burn (worst case of Q-217);
  * an issuer can pause a token (every transfer reverts) or blocklist an address (transfers from or to it revert);
  * a token can charge a fee on transfer (the USDT fee switch): the recipient receives `amount − fee` and the issuer
    the fee; transfers into a Uniswap pool are exempt so the pool model stays exact (Uniswap's own balance checks
    are outside this model), while every transfer out of a pool, between Avana contracts, routes and wallets pays it;
  * a token can call back into the system on transfer (`hooks`), which tests use to attempt reentrancy.
"""
from .mathlib import chk

DECIMALS = {"USDC": 6, "USDT": 6, "DAI": 18, "GHO": 18}
ISSUER = "token_issuer"


class InsufficientBalance(Exception):
    pass


class ZeroTransfer(Exception):
    """Raised by tokens that revert on a zero-amount transfer (every token in the model does, Q-217)."""


class TokenBlocked(Exception):
    """The token refuses a transfer (issuer pause, blocklist, or a recipient that refuses delivery)."""


class Ledger:
    def __init__(self):
        self.bal = {}            # (token, holder) -> amount
        self.supply = {}         # token -> total supply
        self.mint_log = []       # (token, holder, +amount / -amount, tag)
        self.strict_zero = True
        self.blocked = set()     # (token, recipient) pairs the token refuses to deliver to
        self.blocklist = set()   # (token, address) issuer blocklist: transfers from or to revert
        self.paused = set()      # tokens whose issuer paused every transfer
        self.fee_bps = {}        # token -> transfer fee (bps)
        self.hooks = {}          # token -> callable(frm, to, amount) run after each transfer

    def balance(self, token, holder):
        return self.bal.get((token, holder), 0)

    def fee_of(self, token, to, amount):
        f = self.fee_bps.get(token, 0)
        if not f or to.startswith("pool:") or to == ISSUER:
            return 0
        return amount * f // 10_000

    def transfer(self, token, frm, to, amount):
        chk(amount)
        if amount == 0:
            if self.strict_zero:
                raise ZeroTransfer(f"{token}: zero-amount transfer {frm} -> {to}")
            return
        if token in self.paused:
            raise TokenBlocked(f"{token}: paused by the issuer")
        if (token, frm) in self.blocklist or (token, to) in self.blocklist:
            raise TokenBlocked(f"{token}: blocklisted address in {frm} -> {to}")
        if (token, to) in self.blocked:
            raise TokenBlocked(f"{token}: transfer to {to} refused")
        b = self.balance(token, frm)
        if b < amount:
            raise InsufficientBalance(f"{token}: {frm} has {b} < {amount}")
        fee = self.fee_of(token, to, amount)
        self.bal[(token, frm)] = b - amount
        self.bal[(token, to)] = self.balance(token, to) + amount - fee
        if fee:
            self.bal[(token, ISSUER)] = self.balance(token, ISSUER) + fee
        hook = self.hooks.get(token)
        if hook is not None:
            hook(frm, to, amount)

    def mint(self, token, to, amount, tag):
        chk(amount)
        if amount == 0 and self.strict_zero:
            raise ZeroTransfer(f"{token}: zero-amount mint")
        self.bal[(token, to)] = self.balance(token, to) + amount
        self.supply[token] = chk(self.supply.get(token, 0) + amount)
        self.mint_log.append((token, to, amount, tag))

    def burn(self, token, frm, amount, tag):
        if amount == 0 and self.strict_zero:
            raise ZeroTransfer(f"{token}: zero-amount burn")
        b = self.balance(token, frm)
        if b < amount:
            raise InsufficientBalance(f"burn {token}: {frm} has {b} < {amount}")
        self.bal[(token, frm)] = b - amount
        self.supply[token] -= amount
        self.mint_log.append((token, frm, -amount, tag))

    def holders(self, token):
        return {h: v for (t, h), v in self.bal.items() if t == token and v}

    def total(self, token):
        return sum(v for (t, _h), v in self.bal.items() if t == token)
