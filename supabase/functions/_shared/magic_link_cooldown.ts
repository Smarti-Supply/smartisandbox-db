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

/** Segundos até o fim do cooldown (mínimo 1 enquanto dentro da janela). */
export function magicLinkCooldownRemainingSeconds(
  lastRequestedAtIso: string | null,
  cooldownMs: number,
  nowMs: number,
): number {
  if (!isWithinMagicLinkCooldown(lastRequestedAtIso, cooldownMs, nowMs)) {
    return 0;
  }
  const lastMs = Date.parse(lastRequestedAtIso!);
  const remainingMs = cooldownMs - (nowMs - lastMs);
  return Math.max(1, Math.ceil(remainingMs / 1000));
}

export function isEmailSendRateLimited(error: { code?: string }): boolean {
  return error.code === "over_email_send_rate_limit";
}
