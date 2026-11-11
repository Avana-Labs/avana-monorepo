// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// AWS KMS implementation of KmsKey: an ECC_SECG_P256K1 key with SIGN_VERIFY usage. KMS returns DER signatures;
// they are decoded, normalised to low s (EIP-2) and given the recovery bit that recovers the key's address.

import { GetPublicKeyCommand, KMSClient, SignCommand } from "@aws-sdk/client-kms";
import { type Address, type Hex, bytesToHex, keccak256, recoverAddress, toHex } from "viem";
import type { KmsKey } from "../chain/signer.ts";

const SECP256K1_N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;

/** Reads a DER INTEGER at `offset`; returns its value and the offset after it. */
function derInt(der: Uint8Array, offset: number): [bigint, number] {
  if (der[offset] !== 0x02) throw new Error("KMS signature: expected INTEGER");
  const len = der[offset + 1]!;
  const value = BigInt(bytesToHex(der.slice(offset + 2, offset + 2 + len)));
  return [value, offset + 2 + len];
}

export function awsKmsKey(client: KMSClient, keyId: string): KmsKey & { address(): Promise<Address> } {
  let cachedPublicKey: Hex | undefined;
  const publicKey = async (): Promise<Hex> => {
    if (cachedPublicKey) return cachedPublicKey;
    const out = await client.send(new GetPublicKeyCommand({ KeyId: keyId }));
    if (out.KeySpec !== "ECC_SECG_P256K1" || !out.PublicKey) throw new Error(`KMS key ${keyId} is not a secp256k1 signing key`);
    // SubjectPublicKeyInfo ends with the 65-byte uncompressed point 0x04 || X || Y.
    cachedPublicKey = bytesToHex(out.PublicKey.slice(out.PublicKey.length - 65));
    return cachedPublicKey;
  };
  const address = async (): Promise<Address> => `0x${keccak256(`0x${(await publicKey()).slice(4)}`).slice(-40)}` as Address;

  return {
    keyId,
    publicKey,
    address,
    async signDigest(digest: Hex) {
      const out = await client.send(
        new SignCommand({ KeyId: keyId, Message: Buffer.from(digest.slice(2), "hex"), MessageType: "DIGEST", SigningAlgorithm: "ECDSA_SHA_256" }),
      );
      if (!out.Signature) throw new Error("KMS returned no signature");
      const der = out.Signature;
      const [r, next] = derInt(der, 2);
      let [s] = derInt(der, next);
      if (s > SECP256K1_N / 2n) s = SECP256K1_N - s;
      const rHex = toHex(r, { size: 32 });
      const sHex = toHex(s, { size: 32 });
      const expected = (await address()).toLowerCase();
      for (const yParity of [0, 1] as const) {
        const recovered = await recoverAddress({ hash: digest, signature: { r: rHex, s: sHex, yParity } });
        if (recovered.toLowerCase() === expected) return { r: rHex, s: sHex, yParity };
      }
      throw new Error("KMS signature does not recover to the key's address");
    },
  };
}
