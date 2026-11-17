// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Decrypts an encrypted Foundry keystore (Web3 Secret Storage v3, as `cast wallet new` and `cast wallet import` write
// it) in memory, for the services that sign from one: the keeper on a development node (KEEPER_LOCAL_KEYSTORE_<CHAIN>)
// and the faucet on a test network (FAUCET_SIGNER_KEYSTORE). The key is never written anywhere.

import { createDecipheriv, pbkdf2Sync, scrypt } from "node:crypto";
import { type Hex, bytesToHex, concat, hexToBytes, keccak256 } from "viem";

interface KeystoreV3 {
  readonly version: number;
  readonly crypto: {
    readonly cipher: string;
    readonly ciphertext: string;
    readonly cipherparams: { readonly iv: string };
    readonly kdf: "scrypt" | "pbkdf2";
    readonly kdfparams: { readonly dklen: number; readonly salt: string; readonly n?: number; readonly r?: number; readonly p?: number; readonly c?: number; readonly prf?: string };
    readonly mac: string;
  };
}

const unhex = (s: string) => hexToBytes(s.startsWith("0x") ? (s as Hex) : (`0x${s}` as Hex));

function derive(k: KeystoreV3["crypto"], password: string): Promise<Uint8Array> {
  const salt = unhex(k.kdfparams.salt);
  const dklen = k.kdfparams.dklen;
  if (k.kdf === "pbkdf2") {
    if (k.kdfparams.prf !== "hmac-sha256") throw new Error(`keystore pbkdf2 prf ${k.kdfparams.prf} is not supported`);
    return Promise.resolve(new Uint8Array(pbkdf2Sync(password, salt, k.kdfparams.c!, dklen, "sha256")));
  }
  if (k.kdf !== "scrypt") throw new Error(`keystore kdf ${k.kdf} is not supported`);
  const { n, r, p } = k.kdfparams as { n: number; r: number; p: number };
  return new Promise((ok, fail) =>
    scrypt(password, salt, dklen, { N: n, r, p, maxmem: 256 * n * r + 1024 * 1024 }, (e, key) => (e ? fail(e) : ok(new Uint8Array(key)))),
  );
}

/** Decrypts a v3 keystore; a wrong password or a changed file fails the MAC check. */
export async function decryptKeystore(json: string, password: string): Promise<Hex> {
  const ks = JSON.parse(json) as KeystoreV3;
  if (ks.version !== 3) throw new Error(`keystore version ${ks.version} is not 3`);
  const k = ks.crypto;
  if (k.cipher !== "aes-128-ctr") throw new Error(`keystore cipher ${k.cipher} is not supported`);
  const key = await derive(k, password);
  const ciphertext = unhex(k.ciphertext);
  const mac = keccak256(concat([key.slice(16, 32), ciphertext]));
  if (mac.slice(2).toLowerCase() !== k.mac.replace(/^0x/, "").toLowerCase()) throw new Error("keystore MAC mismatch: wrong password or a changed file");
  const decipher = createDecipheriv("aes-128-ctr", key.slice(0, 16), unhex(k.cipherparams.iv));
  const plain = new Uint8Array([...decipher.update(ciphertext), ...decipher.final()]);
  if (plain.length !== 32) throw new Error("keystore does not hold a 32-byte key");
  return bytesToHex(plain);
}
