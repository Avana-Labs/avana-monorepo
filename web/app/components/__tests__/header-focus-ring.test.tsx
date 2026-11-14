import { describe, it, expect, vi } from "vitest"
import { renderToStaticMarkup } from "react-dom/server"

// The header controls only need their markup; stub i18n so no provider is required.
vi.mock("@/app/lib/i18n/use-translation", () => ({ useTranslation: () => ({ t: (s: string) => s }) }))

import { SearchTrigger } from "@/app/components/search-trigger"
import { preferencesTriggerClassName } from "@/app/components/desktop-preference-trigger"

// WCAG 2.4.7: keyboard focus on the primary header controls must be visible. These used
// `focus-visible:ring-0`, which renders no indicator for keyboard users.
describe("header controls have a visible focus ring", () => {
  it("search icon trigger uses a real focus-visible ring, not ring-0", () => {
    const html = renderToStaticMarkup(<SearchTrigger iconOnly />)
    expect(html).toMatch(/focus-visible:ring-2/)
    expect(html).not.toMatch(/focus-visible:ring-0(?![0-9.])/)
  })

  it("preferences trigger className carries a visible focus ring", () => {
    expect(preferencesTriggerClassName).toMatch(/focus-visible:ring-2/)
    expect(preferencesTriggerClassName).not.toMatch(/focus-visible:ring-0(?![0-9.])/)
  })
})
