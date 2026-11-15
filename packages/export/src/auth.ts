// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Request authentication of the private export (services/indexer/EXPORT.md, "Authentication"):
// `x-avana-signature = hex(HMAC-SHA256(secret, timestamp + "\n" + METHOD + "\n" + path?query))`. Web Crypto only, so
// the same code signs in Convex, Node and a browser test, and verifies in any of them.

export const KEY_ID_HEADER = "x-avana-key-id";
export const TIMESTAMP_HEADER = "x-avana-timestamp";
export const SIGNATURE_HEADER = "x-avana-signature";

/** Requests older or newer than this are refused, which bounds the replay window. */
export const MAX_CLOCK_SKEW_SECONDS = 60;

/** A key shorter than this is refused when it is loaded. */
export const MIN_SECRET_BYTES = 32;

export type SignedHeaders = Readonly<Record<typeof KEY_ID_HEADER | typeof TIMESTAMP_HEADER | typeof SIGNATURE_HEADER, string>>;

export function decodeSecret(secretBase64: string): Uint8Array {
  const bytes = Uint8Array.from(atob(secretBase64), (c) => c.charCodeAt(0));
  if (bytes.length < MIN_SECRET_BYTES) throw new Error(`export secret is ${bytes.length} bytes; at least ${MIN_SECRET_BYTES} are required`);
  return bytes;
}

/** `id:base64secret` entries, comma or newline separated; two entries during a rotation. */
export function parseKeys(list: string): Map<string, Uint8Array> {
  const keys = new Map<string, Uint8Array>();
  for (const entry of list.split(/[,\n]/).map((s) => s.trim()).filter(Boolean)) {
    const at = entry.indexOf(":");
    const id = entry.slice(0, at);
    if (at <= 0 || at === entry.length - 1) throw new Error("export keys are id:base64secret");
    if (keys.has(id)) throw new Error(`export key ${id} is listed twice`);
    keys.set(id, decodeSecret(entry.slice(at + 1)));
  }
  if (keys.size === 0) throw new Error("no export key is configured");
  return keys;
}

async function mac(secret: Uint8Array, timestamp: string, method: string, pathAndQuery: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", secret as Uint8Array<ArrayBuffer>, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const message = new TextEncoder().encode(`${timestamp}\n${method.toUpperCase()}\n${pathAndQuery}`);
  const out = new Uint8Array(await crypto.subtle.sign("HMAC", key, message));
  return [...out].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function signRequest(secretBase64: string, keyId: string, method: string, pathAndQuery: string, nowSeconds: number): Promise<SignedHeaders> {
  const timestamp = String(Math.floor(nowSeconds));
  return {
    [KEY_ID_HEADER]: keyId,
    [TIMESTAMP_HEADER]: timestamp,
    [SIGNATURE_HEADER]: await mac(decodeSecret(secretBase64), timestamp, method, pathAndQuery),
  };
}

function equalConstantTime(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export type VerifyResult = { readonly ok: true; readonly keyId: string } | { readonly ok: false; readonly reason: "unknownKey" | "badTimestamp" | "stale" | "badSignature" };

/** Checks the three headers against the listed keys. `header` reads a request header by lower-case name. */
export async function verifyRequest(
  keys: ReadonlyMap<string, Uint8Array>,
  header: (name: string) => string | null | undefined,
  method: string,
  pathAndQuery: string,
  nowSeconds: number,
): Promise<VerifyResult> {
  const keyId = header(KEY_ID_HEADER) ?? "";
  const timestamp = header(TIMESTAMP_HEADER) ?? "";
  const given = (header(SIGNATURE_HEADER) ?? "").toLowerCase();
  const secret = keys.get(keyId);
  if (!secret) return { ok: false, reason: "unknownKey" };
  if (!/^\d{1,12}$/.test(timestamp)) return { ok: false, reason: "badTimestamp" };
  if (Math.abs(Math.floor(nowSeconds) - Number(timestamp)) > MAX_CLOCK_SKEW_SECONDS) return { ok: false, reason: "stale" };
  const expected = await mac(secret, timestamp, method, pathAndQuery);
  return equalConstantTime(expected, given) ? { ok: true, keyId } : { ok: false, reason: "badSignature" };
}
