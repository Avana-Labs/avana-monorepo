/**
 * Cookie naming the wallet (lowercase address) that last completed onboarding on this
 * browser. Written by the signed-in gate checker, read by the root layout so the server can
 * render the product for a returning wallet instead of a skeleton. Rendering hint only.
 */
export const ONBOARDED_COOKIE = "avana_onboarded"
