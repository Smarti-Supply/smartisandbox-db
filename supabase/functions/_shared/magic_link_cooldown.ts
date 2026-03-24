/**
 * Cooldown slightly above Supabase Auth OTP minimum (~45s) to avoid 429 over_email_send_rate_limit.
 */
export const MAGIC_LINK_COOLDOWN_MS = 60_000;

export function isWithinMagicLinkCooldown(
  lastRequestedAtIso: string | null,
  cooldownMs: number,
  nowMs: number,
): boolean {
  if (lastRequestedAtIso == null || lastRequestedAtIso === "") {
    return false;
  }
  const lastMs = Date.parse(lastRequestedAtIso);
  if (Number.isNaN(lastMs)) {
    return false;
  }
  return nowMs - lastMs < cooldownMs;
}

export function isEmailSendRateLimited(error: { code?: string }): boolean {
  return error.code === "over_email_send_rate_limit";
}
