// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Labels built on the server, where the viewer's currency is unknown: compact USD with a literal "$", percentages,
// short wallets and hashes, chain slugs and default page slugs.

export function compactUsd(value: number): string {
  const abs = Math.abs(value);
  if (abs >= 1_000_000_000) return `$${(value / 1_000_000_000).toFixed(2)}B`;
  if (abs >= 1_000_000) return `$${(value / 1_000_000).toFixed(2)}M`;
  if (abs >= 1_000) return `$${(value / 1_000).toFixed(2)}K`;
  return `$${value.toFixed(2)}`;
}

export function pct(value: number, digits = 2): string {
  return `${value.toFixed(digits)}%`;
}

export function shortWallet(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function shortHash(hash: string): string {
  return hash.slice(0, 10);
}

/** Fee tier label from pips: 100 → "0.01%"; 0 means a dynamic fee. */
export function feeTierLabel(pips: number): string {
  if (pips === 0) return "Dynamic";
  let text = (pips / 10_000).toFixed(4);
  while (text.endsWith("0") && text.split(".")[1]!.length > 2) text = text.slice(0, -1);
  return `${text}%`;
}

const CHAIN_SLUGS: Readonly<Record<number, string>> = { 1: "ethereum", 8453: "base", 11155111: "sepolia", 84532: "base-sepolia" };

export function chainSlug(chainId: number): string {
  return CHAIN_SLUGS[chainId] ?? `chain-${chainId}`;
}

export function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/** A Hub's label: the manifest's, else `hub-` and the first six hex digits of its address. */
export function hubLabel(label: string | null | undefined, hub: string): string {
  return label ?? `hub-${hub.slice(2, 8)}`;
}

/** Default slugs until the listing metadata names the page: unique per scope and stable across refreshes. */
export const defaultSlug = {
  /** A Hub: its manifest label, or its short address for a Hub recorded after the manifest. */
  hub: (chainId: number, hubLabel: string) => `${chainSlug(chainId)}-${slugify(hubLabel)}`,
  /** A Hub asset: the same token on two Hubs has two pages, told apart by the Hub. */
  lend: (chainId: number, hubLabel: string, symbolOrAsset: string) => `${chainSlug(chainId)}-${slugify(hubLabel)}-${slugify(symbolOrAsset)}`,
  asset: (chainId: number, spokeLabel: string, symbolOrAsset: string) => `${chainSlug(chainId)}-${slugify(spokeLabel)}-${slugify(symbolOrAsset)}`,
  pool: (chainId: number, marketId: string) => `${chainSlug(chainId)}-market-${marketId}`,
};
