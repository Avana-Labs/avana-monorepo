const EMOJI_PATTERN = /[\p{Extended_Pictographic}\p{Emoji_Presentation}]\uFE0F?/gu
const OPT_IN_ENDING = /^(?:want me to|would you like me to|do you want me to|should i|i can also)\b/i
const FOLLOW_UP_QUESTION =
  /^(?:what can i help|how can i help|is there anything else|anything else|what would you like|what do you want|need anything else)\b.*\?$/i

export function enforceAskAIOutputPolicy(text: string): string {
  const withoutEmoji = text.replace(EMOJI_PATTERN, "").replace(/\uFE0F/g, "")
  const withoutDashPunctuation = withoutEmoji.replace(/\s+-\s+/g, ", ").replace(/[–—]/g, ", ")
  const normalized = withoutDashPunctuation
    .replace(/\s+,\s*/g, ", ")
    .replace(/[ \t]{2,}/g, " ")
    .trim()
  return OPT_IN_ENDING.test(normalized) || FOLLOW_UP_QUESTION.test(normalized) ? "" : normalized
}
