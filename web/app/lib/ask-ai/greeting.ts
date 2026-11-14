/**
 * Personalized empty-state greeting for Ask AI.
 * Uses the onboarding display name (`sandboxProfiles.preferences.name`) when present,
 * plus the user's local clock for time-of-day tone.
 */

type AskAIDayPart = "morning" | "afternoon" | "evening" | "late"

/** Local-hour buckets for greeting tone. */
export function dayPartFromLocalHour(hour: number): AskAIDayPart {
  if (hour >= 5 && hour < 12) return "morning"
  if (hour >= 12 && hour < 17) return "afternoon"
  if (hour >= 17 && hour < 22) return "evening"
  return "late"
}

/** First whitespace-separated token; empty/whitespace → null. */
export function firstNameFromDisplayName(name: string | null | undefined): string | null {
  const trimmed = name?.trim()
  if (!trimmed) return null
  const first = trimmed.split(/\s+/)[0]?.trim()
  return first || null
}

const WITH_NAME: Record<AskAIDayPart, readonly string[]> = {
  morning: ["Morning, {name}!", "Good morning, {name}.", "Hey, {name}!", "Welcome back, {name}!"],
  afternoon: ["Afternoon, {name}!", "Good afternoon, {name}.", "Hey, {name}!", "Welcome back, {name}!"],
  evening: ["Evening, {name}!", "Good evening, {name}.", "Hey, {name}!", "Welcome back, {name}!"],
  late: ["Hey, {name}!", "Welcome back, {name}!"],
}

const WITHOUT_NAME: Record<AskAIDayPart, readonly string[]> = {
  morning: ["Good morning!", "Welcome back!"],
  afternoon: ["Good afternoon!", "Welcome back!"],
  evening: ["Good evening!", "Welcome back!"],
  late: ["Welcome back!", "Hey!"],
}

function pickTemplate(pool: readonly string[], seed: number): string {
  const index = ((seed % pool.length) + pool.length) % pool.length
  return pool[index] ?? pool[0]!
}

/**
 * Short warm greeting. Stable for a given calendar day + day-part so remounts
 * don't flicker; still varies across days.
 */
export function formatAskAIGreeting(name: string | null | undefined, now: Date = new Date()): string {
  const first = firstNameFromDisplayName(name)
  const part = dayPartFromLocalHour(now.getHours())
  const pool = first ? WITH_NAME[part] : WITHOUT_NAME[part]
  const seed = now.getFullYear() * 400 + now.getMonth() * 40 + now.getDate() * 4 + part.length
  const template = pickTemplate(pool, seed)
  return first ? template.replaceAll("{name}", first) : template
}
