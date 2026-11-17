// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The test networks' signers and role addresses. Nothing here names a key, a keystore or a file location: everything
// comes from one private file outside the repository, whose path is the environment variable AVANA_TESTNET_CONFIG
// (KEY=VALUE lines, test-network-config.example in this folder):
//   KEYSTORE_DIR, PASSWORD_FILE                the encrypted Foundry keystores and the file of their shared password
//   DEPLOYER, GOVERNANCE, PAYLOADS_CONTROLLER  the keystore (its file name in KEYSTORE_DIR) that signs as each role
//   ORACLES                                    the four OCR2 oracles' keystores, comma-separated
//   TREASURY, KEEPER, AAVE_PROTOCOL_GUARDIAN, EMERGENCY_GUARDIAN, JOINT_CONFIG_SAFE   addresses that sign nothing
//   GAS_VAULT_FUND_WEI_SEPOLIA, GAS_VAULT_FUND_WEI_BASE_SEPOLIA   optional: the chain's gas vault funding (testnet.ts)
// A keystore's address is read from it at run time, decrypted with the password file; no key is written anywhere.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { type PrivateKeyAccount, privateKeyToAccount } from "viem/accounts";
import { decryptKeystore } from "../../../services/keeper/src/adapters/localKeystore.ts";

export const CONFIG_ENV = "AVANA_TESTNET_CONFIG";

/** The roles that sign deploy transactions, each from a keystore. */
export const SIGNER_ROLES = ["deployer", "governance", "payloadsController", "oracle0", "oracle1", "oracle2", "oracle3"] as const;
export type SignerRole = (typeof SIGNER_ROLES)[number];
/** The roles that are only an address. */
export const ADDRESS_ROLES = ["TREASURY", "KEEPER", "AAVE_PROTOCOL_GUARDIAN", "EMERGENCY_GUARDIAN", "JOINT_CONFIG_SAFE"] as const;
export type AddressRole = (typeof ADDRESS_ROLES)[number];
/** The signers that send transactions, so need test ETH (the other three oracles only sign reports). */
export const FUNDED_ROLES = ["deployer", "governance", "payloadsController", "oracle0"] as const satisfies readonly SignerRole[];

export type Address = `0x${string}`;
export interface TestnetRoles {
  readonly signers: Record<SignerRole, Address>;
  readonly addresses: Record<AddressRole, Address>;
}
/** Where each signer's keystore is, from the private file. */
export interface TestnetKeys {
  readonly passwordFile: string;
  readonly keystores: Record<SignerRole, string>;
}

const isAddress = (a: string): a is Address => /^0x[0-9a-fA-F]{40}$/.test(a);

/** KEY=VALUE lines; `#` comments and blank lines are ignored. */
export function parseConfigFile(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const i = line.indexOf("=");
    if (i === -1) throw new Error(`the test-network config file has a line that is not KEY=VALUE: "${line}"`);
    out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return out;
}

/** The keystore paths and the password file the private file names, or every problem with them. */
export function keysOf(f: Record<string, string | undefined>): { keys?: TestnetKeys; errors: string[] } {
  const errors: string[] = [];
  const dir = f.KEYSTORE_DIR;
  if (!dir || !isAbsolute(dir)) errors.push("KEYSTORE_DIR: not an absolute directory");
  if (!f.PASSWORD_FILE || !isAbsolute(f.PASSWORD_FILE)) errors.push("PASSWORD_FILE: not an absolute file path");
  const oracles = (f.ORACLES ?? "").split(",").map((x) => x.trim()).filter(Boolean);
  if (oracles.length !== 4) errors.push("ORACLES: four keystore names, comma-separated");
  const names: Record<SignerRole, string | undefined> = {
    deployer: f.DEPLOYER,
    governance: f.GOVERNANCE,
    payloadsController: f.PAYLOADS_CONTROLLER,
    oracle0: oracles[0],
    oracle1: oracles[1],
    oracle2: oracles[2],
    oracle3: oracles[3],
  };
  for (const [role, n] of Object.entries(names)) if (!n || /[\\/]/.test(n)) errors.push(`${role}: no keystore name (a file name in KEYSTORE_DIR)`);
  if (new Set(Object.values(names)).size !== SIGNER_ROLES.length) errors.push("every signing role needs its own keystore");
  if (errors.length) return { errors };
  return { keys: { passwordFile: f.PASSWORD_FILE!, keystores: Object.fromEntries(Object.entries(names).map(([r, n]) => [r, join(dir!, n!)])) as Record<SignerRole, string> }, errors };
}

/**
 * Checks a set of role addresses: every role present and a valid address, and no account in two roles (the treasury
 * is never the deployer or the keeper, and so on). Returns the errors, none when the roles are sound.
 */
export function checkRoles(signers: Record<string, string | undefined>, addresses: Record<string, string | undefined>): string[] {
  const errors: string[] = [];
  const all: [string, string][] = [];
  for (const k of SIGNER_ROLES) {
    const a = signers[k];
    if (!a || !isAddress(a)) errors.push(`signer ${k}: no keystore`);
    else all.push([`signer ${k}`, a]);
  }
  for (const r of ADDRESS_ROLES) {
    const a = addresses[r];
    if (!a || !isAddress(a)) errors.push(`${r}: not an address`);
    else all.push([r, a]);
  }
  const seen = new Map<string, string>();
  for (const [role, a] of all) {
    const prev = seen.get(a.toLowerCase());
    if (prev) errors.push(`${role} and ${prev} are one account (${a}): every role is its own account`);
    else seen.set(a.toLowerCase(), role);
  }
  return errors;
}

/** The private file, from AVANA_TESTNET_CONFIG. */
export function configFile(): Record<string, string> {
  const path = process.env[CONFIG_ENV];
  if (!path) throw new Error(`${CONFIG_ENV} is not set: it names the private test-network config file`);
  if (!existsSync(path)) throw new Error(`${CONFIG_ENV} names no file`);
  return parseConfigFile(readFileSync(path, "utf8"));
}

let cachedKeys: TestnetKeys | undefined;
export function testnetKeys(): TestnetKeys {
  if (cachedKeys) return cachedKeys;
  const { keys, errors } = keysOf(configFile());
  if (!keys) throw new Error(`the test-network config file is incomplete:\n  ${errors.join("\n  ")}`);
  for (const [role, p] of Object.entries(keys.keystores)) if (!existsSync(p)) throw new Error(`signer ${role}: its keystore is not in KEYSTORE_DIR`);
  if (!existsSync(keys.passwordFile)) throw new Error("PASSWORD_FILE: no such file");
  cachedKeys = keys;
  return keys;
}

function keystoreAddress(path: string, passwordFile: string): Address {
  const r = spawnSync("cast", ["wallet", "address", "--keystore", path, "--password-file", passwordFile], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`a keystore did not open with the password file: ${(r.stderr || r.stdout).trim().split("\n").at(-1)}`);
  return r.stdout.trim() as Address;
}

let cachedRoles: TestnetRoles | undefined;

/** Every role's address: the keystores' (decrypted with the password file) and the private file's. Throws, listing
 * every problem, unless all are present and distinct. */
export function testnetRoles(): TestnetRoles {
  if (cachedRoles) return cachedRoles;
  const keys = testnetKeys();
  const signers = Object.fromEntries(SIGNER_ROLES.map((r) => [r, keystoreAddress(keys.keystores[r], keys.passwordFile)])) as Record<SignerRole, Address>;
  const addresses = configFile() as Record<AddressRole, Address>;
  const errors = checkRoles(signers, addresses);
  if (errors.length) throw new Error(`the test-network roles are not ready:\n  ${errors.join("\n  ")}`);
  cachedRoles = { signers, addresses: Object.fromEntries(ADDRESS_ROLES.map((r) => [r, addresses[r]])) as Record<AddressRole, Address> };
  return cachedRoles;
}

/** What the deploy steps, the feed refresh and the changes runner read (step.sh, scenarios/ocr2.ts, changes.ts). */
export function testnetSignerEnv(): NodeJS.ProcessEnv {
  const { keystores, passwordFile } = testnetKeys();
  const s = testnetRoles().signers;
  const oracles = [keystores.oracle0, keystores.oracle1, keystores.oracle2, keystores.oracle3];
  return {
    AVANA_DEPLOYER: s.deployer,
    // The treasury signs nothing on a test network: the deployer funds the gas vault (12-fund-gas-vault).
    AVANA_GAS_VAULT_FUNDER: s.deployer,
    AVANA_KEYSTORE_PATHS: SIGNER_ROLES.map((r) => keystores[r]).join(";"),
    AVANA_KEYSTORE_PASSWORD_FILE: passwordFile,
    AVANA_SCHEDULE_OPERATIONS: "1",
    AVANA_OCR_KEYSTORES: oracles.join(";"),
    AVANA_OCR_PASSWORD_FILE: passwordFile,
    AVANA_OCR_ORACLES: [s.oracle0, s.oracle1, s.oracle2, s.oracle3].join(","),
  };
}

/** A keystore file as a viem account, decrypted in memory with `passwordFile`. */
export async function keystoreAccount(path: string, passwordFile: string): Promise<PrivateKeyAccount> {
  const password = readFileSync(passwordFile, "utf8").replace(/\r?\n$/, "");
  return privateKeyToAccount(await decryptKeystore(readFileSync(path, "utf8"), password));
}

/** The signer of `role` on a test network. */
export function signerAccount(role: SignerRole): Promise<PrivateKeyAccount> {
  const k = testnetKeys();
  return keystoreAccount(k.keystores[role], k.passwordFile);
}
