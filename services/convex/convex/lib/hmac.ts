// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Signs an export request (services/indexer/EXPORT.md, "Authentication"):
// `hex(HMAC-SHA256(secret, timestamp + "\n" + METHOD + "\n" + path?query))` with Web Crypto.

export async function signRequest(secretBase64: string, keyId: string, method: string, pathAndQuery: string, nowSeconds: number): Promise<Record<string, string>> {
  const secret = Uint8Array.from(atob(secretBase64), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("raw", secret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const message = new TextEncoder().encode(`${nowSeconds}\n${method.toUpperCase()}\n${pathAndQuery}`);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, message));
  return {
    "x-avana-key-id": keyId,
    "x-avana-timestamp": String(nowSeconds),
    "x-avana-signature": [...mac].map((b) => b.toString(16).padStart(2, "0")).join(""),
  };
}
