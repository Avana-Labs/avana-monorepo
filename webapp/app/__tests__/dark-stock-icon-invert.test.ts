import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

const css = readFileSync(resolve(__dirname, "../globals.css"), "utf8")

describe("dark-mode invert for black stock marks", () => {
  // Token icons are served as sized WebP (`/stock-Icons/w64/apple.webp`) as well as the source PNG,
  // so the rule must match both or the mark renders black on the dark background.
  it.each(["apple", "micron", "spacex"])("inverts %s in both PNG and WebP", (name) => {
    expect(css).toContain(`.dark img[src*="${name}.png"]`)
    expect(css).toContain(`.dark img[src*="${name}.webp"]`)
  })
})
