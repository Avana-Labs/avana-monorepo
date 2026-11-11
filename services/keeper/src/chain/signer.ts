// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The instance's signer: a non-exportable secp256k1 key in a cloud KMS or HSM (Q-245). The keeper asks for a
// signature over a digest under its own service identity; every request is logged by the KMS. No raw key is ever
// in an environment variable, a file or an image.

import { type Address, type Hex, type TransactionSerializable, keccak256, serializeTransaction } from "viem";

/** The KMS operations the keeper uses. One implementation per provider (AWS KMS is the first). */
export interface KmsKey {
  readonly keyId: string;
  /** Uncompressed secp256k1 public key, read once at startup. */
  publicKey(): Promise<Hex>;
  /** Signs a 32-byte digest; returns r, s and the recovery bit with low-s normalisation. */
  signDigest(digest: Hex): Promise<{ r: Hex; s: Hex; yParity: 0 | 1 }>;
}

export interface TxSigner {
  readonly address: Address;
  signTransaction(tx: TransactionSerializable): Promise<Hex>;
}

/** Wraps a KMS key as a transaction signer; the address is derived from the KMS public key, not configured. */
export function kmsSigner(key: KmsKey, address: Address): TxSigner {
  return {
    address,
    async signTransaction(tx) {
      const digest = keccak256(serializeTransaction(tx));
      const { r, s, yParity } = await key.signDigest(digest);
      return serializeTransaction(tx, { r, s, yParity });
    },
  };
}
