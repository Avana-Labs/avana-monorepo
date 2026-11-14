import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("HighlightCarousel accessibility", () => {
  it("P2-09: hides cloned marquee cards from assistive tech and sizes cards to viewport", () => {
    const carouselSource = readFileSync(resolve(__dirname, "../highlight-carousel.tsx"), "utf8")
    expect(carouselSource).toMatch(/aria-hidden="true"[\s\S]{0,80}inert/)

    const lendSource = readFileSync(resolve(__dirname, "../../lend/components/hot-markets.tsx"), "utf8")
    const multiplySource = readFileSync(
      resolve(__dirname, "../../multiply/components/explore-loops-markets-table.tsx"),
      "utf8",
    )
    expect(lendSource).toMatch(/w-\[min\(372px,calc\(100vw-2rem\)\)\]/)
    expect(multiplySource).toMatch(/w-\[min\(372px,calc\(100vw-2rem\)\)\]/)
  })
})
