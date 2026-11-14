import { renderHook, waitFor } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { useHasMounted } from "@/app/lib/ui/use-has-mounted"

describe("useHasMounted", () => {
  it("reports mounted state after effects run", async () => {
    const { result } = renderHook(() => useHasMounted())

    await waitFor(() => {
      expect(result.current).toBe(true)
    })
  })
})
