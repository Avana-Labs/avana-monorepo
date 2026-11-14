import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { collectRouteInitialFiles, runRouteBundleBudgets } from "../../scripts/check-route-bundle-budgets.mjs"

const temporaryDirectories: string[] = []
afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) fs.rmSync(directory, { recursive: true, force: true })
})

describe("product route bundle budgets", () => {
  it("counts the runtime, every layout on the route's path and the page, not sibling routes", () => {
    const files = collectRouteInitialFiles({
      route: "lend/markets/[marketId]/page",
      clientManifest: {
        entryJSFiles: {
          "[project]/app/layout": ["static/root.js"],
          "[project]/app/lend/layout": ["static/lend-layout.js"],
          "[project]/app/lend/markets/[marketId]/page": ["static/detail.js", "static/root.js"],
          "[project]/app/borrow/layout": ["static/borrow-layout.js"],
          "[project]/app/lend/page": ["static/lend-index.js"],
        },
      },
      routeBuildManifest: { rootMainFiles: ["static/runtime.js"] },
    })
    expect(files).toEqual(["static/runtime.js", "static/root.js", "static/lend-layout.js", "static/detail.js"])
  })

  it("fails when a route's first-load JS exceeds its cap", () => {
    const distDir = fs.mkdtempSync(path.join(os.tmpdir(), "avana-route-budget-"))
    temporaryDirectories.push(distDir)
    const chunk = "static/chunks/big.js"
    fs.mkdirSync(path.join(distDir, "static/chunks"), { recursive: true })
    fs.writeFileSync(path.join(distDir, chunk), Array.from({ length: 4000 }, (_, i) => `v${i}=${i * 7919};`).join(""))
    fs.mkdirSync(path.join(distDir, "server/app/lend/page"), { recursive: true })
    fs.writeFileSync(
      path.join(distDir, "server/app/lend/page_client-reference-manifest.js"),
      `globalThis.__RSC_MANIFEST = {}; globalThis.__RSC_MANIFEST["/lend/page"] = ${JSON.stringify({
        entryJSFiles: { "[project]/app/lend/page": [chunk] },
      })};`,
    )
    fs.writeFileSync(
      path.join(distDir, "server/app/lend/page/build-manifest.json"),
      JSON.stringify({ rootMainFiles: [] }),
    )

    expect(() => runRouteBundleBudgets({ distDir, budgets: { "lend/page": 1024 } })).toThrow(/routes over budget/)
    expect(runRouteBundleBudgets({ distDir, budgets: { "lend/page": 10 * 1024 * 1024 } })).toHaveLength(1)
  })
})
