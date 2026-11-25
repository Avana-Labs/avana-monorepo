// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// OCR2 transmitter for the test-network feeds (script/deploy/lib/WorldFeeds.sol): builds a report the way Chainlink's
// OCR2 aggregator (libocr 199a6f1, contract2/OCR2Aggregator.sol) decodes it, has f + 1 of the four local oracles sign
// keccak256(abi.encode(keccak256(report), reportContext)) and sends `transmit` from oracle 0. Prices move only this
// way, so round IDs, `updatedAt` and staleness are the aggregator's own. Oracle keys: the encrypted Foundry keystores
// ocr-0 … ocr-3 and the password file in AVANA_OCR_KEYSTORE_DIR, which script/e2e/e2e-local.sh generates for each fresh
// deployment; they are decrypted in memory only.

import {
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
  encodeAbiParameters,
  keccak256,
  parseAbi,
  parseSignature,
} from "viem";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { type PrivateKeyAccount, privateKeyToAccount } from "viem/accounts";
import { decryptKeystore } from "../../../../services/common/src/keystore.ts";

const F = 1;
const ORACLES = 4;

export const OCR2_ABI = parseAbi([
  "function latestConfigDetails() view returns (uint32 configCount, uint32 blockNumber, bytes32 configDigest)",
  "function latestConfigDigestAndEpoch() view returns (bool scanLogs, bytes32 configDigest, uint32 epoch)",
  "function transmit(bytes32[3] reportContext, bytes report, bytes32[] rs, bytes32[] ss, bytes32 rawVs)",
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);

let cachedOracles: Promise<PrivateKeyAccount[]> | undefined;

/**
 * The four oracles, decrypted once per process: the keystore files of AVANA_OCR_KEYSTORES (`;`-separated) with the
 * password of AVANA_OCR_PASSWORD_FILE when both are set, else the keystores `ocr-0` … `ocr-3` and the file `password`
 * of AVANA_OCR_KEYSTORE_DIR (the local rehearsal's and the local stack's).
 */
export function oracleAccounts(): Promise<PrivateKeyAccount[]> {
  const listed = process.env.AVANA_OCR_KEYSTORES?.split(";").filter(Boolean);
  const dir = process.env.AVANA_OCR_KEYSTORE_DIR;
  const files = listed ?? (dir ? Array.from({ length: ORACLES }, (_, i) => join(dir, `ocr-${i}`)) : undefined);
  const passwordFile = listed ? process.env.AVANA_OCR_PASSWORD_FILE : dir ? join(dir, "password") : undefined;
  if (!files || !passwordFile) throw new Error("AVANA_OCR_KEYSTORE_DIR (or AVANA_OCR_KEYSTORES and AVANA_OCR_PASSWORD_FILE) is not set: the oracle keystores");
  if (files.length !== ORACLES) throw new Error(`AVANA_OCR_KEYSTORES must name ${ORACLES} keystores`);
  cachedOracles ??= (async () => {
    const password = readFileSync(passwordFile, "utf8").replace(/\r?\n$/, "");
    return Promise.all(files.map(async (f) => privateKeyToAccount(await decryptKeystore(readFileSync(f, "utf8"), password))));
  })();
  return cachedOracles;
}

/** The arguments of one signed `transmit` call. */
export type TransmitArgs = readonly [readonly [Hex, Hex, Hex], Hex, Hex[], Hex[], Hex];

/**
 * Transmits one report whose three observations are `answer` (8 decimals) to `aggregator`, at the chain's current
 * time. Returns the transaction hash. A later call always uses a later epoch, as a live OCR2 network does.
 */
export async function transmit(client: PublicClient, wallet: WalletClient, aggregator: Address, answer: bigint): Promise<Hex> {
  const oracles = await oracleAccounts();
  return wallet.writeContract({
    account: oracles[0]!,
    chain: null,
    address: aggregator,
    abi: OCR2_ABI,
    functionName: "transmit",
    args: await signedTransmit(client, aggregator, answer),
  });
}

/**
 * The signed arguments of `transmit` for one report of `answer` on `aggregator`, at the chain's current time and the
 * epoch after the aggregator's last one. Sends nothing: the caller sends it from oracle 0.
 */
export async function signedTransmit(client: PublicClient, aggregator: Address, answer: bigint): Promise<TransmitArgs> {
  const oracles = await oracleAccounts();
  const [, digest, epoch] = (await client.readContract({ address: aggregator, abi: OCR2_ABI, functionName: "latestConfigDigestAndEpoch" })) as [
    boolean,
    Hex,
    number,
  ];
  const block = await client.getBlock();
  const report = encodeAbiParameters(
    [{ type: "uint32" }, { type: "bytes32" }, { type: "int192[]" }, { type: "int192" }],
    [Number(block.timestamp), `0x000102${"00".repeat(29)}`, [answer, answer, answer], 0n],
  );
  // Epoch of the next round: one above the last transmitted epoch, round 1 (least-significant byte).
  const epochAndRound = (BigInt(epoch) + 1n) * 256n + 1n;
  const ctx = [digest, `0x${epochAndRound.toString(16).padStart(64, "0")}` as Hex, `0x${"00".repeat(32)}` as Hex] as const;
  const h = keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32[3]" }], [keccak256(report), ctx]));
  const rs: Hex[] = [];
  const ss: Hex[] = [];
  let rawVs = 0n;
  for (let i = 0; i <= F; i++) {
    const sig = parseSignature(await oracles[i]!.sign({ hash: h }));
    rs.push(sig.r);
    ss.push(sig.s);
    rawVs |= BigInt(sig.yParity ?? Number(sig.v! - 27n)) << BigInt(248 - 8 * i);
  }
  return [ctx, report, rs, ss, `0x${rawVs.toString(16).padStart(64, "0")}`];
}
