// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs

import { randomBytes } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { loadSigner } from "../src/signer.ts";
import { encryptKeystore } from "./keystore.ts";

const dir = mkdtempSync(join(tmpdir(), "liquidator-keystore-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

const key = generatePrivateKey();
const address = privateKeyToAccount(key).address;
const password = randomBytes(16).toString("hex");
const keystore = join(dir, "signer");
const passwordFile = join(dir, "password");
writeFileSync(keystore, encryptKeystore(key, password));
writeFileSync(passwordFile, `${password}\n`, { mode: 0o600 });

describe("keystore signer", () => {
  it("decrypts with the password file", async () => {
    expect((await loadSigner(keystore, passwordFile)).address).toBe(address);
  });

  it("decrypts with the prompt when there is no password file", async () => {
    expect((await loadSigner(keystore, undefined, async () => password)).address).toBe(address);
  });

  it("fails on a wrong password", async () => {
    await expect(loadSigner(keystore, undefined, async () => "wrong")).rejects.toThrow(/MAC/);
  });

  it("signs with the decrypted key", async () => {
    const signer = await loadSigner(keystore, passwordFile);
    const sig = await signer.signMessage({ message: "avana" });
    expect(sig).toBe(await privateKeyToAccount(key).signMessage({ message: "avana" }));
  });
});
