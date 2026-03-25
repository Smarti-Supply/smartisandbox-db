# supplier-logon

Edge Function that validates supplier contact/email, then requests a Supabase Auth magic link (OTP) with `shouldCreateUser: false`.

## Client integration

- The function enforces a **server-side cooldown** (`MAGIC_LINK_COOLDOWN_MS` in [`../_shared/magic_link_cooldown.ts`](../_shared/magic_link_cooldown.ts), currently 60 seconds) per `supplier_users` row to avoid Auth `over_email_send_rate_limit` (HTTP 429).
- **Recommended:** disable the “send link” control for at least the same duration (or slightly longer) after a successful request so users do not double-submit and UX matches server behavior.

## Response shape

- Valid or invalid email (no `supplier_contact` / no `supplier_user`): `{ success: true }` at HTTP 200 by design (email enumeration mitigation).
- Magic link sent: `{ success: true }` at HTTP 200.
- Cooldown active (same `supplier_user` requested again within `MAGIC_LINK_COOLDOWN_MS`): HTTP **429** with `{ success: false, code: "MAGIC_LINK_COOLDOWN", error, retry_after_seconds }`.
- Supabase Auth `over_email_send_rate_limit`: HTTP **429** with `{ success: false, code: "EMAIL_SEND_RATE_LIMIT", error }`.
- Other Auth errors sending OTP: HTTP **502** with `{ success: false, code: "MAGIC_LINK_SEND_FAILED", error }`.
- Missing body field: HTTP 400 with `{ error: "..." }` (Portuguese product copy).
