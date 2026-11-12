// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Export authentication (EXPORT.md, "Authentication"): HMAC-SHA256 over timestamp, method and path with query, under
// a key from INDEXER_EXPORT_KEYS, inside a 60-second window.

import { Hono } from "hono";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MAX_CLOCK_SKEW_SECONDS, requireExportAuth, signatureFor } from "../src/api/auth.ts";

const SECRET = Buffer.alloc(32, 7);
const ROTATED = Buffer.alloc(32, 9);
const PATH = "/export/v1/pages?chainId=1&after=10";

function app() {
  vi.stubEnv("INDEXER_EXPORT_KEYS", `k1:${SECRET.toString("base64")},k2:${ROTATED.toString("base64")}`);
  const a = new Hono();
  a.use("/export/*", requireExportAuth());
  a.get("/export/v1/pages", (c) => c.json({ ok: true }));
  return a;
}

function request(a: Hono, headers: Record<string, string>, path = PATH, method = "GET") {
  return a.request(`http://indexer${path}`, { method, headers });
}

const now = () => String(Math.floor(Date.now() / 1000));
const signed = (keyId: string, secret: Buffer, ts = now(), path = PATH) => ({
  "x-avana-key-id": keyId,
  "x-avana-timestamp": ts,
  "x-avana-signature": signatureFor(secret, ts, "get", path),
});

afterEach(() => vi.unstubAllEnvs());

describe("requireExportAuth", () => {
  it("accepts a fresh request signed with either configured key", async () => {
    const a = app();
    expect((await request(a, signed("k1", SECRET))).status).toBe(200);
    expect((await request(a, signed("k2", ROTATED))).status).toBe(200);
  });

  it("refuses a signature made with another key's secret", async () => {
    expect((await request(app(), signed("k1", ROTATED))).status).toBe(401);
  });

  it("refuses an unknown key ID", async () => {
    expect((await request(app(), signed("k3", SECRET))).status).toBe(401);
  });

  it("binds the signature to the query string", async () => {
    const headers = signed("k1", SECRET);
    expect((await request(app(), headers, "/export/v1/pages?chainId=1&after=11")).status).toBe(401);
  });

  it("refuses a timestamp outside the clock-skew window", async () => {
    const stale = String(Math.floor(Date.now() / 1000) - MAX_CLOCK_SKEW_SECONDS - 5);
    expect((await request(app(), signed("k1", SECRET, stale))).status).toBe(401);
    expect((await request(app(), signed("k1", SECRET, "12abc"))).status).toBe(401);
  });

  it("refuses a truncated signature without comparing unequal lengths", async () => {
    const headers = signed("k1", SECRET);
    headers["x-avana-signature"] = headers["x-avana-signature"].slice(0, 10);
    expect((await request(app(), headers)).status).toBe(401);
  });

  it("stops startup on a key shorter than 32 bytes or an empty key list", () => {
    vi.stubEnv("INDEXER_EXPORT_KEYS", `k1:${Buffer.alloc(16).toString("base64")}`);
    expect(() => requireExportAuth()).toThrow(/shorter than 32 bytes/);
    vi.stubEnv("INDEXER_EXPORT_KEYS", "");
    expect(() => requireExportAuth()).toThrow(/is empty/);
  });
});
