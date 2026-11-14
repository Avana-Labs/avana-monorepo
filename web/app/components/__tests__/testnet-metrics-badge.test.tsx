import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { TestnetMetricsBadge } from "../testnet-metrics-badge"
import styles from "../testnet-metrics-badge.module.css"

describe("TestnetMetricsBadge", () => {
  it("renders its label while keeping the icon and sparkles hidden from assistive technology", () => {
    const { container } = render(<TestnetMetricsBadge label="Testnet" />)

    expect(screen.getByText("Testnet")).toBeInTheDocument()
    expect(container.querySelector("img")).toHaveAttribute("src", "/asset-icons/w64/testnet.webp")
    // The Testnet icon plus three sparkles.
    expect(container.querySelectorAll('[aria-hidden="true"]')).toHaveLength(4)
  })

  it("supports a compact size for the homepage action card", () => {
    const { container } = render(<TestnetMetricsBadge label="Testnet" size="compact" />)

    expect(container.firstElementChild).toHaveClass(styles.compact)
  })
})
