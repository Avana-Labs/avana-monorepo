import { cn } from "@/lib/utils"
/* eslint-disable @next/next/no-img-element */

type BrandLogoProps = {
  mobileOnly?: boolean
  className?: string
  /** The caller hides the wordmark below this breakpoint: serve a 1px placeholder there instead
   *  of downloading the 30KB PNG (an eager high-priority <img> loads even when display:none). */
  visibleFrom?: "xl"
}

const TRANSPARENT_PIXEL = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

const HEADER_WORDMARK_PATH = "/avana-wordmark-220.png"
const SITE_NAME = "Avana"

export function BrandLogo({ mobileOnly = false, className, visibleFrom }: BrandLogoProps) {
  const img = (
    <img
      src={HEADER_WORDMARK_PATH}
      srcSet={`${HEADER_WORDMARK_PATH} 220w, /avana-wordmark-440.png 440w`}
      sizes="220px"
      alt={`${SITE_NAME} logo`}
      width={220}
      height={86}
      loading="eager"
      fetchPriority="high"
      className={mobileOnly ? "h-[56px] w-auto scale-[1.08] origin-left" : "h-[36px] w-auto origin-left"}
    />
  )
  return (
    // className must live on the wrapper — hiding only the <img> leaves an
    // inline-flex strut that shifts vertical centering vs BrandIcon routes.
    <span className={cn("inline-flex items-center overflow-hidden", className)}>
      {visibleFrom === "xl" ? (
        <picture>
          <source media="(max-width: 1279.98px)" srcSet={TRANSPARENT_PIXEL} />
          {img}
        </picture>
      ) : (
        img
      )}
    </span>
  )
}

type BrandIconProps = {
  className?: string
}

export function BrandIcon({ className }: BrandIconProps) {
  return (
    <span className={cn("inline-flex items-center overflow-hidden", className)}>
      {/* Plain img avoids next/image SSR markup drift in the mobile header. */}
      <img
        src="/avana-icon-64.png"
        alt="Avana logo"
        width={58}
        height={64}
        loading="eager"
        fetchPriority="high"
        className="h-8 w-8 object-cover"
      />
    </span>
  )
}
