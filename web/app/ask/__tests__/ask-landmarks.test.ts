import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { expect, it } from "vitest"

const read = (file: string) => readFileSync(resolve(__dirname, "..", file), "utf8")

it("keeps a main landmark when the guest session fails to start", () => {
  const boundary = read("ask-ai-convex-boundary.tsx")
  const errorBranch = boundary.split("if (error) {")[1]?.split("}\n")[0] ?? ""
  expect(errorBranch).toMatch(/<main\b/)
})

it("skips the hidden wordmark download on phones", () => {
  expect(read("ask-page-client.tsx")).toMatch(/<BrandLogo[^>]*visibleFrom="xl"/)
})
