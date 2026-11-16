import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { NetworkBadge, networkBadgeLabel } from "../network-badge"
import styles from "../network-badge.module.css"

describe("NetworkBadge", () => {
  afterEach(() => {
    vi.unstubAllEnvs()
  })

  it("renders its label while keeping the icon and sparkles hidden from assistive technology", () => {
    const { container } = render(<NetworkBadge label="Local" />)

    expect(screen.getByText("Local")).toBeInTheDocument()
    expect(container.querySelector("img")).toHaveAttribute("src", "/asset-icons/w64/network.webp")
    // The network icon plus three sparkles.
    expect(container.querySelectorAll('[aria-hidden="true"]')).toHaveLength(4)
  })

  it("supports a compact size for the homepage action card", () => {
    const { container } = render(<NetworkBadge label="Local" size="compact" />)

    expect(container.firstElementChild).toHaveClass(styles.compact)
  })

  it("renders nothing without a network label", () => {
    const { container } = render(<NetworkBadge label={null} />)

    expect(container).toBeEmptyDOMElement()
  })

  it("reads the label from NEXT_PUBLIC_AVANA_NETWORK_LABEL", () => {
    vi.stubEnv("NEXT_PUBLIC_AVANA_NETWORK_LABEL", " Sepolia ")
    expect(networkBadgeLabel()).toBe("Sepolia")
    vi.stubEnv("NEXT_PUBLIC_AVANA_NETWORK_LABEL", "")
    expect(networkBadgeLabel()).toBeNull()
  })
})
