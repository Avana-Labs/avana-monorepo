// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Alert lifecycle (one notice per open, level change, resolution or event), routing to responders and the signers
// on pages, the refusal of a routing table that leaves anyone out, and the incident-log line.

import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { AlertBook, type Evaluation } from "../src/alertBook.ts";
import { fileIncidentLog, incidentEntry } from "../src/incidentLog.ts";
import { RECIPIENTS, type Recipient, channelsOf, checkRouting, recipientsOf } from "../src/routing.ts";
import type { Finding, Notice } from "../src/types.ts";

const f = (signal: Finding["signal"], level: Finding["level"], subject = "market:1", kind: Finding["kind"] = "condition"): Finding => ({ signal, kind, level, subject, detail: {} });
const ev = (block: bigint, findings: Finding[], complete = true, source: Evaluation["source"] = "snapshot"): Evaluation => ({ source, chainId: 1, blockNumber: block, timestamp: Number(block) * 12, findings, complete });
const brief = (ns: Notice[]) => ns.map((n) => `${n.transition}:${n.alert.signal}:${n.alert.level}:${n.alert.subject}`);

describe("AlertBook", () => {
  it("opens, stays quiet at the same level, escalates, de-escalates and resolves", () => {
    const book = new AlertBook();
    expect(brief(book.apply(ev(1n, [f("M-01", "ok")])))).toEqual([]);
    expect(brief(book.apply(ev(2n, [f("M-01", "warn")])))).toEqual(["open:M-01:warn:market:1"]);
    expect(brief(book.apply(ev(3n, [f("M-01", "warn")])))).toEqual([]);
    const up = book.apply(ev(4n, [f("M-01", "page")]));
    expect(brief(up)).toEqual(["escalate:M-01:page:market:1"]);
    expect(up[0]!.from).toBe("warn");
    const down = book.apply(ev(5n, [f("M-01", "warn")]));
    expect(brief(down)).toEqual(["deescalate:M-01:warn:market:1"]);
    expect(down[0]!.from).toBe("page");
    const end = book.apply(ev(6n, [f("M-01", "ok")]));
    expect(brief(end)).toEqual(["resolve:M-01:warn:market:1"]);
    expect(end[0]!.alert.blockNumber).toBe(6n);
    expect(book.open()).toEqual([]);
  });

  it("sends an event every time and never keeps it open", () => {
    const book = new AlertBook();
    expect(brief(book.apply(ev(1n, [f("M-24", "warn", "market:1", "event")])))).toEqual(["event:M-24:warn:market:1"]);
    expect(brief(book.apply(ev(2n, [f("M-24", "warn", "market:1", "event")])))).toEqual(["event:M-24:warn:market:1"]);
    expect(book.open()).toEqual([]);
  });

  it("resolves an open alert whose subject a complete evaluation no longer reports", () => {
    const book = new AlertBook();
    book.apply(ev(1n, [f("M-08", "page", "market:7")]));
    expect(brief(book.apply(ev(2n, [f("M-08", "ok", "market:1")], false)))).toEqual([]);
    const gone = book.apply(ev(3n, [f("M-08", "ok", "market:1")]));
    expect(brief(gone)).toEqual(["resolve:M-08:page:market:7"]);
    expect(gone[0]!.alert.detail.note).toBe("subject no longer read");
  });

  it("leaves other sources and chains alone when resolving missing subjects", () => {
    const book = new AlertBook();
    book.apply(ev(1n, [f("M-09", "warn", "account:0xabc")], false, "keeper"));
    book.apply({ ...ev(1n, [f("M-01", "warn", "market:1")]), chainId: 8453 });
    expect(brief(book.apply(ev(2n, [])))).toEqual([]);
    expect(book.open().map((a) => a.signal).sort()).toEqual(["M-01", "M-09"]);
  });
});

describe("routing", () => {
  const n = (signal: Finding["signal"], level: "warn" | "page", from?: "warn" | "page"): Notice => ({ alert: { signal, level, chainId: 1, blockNumber: 1n, subject: "s", detail: {} }, transition: "open", timestamp: 0, ...(from ? { from } : {}) });

  it("sends a warn to the on-call engineer and the signal's responders", () => {
    expect(recipientsOf(n("M-18", "warn"))).toEqual(["onCall", "riskProviders"]);
  });

  it("sends a page also to both Safes' signers and the Aave Protocol Guardian", () => {
    expect(recipientsOf(n("M-01", "page"))).toEqual(["onCall", "operators", "emergencyGuardian", "governanceSafeSigners", "emergencyGuardianSigners", "aaveProtocolGuardian"]);
  });

  it("tells the page recipients when a page eases to a warn", () => {
    expect(recipientsOf(n("M-18", "warn", "page"))).toContain("governanceSafeSigners");
  });

  it("refuses a table with a recipient left out or an undefined channel, and dedupes channels", () => {
    const all = Object.fromEntries(RECIPIENTS.map((r) => [r, ["ops"]])) as Record<Recipient, string[]>;
    expect(() => checkRouting({ ...all, signers: [] }, new Set(["ops"]))).toThrow(/no channel for signers/);
    expect(() => checkRouting({ ...all, aave: ["aave-email"] }, new Set(["ops"]))).toThrow(/aave -> aave-email/);
    const table = checkRouting({ ...all, governanceSafeSigners: ["safe-pager", "ops"] }, new Set(["ops", "safe-pager"]));
    expect(channelsOf(n("M-01", "page"), table)).toEqual(["ops", "safe-pager"]);
    expect(channelsOf(n("M-01", "warn"), table)).toEqual(["ops"]);
  });
});

describe("incident log", () => {
  it("appends one JSON line per notice with its block, recipients and deliveries", () => {
    const path = join(mkdtempSync(join(tmpdir(), "monitor-")), "incidents.jsonl");
    const log = fileIncidentLog(path);
    const notice: Notice = { alert: { signal: "M-15", level: "page", chainId: 1, blockNumber: 123_456_789_012n, subject: "hubAsset:0xh:1", detail: { deficit: "5" } }, transition: "escalate", from: "warn", timestamp: 1_700_000_000 };
    log.write(incidentEntry(notice, ["onCall", "coverageRole"], [{ channel: "ops", ok: true }, { channel: "pd", ok: false, error: "HTTP 500" }]));
    log.write(incidentEntry({ ...notice, transition: "resolve" }, ["onCall"], []));
    const lines = readFileSync(path, "utf8").trim().split("\n").map((l) => JSON.parse(l));
    expect(lines).toHaveLength(2);
    expect(lines[0]).toMatchObject({ type: "monitor.notice", transition: "escalate", signal: "M-15", blockNumber: "123456789012", deliveries: [{ channel: "ops", ok: true }, { channel: "pd", ok: false, error: "HTTP 500" }] });
  });
});
