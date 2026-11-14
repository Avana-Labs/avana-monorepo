// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Writes src/addresses/generated.ts from deployments/verified/, or checks that the committed file is current.
//
//   node src/addresses/cli.ts                       # write (npm run addresses)
//   node src/addresses/cli.ts --check               # exit 1 if the committed file differs (npm run check-addresses)
//   node src/addresses/cli.ts --deployments <dir> --out <file>

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readAddressBook, renderAddressBook } from "./generate.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "../../../..");

const opt = (name: string): string | undefined => {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? undefined : process.argv[i + 1];
};
const deploymentsDir = resolve(opt("deployments") ?? join(REPO, "deployments"));
const out = resolve(opt("out") ?? join(HERE, "generated.ts"));

const book = readAddressBook(deploymentsDir);
const text = renderAddressBook(book);
const chains = Object.keys(book.deployments).length;

if (process.argv.includes("--check")) {
  if (!existsSync(out) || readFileSync(out, "utf8") !== text) {
    console.error(`stale: ${out}; run \`npm run addresses -w packages/protocol\` and commit the result`);
    process.exit(1);
  }
  console.log(`${out} is current (${chains} chains)`);
} else {
  writeFileSync(out, text);
  console.log(`wrote ${out} (${chains} chains)`);
}
