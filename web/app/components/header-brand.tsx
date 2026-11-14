import { BrandIcon, BrandLogo } from "./brand-logo"

/** Desktop header brand: the mark below xl, the wordmark from xl. */
export function HeaderBrand() {
  return (
    <>
      <BrandIcon className="xl:hidden" />
      <BrandLogo className="hidden xl:inline-flex" visibleFrom="xl" />
    </>
  )
}

/** Phone header brand: the mark. */
export function MobileHeaderBrand() {
  return <BrandIcon />
}
