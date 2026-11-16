// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The stack's long-running processes (anvil nodes, recorders, indexer, Convex, keeper, monitor, activity, webapp):
// each starts detached, with its log in STACK/logs/<name>.log and its record in STACK/pids/<name>.json, so it keeps
// running after the command that started it returns, and after a step fails. `stop` ends a process and its children
// (taskkill /T on Windows, the process group elsewhere).

import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, openSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { LOGS, PIDS, REPO } from "./env.ts";

export interface ProcRecord {
  readonly name: string;
  readonly pid: number;
  readonly command: string;
  readonly args: readonly string[];
  readonly cwd: string;
  readonly log: string;
  readonly started: string;
}

const recordPath = (name: string) => join(PIDS, `${name}.json`);
export const logPath = (name: string) => join(LOGS, `${name}.log`);

export function record(name: string): ProcRecord | undefined {
  const p = recordPath(name);
  return existsSync(p) ? (JSON.parse(readFileSync(p, "utf8")) as ProcRecord) : undefined;
}

export function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
}

export function running(name: string): boolean {
  const r = record(name);
  return r !== undefined && alive(r.pid);
}

/** Starts `command` detached; its stdout and stderr go to the log (appended). Returns the record. */
export function start(
  name: string,
  command: string,
  args: readonly string[],
  opts: { cwd?: string; env?: NodeJS.ProcessEnv } = {},
): ProcRecord {
  mkdirSync(LOGS, { recursive: true });
  mkdirSync(PIDS, { recursive: true });
  const log = logPath(name);
  const fd = openSync(log, "a");
  const cwd = opts.cwd ?? REPO;
  const child = spawn(command, args, {
    cwd,
    env: { ...process.env, ...opts.env },
    detached: true,
    stdio: ["ignore", fd, fd],
    windowsHide: true,
  });
  if (child.pid === undefined) throw new Error(`${name}: could not start ${command}`);
  child.unref();
  const r: ProcRecord = { name, pid: child.pid, command, args, cwd, log, started: new Date().toISOString() };
  writeFileSync(recordPath(name), `${JSON.stringify(r, null, 2)}\n`);
  return r;
}

/** Ends a process and its children; the record is removed. */
export function stop(name: string): boolean {
  const r = record(name);
  if (!r) return false;
  if (alive(r.pid)) {
    if (process.platform === "win32") spawnSync("taskkill", ["/PID", String(r.pid), "/T", "/F"], { stdio: "ignore" });
    else {
      try {
        process.kill(-r.pid, "SIGTERM");
      } catch {
        try {
          process.kill(r.pid, "SIGTERM");
        } catch {}
      }
    }
  }
  rmSync(recordPath(name), { force: true });
  return true;
}

export function names(): string[] {
  if (!existsSync(PIDS)) return [];
  return readdirSync(PIDS).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5));
}

/** The JavaScript entry of a package's binary, run with this node (no shell shims, which differ on Windows). */
export function binJs(pkg: string, bin = pkg): string {
  const dir = join(REPO, "node_modules", pkg);
  const p = JSON.parse(readFileSync(join(dir, "package.json"), "utf8")) as { bin?: string | Record<string, string> };
  const rel = typeof p.bin === "string" ? p.bin : p.bin?.[bin];
  if (!rel) throw new Error(`${pkg} has no binary ${bin}`);
  return join(dir, rel);
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Polls `check` every `everyMs` until it returns a value or `timeoutMs` passes. */
export async function waitFor<T>(what: string, check: () => Promise<T | undefined>, timeoutMs: number, everyMs = 1000): Promise<T> {
  const until = Date.now() + timeoutMs;
  for (;;) {
    try {
      const v = await check();
      if (v !== undefined && v !== null && (v as unknown) !== false) return v;
    } catch {}
    if (Date.now() > until) throw new Error(`${what}: not ready after ${Math.round(timeoutMs / 1000)} s`);
    await sleep(everyMs);
  }
}

/** The last lines of a process's log. */
export function tail(name: string, lines = 20): string {
  const p = logPath(name);
  if (!existsSync(p)) return "";
  return readFileSync(p, "utf8").split(/\r?\n/).slice(-lines - 1).join("\n");
}
