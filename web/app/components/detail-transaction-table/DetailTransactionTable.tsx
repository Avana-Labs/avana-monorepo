"use client"

import { TablePager, useTablePagination } from "@/app/components/table-pager"
import type { DetailTransactionRow } from "@/app/lib/detail-page/transaction-history"
import { formatRelativeTime } from "@/app/lib/detail-page/transaction-history"
import { useCurrency } from "@/app/lib/currency/use-currency"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { TABLE_ROW_HOVER_BG, TABLE_ROW_HOVER_LEFT, TABLE_ROW_HOVER_RIGHT } from "@/app/lib/ui/table-row-hover"
import { cn } from "@/lib/utils"
import {
  PRESET_COLUMNS,
  resolveColumnLabel,
  resolveTransactionKindLabel,
  resolveTransactionKindTone,
  type DetailTransactionPreset,
  type TransactionKindConfig,
} from "./kind-configs"
import {
  TransactionPoolTokenCell,
  TransactionTokenCell,
  TransactionUsdCell,
  useDetailTransactionPriceContext,
} from "./transaction-token-cell"

type Props = {
  transactions: DetailTransactionRow[]
  preset?: DetailTransactionPreset
  kindConfig: TransactionKindConfig
  context?: Record<string, string>
  title?: string
  /**
   * Debt/asset feed only: re-derive each row's token quantity from its recorded USD at the live
   * price and show that recorded USD, so the two cells reconcile with the transaction record (a
   * single borrowed token's quantity is otherwise reconstructed at a frozen seed price and drifts
   * from the live-priced USD). Off for pool/lend/multiply, which carry real recorded amounts.
   */
  reconcileTokenToLiveUsd?: boolean
}

const COLUMN_WIDTHS: Record<DetailTransactionPreset, string[]> = {
  standard: ["13%", "14%", "28%", "18%", "27%"],
  pool: ["12%", "12%", "16%", "20%", "20%", "20%"],
}

export function DetailTransactionTable({
  transactions,
  preset = "standard",
  kindConfig,
  context = {},
  title = "Transactions",
  reconcileTokenToLiveUsd = false,
}: Props) {
  const { t, language } = useTranslation()
  const { ctx } = useCurrency()
  const columns = PRESET_COLUMNS[preset]
  const priceContext = useDetailTransactionPriceContext(context)
  const token0Symbol = context.token0Symbol ?? ""
  const token1Symbol = context.token1Symbol ?? ""
  const poolSymbols =
    preset === "pool" && token0Symbol && token1Symbol ? { token0: token0Symbol, token1: token1Symbol } : undefined

  const { page, pageCount, pageItems: pageRows, setPage } = useTablePagination(transactions)

  return (
    <section className="min-w-0">
      <div className="mb-4">
        <h2 className="text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
          {t(title)}
        </h2>
      </div>

      {transactions.length === 0 ? (
        <div className="rounded-radius-md border border-border px-4 py-8 text-center text-[13px] text-muted-foreground">
          {t("No transactions yet")}
        </div>
      ) : (
        <>
          <div className="overflow-x-auto md:overflow-x-visible">
            <table className="w-full min-w-[40rem] table-fixed border-separate border-spacing-0 text-[13px] md:min-w-0">
              <colgroup>
                {COLUMN_WIDTHS[preset].map((width, index) => (
                  <col key={columns[index]?.id ?? index} style={{ width }} />
                ))}
              </colgroup>
              <thead>
                <tr className="text-left text-[11px] font-medium uppercase tracking-[0.06em] text-muted-foreground">
                  {columns.map((column, index) => (
                    <th
                      key={column.id}
                      className={cn(
                        "overflow-hidden bg-table-header px-2 pb-2 pt-2.5 text-[11px] font-medium uppercase tracking-[0.08em] text-muted-foreground dark:text-white/58",
                        index === 0 && "rounded-l-radius-lg pl-4",
                        index === columns.length - 1 && "rounded-r-radius-lg pr-4",
                      )}
                    >
                      {t(resolveColumnLabel(column, context, ctx.currency))}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {pageRows.map((row) => (
                  <tr key={row.id} className="group transition-colors">
                    {columns.map((column, index) => {
                      const hoverClass =
                        index === 0
                          ? `${TABLE_ROW_HOVER_LEFT} group-hover:rounded-l-radius-lg`
                          : index === columns.length - 1
                            ? `${TABLE_ROW_HOVER_RIGHT} group-hover:rounded-r-radius-lg`
                            : TABLE_ROW_HOVER_BG
                      const padX = index === 0 ? "pl-4 pr-2" : index === columns.length - 1 ? "pl-2 pr-4" : "px-2"
                      const cellClass = cn("overflow-hidden py-2.5 align-middle", padX, hoverClass)

                      if (column.id === "time") {
                        return (
                          <td
                            key={column.id}
                            className={cn(
                              cellClass,
                              "font-data text-[13px] font-medium tabular-nums text-muted-foreground",
                            )}
                          >
                            {row.timeLabel ?? formatRelativeTime(row.at, language)}
                          </td>
                        )
                      }

                      if (column.id === "type") {
                        return (
                          <td key={column.id} className={cellClass}>
                            <span
                              className={cn(
                                "inline-block whitespace-nowrap text-[14px] font-medium tracking-normal",
                                resolveTransactionKindTone(kindConfig, row.kind),
                              )}
                            >
                              {t(resolveTransactionKindLabel(kindConfig, row.kind))}
                            </span>
                          </td>
                        )
                      }

                      if (column.id === "for") {
                        return (
                          <td key={column.id} className={cellClass}>
                            <TransactionTokenCell
                              row={row}
                              priceContext={priceContext}
                              reconcileToLiveUsd={reconcileTokenToLiveUsd}
                            />
                          </td>
                        )
                      }

                      if (column.id === "usd") {
                        return (
                          <td key={column.id} className={cellClass}>
                            <TransactionUsdCell
                              row={row}
                              priceContext={priceContext}
                              poolSymbols={poolSymbols}
                              reconcileToLiveUsd={reconcileTokenToLiveUsd}
                            />
                          </td>
                        )
                      }

                      if (column.id === "token0" || column.id === "token1") {
                        return (
                          <td key={column.id} className={cellClass}>
                            <TransactionPoolTokenCell
                              row={row}
                              leg={column.id}
                              token0Symbol={token0Symbol}
                              token1Symbol={token1Symbol}
                              priceContext={priceContext}
                            />
                          </td>
                        )
                      }

                      return (
                        <td
                          key={column.id}
                          className={cn(cellClass, "font-data text-[13px] font-normal tabular-nums text-foreground")}
                        >
                          {row.walletHref ? (
                            <a
                              href={row.walletHref}
                              target="_blank"
                              rel="noreferrer"
                              className="block w-full truncate whitespace-nowrap text-foreground underline-offset-2 hover:underline"
                            >
                              {row.walletLabel ?? row.txHashShort}
                            </a>
                          ) : (
                            <span className="block w-full truncate whitespace-nowrap">
                              {row.walletLabel ?? row.txHashShort}
                            </span>
                          )}
                        </td>
                      )
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <TablePager page={page} pageCount={pageCount} onPageChange={setPage} label={t("Transactions pagination")} />
        </>
      )}
    </section>
  )
}
