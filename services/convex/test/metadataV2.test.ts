// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Listing metadata version 2: project links and risk text per entry, bounded FAQs, Lend entries with symbol and
// category; version 1 files stay valid but may not carry the new fields. The risk text feeds the risk cards.

import { describe, expect, it } from "vitest";
import { fixtureMarkets } from "@avana/services-common/fixtures";
import { MAX_FAQS, MetadataRejected, metadataHash, parseMetadata } from "../convex/lib/metadata.ts";
import { contentRiskAssessment, poolRiskAssessment } from "../convex/lib/riskViews.ts";
import type { PageRisk } from "../convex/lib/uiTypes.ts";

const risk: PageRisk = {
  summary: "USDC is a fiat-backed stablecoin; the main risks are issuer and depeg risk.",
  factors: [
    { id: "issuer", label: "Issuer", level: "moderate", text: "Reserves are held by a single issuer." },
    { id: "depeg", label: "Depeg", level: "low", text: "Redeemable one to one." },
  ],
};
const lend = {
  scope: "lend",
  key: "0x1111111111111111111111111111111111111111:1",
  slug: "ethereum-usdc",
  name: "USDC",
  symbol: "USDC",
  category: "stable",
  description: "USD Coin on the Stable LP Hub.",
  stats: [],
  history: [],
  faqs: [{ question: "Who can supply?", answer: "Any wallet." }],
  links: { website: "https://www.circle.com", x: "https://x.com/circle", docs: "https://developers.circle.com/", audits: [{ label: "Audit 2026", href: "https://example.org/audit.pdf" }] },
  risk,
};
const parse = (f: unknown) => {
  const b = new TextEncoder().encode(JSON.stringify(f));
  return () => parseMetadata(b, metadataHash(b), 1);
};

describe("listing metadata version 2", () => {
  it("loads links and risk text", () => {
    const file = parse({ version: 2, chainId: 1, entries: [lend] })();
    expect(file.entries[0]!.links?.x).toBe("https://x.com/circle");
    expect(file.entries[0]!.risk?.factors).toHaveLength(2);
  });

  it("requires a Lend entry to name its symbol and category", () => {
    const { symbol: _s, ...noSymbol } = lend;
    const { category: _c, ...noCategory } = lend;
    expect(parse({ version: 2, chainId: 1, entries: [noSymbol] })).toThrow(/symbol and category/);
    expect(parse({ version: 2, chainId: 1, entries: [noCategory] })).toThrow(/symbol and category/);
  });

  it("refuses unsafe or unknown links, malformed risk text and too many FAQs", () => {
    const v2 = (e: Record<string, unknown>) => parse({ version: 2, chainId: 1, entries: [{ ...lend, ...e }] });
    expect(v2({ links: { website: "http://circle.com" } })).toThrow(/https/);
    expect(v2({ links: { website: "javascript:alert(1)" } })).toThrow(/https/);
    expect(v2({ links: { x: "https://evil.example/circle" } })).toThrow(/x.com/);
    expect(v2({ links: { telegram: "https://t.me/x" } })).toThrow(/unknown link/);
    expect(v2({ risk: { summary: "", factors: [] } })).toThrow(/summary/);
    expect(v2({ risk: { ...risk, factors: [risk.factors[0], risk.factors[0]] } })).toThrow(/unique/);
    expect(v2({ risk: { ...risk, factors: [{ ...risk.factors[0], level: "severe" }] } })).toThrow(/level/);
    expect(v2({ faqs: Array.from({ length: MAX_FAQS + 1 }, (_, i) => ({ question: `Q${i}?`, answer: "A." })) })).toThrow(/FAQs/);
  });

  it("keeps version 1 files valid and refuses version 2 fields in them", () => {
    const { links: _l, risk: _r, ...v1 } = lend;
    expect(parse({ version: 1, chainId: 1, entries: [v1] })().entries).toHaveLength(1);
    expect(parse({ version: 1, chainId: 1, entries: [lend] })).toThrow(MetadataRejected);
    expect(parse({ version: 3, chainId: 1, entries: [v1] })).toThrow(/version/);
  });
});

describe("listing metadata version 2: review day, factor bps, dependencies, disclosures, tokens", () => {
  const v2 = (entries: unknown[]) => parse({ version: 2, chainId: 1, entries });
  const pool = { scope: "pool", key: "7", slug: "usdc-usdt", name: "USDC / USDT", description: "", stats: [], history: [], faqs: [] };
  const dep = { kind: "oracle", label: "USDC / USD (primary)", address: "0x2222222222222222222222222222222222222222" };

  it("loads a market's review day, factor bps and dependencies", () => {
    const r = { ...risk, reviewedAt: "2026-11-16", factors: [{ ...risk.factors[0], bps: 40 }], dependencies: [dep] };
    const e = v2([{ ...pool, risk: r }])().entries[0]!;
    expect(e.risk).toMatchObject({ reviewedAt: "2026-11-16", factors: [{ bps: 40 }], dependencies: [dep] });
  });

  it("refuses a malformed review day, bps or dependency", () => {
    const bad = (r: Record<string, unknown>) => v2([{ ...pool, risk: { ...risk, ...r } }]);
    expect(bad({ reviewedAt: "16/11/2026" })).toThrow(/reviewedAt/);
    expect(bad({ reviewedAt: "2026-02-30" })).toThrow(/reviewedAt/);
    expect(bad({ factors: [{ ...risk.factors[0], bps: 12.5 }] })).toThrow(/bps/);
    expect(bad({ factors: [{ ...risk.factors[0], bps: 10_001 }] })).toThrow(/bps/);
    expect(bad({ dependencies: [{ ...dep, kind: "bridge" }] })).toThrow(/dependency/);
    expect(bad({ dependencies: [{ ...dep, address: "0xABCDEF0000000000000000000000000000000000" }] })).toThrow(/lower-case address/);
  });

  it("takes disclosures on a Hub entry only", () => {
    const hub = { scope: "hub", key: "0x3333333333333333333333333333333333333333", slug: "avana-ethereum-hub", name: "Avana Ethereum Hub", description: "", stats: [], history: [], faqs: [] };
    expect(v2([{ ...hub, disclosures: { borrow: "Borrowing risks.", lend: "Supplying risks." } }])().entries[0]!.disclosures).toEqual({ borrow: "Borrowing risks.", lend: "Supplying risks." });
    expect(v2([{ ...hub, disclosures: { swap: "x" } }])).toThrow(/unknown disclosure/);
    expect(v2([{ ...pool, disclosures: { borrow: "x" } }])).toThrow(/only a Hub entry/);
    expect(parse({ version: 1, chainId: 1, entries: [{ ...hub, disclosures: { borrow: "x" } }] })).toThrow(/version 2/);
  });

  it("requires a token entry to name its symbol", () => {
    const token = { scope: "token", key: "0x4444444444444444444444444444444444444444", slug: "aero", name: "Aerodrome", description: "", stats: [], history: [], faqs: [] };
    expect(v2([{ ...token, symbol: "AERO", iconUrl: "https://example.org/aero.png" }])().entries[0]!.symbol).toBe("AERO");
    expect(v2([token])).toThrow(/token entry names its symbol/);
  });
});

describe("risk cards from listed risk text", () => {
  it("rates a Lend or asset card by its worst factor and hides it without text", () => {
    expect(contentRiskAssessment(risk, "USDC risk")).toMatchObject({ level: "moderate", summary: risk.summary, breakdown: [{ id: "issuer" }, { id: "depeg" }] });
    expect(contentRiskAssessment(undefined, "USDC risk")).toBeNull();
  });

  it("adds a pool's listed factors after its collateral risk premium", () => {
    const card = poolRiskAssessment(fixtureMarkets[0]!, risk);
    expect(card.breakdown.map((b) => b.id)).toEqual(["collateralRisk", "issuer", "depeg"]);
    expect(card.summary).toBe(risk.summary);
    expect(poolRiskAssessment(fixtureMarkets[0]!).breakdown).toHaveLength(1);
  });

  it("splits a pool's premium over its listed factors when the listing gives their bps", () => {
    const split = { ...risk, factors: risk.factors.map((x, i) => ({ ...x, bps: i === 0 ? 30 : 10 })) };
    const card = poolRiskAssessment(fixtureMarkets[0]!, split);
    expect(card.breakdown.map((b) => [b.id, b.bps])).toEqual([["issuer", 30], ["depeg", 10]]);
    expect(card.premiumBps).toBe(fixtureMarkets[0]!.collateralRiskBps);
  });
});
