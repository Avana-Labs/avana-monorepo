import { redirect } from "next/navigation"
import type { Metadata } from "next"
import { borrowAssetDetailPath, getAssetDetail, normalizeBorrowAssetRouteId } from "@/app/lib/borrow-detail"

type PageProps = {
  params: Promise<{ assetId: string }>
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { assetId } = await params
  const detail = getAssetDetail(assetId)
  if (!detail) return { title: "Asset · Avana" }
  return {
    title: `${detail.hero.symbol} · Avana Borrow`,
    description: detail.about.description,
  }
}

export default async function AssetDetailPage({ params }: PageProps) {
  const { assetId } = await params
  redirect(borrowAssetDetailPath(normalizeBorrowAssetRouteId(assetId)))
}
