import { redirect } from "next/navigation"
import { borrowAssetDetailPath, normalizeBorrowAssetRouteId } from "@/app/lib/borrow-routes"

type PageProps = {
  params: Promise<{ assetId: string }>
}

/** Older singular asset links: redirect to the asset detail page. */
export default async function AssetDetailRedirectPage({ params }: PageProps) {
  const { assetId } = await params
  redirect(borrowAssetDetailPath(normalizeBorrowAssetRouteId(assetId)))
}
