"use client"

import { lazy, Suspense, useCallback, useMemo, useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useTranslation } from "@/app/lib/i18n/use-translation"

export type SupportSubmitPayload = {
  category: string
  categoryLabel?: string
  topic: string
  topicLabel?: string
  message: string
}

export type SupportSubmit = (payload: SupportSubmitPayload) => Promise<void>

type SupportArticle = {
  title: string
  body: string
}

type SupportTopic = {
  value: string
  label: string
  articles: SupportArticle[]
}

type SupportCategory = {
  value: string
  label: string
  topics: SupportTopic[]
}

type Translate = (key: string) => string

/** Built with literal `t("…")` keys so i18n parity extracts every support string. */
function getSupportCategories(t: Translate): SupportCategory[] {
  return [
    {
      value: "core-concepts",
      label: t("Core Concepts"),
      topics: [
        {
          value: "what-is-avana",
          label: t("What is Avana?"),
          articles: [
            {
              title: t("Protocol overview"),
              body: t("Avana is an LP-collateral lending protocol built around Aave v4's Hub-and-Spoke architecture."),
            },
            {
              title: t("Why it exists"),
              body: t(
                "The goal is to let liquidity providers borrow against active positions without unwinding the pool position first.",
              ),
            },
          ],
        },
        {
          value: "what-is-a-borrow-spoke",
          label: t("What does the Borrow Spoke do?"),
          articles: [
            {
              title: t("LP-specific underwriting"),
              body: t(
                "Borrow Spokes value supported positions, monitor health, and route liquidation behavior for LP collateral.",
              ),
            },
            {
              title: t("Shared coordination"),
              body: t(
                "The Hub coordinates shared liquidity and debt accounting while the spoke handles the LP-specific logic.",
              ),
            },
          ],
        },
      ],
    },
    {
      value: "borrowing-capacity",
      label: t("Borrowing Capacity & Valuation"),
      topics: [
        {
          value: "capacity-calculation",
          label: t("How is borrowing capacity calculated?"),
          articles: [
            {
              title: t("Adjusted collateral value"),
              body: t(
                "Each approved LP position is valued independently, then collateral factors and pool-specific risk controls are applied.",
              ),
            },
            {
              title: t("Aggregated in the spoke"),
              body: t(
                "The spoke aggregates approved positions into borrowing capacity and the Hub enforces the result.",
              ),
            },
          ],
        },
        {
          value: "capacity-changes",
          label: t("Why did my capacity change?"),
          articles: [
            {
              title: t("Market movement"),
              body: t("Capacity can change when the underlying assets move or when recoverable value shifts."),
            },
            {
              title: t("Risk settings"),
              body: t(
                "Collateral factors and market-specific risk settings can also change the amount shown in the interface.",
              ),
            },
          ],
        },
      ],
    },
    {
      value: "health-liquidation",
      label: t("Health & Liquidation"),
      topics: [
        {
          value: "health-factor",
          label: t("What is the health factor?"),
          articles: [
            {
              title: t("How to read health"),
              body: t(
                "Health factor expresses the relationship between adjusted collateral value and outstanding debt inside one Borrow Spoke.",
              ),
            },
            {
              title: t("What it means for users"),
              body: t(
                "As the buffer shrinks, the position becomes more exposed to liquidation if market conditions move against it.",
              ),
            },
          ],
        },
        {
          value: "liquidation-flow",
          label: t("When can liquidation happen?"),
          articles: [
            {
              title: t("Triggers"),
              body: t(
                "If market moves weaken health enough, the position can become liquidatable under the spoke's rules.",
              ),
            },
            {
              title: t("What happens next"),
              body: t(
                "The spoke monitors risk continuously and routes liquidation behavior while the Hub keeps reserves coordinated.",
              ),
            },
          ],
        },
      ],
    },
    {
      value: "leverage-markets",
      label: t("Leverage Markets"),
      topics: [
        {
          value: "how-leverage-works",
          label: t("How do leverage markets work?"),
          articles: [
            {
              title: t("LP-backed exposure"),
              body: t(
                "Leverage markets let Avana support LP-backed borrowing and directional exposure in a more specialized workflow.",
              ),
            },
            {
              title: t("Position stacking"),
              body: t(
                "Borrowing capacity can be aggregated from multiple approved positions inside the same Borrow Spoke.",
              ),
            },
          ],
        },
        {
          value: "multiple-positions",
          label: t("Can one account use multiple LP positions?"),
          articles: [
            {
              title: t("Multiple positions"),
              body: t(
                "Yes. A single account can combine supported LP positions so long as each position passes the protocol's checks.",
              ),
            },
            {
              title: t("Per-position risk"),
              body: t(
                "Each position is evaluated on its own terms before being included in the final borrowing capacity.",
              ),
            },
          ],
        },
      ],
    },
    {
      value: "fees-policy",
      label: t("Fees & Interface Policy"),
      topics: [
        {
          value: "interface-fees",
          label: t("Are interface fees fixed across all integrations?"),
          articles: [
            {
              title: t("Operational settings"),
              body: t(
                "Exact fee rates, exemptions, and rollout status are operational settings and should be verified in the live interface.",
              ),
            },
            {
              title: t("Integration differences"),
              body: t(
                "Direct integrations or third-party frontends may follow different assumptions, so always verify the interface you are using.",
              ),
            },
          ],
        },
        {
          value: "protocol-economics",
          label: t("What counts as protocol economics vs interface policy?"),
          articles: [
            {
              title: t("Protocol layer"),
              body: t("Core collateral valuation, debt controls, and liquidation pathways live at the protocol layer."),
            },
            {
              title: t("Interface layer"),
              body: t(
                "The frontend can present policy, routing, and support flows differently from one integration to another.",
              ),
            },
          ],
        },
      ],
    },
    {
      value: "risk-security",
      label: t("Risk & Security"),
      topics: [
        {
          value: "main-risks",
          label: t("What are the main risks?"),
          articles: [
            {
              title: t("Market and liquidity risk"),
              body: t(
                "The main risks are market moves in the underlying assets, impermanent loss, and range drift for concentrated positions.",
              ),
            },
            {
              title: t("Liquidation risk"),
              body: t(
                "If the health buffer weakens while debt remains outstanding, the position can become liquidatable.",
              ),
            },
          ],
        },
        {
          value: "security-guidance",
          label: t("How should I think about security?"),
          articles: [
            {
              title: t("Protocol guidance"),
              body: t(
                "Use the same caution you would for any LP position and follow the protocol's risk guidance closely.",
              ),
            },
            {
              title: t("Support request"),
              body: t("If something looks off, send the details and our team can help you triage the issue."),
            },
          ],
        },
      ],
    },
  ]
}

type SendStatus = "idle" | "sending" | "sent" | "error"

function SupportCenterForm({ submit }: { submit: SupportSubmit }) {
  const { t } = useTranslation()
  const [stage, setStage] = useState<1 | 2 | 3>(1)
  const [categoryValue, setCategoryValue] = useState("")
  const [topicValue, setTopicValue] = useState("")
  const [message, setMessage] = useState("")
  const [sendStatus, setSendStatus] = useState<SendStatus>("idle")
  const [sendError, setSendError] = useState<string | null>(null)

  const categories = useMemo(() => getSupportCategories(t), [t])
  const selectedCategory = useMemo(
    () => categories.find((category) => category.value === categoryValue),
    [categories, categoryValue],
  )
  const selectedTopic = useMemo(
    () => selectedCategory?.topics.find((topic) => topic.value === topicValue),
    [selectedCategory, topicValue],
  )

  const hasArticles = Boolean(selectedTopic && stage >= 2)
  const canContinue = Boolean(selectedTopic)
  const canSend = message.trim().length >= 10 && sendStatus !== "sending"
  const footerLabel = stage === 3 ? (sendStatus === "sending" ? t("Sending…") : t("Send")) : t("Continue")

  const handleCategoryChange = (value: string) => {
    setCategoryValue(value)
    setTopicValue("")
    setMessage("")
    setStage(2)
  }

  const handleTopicChange = (value: string) => {
    setTopicValue(value)
    setMessage("")
  }

  const handleBack = () => {
    if (stage === 3) {
      setStage(2)
      return
    }

    if (topicValue) {
      setTopicValue("")
      setMessage("")
      return
    }

    if (categoryValue) {
      setCategoryValue("")
      setTopicValue("")
      setMessage("")
      setStage(1)
    }
  }

  const handleContinue = () => {
    if (canContinue) {
      setStage(3)
    }
  }

  const handleSend = useCallback(async () => {
    if (!selectedCategory || !selectedTopic || message.trim().length < 10) return
    setSendStatus("sending")
    setSendError(null)
    try {
      await submit({
        category: selectedCategory.value,
        categoryLabel: selectedCategory.label,
        topic: selectedTopic.value,
        topicLabel: selectedTopic.label,
        message: message.trim(),
      })
      setSendStatus("sent")
    } catch (error) {
      setSendStatus("error")
      setSendError(error instanceof Error ? error.message : t("Something went wrong. Please try again."))
    }
  }, [message, selectedCategory, selectedTopic, submit, t])

  const handleReset = useCallback(() => {
    setStage(1)
    setCategoryValue("")
    setTopicValue("")
    setMessage("")
    setSendStatus("idle")
    setSendError(null)
  }, [])

  return (
    <main className="min-h-[calc(100vh-56px)] bg-background text-foreground">
      <div className="mx-auto w-full max-w-[960px] px-4 pb-16 pt-8 sm:px-6 sm:pt-12 lg:px-8">
        <header className="border-b border-border pb-6 sm:pb-8">
          <h1 className="max-w-[20ch] text-[24px] font-medium leading-[1.15] tracking-[-0.03em] sm:text-[28px]">
            {t("How can we help?")}
          </h1>
        </header>

        <div className="mt-6 grid gap-7 sm:mt-8 lg:grid-cols-[210px_minmax(0,1fr)] lg:gap-14">
          <aside aria-label={t("Support progress")} className="lg:border-r lg:border-border lg:pr-8">
            <ol className="grid grid-cols-3 gap-2 lg:flex lg:flex-col lg:gap-6">
              {[
                [t("Choose topic"), stage >= 1],
                [t("Review resources"), Boolean(selectedTopic)],
                [t("Contact support"), stage === 3],
              ].map(([label, isActive], index) => (
                <li key={label as string} className="flex min-w-0 flex-col gap-2 lg:flex-row lg:items-center lg:gap-3">
                  <span
                    className={`flex size-7 shrink-0 items-center justify-center rounded-full border text-[12px] font-medium ${
                      isActive
                        ? "border-brand bg-brand text-white"
                        : "border-border bg-background text-muted-foreground"
                    }`}
                  >
                    {index + 1}
                  </span>
                  <span
                    className={`text-[11px] font-medium leading-tight sm:text-[12px] lg:text-[14px] ${
                      isActive ? "text-foreground" : "text-muted-foreground"
                    }`}
                  >
                    {label as string}
                  </span>
                </li>
              ))}
            </ol>
          </aside>

          <section className="min-w-0">
            {sendStatus === "sent" ? (
              <div className="max-w-[560px]">
                <div className="rounded-radius-md border border-border bg-card p-6 sm:p-8">
                  <div className="flex size-11 items-center justify-center rounded-full bg-brand/12 text-brand">
                    <svg viewBox="0 0 24 24" fill="none" className="size-6" aria-hidden>
                      <path
                        d="M5 13l4 4L19 7"
                        stroke="currentColor"
                        strokeWidth="2.2"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                      />
                    </svg>
                  </div>
                  <h2 className="mt-4 text-[22px] font-medium tracking-[-0.03em] text-foreground sm:text-[24px]">
                    {t("Request received")}
                  </h2>
                  <p className="mt-2 text-[15px] leading-6 text-muted-foreground">
                    {t("Thanks — we’ve logged your message about")}{" "}
                    <span className="font-medium text-foreground">{selectedTopic?.label}</span>{" "}
                    {t("and the Avana team will follow up. You can submit another request any time.")}
                  </p>
                  <Button
                    type="button"
                    onClick={handleReset}
                    className="mt-6 h-10 rounded-xs bg-brand px-5 text-[14px] font-medium text-white hover:bg-brand/90"
                  >
                    {t("Submit another request")}
                  </Button>
                </div>
              </div>
            ) : stage !== 3 ? (
              <div className="max-w-[560px] space-y-6 sm:space-y-7">
                <div>
                  <h2 className="text-[22px] font-medium tracking-[-0.03em] text-foreground sm:text-[24px]">
                    {t("Tell us what happened")}
                  </h2>
                  <p className="mt-2 text-[15px] leading-6 text-muted-foreground">
                    {t("Choose the closest match so we can show the most relevant guidance first.")}
                  </p>
                </div>

                <div className="space-y-5">
                  <div className="space-y-2">
                    <label htmlFor="support-category" className="block text-[14px] font-medium text-foreground">
                      {t("Category")}
                    </label>
                    <Select value={categoryValue} onValueChange={handleCategoryChange}>
                      <SelectTrigger
                        id="support-category"
                        className="h-11 w-full border-border bg-background px-3.5 text-[16px] font-normal shadow-none sm:text-[15px]"
                      >
                        <SelectValue placeholder={t("Select...")} />
                      </SelectTrigger>
                      <SelectContent className="max-h-[420px]">
                        {categories.map((category) => (
                          <SelectItem
                            key={category.value}
                            value={category.value}
                            className="py-3 text-[15px] font-normal"
                          >
                            {category.label}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>

                  {categoryValue ? (
                    <div className="space-y-2">
                      <label htmlFor="support-topic" className="block text-[14px] font-medium text-foreground">
                        {t("Topic")}
                      </label>
                      <Select value={topicValue} onValueChange={handleTopicChange}>
                        <SelectTrigger
                          id="support-topic"
                          className="h-11 w-full border-border bg-background px-3.5 text-[16px] font-normal shadow-none sm:text-[15px]"
                        >
                          <SelectValue placeholder={t("Select...")} />
                        </SelectTrigger>
                        <SelectContent className="max-h-[420px]">
                          {selectedCategory?.topics.map((topic) => (
                            <SelectItem key={topic.value} value={topic.value} className="py-3 text-[15px] font-normal">
                              {topic.label}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    </div>
                  ) : null}
                </div>

                {hasArticles ? (
                  <div className="border-y border-border py-5">
                    <h3 className="text-[15px] font-semibold text-foreground">{t("Recommended articles")}</h3>
                    <div className="mt-3 divide-y divide-border">
                      {selectedTopic?.articles.map((article) => (
                        <button key={article.title} type="button" className="block w-full py-3 text-left">
                          <div className="text-[15px] font-medium text-brand">{article.title}</div>
                          <p className="mt-1 max-w-[56ch] text-[13px] leading-5 text-muted-foreground">
                            {article.body}
                          </p>
                        </button>
                      ))}
                    </div>
                  </div>
                ) : null}
              </div>
            ) : (
              <div className="max-w-[560px] space-y-6 sm:space-y-7">
                <div className="border-b border-border pb-5">
                  <h2 className="text-[22px] font-medium tracking-[-0.03em] text-foreground sm:text-[24px]">
                    {t("Contact support")}
                  </h2>
                  <p className="mt-2 text-[15px] leading-6 text-muted-foreground">
                    {t("Tell us more about")}{" "}
                    <span className="font-medium text-foreground">{selectedTopic?.label}</span>.
                  </p>
                </div>

                <dl className="grid gap-x-6 gap-y-3 text-[13px] sm:grid-cols-2">
                  <div>
                    <dt className="font-medium text-muted-foreground">{t("Category")}</dt>
                    <dd className="mt-1 text-foreground">{selectedCategory?.label}</dd>
                  </div>
                  <div>
                    <dt className="font-medium text-muted-foreground">{t("Topic")}</dt>
                    <dd className="mt-1 text-foreground">{selectedTopic?.label}</dd>
                  </div>
                </dl>

                <div className="space-y-2">
                  <label htmlFor="support-message" className="block text-[14px] font-medium text-foreground">
                    {t("Describe the issue")}
                  </label>
                  <textarea
                    id="support-message"
                    value={message}
                    onChange={(event) => setMessage(event.target.value)}
                    className="h-[220px] w-full resize-none rounded-radius-sm border border-border bg-background px-3.5 py-3 text-[16px] leading-6 text-foreground outline-none transition-colors placeholder:text-muted-foreground/70 focus:border-brand focus:ring-2 focus:ring-brand/15 sm:h-[260px] sm:text-[15px]"
                    placeholder={t(
                      "Include what you were trying to do, what happened, and any transaction or market details that may help.",
                    )}
                  />
                </div>
              </div>
            )}

            {sendStatus !== "sent" ? (
              <>
                {sendStatus === "error" && sendError ? (
                  <p className="mt-5 max-w-[560px] rounded-radius-sm border border-rose-500/30 bg-rose-500/10 px-3.5 py-2.5 text-[13px] leading-5 text-rose-600 dark:text-rose-400">
                    {sendError}
                  </p>
                ) : null}
                <div className="mt-7 flex max-w-[560px] items-center justify-between gap-3 border-t border-border pt-5 sm:mt-9">
                  <Button
                    type="button"
                    variant="ghost"
                    onClick={handleBack}
                    disabled={sendStatus === "sending"}
                    className="h-10 px-0 text-[14px] font-medium text-brand hover:bg-transparent hover:text-brand/80 sm:h-9"
                  >
                    {t("Back")}
                  </Button>

                  <Button
                    type="button"
                    onClick={stage === 3 ? handleSend : handleContinue}
                    disabled={stage !== 3 ? !canContinue : !canSend}
                    className="h-10 rounded-xs bg-brand px-5 text-[14px] font-medium text-white hover:bg-brand/90 disabled:cursor-not-allowed disabled:bg-surface-inset disabled:text-muted-foreground sm:h-9"
                  >
                    {footerLabel}
                  </Button>
                </div>
              </>
            ) : null}
          </section>
        </div>
      </div>
    </main>
  )
}

const SupportCenterSubmissionBridge = lazy(async () => ({
  default: (await import("./support-center-submission-bridge")).SupportCenterSubmissionBridge,
}))

/**
 * Public entry. Uses the Convex-backed submitter whenever live Convex is
 * available (including open-gate, which authenticates as the test wallet).
 * Only mock/Playwright data mode skips the bridge so the form still works
 * without a backend.
 */
export function SupportCenterClient() {
  const submitRef = useRef<SupportSubmit>(async () => {})
  const submit = useCallback<SupportSubmit>((payload) => submitRef.current(payload), [])
  const handleConnectedSubmit = useCallback((connectedSubmit: SupportSubmit | null) => {
    submitRef.current = connectedSubmit ?? (async () => {})
  }, [])

  return (
    <>
      <Suspense fallback={null}>
        <SupportCenterSubmissionBridge onReady={handleConnectedSubmit} />
      </Suspense>
      <SupportCenterForm submit={submit} />
    </>
  )
}
