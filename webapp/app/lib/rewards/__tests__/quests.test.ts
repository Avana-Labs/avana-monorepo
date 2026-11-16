import { describe, expect, it } from "vitest"
import { CLIENT_QUEST_POINTS } from "@/convex/lib/clientQuests"
import { REFERRAL_QUEST_POINTS } from "@/convex/lib/referrals"
import { QUEST_POINTS } from "@/convex/lib/rewards"
import { questDialog, questHref, questsByTab } from "@/app/lib/data/rewards/quests"
import { translate, TRANSLATIONS } from "@/app/lib/i18n/translations"

const labels = { comingSoon: "Coming soon", earned: "Earned" }
const all = (completed: string[]) => Object.values(questsByTab(labels, new Set(completed))).flat()
const byId = (completed: string[], id: string) => all(completed).find((q) => q.id === id)!

describe("rewards quests", () => {
  it("shows the Convex points of the real quests", () => {
    for (const [id, points] of Object.entries(QUEST_POINTS)) {
      expect(byId([], id).reward, id).toBe(`${points} pts`)
    }
  })

  it("shows the Convex points of the client quests that are live", () => {
    expect(byId([], "connect-wallet").reward).toBe(`${CLIENT_QUEST_POINTS["connect-wallet"]} pts`)
    expect(byId([], "connect-wallet")).toMatchObject({ status: "available", cta: "Connect Wallet" })
    expect(byId(["connect-wallet"], "connect-wallet")).toMatchObject({ status: "claimed", cta: "Earned" })
    expect(questHref("connect-wallet")).toBe("/dashboard")
  })

  it("opens a dialog for the primer and the two pin quests, and shows their Convex points", () => {
    expect(byId([], "review-risk-basics")).toMatchObject({
      status: "available",
      cta: "Read",
      reward: `${CLIENT_QUEST_POINTS["review-risk-basics"]} pts`,
    })
    expect(byId([], "favorite-market")).toMatchObject({
      status: "available",
      cta: "Pin",
      reward: `${CLIENT_QUEST_POINTS["favorite-market"]} pts`,
    })
    expect(byId([], "favorite-lend-market")).toMatchObject({
      status: "available",
      cta: "Pin",
      reward: `${CLIENT_QUEST_POINTS["favorite-lend-market"]} pts`,
    })
    expect(byId(["favorite-market"], "favorite-market")).toMatchObject({ status: "claimed", cta: "Earned" })
    expect(questDialog("review-risk-basics")).toBe("primer")
    expect(questDialog("favorite-market")).toBe("pin-pool")
    expect(questDialog("favorite-lend-market")).toBe("pin-lend")
    expect(questHref("favorite-market")).toBeUndefined()
    expect(questDialog("first-borrow")).toBeUndefined()
  })

  it("opens the referral dialog for the three referral quests", () => {
    for (const id of ["share-referral-link", "invite-first-wallet", "bring-3-active-users"]) {
      expect(byId([], id)).toMatchObject({ status: "available", cta: "Invite" })
      expect(questDialog(id)).toBe("referral")
    }
    expect(byId(["bring-3-active-users"], "bring-3-active-users")).toMatchObject({ status: "claimed", cta: "Earned" })
  })

  it("opens the page of a real quest that is not done and marks a done one Earned", () => {
    expect(byId([], "first-lend-deposit")).toMatchObject({ status: "available", cta: "Deposit" })
    expect(byId([], "supply-500-lend")).toMatchObject({ status: "available", cta: "Deposit" })
    expect(byId(["supply-500-lend"], "supply-500-lend")).toMatchObject({ status: "claimed", cta: "Earned" })
    expect(byId([], "first-borrow")).toMatchObject({ status: "available", cta: "Borrow" })
    expect(byId([], "first-repay")).toMatchObject({ status: "available", cta: "Repay" })
    expect(byId([], "pledge-uniswap-v3-position")).toMatchObject({ status: "available", cta: "Pledge" })
    expect(byId(["first-borrow"], "first-borrow")).toMatchObject({ status: "claimed", cta: "Earned" })
    expect(byId(["first-borrow"], "first-repay")).toMatchObject({ status: "available" })
    expect(questHref("first-lend-deposit")).toBe("/lend")
    expect(questHref("first-borrow")).toBe("/borrow")
  })

  it("gives every quest a button that opens a page or a dialog, and none Coming soon", () => {
    const cards = all([])
    expect(cards).toHaveLength(12)
    for (const q of cards) {
      expect(q.status, q.id).toBe("available")
      expect(Boolean(questHref(q.id)) !== Boolean(questDialog(q.id)), q.id).toBe(true)
      const points = QUEST_POINTS[q.id] ?? CLIENT_QUEST_POINTS[q.id] ?? REFERRAL_QUEST_POINTS[q.id]
      expect(q.reward, q.id).toBe(`${points} pts`)
    }
    expect(cards.some((q) => /AVA|Coming soon/.test(`${q.reward} ${q.cta}`))).toBe(false)
  })

  it("has the button labels and the Earned label translated in every locale", () => {
    for (const lang of Object.keys(TRANSLATIONS).filter((l) => l !== "EN")) {
      for (const key of ["Deposit", "Borrow", "Repay", "Pledge", "Earned", "Connect Wallet", "Read", "Pin", "Invite"]) {
        expect(translate(lang as keyof typeof TRANSLATIONS, key), `${lang} ${key}`).not.toBe(key)
      }
    }
  })
})
