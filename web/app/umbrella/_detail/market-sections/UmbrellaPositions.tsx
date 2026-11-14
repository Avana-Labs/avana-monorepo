"use client"

import Link from "next/link"
import { ActionIcon } from "@/app/components/action-icon"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"
import {
  MarketMobileActionFooter,
  MarketMobileCard,
  MarketMobileCardHeader,
  MarketMobileIdentityText,
  MarketMobileMetric,
  MarketMobileStatList,
  MarketMobileStatRow,
  MarketMobileSupportingValue,
  MARKET_MOBILE_CTA_CLASS,
} from "@/app/components/market-card-primitives"
import { DesktopTableSurface, HoverActionGroup, SilentActionHeader } from "@/app/components/market-table-primitives"
import { TokenIcon } from "@/app/components/token-icon"
import { Button } from "@/components/ui/button"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import { useUmbrellaSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { useOptionalDisplayPreferences } from "@/app/components/display-preferences"
import { LiveInterestEarnedUsd } from "@/app/dashboard/live-accrual"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import type { UmbrellaMarketId } from "@/app/lib/umbrella-system/use-umbrella-session"
import {
  TABLE_CELL_NUMERIC,
  TABLE_CELL_SECONDARY,
  TABLE_CELL_SECONDARY_UNCOLORED,
  TABLE_HEADER_CELL,
  TABLE_ROW_HOVER_BG,
  TABLE_ROW_HOVER_LEFT,
  TABLE_ROW_HOVER_RIGHT,
} from "@/app/lib/ui/table-row-hover"
import { cn } from "@/lib/utils"
import { formatPct, formatUnits, formatUsd } from "../format"

const MASK = "••••"

type PositionRow = {
  id: UmbrellaMarketId
  asset: string
  symbol: string
  coverage: string
  activeStakeUsd: number
  coolingUsd: number
  activeStakeAmountLabel: string
  activeStakeUsdLabel: string
  coolingLabel: string
  apyTotal: string
  apyReward: string
  rewardApyPct: number
  rewardAnchorMs: number
  rewardPrincipalUsd: number
  pendingRewards: number
  claimedRewardsUsd: number
  claimedRewardsLabel: string
  cooldownStatus: "idle" | "cooling" | "ready" | "expired"
  hasClaim: boolean
}

function PositionHeader({ label, tooltip }: { label: string; tooltip: string }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      {label}
      <ActionMetricHelp text={tooltip} topic={label} />
    </span>
  )
}

const COVERED_RESERVE_LABELS: Record<UmbrellaMarketId, string> = {
  gho: "Stable Hub Deficits",
  usdc: "Stable Hub Deficits",
  usdt: "Correlated Hub Deficits",
  weth: "Correlated Hub Deficits",
}

export function UmbrellaPositions({ onSelectMarket }: { onSelectMarket?: (marketId: UmbrellaMarketId) => void }) {
  const { t } = useTranslation()
  const umbrella = useUmbrellaSessionContext()
  const showDollarAmounts = useOptionalDisplayPreferences()?.showDollarAmounts ?? true
  const rows: PositionRow[] = umbrella.marketOrder.map((id) => {
    const market = umbrella.markets[id]
    const position = umbrella.positions[id]
    const activeStake = Math.max(position.amount - position.cooldownAmount, 0)
    const activeStakeUsd = Math.max(position.valueUsd - position.cooldownValueUsd, 0)
    return {
      id,
      asset: market.asset,
      symbol: market.symbol,
      coverage: COVERED_RESERVE_LABELS[id],
      activeStakeUsd,
      // An expired cooldown no longer counts as cooling (the "In cooldown" card reads $0 and the
      // stake must restart it), so the row showed "In cooldown $2,497" against "$0" above.
      coolingUsd: position.cooldownStatus === "expired" ? 0 : position.cooldownValueUsd,
      activeStakeAmountLabel: `${formatUnits(activeStake)} ${market.symbol}`,
      activeStakeUsdLabel: formatUsd(activeStakeUsd),
      coolingLabel: formatUsd(position.cooldownStatus === "expired" ? 0 : position.cooldownValueUsd),
      apyTotal: `${formatPct(market.apy)}%`,
      apyReward: `${formatPct(market.rewardApy)}%`,
      rewardApyPct: market.rewardApy,
      rewardAnchorMs: position.updatedAt,
      rewardPrincipalUsd: position.valueUsd,
      pendingRewards: position.pendingRewardsUsd,
      claimedRewardsUsd: position.claimedRewardsUsd,
      claimedRewardsLabel: formatUsd(position.claimedRewardsUsd),
      cooldownStatus: position.cooldownStatus,
      hasClaim: position.pendingRewardsUsd > 0,
    }
  })

  const idleRow = (row: PositionRow) => row.activeStakeUsd === 0 && row.coolingUsd === 0 && row.pendingRewards === 0
  const nonIdle = rows.filter((row) => !idleRow(row) || umbrella.walletBalances[row.id] > 0)
  const showEmptyState = nonIdle.length === 0
  const visible = showEmptyState ? [] : nonIdle

  const handleRowClick = (id: UmbrellaMarketId) => {
    onSelectMarket?.(id)
  }

  return (
    <section aria-label={t("Umbrella positions")}>
      <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
        <h2 className="text-[22px] font-medium leading-none tracking-[-0.03em] text-foreground md:text-[24px]">
          {t("Umbrella positions")}
        </h2>
      </div>

      <div className="hidden md:block">
        <DesktopTableSurface className="!rounded-none">
          <table className="w-full min-w-[640px] table-fixed border-separate border-spacing-0 text-[13px]">
            <colgroup>
              <col className="w-[34%]" />
              <col className="w-[18%]" />
              <col className="w-[15%]" />
              <col className="w-[15%]" />
              <col className="w-[18%]" />
            </colgroup>
            <thead>
              <tr className="text-left">
                <th className={cn(TABLE_HEADER_CELL, "pl-5")}>
                  <PositionHeader
                    label={t("Covered reserve")}
                    tooltip={t(
                      "The Hub asset this Umbrella market protects. Deficits from any eligible Spoke borrowing this reserve can be covered by this market.",
                    )}
                  />
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4 text-right")}>
                  <PositionHeader
                    label={t("Deposited")}
                    tooltip={t(
                      "The amount of Umbrella capital currently deposited and available to absorb deficits for this covered reserve. Capital in cooldown is no longer counted as fully available protection.",
                    )}
                  />
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4 text-right")}>
                  <PositionHeader
                    label={t("Cooling")}
                    tooltip={t(
                      "The amount of staked capital currently in the cooldown period before it can be withdrawn. A larger cooling balance means less protection may remain available if those funds exit.",
                    )}
                  />
                </th>
                <th className={cn(TABLE_HEADER_CELL, "px-4 text-right")}>
                  <PositionHeader
                    label={t("Rewards")}
                    tooltip={t(
                      "The staking rewards you have earned for providing Umbrella coverage. Rewards may include protocol incentives and other compensation for taking slashing and lockup risk.",
                    )}
                  />
                </th>
                <SilentActionHeader className="!rounded-none pr-5" />
              </tr>
            </thead>
            <tbody className="divide-y divide-border dark:divide-white/6">
              {showEmptyState ? (
                <tr>
                  <td colSpan={5} className="py-8 pl-5 pr-5 text-center">
                    <div className="flex flex-wrap items-center justify-center gap-3">
                      <span className="text-[14px] text-muted-foreground">
                        {t("You have no Umbrella positions yet.")}
                      </span>
                      <Button asChild size="table" variant="table-primary" className="w-auto">
                        <Link href={actionPagePath("umbrella", "stake", { return: "/umbrella" })}>
                          <ActionIcon label={t("Stake")} />
                          {t("Stake")}
                        </Link>
                      </Button>
                    </div>
                  </td>
                </tr>
              ) : (
                visible.map((row) => (
                  <tr
                    key={row.id}
                    className="group cursor-pointer transition-colors"
                    onClick={() => handleRowClick(row.id)}
                  >
                    <td className={cn("py-3.5 pl-5", TABLE_ROW_HOVER_LEFT)}>
                      <div className="flex items-center gap-2.5">
                        <TokenIcon symbol={row.symbol} size="table" />
                        <div className="flex min-w-0 flex-col">
                          <span className="truncate text-[15px] font-medium tracking-[-0.03em] text-foreground dark:text-white">
                            {row.asset}
                          </span>
                          <span className="mt-0.5 truncate text-[13px] text-muted-foreground">{row.coverage}</span>
                        </div>
                      </div>
                    </td>
                    <td className={cn("py-3.5 px-4 text-right", TABLE_ROW_HOVER_BG)}>
                      <div className="flex flex-col items-end">
                        <span className={cn(TABLE_CELL_NUMERIC, "tracking-[-0.03em]")}>
                          {showDollarAmounts ? row.activeStakeAmountLabel : MASK}
                        </span>
                        <span className={TABLE_CELL_SECONDARY}>
                          {showDollarAmounts ? row.activeStakeUsdLabel : MASK}
                        </span>
                      </div>
                    </td>
                    <td className={cn("py-3.5 px-4 text-right", TABLE_ROW_HOVER_BG)}>
                      <div className="flex flex-col items-end">
                        <span className={cn(TABLE_CELL_NUMERIC, row.coolingUsd > 0 && "text-warning")}>
                          {showDollarAmounts ? row.coolingLabel : MASK}
                        </span>
                        {row.cooldownStatus === "expired" ? (
                          <span className="mt-0.5 text-[12px] text-danger">{t("Cooldown expired")}</span>
                        ) : row.coolingUsd > 0 ? (
                          <span className="mt-0.5 text-[12px] text-warning">{t("In cooldown")}</span>
                        ) : null}
                      </div>
                    </td>
                    <td className={cn("py-3.5 px-4 text-right", TABLE_ROW_HOVER_BG)}>
                      <div className="flex flex-col items-end">
                        <span className={TABLE_CELL_NUMERIC}>{showDollarAmounts ? row.apyReward : MASK}</span>
                        <span className={cn(TABLE_CELL_SECONDARY_UNCOLORED, "text-success")}>
                          {showDollarAmounts ? (
                            <>
                              +
                              <LiveInterestEarnedUsd
                                anchorMs={row.rewardAnchorMs}
                                ratePerYearUsd={(row.rewardPrincipalUsd * row.rewardApyPct) / 100}
                                baseUsd={row.pendingRewards}
                                fractionDigits={4}
                              />
                            </>
                          ) : (
                            MASK
                          )}
                        </span>
                      </div>
                    </td>
                    <td
                      className={cn("py-3.5 pr-5", TABLE_ROW_HOVER_RIGHT)}
                      onClick={(event) => event.stopPropagation()}
                    >
                      <HoverActionGroup className="justify-end">
                        {row.hasClaim ? (
                          <Button asChild size="table" variant="table-secondary" className="w-auto">
                            <Link
                              href={actionPagePath("umbrella", "claim", {
                                market: row.id,
                                return: "/umbrella",
                              })}
                            >
                              <ActionIcon label={t("Claim")} />
                              {t("Claim")}
                            </Link>
                          </Button>
                        ) : null}
                      </HoverActionGroup>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </DesktopTableSurface>
      </div>

      <div className="space-y-2 md:hidden">
        {showEmptyState ? (
          <MarketMobileCard className="flex flex-col items-center gap-3 py-6 text-center">
            <span className="text-[14px] text-muted-foreground">{t("You have no Umbrella positions yet.")}</span>
            <Button asChild size="sm" variant="brand" className="h-10 w-full gap-2">
              <Link href={actionPagePath("umbrella", "stake", { return: "/umbrella" })}>
                <ActionIcon label={t("Stake")} />
                {t("Stake")}
              </Link>
            </Button>
          </MarketMobileCard>
        ) : (
          visible.map((row) => (
            <MarketMobileCard key={row.id} clickable className="space-y-2" onClick={() => handleRowClick(row.id)}>
              <MarketMobileCardHeader
                identity={
                  <div className="flex min-w-0 items-center gap-2.5">
                    <TokenIcon symbol={row.symbol} size="table" />
                    <MarketMobileIdentityText title={row.asset} subtitle={row.coverage} />
                  </div>
                }
                metric={<MarketMobileMetric value={showDollarAmounts ? row.apyTotal : MASK} label={t("APY")} />}
              />
              <MarketMobileStatList>
                <MarketMobileStatRow
                  label={t("Deposited")}
                  value={
                    <div className="flex flex-col items-end">
                      <span>{showDollarAmounts ? row.activeStakeAmountLabel : MASK}</span>
                      <MarketMobileSupportingValue>
                        {showDollarAmounts ? row.activeStakeUsdLabel : MASK}
                      </MarketMobileSupportingValue>
                    </div>
                  }
                />
                {row.coolingUsd > 0 ? (
                  <MarketMobileStatRow
                    label={t("Cooling")}
                    value={showDollarAmounts ? row.coolingLabel : MASK}
                    valueClassName="text-warning"
                  />
                ) : null}
                <MarketMobileStatRow
                  label={t("Rewards")}
                  value={
                    <div className="flex flex-col items-end">
                      <span>{showDollarAmounts ? row.apyReward : MASK}</span>
                      <MarketMobileSupportingValue>
                        {showDollarAmounts ? (
                          <>
                            +
                            <LiveInterestEarnedUsd
                              anchorMs={row.rewardAnchorMs}
                              ratePerYearUsd={(row.rewardPrincipalUsd * row.rewardApyPct) / 100}
                              baseUsd={row.pendingRewards}
                              fractionDigits={4}
                            />
                          </>
                        ) : (
                          MASK
                        )}
                      </MarketMobileSupportingValue>
                      {row.claimedRewardsUsd > 0 ? (
                        <MarketMobileSupportingValue>
                          {t("{amount} claimed").replace("{amount}", row.claimedRewardsLabel)}
                        </MarketMobileSupportingValue>
                      ) : null}
                    </div>
                  }
                  valueClassName="text-success"
                />
              </MarketMobileStatList>
              <div onClick={(event) => event.stopPropagation()}>
                <MarketMobileActionFooter>
                  {row.hasClaim ? (
                    <Button asChild variant="brand" className={MARKET_MOBILE_CTA_CLASS}>
                      <Link
                        href={actionPagePath("umbrella", "claim", {
                          market: row.id,
                          return: "/umbrella",
                        })}
                      >
                        <ActionIcon label={t("Claim")} />
                        {t("Claim")}
                      </Link>
                    </Button>
                  ) : (
                    <Button type="button" variant="brand" className={MARKET_MOBILE_CTA_CLASS} disabled>
                      <ActionIcon label={t("Claim")} />
                      {t("Claim")}
                    </Button>
                  )}
                  <Button asChild variant="brand-secondary" className={MARKET_MOBILE_CTA_CLASS}>
                    <Link
                      href={actionPagePath("umbrella", "stake", {
                        market: row.id,
                        return: "/umbrella",
                      })}
                    >
                      <ActionIcon label={t("Stake")} />
                      {t("Stake")}
                    </Link>
                  </Button>
                </MarketMobileActionFooter>
              </div>
            </MarketMobileCard>
          ))
        )}
      </div>
    </section>
  )
}
