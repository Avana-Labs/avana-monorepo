// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A raw-key signer for the local anvil rehearsal only (KEEPER_LOCAL_KEY_ANVIL): the rehearsal binds the operator
// helper to one of anvil's published test accounts, whose key is public, so the failover drill can run an active
// keeper without a cloud KMS. config.ts refuses the variable on every network set except `local`; a published or test
// network deployment signs only through the KMS (Q-245).

import type { Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { TxSigner } from "../chain/signer.ts";

export function localKeySigner(privateKey: Hex): TxSigner {
  const account = privateKeyToAccount(privateKey);
  return { address: account.address, signTransaction: (tx) => account.signTransaction(tx) };
}
