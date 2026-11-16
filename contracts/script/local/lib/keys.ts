// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The stack's signers, each an encrypted Foundry keystore made by `cast wallet new` with one random password kept in a
// file only the user reads (the password reaches cast through CAST_PASSWORD, never a command line). No key is ever
// written in clear, passed as an argument or kept in an env file.
//   deployer   deploys and runs every release step on both chains (the operator's signer)
//   keeper     the keeper's signer and the operator helper's signer of each chain's config (the liquidation bot)
//   treasury   the fee recipient (ParameterStore.feeRecipient): the liquidation fee share and the front-end fee
//   faucet     the webapp's test-funds faucet (gas and test tokens)
//   activity-funds  the test tokens the activity loop gives its simulated users
//   ocr-0..3   the four OCR2 oracles that sign every price report of the local feeds
// The governance Safe, the guardians and the Aave executor are multisig and governance stand-ins: anvil's unlocked
// senders (--auto-impersonate), as in the rehearsal.

import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { join } from "node:path";
import { STACK } from "./env.ts";

export const KEYSTORE = join(STACK, "keystore");
export const PASSWORD_FILE = join(KEYSTORE, "password");
export const KEY_NAMES = ["deployer", "keeper", "treasury", "faucet", "activity-funds", "ocr-0", "ocr-1", "ocr-2", "ocr-3"] as const;
export type KeyName = (typeof KEY_NAMES)[number];
const ADDRESSES = join(KEYSTORE, "addresses.json");

export const keystorePath = (name: KeyName) => join(KEYSTORE, name);

function cast(args: string[], env: NodeJS.ProcessEnv = {}): string {
  const r = spawnSync("cast", args, { encoding: "utf8", env: { ...process.env, ...env } });
  if (r.status !== 0) throw new Error(`cast ${args[0]} ${args[1] ?? ""}: ${(r.stderr || r.stdout).trim().split("\n").slice(-2).join(" ")}`);
  return r.stdout.trim();
}

/** Makes every missing keystore; existing ones are kept (a stack restarted on its saved chains reuses them). */
export function ensureKeys(): Record<KeyName, `0x${string}`> {
  mkdirSync(KEYSTORE, { recursive: true });
  try {
    chmodSync(KEYSTORE, 0o700);
  } catch {}
  if (!existsSync(PASSWORD_FILE)) writeFileSync(PASSWORD_FILE, randomBytes(32).toString("hex"), { mode: 0o600 });
  const password = readFileSync(PASSWORD_FILE, "utf8").trim();
  for (const n of KEY_NAMES) {
    if (!existsSync(keystorePath(n))) cast(["wallet", "new", KEYSTORE, n], { CAST_PASSWORD: password });
  }
  const known = existsSync(ADDRESSES) ? (JSON.parse(readFileSync(ADDRESSES, "utf8")) as Record<string, `0x${string}`>) : {};
  const out = {} as Record<KeyName, `0x${string}`>;
  for (const n of KEY_NAMES) {
    out[n] = known[n] ?? (cast(["wallet", "address", "--keystore", keystorePath(n), "--password-file", PASSWORD_FILE]) as `0x${string}`);
  }
  writeFileSync(ADDRESSES, `${JSON.stringify(out, null, 2)}\n`);
  // The deployer, the keeper (the liquidation bot) and the fee recipient are three different accounts.
  const roles = [out.deployer, out.keeper, out.treasury].map((a) => a.toLowerCase());
  if (new Set(roles).size !== roles.length) throw new Error("the deployer, keeper and treasury keystores must be three different accounts");
  return out;
}

export function addresses(): Record<KeyName, `0x${string}`> {
  if (!existsSync(ADDRESSES)) throw new Error(`no keystores in ${KEYSTORE}: run the stack's up command first`);
  return JSON.parse(readFileSync(ADDRESSES, "utf8")) as Record<KeyName, `0x${string}`>;
}

/** What the deploy steps and the feed refresh read (script/deploy/step.sh, refresh-feeds.ts). */
export function signerEnv(): NodeJS.ProcessEnv {
  const a = addresses();
  return {
    AVANA_DEPLOYER: a.deployer,
    AVANA_DEPLOYER_KEYSTORE: keystorePath("deployer"),
    AVANA_DEPLOYER_PASSWORD_FILE: PASSWORD_FILE,
    AVANA_OCR_KEYSTORE_DIR: KEYSTORE,
    AVANA_OCR_ORACLES: [a["ocr-0"], a["ocr-1"], a["ocr-2"], a["ocr-3"]].join(","),
  };
}
