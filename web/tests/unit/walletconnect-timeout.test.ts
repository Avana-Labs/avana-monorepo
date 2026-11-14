import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import path from "node:path"
import { describe, expect, it } from "vitest"

const lock = JSON.parse(readFileSync(new URL("../../package-lock.json", import.meta.url), "utf8"))
const copies = Object.keys(lock.packages).filter((name) => name.endsWith("node_modules/@walletconnect/utils"))

describe("WalletConnect proposal timeout", () => {
  // A separate process with strict rejection handling catches the orphan that escaped
  // ConnectKit's existing try/catch. Exercise the installed code, not a duplicate helper.
  for (const copy of copies) {
    const installed = JSON.parse(readFileSync(path.resolve(copy, "package.json"), "utf8"))
    for (const entry of [installed.main, installed.module]) {
      it(`${copy}/${entry} rejects only the awaited promise and permits a fresh attempt`, () => {
        const script = `
          const assert = require('node:assert/strict');
          (async () => {
            const { createDelayedPromise } = await import(${JSON.stringify(path.resolve(copy, entry))});
            const proposal = createDelayedPromise(0.01, 'Proposal expired');
            await assert.rejects(proposal.done(), { message: 'Proposal expired' });
            await new Promise(resolve => setTimeout(resolve, 20));
            const retry = createDelayedPromise(0.01, 'Proposal expired');
            const approval = retry.done();
            retry.resolve('connected');
            assert.equal(await approval, 'connected');
            const rejected = createDelayedPromise(0.01, 'Proposal expired');
            const rejection = assert.rejects(rejected.done(), { message: 'User rejected' });
            rejected.reject(new Error('User rejected'));
            await rejection;
            await new Promise(resolve => setTimeout(resolve, 20));
          })().catch(error => { console.error(error); process.exitCode = 1; });
        `
        expect(() => execFileSync(process.execPath, ["--unhandled-rejections=strict", "-e", script])).not.toThrow()
      })
    }
  }
})
