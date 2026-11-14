# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Addresses, IDs and the revert helper shared by the Avana model modules."""
from .tokens import InsufficientBalance, ZeroTransfer, TokenBlocked
from .mathlib import Overflow
from .aave import AaveError

GHO, USDC_DEBT = "GHO", "USDC"
HUB, LPVAULT, COLL, ADAPTER, SWAP = "hub", "lpvault", "collateralization", "aave_adapter", "lpvaultswap"
FEE_RECIPIENT, FLASH_SOURCE, DEX = "avana_fee", "aave_v3_pool_flash_source", "dex"
ARB, FAUCET_TAG, ESCROW = "arb", "faucet", "inkind_escrow"
LEND_SPOKE = "lend_spoke"
COV = {GHO: "cov:GHO", USDC_DEBT: "cov:USDC"}
CDP, TIER2 = "cdp", "tier2"
GHO_RID, USDC_RID = 0, 1
DEBT_RIDS = {GHO_RID: GHO, USDC_RID: USDC_DEBT}
NONE, FROZEN, PAUSED = "None", "Frozen", "Paused"
GENERAL, MINT_PATH_SUSPECT = "General", "MintPathSuspect"
GUARDIANS = ("emergency_guardian", "aave_guardian")


class AvanaError(Exception):
    pass


REVERTS = (AvanaError, AaveError, InsufficientBalance, ZeroTransfer, TokenBlocked, Overflow, PermissionError,
           ValueError)


def need(cond, err):
    if not cond:
        raise AvanaError(err)
