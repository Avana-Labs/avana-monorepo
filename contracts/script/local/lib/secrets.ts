// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The stack's local secrets (the fork RPC URLs, ETHEREUM_FORK_RPC_URL and BASE_FORK_RPC_URL): never in the repository,
// never on a command line. They are kept in STACK/keystore/secrets.enc, next to the Foundry keystores, encrypted with
// AES-256-GCM under a key derived (scrypt) from the keystores' password file, and decrypted when the stack starts.
// A variable set in the environment takes precedence over the file.

import { createCipheriv, createDecipheriv, randomBytes, scryptSync } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { KEYSTORE, PASSWORD_FILE } from "./keys.ts";

export const SECRETS_FILE = join(KEYSTORE, "secrets.enc");
export const SECRET_NAMES = ["ETHEREUM_FORK_RPC_URL", "BASE_FORK_RPC_URL"] as const;

function key(salt: Buffer): Buffer {
  if (!existsSync(PASSWORD_FILE)) throw new Error(`no password file ${PASSWORD_FILE}: run the stack's up or deploy command once`);
  return scryptSync(readFileSync(PASSWORD_FILE, "utf8").trim(), salt, 32);
}

export function readSecrets(): Record<string, string> {
  return existsSync(SECRETS_FILE) ? readSecretsAt(SECRETS_FILE, key) : {};
}

/** The secrets file `file` of a checkout, its key derived from that checkout's password file `passwordFile` (the
 * test-network app reads the secrets of the checkout that deployed). Empty when the file does not exist. */
export function readSecretsFile(file: string, passwordFile: string): Record<string, string> {
  if (!existsSync(file)) return {};
  if (!existsSync(passwordFile)) throw new Error(`no password file next to ${file}`);
  return readSecretsAt(file, (salt) => scryptSync(readFileSync(passwordFile, "utf8").trim(), salt, 32));
}

function readSecretsAt(file: string, keyOf: (salt: Buffer) => Buffer): Record<string, string> {
  const raw = Buffer.from(readFileSync(file, "utf8").trim(), "base64");
  const [salt, iv, tag, data] = [raw.subarray(0, 16), raw.subarray(16, 28), raw.subarray(28, 44), raw.subarray(44)];
  const d = createDecipheriv("aes-256-gcm", keyOf(salt), iv);
  d.setAuthTag(tag);
  return JSON.parse(Buffer.concat([d.update(data), d.final()]).toString("utf8")) as Record<string, string>;
}

function writeSecrets(values: Record<string, string>): void {
  const salt = randomBytes(16);
  const iv = randomBytes(12);
  const c = createCipheriv("aes-256-gcm", key(salt), iv);
  const data = Buffer.concat([c.update(JSON.stringify(values), "utf8"), c.final()]);
  writeFileSync(SECRETS_FILE, Buffer.concat([salt, iv, c.getAuthTag(), data]).toString("base64"), { mode: 0o600 });
}

/** The secret `name`: the environment's value, else the encrypted file's; undefined when neither holds it. */
export function secretValue(name: (typeof SECRET_NAMES)[number]): string | undefined {
  return process.env[name]?.trim() || readSecrets()[name] || undefined;
}

/** Asks for each secret without echoing it and stores the answers (an empty answer keeps the stored value). */
export async function promptSecrets(say: (s: string) => void): Promise<void> {
  const current = readSecrets();
  const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  let muted = false;
  const out = rl as unknown as { _writeToOutput: (s: string) => void; output: NodeJS.WriteStream };
  const write = out._writeToOutput.bind(rl);
  out._writeToOutput = (s: string) => {
    if (!muted || s.includes("\n")) write(muted ? "\n" : s);
  };
  const ask = (q: string) =>
    new Promise<string>((resolve) => {
      rl.question(q, (a) => resolve(a.trim()));
      muted = true;
    });
  for (const n of SECRET_NAMES) {
    muted = false;
    const a = await ask(`${n}${current[n] ? " (stored; Enter keeps it)" : ""}: `);
    if (a) current[n] = a;
  }
  rl.close();
  writeSecrets(current);
  say(`stored ${Object.keys(current).filter((k) => current[k]).join(", ") || "nothing"} in ${SECRETS_FILE} (encrypted)`);
}
