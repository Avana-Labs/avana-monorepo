import styles from "./testnet-metrics-badge.module.css"

/**
 * Small indicator for surfaces backed by testnet data: the Testnet chain icon (the one the Chains
 * filter uses; a fixed w64 WebP variant so this stays import-free) plus the label.
 */
export function TestnetMetricsBadge({ label, size = "default" }: { label: string; size?: "default" | "compact" }) {
  return (
    <span className={size === "compact" ? `${styles.badge} ${styles.compact}` : styles.badge}>
      {/* eslint-disable-next-line @next/next/no-img-element -- tiny local icon at a fixed box */}
      <img
        src="/asset-icons/w64/testnet.webp"
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
