/**
 * Routes that need a signed-in wallet which finished onboarding. Everything else is open to
 * guests and to signed-in wallets still onboarding: they browse live market data, and the
 * action CTA (not the gate) asks them to connect or onboard before transacting.
 */
const ONBOARDING_ROUTES = ["/dashboard", "/sandbox/transactions"]

export function requiresOnboarding(pathname: string) {
  return ONBOARDING_ROUTES.some((route) => pathname === route || pathname.startsWith(`${route}/`))
}
