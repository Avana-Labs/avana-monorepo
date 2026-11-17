// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Which failures move a request to the backup provider. Only infrastructure failures do: a timeout, a connection
// error, a rate limit, a server error, a refused credential, a malformed answer or a stale head. A contract revert or
// an invalid request is the same on every provider, so it is returned to the caller at once, never retried.

export type InfraFailure = "timeout" | "connection" | "rate-limit" | "server" | "auth" | "malformed" | "stale";

/** Messages a node gives for a request or a transaction that is wrong in itself (any provider would refuse it). */
const NOT_INFRA = /revert|nonce too low|nonce too high|insufficient funds|intrinsic gas|underpriced|already known|known transaction|invalid (argument|params|sender|signature|transaction)|gas required exceeds|exceeds (block )?gas limit|max fee per gas less than|out of gas|EOA nonce changed/i;
const RATE = /rate.?limit|too many requests|exceeded .*(capacity|limit|quota)|compute units|request limit|throughput/i;
const TIMEOUT = /timed? ?out|timeout|deadline exceeded/i;
const STALE = /header not found|missing trie node|block not found|unknown block|state (is )?not available/i;
const CONNECTION = /error sending request|connection (refused|reset|closed|aborted)|socket hang up|ECONNREFUSED|ECONNRESET|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|EPIPE|dns error|tcp connect error|fetch failed|network error|socket has been closed/i;
const SERVER = /bad gateway|service unavailable|gateway timeout|internal server error|\b50[0234]\b/i;

const codeOf = (e: Record<string, unknown>) => (typeof e.code === "number" ? e.code : undefined);

/**
 * The infrastructure failure `error` is, or undefined when it is not one (a revert, an invalid request, an abort):
 * walks viem's error chain (RpcRequestError and its typed subclasses, HttpRequestError, TimeoutError,
 * SocketClosedError, WebSocketRequestError) down to the cause.
 */
export function classifyError(error: unknown): InfraFailure | undefined {
  const chain: Record<string, unknown>[] = [];
  for (let e = error; e && typeof e === "object" && chain.length < 10; e = (e as { cause?: unknown }).cause) chain.push(e as Record<string, unknown>);
  if (chain.length === 0) return undefined;
  const text = chain.map((e) => [e.shortMessage, e.details, e.message].filter((x) => typeof x === "string").join(" ")).join(" ");
  if (chain.some((e) => e.name === "AbortError")) return undefined;
  if (chain.some((e) => e.name === "InvalidRpcResponseError")) return "malformed";
  if (chain.some((e) => e.name === "StaleHeadError")) return "stale";
  // A JSON-RPC error object: the node answered, so the code (and for -32000, the message) decides.
  const coded = chain.find((e) => codeOf(e) !== undefined && codeOf(e) !== -1);
  if (coded) {
    const code = codeOf(coded)!;
    if (code === 429 || code === -32005 || code === -32007) return "rate-limit";
    if (NOT_INFRA.test(text)) return undefined;
    if (code === -32603 || code === -32000 || code === -32001 || code === -32002) {
      if (RATE.test(text)) return "rate-limit";
      if (STALE.test(text)) return "stale";
      if (TIMEOUT.test(text)) return "timeout";
      if (CONNECTION.test(text)) return "connection";
      if (SERVER.test(text) || code === -32603 || code === -32002) return "server";
    }
    return undefined;
  }
  if (chain.some((e) => e.name === "TimeoutError")) return "timeout";
  if (chain.some((e) => e.name === "SocketClosedError" || e.name === "WebSocketRequestError")) return "connection";
  // A WebSocket's own error event (the socket failed or closed under a request in flight).
  if (chain.some((e) => e.type === "error" && "target" in e)) return "connection";
  const http = chain.find((e) => e.name === "HttpRequestError");
  if (http) {
    const status = typeof http.status === "number" ? http.status : undefined;
    if (status === undefined) return chain.some((e) => e.name === "SyntaxError") ? "malformed" : "connection";
    if (status === 429) return "rate-limit";
    if (status === 408 || status === 504) return "timeout";
    if (status >= 500) return "server";
    // 401/403/404: the credential is refused or the network is not enabled for it; another provider may serve.
    if (status === 401 || status === 403 || status === 404) return "auth";
    // 400, 413 and the rest: the request itself.
    return undefined;
  }
  if (NOT_INFRA.test(text)) return undefined;
  if (TIMEOUT.test(text)) return "timeout";
  if (CONNECTION.test(text)) return "connection";
  return undefined;
}

/**
 * The infrastructure failure a tool's output reports (forge, cast: they print the RPC error as text), or undefined.
 * Output that also reports a revert or a nonce mismatch is never an infrastructure failure: rerunning elsewhere would
 * not help, and could send again.
 */
export function classifyText(text: string): InfraFailure | undefined {
  if (NOT_INFRA.test(text)) return undefined;
  if (RATE.test(text) || /\b429\b|-32005|-32007/.test(text)) return "rate-limit";
  if (STALE.test(text)) return "stale";
  if (TIMEOUT.test(text)) return "timeout";
  if (CONNECTION.test(text)) return "connection";
  if (SERVER.test(text)) return "server";
  return undefined;
}

/** A response that is not what the method returns (not JSON-RPC, the wrong type, another chain). */
export class InvalidRpcResponseError extends Error {
  constructor(method: string, why: string) {
    super(`invalid RPC response to ${method}: ${why}`);
    this.name = "InvalidRpcResponseError";
  }
}

/** A head behind the best head seen, or too old. */
export class StaleHeadError extends Error {
  constructor(why: string) {
    super(`stale head: ${why}`);
    this.name = "StaleHeadError";
  }
}

/** Every provider of the chain failed the request with an infrastructure failure. */
export class RpcUnavailableError extends Error {
  readonly chainId: number;
  readonly method: string;
  readonly attempts: readonly { provider: string; failure: InfraFailure }[];
  constructor(chainId: number, method: string, attempts: readonly { provider: string; failure: InfraFailure }[], cause: unknown) {
    super(`chain ${chainId}: ${method} failed on every provider after ${attempts.length} attempts (${attempts.map((a) => `${a.provider} ${a.failure}`).join(", ")})`, { cause });
    this.name = "RpcUnavailableError";
    this.chainId = chainId;
    this.method = method;
    this.attempts = attempts;
  }
}

/**
 * A transaction whose sending failed in a way that leaves its fate unknown, and whose hash and nonce the other
 * providers could not settle: it was not sent again. Wait for `hash` (or the sender's nonce) before anything else.
 */
export class TransactionOutcomeUnknownError extends Error {
  readonly hash: `0x${string}` | undefined;
  readonly nonce: number | undefined;
  constructor(hash: `0x${string}` | undefined, nonce: number | undefined, why: string, cause?: unknown) {
    super(`transaction ${hash ?? "(hash unknown)"}${nonce === undefined ? "" : ` (nonce ${nonce})`}: outcome unknown, not sent again: ${why}`, { cause });
    this.name = "TransactionOutcomeUnknownError";
    this.hash = hash;
    this.nonce = nonce;
  }
}

/** The transaction's nonce was used by another transaction: sending it again could never succeed. */
export class NonceConsumedError extends Error {
  readonly hash: `0x${string}`;
  readonly nonce: number;
  constructor(hash: `0x${string}`, nonce: number) {
    super(`transaction ${hash}: nonce ${nonce} was used by another transaction`);
    this.name = "NonceConsumedError";
    this.hash = hash;
    this.nonce = nonce;
  }
}
