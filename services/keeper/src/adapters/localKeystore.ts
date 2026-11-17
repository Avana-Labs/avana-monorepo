// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The signer of the local anvil rehearsal only (KEEPER_LOCAL_KEYSTORE_<CHAIN>): an encrypted keystore (Web3 Secret
// Storage v3, as `cast wallet import` writes it) and the file holding its password, so the failover drill can run an
// active keeper without a cloud KMS and no key is ever written in plain text. config.ts refuses the variable on every
// network set except `local`; a published or test network deployment signs only through the KMS (Q-245).

import { readFile } from "node:fs/promises";
import { decryptKeystore } from "@avana/services-common/keystore";
import { privateKeyToAccount } from "viem/accounts";
import type { TxSigner } from "../chain/signer.ts";

export interface LocalKeystore {
  /** Path of the keystore JSON. */
  readonly path: string;
  /** Path of the file holding its password (outside the repository). */
  readonly passwordFile: string;
}

export { decryptKeystore };

export async function localKeystoreSigner(ks: LocalKeystore): Promise<TxSigner> {
  const password = (await readFile(ks.passwordFile, "utf8")).replace(/\r?\n$/, "");
  const account = privateKeyToAccount(await decryptKeystore(await readFile(ks.path, "utf8"), password));
  return { address: account.address, signTransaction: (tx) => account.signTransaction(tx) };
}
