// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The probes each chain runs, in order. Each keeps its own state per chain. The Safes, the Core Hub comparison and
// the frontend run only where they are configured.

import { promises as dns } from "node:dns";
import type { ChainConfig, MonitorConfig } from "./config.ts";
import { snapshotProbe } from "./confirm.ts";
import type { Probe } from "./probe.ts";
import { coverageProbe } from "./probes/coverage.ts";
import { eventsProbe } from "./probes/events.ts";
import { type FrontendDeps, frontendProbe, ghoRateProbe, issuerProbe, safesProbe } from "./probes/external.ts";
import { oracleProbe } from "./probes/oracle.ts";

/** The frontend reads: the page body and `server` header, and the host's A, AAAA, CNAME and NS records. */
export const liveFrontend: FrontendDeps = {
  async fetchText(url) {
    const r = await fetch(url, { redirect: "manual" });
    if (r.status >= 400) throw new Error(`${url} answered HTTP ${r.status}`);
    return { body: await r.text(), server: r.headers.get("server") ?? "" };
  },
  async resolve(host) {
    const safe = async (f: () => Promise<string[]>) => (await f().catch(() => [] as string[])).map((x) => x.toLowerCase()).sort();
    const [a, aaaa, cname, ns] = await Promise.all([safe(() => dns.resolve4(host)), safe(() => dns.resolve6(host)), safe(() => dns.resolveCname(host)), safe(() => dns.resolveNs(host))]);
    return `A=${a.join(",")} AAAA=${aaaa.join(",")} CNAME=${cname.join(",")} NS=${ns.join(",")}`;
  },
};

export function probesFor(chain: ChainConfig, config: MonitorConfig, frontendDeps: FrontendDeps = liveFrontend): Probe[] {
  const id = chain.chain.id;
  const probes: Probe[] = [snapshotProbe() as Probe, oracleProbe() as Probe, coverageProbe() as Probe, eventsProbe() as Probe, issuerProbe() as Probe];
  const safes = config.safes.get(id);
  if (safes && safes.length > 0) probes.push(safesProbe(safes) as Probe);
  const core = config.coreHubGho.get(id);
  if (core) probes.push(ghoRateProbe(core) as Probe);
  if (config.frontend && config.frontend.chainId === id) probes.push(frontendProbe(config.frontend, frontendDeps) as Probe);
  return probes;
}
