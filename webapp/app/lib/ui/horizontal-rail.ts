/**
 * Mobile rails bleed through the page gutter, then restore a 12px inner gutter.
 * Scroll padding keeps snapped items aligned with that gutter while the mask
 * makes additional off-screen content visible without clipping the first item.
 */
export const MOBILE_EDGE_RAIL_CLASS =
  "max-md:-mx-3 max-md:px-3 max-md:scroll-px-3 max-md:overscroll-x-contain max-md:[mask-image:linear-gradient(to_right,transparent_0,black_0.75rem,black_calc(100%-0.75rem),transparent_100%)]"
