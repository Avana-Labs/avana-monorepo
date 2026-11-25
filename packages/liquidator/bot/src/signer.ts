// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The bot's signer: an encrypted Foundry keystore, decrypted in memory with a password read from a file or typed at a
// hidden prompt. The key is never written, logged or passed on a command line.

import { readFile } from "node:fs/promises";
import { createInterface } from "node:readline";
import { decryptKeystore } from "@avana/services-common/keystore";
import { type LocalAccount } from "viem";
import { privateKeyToAccount } from "viem/accounts";

/** Reads the password without echoing it. */
export function promptPassword(question = "keystore password: "): Promise<string> {
  if (!process.stdin.isTTY) return Promise.reject(new Error("no terminal to prompt on: set LIQUIDATION_BOT_PASSWORD_FILE"));
  return new Promise((ok) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    const mute = rl as unknown as { _writeToOutput: (s: string) => void };
    process.stdout.write(question);
    mute._writeToOutput = () => {};
    rl.question("", (answer) => {
      rl.close();
      process.stdout.write("\n");
      ok(answer);
    });
  });
}

export async function loadSigner(
  keystore: string,
  passwordFile: string | undefined,
  prompt: () => Promise<string> = promptPassword,
): Promise<LocalAccount> {
  const password = passwordFile ? (await readFile(passwordFile, "utf8")).replace(/\r?\n$/, "") : await prompt();
  return privateKeyToAccount(await decryptKeystore(await readFile(keystore, "utf8"), password));
}
