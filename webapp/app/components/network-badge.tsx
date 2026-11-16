import styles from "./network-badge.module.css"

/**
 * The network the app runs on ("Local", "Sepolia"), from NEXT_PUBLIC_AVANA_NETWORK_LABEL.
 * Unset on the production networks, where nothing is shown.
 */
export function networkBadgeLabel(): string | null {
  const label = process.env.NEXT_PUBLIC_AVANA_NETWORK_LABEL?.trim()
  return label ? label : null
}

/**
 * Small indicator of the network: its icon (a fixed w64 WebP variant so this stays import-free)
 * plus the label. Renders nothing when no network label is set.
 */
export function NetworkBadge({
  label = networkBadgeLabel(),
  size = "default",
}: {
  label?: string | null
  size?: "default" | "compact"
}) {
  if (!label) return null
  return (
    <span className={size === "compact" ? `${styles.badge} ${styles.compact}` : styles.badge}>
      {/* eslint-disable-next-line @next/next/no-img-element -- tiny local icon at a fixed box */}
      <img
        src="/asset-icons/w64/network.webp"
        alt=""
        aria-hidden="true"
        width={14}
        height={14}
        className={styles.icon}
      />
      <span>{label}</span>
      <span aria-hidden="true" className={`${styles.sparkle} ${styles.sparkleOne}`}>
        ✦
      </span>
      <span aria-hidden="true" className={`${styles.sparkle} ${styles.sparkleTwo}`}>
        ✧
      </span>
      <span aria-hidden="true" className={`${styles.sparkle} ${styles.sparkleThree}`}>
        ✦
      </span>
    </span>
  )
}
