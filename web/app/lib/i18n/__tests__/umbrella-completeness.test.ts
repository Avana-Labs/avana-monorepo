import { describe, expect, it } from "vitest"
import { TRANSLATIONS } from "@/app/lib/i18n/translations"

/**
 * Wave-4 A completeness test. Unlike the sibling translation-completeness suite
 * (which only checks keys already present in ≥1 locale), this one asserts that
 * a hand-curated set of umbrella-feature source strings is translated in EVERY
 * non-English locale. Fails on the "translator forgot the new page" class of
 * regression: adding a new umbrella t("…") without matching entries in the 13
 * dicts stays English-fallback in production, and this test surfaces it in CI.
 *
 * When adding an umbrella string, also add its English source to this list.
 */
export const UMBRELLA_TRANSLATION_KEYS: readonly string[] = [
  "APY",
  "Active Deficit",
  "Amount Avana covers first before user-staked coverage is exposed. Stakers only take losses once realized deficits exceed this offset.",
  "Asset",
  "Back to Umbrella",
  "Claim",
  "Close",
  "Close umbrella actions",
  "Cooldown",
  "Cooling",
  "Coverage",
  "Coverage currently in cooldown across all stakers of this asset. Cooldown positions still absorb losses until they finish the 20-day wait and are unstaked.",
  "Current realized shortfall in {symbol}. Staker Exposure = max(Active Deficit − Deficit Offset, 0). Current staker exposure: {exposure}.",
  "Deficit Offset",
  "Deposited",
  "Desired amount of user-staked coverage for this asset.",
  "Dynamic rewards",
  "Hub + reserve coverage",
  "Coverage is defined for a specific Hub reserve and covers eligible deficits from every Spoke borrowing that reserve, including credit-line draws.",
  "First-loss protection",
  "The Deficit Offset absorbs the first layer of loss. Only the residual deficit beyond that offset can reach staked Umbrella coverage.",
  "Independent underwriting",
  "Target liquidity and reward emissions reflect reserve risk, economics, opportunity cost, and the slashing and lockup risk accepted by coverage providers.",
  "Earning",
  "Each Umbrella stake token covers deficits for its matching borrowed asset on the same network.",
  "Emissions adjust against target liquidity, and each staked asset can earn multiple reward tokens.",
  "Estimated annual staking yield paid to stakers of this asset.",
  "Expired",
  "In cooldown",
  "Isolated slashing",
  "Learn Umbrella",
  "Umbrella Overview",
  "Module assets",
  "More",
  "More umbrella actions",
  "Next cooldown",
  "Next market risk",
  "Once cooldown finishes, users can unstake during the withdrawal window before cooldown has to be restarted.",
  "Previous cooldown",
  "Previous market risk",
  "Ready",
  "Remove",
  "Removes in",
  "Restart",
  "Restart cooldown",
  "Rewards",
  "Sandbox wallet",
  "Stake",
  "Stake in umbrella",
  "Stake, claim rewards, start cooldown, or unstake from the umbrella safety module.",
  "Stake, claim, cooldown, unstake",
  "Start cooldown before withdrawing. During cooldown, the position keeps earning incentives and remains slashable.",
  "Your APY combines base supply yield and reward emissions for keeping capital available as coverage while the position stays active.",
  "Start a 20-day cooldown before withdrawing. During cooldown, the position keeps earning and remains slashable.",
  "Status",
  "Target",
  "Total coverage",
  "Total user-staked capital available to absorb losses for this asset.",
  "Umbrella",
  "Umbrella Cooldown",
  "Umbrella actions",
  "Umbrella activity",
  "Umbrella positions are split by asset and network, so each stake token has its own risk and reward profile.",
  "Umbrella positions",
  "Unstake",
  "Unstake from umbrella",
  "Unstake window",
  "Weighted APY",
  "Withdrawal ready",
  "Withdrawal window",
  "When cooldown ends, a 2-day withdrawal window opens. Unstake within it, or restart cooldown before exiting.",
  "You have no Umbrella positions yet.",
  "Your Umbrella",
  "Your Umbrella stake",
  "After cooldown completes, there is a short window to unstake. If it expires, cooldown must be started again.",
  "base {base} + reward {reward}",
  "live mix",
  "none",
  "{amount} active deficit",
  "{amount} claimed",
  "{amount} cooling",
  "{amount} deficit offset",
  "{amount} in cooldown",
  "{amount} market",
  "{amount} pending",
  "{amount} target",
  "{pct}% of coverage cooling · {deficits} deficits absorbed",
  "{pct}% of target",
  "{pct}% of target coverage.",
  "{staked} staked · {target} target",
  "{time} left",
  "{value} total",
]

const NON_EN_LANGS = Object.keys(TRANSLATIONS).filter((lang) => lang !== "EN") as Array<keyof typeof TRANSLATIONS>

describe("umbrella translation completeness", () => {
  it("every umbrella source string has a translation in every non-English locale", () => {
    const missing: string[] = []
    for (const lang of NON_EN_LANGS) {
      const dict = TRANSLATIONS[lang] ?? {}
      for (const key of UMBRELLA_TRANSLATION_KEYS) {
        const value = dict[key]
        if (value == null || String(value).trim() === "") {
          missing.push(`${lang}: "${key}"`)
        }
      }
    }
    expect(missing, `Missing umbrella translations:\n${missing.join("\n")}`).toEqual([])
  })
})
