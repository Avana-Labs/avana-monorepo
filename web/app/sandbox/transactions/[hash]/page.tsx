import type { Metadata } from "next"
import { SyntheticTransactionClient } from "./synthetic-transaction-client"

export const metadata: Metadata = {
  title: "Transaction receipt",
  description: "View an authenticated Avana transaction receipt.",
}

export default async function SyntheticTransactionPage({ params }: { params: Promise<{ hash: string }> }) {
  const { hash } = await params
  return <SyntheticTransactionClient hash={decodeURIComponent(hash)} />
}
