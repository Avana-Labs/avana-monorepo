import { cleanup, fireEvent, render, renderHook, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { TablePager, useTablePagination } from "@/app/components/table-pager"

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (key: string) => key, language: "EN" }),
}))

describe("useTablePagination", () => {
  it("slices 10 items per page and reports page count", () => {
    const items = Array.from({ length: 23 }, (_, i) => i)
    const { result } = renderHook(() => useTablePagination(items))
    expect(result.current.pageCount).toBe(3)
    expect(result.current.pageItems).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
  })

  it("clamps the page when the list shrinks below the current page", () => {
    let items = Array.from({ length: 25 }, (_, i) => i)
    const { result, rerender } = renderHook(() => useTablePagination(items))
    result.current.setPage(2) // last page of 25
    rerender()
    expect(result.current.page).toBe(2)
    items = Array.from({ length: 5 }, (_, i) => i) // now a single page
    rerender()
    expect(result.current.page).toBe(0)
    expect(result.current.pageItems).toHaveLength(5)
  })
})

describe("TablePager", () => {
  afterEach(cleanup)

  it("renders nothing for a single page", () => {
    const { container } = render(
      <TablePager page={0} pageCount={1} onPageChange={() => {}} label="Transactions pagination" />,
    )
    expect(container.firstChild).toBeNull()
  })

  it("disables prev on the first page and next on the last", () => {
    const { rerender } = render(
      <TablePager page={0} pageCount={3} onPageChange={() => {}} label="Transactions pagination" />,
    )
    expect(screen.getByLabelText("Previous page")).toBeDisabled()
    expect(screen.getByLabelText("Next page")).not.toBeDisabled()
    expect(screen.getByText("1")).toBeInTheDocument()

    rerender(<TablePager page={2} pageCount={3} onPageChange={() => {}} label="Transactions pagination" />)
    expect(screen.getByLabelText("Next page")).toBeDisabled()
    expect(screen.getByText("3")).toBeInTheDocument()
  })

  it("labels the nav distinctly and moves pages via the buttons", () => {
    const onPageChange = vi.fn()
    render(<TablePager page={1} pageCount={3} onPageChange={onPageChange} label="Changelog pagination" />)
    expect(screen.getByLabelText("Changelog pagination")).toBeInTheDocument()
    fireEvent.click(screen.getByLabelText("Next page"))
    expect(onPageChange).toHaveBeenCalledWith(2)
    fireEvent.click(screen.getByLabelText("Previous page"))
    expect(onPageChange).toHaveBeenCalledWith(0)
  })
})
