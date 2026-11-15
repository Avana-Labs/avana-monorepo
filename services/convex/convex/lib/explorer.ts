// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Block explorer links per chain. The base URL comes from the chain's `deployments` row (written from its release
// manifest); a local chain has none, and a row with no explorer gets no links rather than a link to another chain.

const HASH = /^0x[0-9a-fA-F]{64}$/;
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;

export interface ExplorerLinks {
  readonly base: string;
  tx(hash: string): string | undefined;
  address(address: string): string | undefined;
  block(number: string | number | bigint): string | undefined;
}

/** Links under `base`; undefined for a malformed hash, address or block, so a bad value never becomes a link. */
export function explorerLinks(base: string | null | undefined): ExplorerLinks | null {
  if (!base || !/^https:\/\/[^\s/]+(\/[^\s]*)?$/.test(base)) return null;
  const root = base.replace(/\/+$/, "");
  return {
    base: root,
    tx: (hash) => (HASH.test(hash) ? `${root}/tx/${hash.toLowerCase()}` : undefined),
    address: (a) => (ADDRESS.test(a) ? `${root}/address/${a.toLowerCase()}` : undefined),
    block: (n) => (/^\d+$/.test(String(n)) ? `${root}/block/${String(n)}` : undefined),
  };
}
