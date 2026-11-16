// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The keystore signer exists only for the local anvil rehearsal: KEEPER_LOCAL_KEYSTORE_<CHAIN> is refused on every other
// network set, so a published or test-network keeper signs only through the KMS (Q-245). The key is generated for each
// run and only ever stored encrypted, in a temporary keystore written the way `cast wallet import` writes one.

import { createCipheriv, randomBytes, scryptSync } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { type Hex, bytesToHex, concat, hexToBytes, keccak256 } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { CHAINS } from "@avana/services-common";
import { decryptKeystore, localKeystoreSigner } from "../src/adapters/localKeystore.ts";
import { localKeystore } from "../src/config.ts";

const N = 1 << 10; // a low scrypt cost keeps the test fast; Foundry writes 2^13

/** A Web3 Secret Storage v3 keystore of `key` under `password` (scrypt, aes-128-ctr, keccak256 MAC). */
function encrypt(key: Hex, password: string): string {
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

const dir = mkdtempSync(join(tmpdir(), "keeper-keystore-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

const key = generatePrivateKey();
const password = randomBytes(16).toString("hex");
const path = join(dir, "signer");
const passwordFile = join(dir, "password");
writeFileSync(path, encrypt(key, password));
writeFileSync(passwordFile, `${password}\n`, { mode: 0o600 });

describe("local rehearsal keystore", () => {
  // A development node standing in for Ethereum (CHAIN_ID_MAINNET=31337).
  const dev = { ...CHAINS.mainnet, id: 31337 };
  it("is read on a development node, with its password file", () => {
    expect(localKeystore({ KEEPER_LOCAL_KEYSTORE_MAINNET: path, KEEPER_LOCAL_KEYSTORE_PASSWORD_FILE: passwordFile }, dev)).toEqual({ path, passwordFile });
    expect(localKeystore({}, dev)).toBeUndefined();
    expect(() => localKeystore({ KEEPER_LOCAL_KEYSTORE_MAINNET: path }, dev)).toThrow(/PASSWORD_FILE/);
  });

  it("is refused on production and test networks", () => {
    for (const chain of [CHAINS.mainnet, CHAINS.base, CHAINS.sepolia, CHAINS.baseSepolia]) {
      expect(() => localKeystore({ [`KEEPER_LOCAL_KEYSTORE_${chain.envSuffix}`]: path, KEEPER_LOCAL_KEYSTORE_PASSWORD_FILE: passwordFile }, chain)).toThrow(/only on a development node/);
    }
  });

  it("decrypts to the key it was made from and signs as its account", async () => {
    expect(await decryptKeystore(encrypt(key, password), password)).toBe(key);
    const signer = await localKeystoreSigner({ path, passwordFile });
    expect(signer.address).toBe(privateKeyToAccount(key).address);
  });

  it("refuses a wrong password or a changed file", async () => {
    await expect(decryptKeystore(encrypt(key, password), "wrong")).rejects.toThrow(/MAC mismatch/);
    const changed = JSON.parse(encrypt(key, password));
    changed.crypto.ciphertext = `${changed.crypto.ciphertext.slice(0, -2)}00`;
    await expect(decryptKeystore(JSON.stringify(changed), password)).rejects.toThrow(/MAC mismatch/);
  });
});
