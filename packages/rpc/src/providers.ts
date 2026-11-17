// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// RPC providers: each turns its credentials and a chain into an HTTP or WebSocket endpoint. The URL formulas and the
// network slugs mirror the Aave toolbox (aave-dao/toolkit packages/toolbox src/ecosystem/rpcs.ts getAlchemyRPC and
// getQuicknodeRpc, and its generated network maps), with the wss forms added. A new provider is one more entry of
// PROVIDERS: its id, the variables holding its credentials, its chains and its URL builder.

export type EndpointKind = "http" | "ws";
/** Provider credentials by variable name (ALCHEMY_API_KEY, QUICKNODE_ENDPOINT_NAME, QUICKNODE_TOKEN, …). */
export type Credentials = Readonly<Record<string, string | undefined>>;

export interface RpcProvider {
  readonly id: string;
  /** The variables holding the provider's credentials, all required; each value is a secret. */
  readonly credentialNames: readonly string[];
  /** The chain's network slug, or undefined when the provider does not serve the chain. */
  slug(chainId: number): string | undefined;
  /** The endpoint (a secret: it carries the credentials). Called only when every credential is set. */
  url(chainId: number, kind: EndpointKind, credentials: Credentials): string;
}

export class ProviderConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProviderConfigError";
  }
}

/** A credential placed in a host name or path: refused unless it is a plain token (it is never echoed). */
function token(credentials: Credentials, name: string, pattern: RegExp): string {
  const v = credentials[name]?.trim();
  if (!v) throw new ProviderConfigError(`${name} is not set`);
  if (!pattern.test(v)) throw new ProviderConfigError(`${name} has characters an endpoint cannot carry`);
  return v;
}

const scheme = (kind: EndpointKind) => (kind === "http" ? "https" : "wss");

/** Alchemy: <slug>.g.alchemy.com/v2/<key> (toolbox getAlchemyRPC; slugs from its alchemyNetworkMap). */
export const alchemy: RpcProvider = {
  id: "alchemy",
  credentialNames: ["ALCHEMY_API_KEY"],
  slug: (chainId) => ({ 1: "eth-mainnet", 11155111: "eth-sepolia", 8453: "base-mainnet", 84532: "base-sepolia" })[chainId],
  url(chainId, kind, credentials) {
    const key = token(credentials, "ALCHEMY_API_KEY", /^[A-Za-z0-9_-]+$/);
    return `${scheme(kind)}://${this.slug(chainId)}.g.alchemy.com/v2/${key}`;
  },
};

/**
 * QuickNode: <endpoint name>.<slug>.quiknode.pro/<token> (toolbox getQuicknodeRpc; slugs from its quicknodeNetworkMap).
 * Ethereum mainnet's endpoint has no slug, as in the toolbox.
 */
export const quicknode: RpcProvider = {
  id: "quicknode",
  credentialNames: ["QUICKNODE_ENDPOINT_NAME", "QUICKNODE_TOKEN"],
  slug: (chainId) => ({ 1: "", 11155111: "ethereum-sepolia", 8453: "base-mainnet", 84532: "base-sepolia" })[chainId],
  url(chainId, kind, credentials) {
    const name = token(credentials, "QUICKNODE_ENDPOINT_NAME", /^[a-z0-9-]+$/i);
    const t = token(credentials, "QUICKNODE_TOKEN", /^[A-Za-z0-9_-]+$/);
    const slug = this.slug(chainId);
    return `${scheme(kind)}://${name}${slug ? `.${slug}` : ""}.quiknode.pro/${t}`;
  },
};

/** Every known provider, by id. The default order is DEFAULT_PROVIDER_ORDER. */
export const PROVIDERS: Readonly<Record<string, RpcProvider>> = { alchemy, quicknode };
/** Alchemy primary, QuickNode backup. */
export const DEFAULT_PROVIDER_ORDER: readonly string[] = ["alchemy", "quicknode"];

/** Whether every credential of the provider is set. */
export const configured = (p: RpcProvider, credentials: Credentials) => p.credentialNames.every((n) => !!credentials[n]?.trim());
