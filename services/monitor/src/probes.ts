// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The probes each chain runs, in order. Each keeps its own state per chain.

import type { ChainConfig, MonitorConfig } from "./config.ts";
import { snapshotProbe } from "./confirm.ts";
import type { Probe } from "./probe.ts";
import { oracleProbe } from "./probes/oracle.ts";

export function probesFor(_chain: ChainConfig, _config: MonitorConfig): Probe[] {
  return [snapshotProbe(), oracleProbe()] as Probe[];
}
