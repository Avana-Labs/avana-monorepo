"use client"

import { useConvexAuth, useMutation, useQuery } from "convex/react"
import { useEffect, useRef } from "react"
import { api } from "@/convex/_generated/api"
import { useDisplayPreferences } from "@/app/components/display-preferences"
import { useTheme } from "@/app/components/theme-provider"
import {
  applyRemotePreferences,
  normalizePreferences,
  serializePreferences,
  snapshotLocalPreferences,
  type StoredPreferences,
} from "@/app/components/preferences-sync"

/**
 * Keeps signed-in display preferences (theme / language / currency / show-$) aligned
 * with the Convex wallet profile across devices.
 *
 * - Bootstrap once per wallet: pull remote if present, otherwise seed from local.
 * - After bootstrap: apply any later remote preference updates (other device / tab via Convex).
 * - Local changes debounce-push to Convex; lastSavedKeyRef prevents echo loops.
 * - Applying remote updates local React state → localStorage → same-browser tab sync.
 */
export function PreferencesProfileSyncConnected({ wallet }: { wallet: string }) {
  const { isAuthenticated } = useConvexAuth()
  const { theme, setTheme } = useTheme()
  const { language, setLanguage, currency, setCurrency, showDollarAmounts, setShowDollarAmounts } =
    useDisplayPreferences()
  const profile = useQuery(api.wallet.profiles.getMine, isAuthenticated ? {} : "skip") as
    { preferences?: StoredPreferences } | null | undefined
  const savePreferences = useMutation(api.wallet.profiles.savePreferences)
  const bootstrappedWalletRef = useRef<string | null>(null)
  const lastSavedKeyRef = useRef<string | null>(null)

  // Pull: bootstrap + live remote updates for the active wallet.
  useEffect(() => {
    if (!isAuthenticated || profile === undefined) return

    const local = { theme, language, currency, showDollarAmounts }
    const setters = { setTheme, setLanguage, setCurrency, setShowDollarAmounts }
    const remote = normalizePreferences(profile?.preferences)
    const isBootstrap = bootstrappedWalletRef.current !== wallet

    if (isBootstrap) {
      if (remote) {
        const remoteKey = serializePreferences(remote)
        lastSavedKeyRef.current = remoteKey
        applyRemotePreferences(remote, local, setters)
      } else {
        const localPreferences = snapshotLocalPreferences(local)
        lastSavedKeyRef.current = serializePreferences(localPreferences)
        void savePreferences({ preferences: localPreferences }).catch((error: unknown) => {
          lastSavedKeyRef.current = null
          if (process.env.NODE_ENV !== "production") {
            console.warn("[preferences-sync] failed to persist initial preferences to Convex:", error)
          }
        })
      }
      bootstrappedWalletRef.current = wallet
      return
    }

    // Live multi-device: another client wrote preferences; apply if they differ from our echo key.
    if (!remote) return
    const remoteKey = serializePreferences(remote)
    if (remoteKey === lastSavedKeyRef.current) return

    lastSavedKeyRef.current = remoteKey
    applyRemotePreferences(remote, local, setters)
  }, [
    currency,
    isAuthenticated,
    language,
    savePreferences,
    setCurrency,
    setLanguage,
    setShowDollarAmounts,
    setTheme,
    showDollarAmounts,
    profile,
    theme,
    wallet,
  ])

  // Push: local UI changes → Convex (skipped when key matches what we last pulled/pushed).
  useEffect(() => {
    if (!isAuthenticated || bootstrappedWalletRef.current !== wallet) return
    const nextPreferences = snapshotLocalPreferences({ theme, language, currency, showDollarAmounts })
    const nextKey = serializePreferences(nextPreferences)
    if (nextKey === lastSavedKeyRef.current) return
    const timeoutId = window.setTimeout(() => {
      lastSavedKeyRef.current = nextKey
      void savePreferences({ preferences: nextPreferences }).catch((error: unknown) => {
        lastSavedKeyRef.current = null
        if (process.env.NODE_ENV !== "production") {
          console.warn("[preferences-sync] failed to persist display preferences to Convex:", error)
        }
      })
    }, 250)
    return () => window.clearTimeout(timeoutId)
  }, [currency, isAuthenticated, language, savePreferences, showDollarAmounts, theme, wallet])

  return null
}
