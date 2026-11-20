// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-23 Safes, M-25 issuer probes, M-29 GHO base rate and M-27 frontend on scripted reads, and which probes a chain
// runs from its configuration.

import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { CHAINS, type ServiceManifest } from "@avana/services-common";
import { FIXTURE_HUB, FIXTURE_USDC, fixtureHubAsset, fixtureMarkets } from "@avana/services-common/fixtures";
import type { Address } from "viem";
import type { ChainConfig, MonitorConfig } from "../src/config.ts";
import type { Probe } from "../src/probe.ts";
import { probesFor } from "../src/probes.ts";
import { SAFE_GUARD_SLOT, frontendProbe, ghoRateProbe, issuerProbe, m29Gho, safeChanges, safesProbe, withoutNonces, withoutPerLoadValues } from "../src/probes/external.ts";
import { EMPTY_MANIFEST, contextOf, fakeProvider, fixtureSnapshot, on } from "./fakeChain.ts";

const SAFE = "0x00000000000000000000000000000000000005af" as Address;
const block = (n: number) => ({ number: BigInt(n), timestamp: n });

async function run<I>(probe: Probe<I>, p: ReturnType<typeof fakeProvider>, n: number, manifest: ServiceManifest = EMPTY_MANIFEST) {
  const ctx = await contextOf(p, block(n), manifest);
  const input = await probe.read(ctx);
  return { input, findings: probe.evaluate(input, ctx.block) };
}

describe("M-23 Safes", () => {
  it("pages on any change of owners, threshold, guard or modules, after a first read that sets the baseline", async () => {
    let owners = ["0xa", "0xb"];
    let threshold = 2n;
    const p = fakeProvider({ handlers: [on("getOwners", () => owners), on("getThreshold", () => threshold), on("getModulesPaginated", () => [[], "0x1"])] });
    const probe = safesProbe([{ label: "governance", address: SAFE }]);
    expect((await run(probe, p, 1)).findings).toEqual([]);
    expect((await run(probe, p, 2)).findings).toEqual([]);
    owners = ["0xb", "0xc"];
    threshold = 1n;
    p.storage.set(`${SAFE}:${SAFE_GUARD_SLOT}`, `0x${"00".repeat(12)}${"ab".repeat(20)}`);
    const [f] = (await run(probe, p, 3)).findings;
    expect(f).toMatchObject({ signal: "M-23", kind: "event", level: "page", detail: { safe: "governance", owners: "0xa,0xb -> 0xb,0xc", threshold: "2 -> 1", guard: `0x${"00".repeat(20)} -> 0x${"ab".repeat(20)}` } });
  });

  it("compares owner sets regardless of order and case", () => {
    const s = { owners: ["0xA", "0xb"], threshold: "2", guard: "0x0", modules: [] };
    expect(safeChanges(s, { ...s, owners: ["0xB", "0xa"] })).toEqual({});
  });

  it("reports an unreadable Safe as unread", async () => {
    const probe = safesProbe([{ label: "g", address: SAFE }]);
    expect((await run(probe, fakeProvider(), 1)).findings.map((f) => f.kind)).toEqual(["unread"]);
  });
});

describe("M-25 issuer probes", () => {
  it("warns when a token's pause or fee changes, and on first sight of a paused token or a fee", async () => {
    let paused = false;
    const usdt = fixtureMarkets[0]!.tokens[1]!.toLowerCase();
    const p = fakeProvider({ handlers: [on("paused", () => paused, FIXTURE_USDC), on("basisPointsRate", () => 5n, usdt)] });
    const probe = issuerProbe();
    const first = (await run(probe, p, 1)).findings;
    expect(first.map((f) => f.subject)).toEqual([`token:${usdt}`]); // USDT's fee is not 0
    expect((await run(probe, p, 2)).findings).toEqual([]);
    paused = true;
    const [f] = (await run(probe, p, 3)).findings;
    expect(f).toMatchObject({ signal: "M-25", level: "warn", subject: `token:${FIXTURE_USDC}`, detail: { paused: "false -> true" } });
  });
});

describe("M-29 GHO base rate", () => {
  const GHO = "0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f";
  const manifest = { ...EMPTY_MANIFEST, debtReserves: [{ asset: GHO, isGho: true }] } as unknown as ServiceManifest;
  const ghoSnapshot = (b: { number: bigint; timestamp: number }) => fixtureSnapshot(b, (s) => ({ ...s, hubAssets: [{ ...fixtureHubAsset, underlying: GHO as Address, rateCurve: { ...fixtureHubAsset.rateCurve!, baseDrawnRateBps: 400 } }] }));

  it("pages while an Avana Hub's GHO base rate is below the Core Hub's", async () => {
    let core = 450n;
    const IRS = "0x00000000000000000000000000000000000000c1";
    const p = fakeProvider({ snapshot: ghoSnapshot, handlers: [on("getAssetConfig", () => ({ feeReceiver: IRS, liquidityFee: 0, irStrategy: IRS, reinvestmentController: IRS })), on("getInterestRateData", () => ({ optimalUsageRatio: 8_000, baseDrawnRate: Number(core), rateGrowthBeforeOptimal: 0, rateGrowthAfterOptimal: 0 }), IRS)] });
    const probe = ghoRateProbe({ hub: "0x00000000000000000000000000000000000000c0", assetId: 3n });
    const subject = `hubAsset:${FIXTURE_HUB}:1:ghoBase`;
    expect((await run(probe, p, 1, manifest)).findings).toEqual([{ signal: "M-29", kind: "condition", level: "page", subject, detail: { baseDrawnRateBps: "400", coreHubBaseDrawnRateBps: "450" } }]);
    core = 400n;
    expect((await run(probe, p, 2, manifest)).findings[0]!.level).toBe("ok");
    expect(m29Gho(399n, 400n)).toBe("page");
  });

  it("reports unread when the Core Hub read fails", async () => {
    const probe = ghoRateProbe({ hub: "0x00000000000000000000000000000000000000c0", assetId: 3n });
    expect((await run(probe, fakeProvider({ snapshot: ghoSnapshot }), 1, manifest)).findings.map((f) => f.kind)).toEqual(["unread"]);
  });
});

describe("M-27 frontend", () => {
  const body = "<html>app</html>";
  const sha = createHash("sha256").update(body).digest("hex");

  it("pages on a bundle hash other than the released one and warns on DNS and hosting changes", async () => {
    const state = { body, server: "cloudflare", dns: "A=1.1.1.1" };
    const deps = { fetchText: async () => ({ body: state.body, server: state.server }), resolve: async () => state.dns };
    const probe = frontendProbe({ url: "https://app.example", expectedSha256: `0x${sha}` }, deps);
    const p = fakeProvider();
    expect((await run(probe, p, 1)).findings.map((f) => `${f.subject}:${f.level}`)).toEqual(["frontend:bundle:ok"]);
    Object.assign(state, { body: "<html>evil</html>", dns: "A=6.6.6.6", server: "nginx" });
    expect((await run(probe, p, 2)).findings.map((f) => `${f.subject}:${f.level}`)).toEqual(["frontend:bundle:page", "frontend:dns:warn", "frontend:hosting:warn"]);
  });

  it("warns on a hash change when no released hash is configured", async () => {
    let page = "a";
    const probe = frontendProbe({ url: "https://app.example", expectedSha256: null }, { fetchText: async () => ({ body: page, server: "" }), resolve: async () => "" });
    const p = fakeProvider();
    expect((await run(probe, p, 1)).findings).toEqual([]);
    page = "b";
    expect((await run(probe, p, 2)).findings.map((f) => `${f.subject}:${f.kind}:${f.level}`)).toEqual(["frontend:bundle:event:warn"]);
  });

  it("ignores the per-load CSP nonce, wherever the page repeats it, and Sentry's trace tags, but not a change of the page", async () => {
    let n = 0;
    let app = "app";
    const page = () => {
      const nonce = btoa(`${String(++n).padStart(8, "0")}-0000-4000-8000-000000000000`);
      const trace = String(n).padStart(32, "0");
      const sentry = `<meta name="sentry-trace" content="${trace}-${"a".repeat(16)}-${n % 2}"/><meta name="baggage" content="sentry-trace_id=${trace},sentry-sampled=${n % 2 === 1},sentry-sample_rand=0.${n}"/>`;
      return `<html>${sentry}<script nonce="${nonce}">theme()</script><script>self.__next_f.push([1,"{\\"nonce\\":\\"${nonce}\\"}"])</script>${app}</html>`;
    };
    const probe = frontendProbe({ url: "https://app.example", expectedSha256: null }, { fetchText: async () => ({ body: page(), server: "" }), resolve: async () => "" });
    const p = fakeProvider();
    expect((await run(probe, p, 1)).findings).toEqual([]);
    expect((await run(probe, p, 2)).findings).toEqual([]);
    app = "evil";
    expect((await run(probe, p, 3)).findings.map((f) => `${f.subject}:${f.kind}:${f.level}`)).toEqual(["frontend:bundle:event:warn"]);
  });

  it("blanks the app's nonce wherever it appears and leaves a page without one as served", () => {
    const nonce = btoa(crypto.randomUUID());
    expect(withoutNonces(`<script nonce="${nonce}">x</script><link rel="preload" nonce="${nonce}">"${nonce}"`)).toBe(`<script nonce="">x</script><link rel="preload" nonce="">""`);
    expect(withoutNonces("<html>app</html>")).toBe("<html>app</html>");
  });

  it("hashes the page as served when a nonce is not the app's, or the page carries two", () => {
    const a = btoa(crypto.randomUUID());
    const b = btoa(crypto.randomUUID());
    const injected = `<script nonce="${a}">x</script><script nonce="x><script src=//evil.example/a.js></script>">y</script>`;
    expect(withoutNonces(injected)).toBe(injected);
    const two = `<script nonce="${a}">x</script><script nonce="${b}">y</script>`;
    expect(withoutNonces(two)).toBe(two);
    const unquoted = `<script nonce=${a}>x</script>`;
    expect(withoutNonces(unquoted)).toBe(unquoted);
  });

  it("blanks Sentry's per-request trace values in their exact format and keeps the rest of its tags", () => {
    const hex = (n: number) => Array.from({ length: n }, () => Math.floor(Math.random() * 16).toString(16)).join("");
    const tags = (trace: string, sampled: string, rand: string) =>
      `<meta name="sentry-trace" content="${trace}-${hex(16)}-${sampled === "true" ? 1 : 0}"/><meta name="baggage" content="sentry-environment=production,sentry-release=abc,sentry-trace_id=${trace},sentry-sampled=${sampled},sentry-sample_rand=${rand},sentry-sample_rate=0.1"/>`;
    const blanked = `<meta name="sentry-trace" content=""/><meta name="baggage" content="sentry-environment=production,sentry-release=abc,sentry-trace_id=,sentry-sampled=,sentry-sample_rand=,sentry-sample_rate=0.1"/>`;
    expect(withoutPerLoadValues(tags(hex(32), "false", "0.6561982643347349"))).toBe(blanked);
    expect(withoutPerLoadValues(tags(hex(32), "true", "0.02"))).toBe(blanked);
    // A changed release, or anything but a trace value where one belongs, is hashed as served.
    expect(withoutPerLoadValues(tags(hex(32), "false", "0.5").replace("release=abc", "release=def"))).not.toBe(blanked);
    const injected = `<meta name="sentry-trace" content="x"/><script src=//evil.example/a.js></script>"/>`;
    expect(withoutPerLoadValues(injected)).toBe(injected);
    const baggage = `<meta name="baggage" content="sentry-trace_id=</script><script>x()</script>"/>`;
    expect(withoutPerLoadValues(baggage)).toBe(baggage);
  });
});

describe("probesFor", () => {
  const chain = { chain: CHAINS.mainnet } as ChainConfig;
  const base = { safes: new Map(), coreHubGho: new Map(), frontend: null, keeperWallets: { warnWei: null, pageWei: null, extra: new Map() } } as unknown as MonitorConfig;
  const deps = { fetchText: async () => ({ body: "", server: "" }), resolve: async () => "" };

  it("runs the protocol probes everywhere and the others only where configured", () => {
    expect(probesFor(chain, base, deps).map((p) => p.name)).toEqual(["snapshot", "oracle", "coverage", "markets", "wallets", "events", "issuers"]);
    const full = { ...base, safes: new Map([[1, [{ label: "g", address: SAFE }]]]), coreHubGho: new Map([[1, { hub: SAFE, assetId: 1n }]]), frontend: { url: "https://x", expectedSha256: null, chainId: 1 } } as unknown as MonitorConfig;
    expect(probesFor(chain, full, deps).map((p) => p.name)).toEqual(["snapshot", "oracle", "coverage", "markets", "wallets", "events", "issuers", "safes", "ghoRate", "frontend"]);
    expect(probesFor({ chain: CHAINS.base } as ChainConfig, full, deps).map((p) => p.name)).toEqual(["snapshot", "oracle", "coverage", "markets", "wallets", "events", "issuers"]);
  });
});
