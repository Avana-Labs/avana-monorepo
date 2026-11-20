// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Test helper: a Web3 Secret Storage v3 keystore written the way `cast wallet import` writes one, for a key made at run
// time. No key is stored in the repository.

import { createCipheriv, randomBytes, scryptSync } from "node:crypto";
import { type Hex, bytesToHex, concat, hexToBytes, keccak256 } from "viem";

const N = 1 << 10; // a low scrypt cost keeps the test fast; Foundry writes 2^13

export function encryptKeystore(key: Hex, password: string): string {
  const salt = randomBytes(32);
  const iv = randomBytes(16);
  const derived = scryptSync(password, salt, 32, { N, r: 8, p: 1 });
  const cipher = createCipheriv("aes-128-ctr", derived.subarray(0, 16), iv);
  const ciphertext = new Uint8Array([...cipher.update(hexToBytes(key)), ...cipher.final()]);
  const mac = keccak256(concat([new Uint8Array(derived.subarray(16, 32)), ciphertext]));
  return JSON.stringify({
    version: 3,
    id: "00000000-0000-4000-8000-000000000000",
    crypto: {
      cipher: "aes-128-ctr",
      ciphertext: bytesToHex(ciphertext).slice(2),
      cipherparams: { iv: iv.toString("hex") },
      kdf: "scrypt",
      kdfparams: { dklen: 32, n: N, r: 8, p: 1, salt: salt.toString("hex") },
      mac: mac.slice(2),
    },
  });
}
