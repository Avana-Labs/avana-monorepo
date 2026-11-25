// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Request authentication for the private export (EXPORT.md, "Authentication"): HMAC-SHA256 over the timestamp,
// method and path with query, under a key ID from INDEXER_EXPORT_KEYS. Two keys are accepted during a rotation.

import { createHmac, timingSafeEqual } from "node:crypto";
import type { MiddlewareHandler } from "hono";
import { listEnv } from "@avana/services-common";

/** Requests older or newer than this are refused, which bounds the replay window. */
export const MAX_CLOCK_SKEW_SECONDS = 60;

function loadKeys(): Map<string, Buffer> {
  const keys = new Map<string, Buffer>();
  for (const entry of listEnv(process.env, "INDEXER_EXPORT_KEYS")) {
    const [id, secret] = entry.split(":");
    if (!id || !secret) throw new Error("INDEXER_EXPORT_KEYS entries must be id:base64secret");
    const bytes = Buffer.from(secret, "base64");
    if (bytes.length < 32) throw new Error(`export key ${id} is shorter than 32 bytes`);
    keys.set(id, bytes);
  }
  if (keys.size === 0) throw new Error("INDEXER_EXPORT_KEYS is empty: the export refuses every request");
  return keys;
}

export function signatureFor(secret: Buffer, timestamp: string, method: string, pathWithQuery: string): string {
  return createHmac("sha256", secret).update(`${timestamp}\n${method.toUpperCase()}\n${pathWithQuery}`).digest("hex");
}

export function requireExportAuth(): MiddlewareHandler {
  const keys = loadKeys();
  return async (c, next) => {
    const keyId = c.req.header("x-avana-key-id") ?? "";
    const timestamp = c.req.header("x-avana-timestamp") ?? "";
    const given = c.req.header("x-avana-signature") ?? "";
    const secret = keys.get(keyId);
    const now = Math.floor(Date.now() / 1000);
    if (!secret || !/^\d+$/.test(timestamp) || Math.abs(now - Number(timestamp)) > MAX_CLOCK_SKEW_SECONDS) {
      return c.json({ error: "unauthorized" }, 401);
    }
    const url = new URL(c.req.url);
    const expected = Buffer.from(signatureFor(secret, timestamp, c.req.method, url.pathname + url.search), "hex");
    const provided = Buffer.from(given, "hex");
    if (provided.length !== expected.length || !timingSafeEqual(provided, expected)) {
      return c.json({ error: "unauthorized" }, 401);
    }
    await next();
  };
}
