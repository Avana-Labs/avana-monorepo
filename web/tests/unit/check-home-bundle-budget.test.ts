import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { gzipSync } from "node:zlib"
import { afterEach, describe, expect, it } from "vitest"
import {
  analyzeInitialBundles,
  collectInitialFiles,
  parseClientReferenceManifest,
  runBundleBudget,
} from "../../scripts/check-home-bundle-budget.mjs"

const temporaryDirectories: string[] = []

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) fs.rmSync(directory, { recursive: true, force: true })
})

describe("home bundle budget", () => {
  it("parses the Next 16 client-reference assignment", () => {
    const manifest = parseClientReferenceManifest(
      'globalThis.__RSC_MANIFEST = globalThis.__RSC_MANIFEST || {}; globalThis.__RSC_MANIFEST["/page"] = {"entryJSFiles":{"[project]/app/page":["static/page.js"]}};',
    )
    expect(manifest.entryJSFiles["[project]/app/page"]).toEqual(["static/page.js"])
  })

  it("deduplicates runtime, layout, and page entry chunks", () => {
    expect(
      collectInitialFiles({
        clientManifest: {
          entryJSFiles: {
            "[project]/app/layout": ["static/shared.js", "static/layout.js"],
            "[project]/app/page": ["static/shared.js", "static/page.js"],
          },
        },
        routeBuildManifest: { rootMainFiles: ["static/runtime.js", "static/shared.js"] },
      }),
    ).toEqual(["static/runtime.js", "static/shared.js", "static/layout.js", "static/page.js"])
  })

  function writeMinimalHomeManifest(distDir: string, chunkRel: string, chunkSource: string) {
    const chunkAbs = path.join(distDir, chunkRel)
    fs.mkdirSync(path.dirname(chunkAbs), { recursive: true })
    fs.writeFileSync(chunkAbs, chunkSource)
    const clientManifestPath = path.join(distDir, "server/app/page_client-reference-manifest.js")
    fs.mkdirSync(path.dirname(clientManifestPath), { recursive: true })
    fs.writeFileSync(
      clientManifestPath,
      `globalThis.__RSC_MANIFEST = globalThis.__RSC_MANIFEST || {}; globalThis.__RSC_MANIFEST["/page"] = ${JSON.stringify(
        {
          entryJSFiles: { "[project]/app/layout": [chunkRel], "[project]/app/page": [] },
        },
      )};`,
    )
    const routeBuildManifestPath = path.join(distDir, "server/app/page/build-manifest.json")
    fs.mkdirSync(path.dirname(routeBuildManifestPath), { recursive: true })
    fs.writeFileSync(routeBuildManifestPath, JSON.stringify({ rootMainFiles: [] }))
  }

  it("fails when forbidden runtime markers appear in initial chunks", () => {
    const distDir = fs.mkdtempSync(path.join(os.tmpdir(), "avana-bundle-forbid-"))
    temporaryDirectories.push(distDir)
    writeMinimalHomeManifest(distDir, "static/chunks/entry.js", "export const ConvexReactClient = {}")

    expect(() => runBundleBudget({ distDir, maxGzipBytes: 1024 * 1024 })).toThrow(/forbidden initial runtime/)
  })

  it("fails when a wallet SDK marker is injected into the guest initial graph", () => {
    const distDir = fs.mkdtempSync(path.join(os.tmpdir(), "avana-bundle-wagmi-"))
    temporaryDirectories.push(distDir)
    writeMinimalHomeManifest(distDir, "static/chunks/wallet.js", 'import { createConfig } from "wagmi"')

    expect(() => runBundleBudget({ distDir, maxGzipBytes: 1024 * 1024 })).toThrow(/forbidden initial runtime/)
  })

  it("fails when expected build artifacts are missing", () => {
    const distDir = fs.mkdtempSync(path.join(os.tmpdir(), "avana-bundle-missing-"))
    temporaryDirectories.push(distDir)

    expect(() => runBundleBudget({ distDir, maxGzipBytes: 1024 * 1024 })).toThrow(/missing|not found|unable|artifact/i)
  })

  it("records every counted chunk in the budget result", () => {
    const distDir = fs.mkdtempSync(path.join(os.tmpdir(), "avana-bundle-rows-"))
    temporaryDirectories.push(distDir)
    fs.mkdirSync(path.join(distDir, "static"))
    fs.writeFileSync(path.join(distDir, "static", "a.js"), "export const a = 1")
    fs.writeFileSync(path.join(distDir, "static", "b.js"), "export const b = 2")
    const files = ["static/a.js", "static/b.js"]
    const result = analyzeInitialBundles({ distDir, files, forbiddenGroups: {} })
    expect(result.rows.map((row) => row.file).sort()).toEqual(files)
  })

  it("measures gzip bytes and identifies forbidden runtime markers", () => {
    const distDir = fs.mkdtempSync(path.join(os.tmpdir(), "avana-bundle-budget-"))
    temporaryDirectories.push(distDir)
    fs.mkdirSync(path.join(distDir, "static"))
    const contents = Buffer.from("const client = new ConvexReactClient('https://example.test')")
    fs.writeFileSync(path.join(distDir, "static", "entry.js"), contents)

    const result = analyzeInitialBundles({
      distDir,
      files: ["static/entry.js"],
      forbiddenGroups: { convex: ["ConvexReactClient"] },
    })

    expect(result.rawBytes).toBe(contents.byteLength)
    expect(result.gzipBytes).toBe(gzipSync(contents, { level: 9 }).byteLength)
    expect(result.forbidden.get("convex")).toEqual(["static/entry.js"])
  })
})
