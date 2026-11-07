# Changelog

## 1.1.0 — 2026-11-08

- Trilingual UI: Simplified Chinese, English and Japanese. Follows the
  system language by default; switchable in Settings → General, or from
  the language row at the bottom of either panel.
- Launch at login (Settings → General).
- Compact menu bar mode: hide the reset countdowns, keep icon + percent.
- Low-quota alert threshold is adjustable (Settings → General, percent).
- Check-for-updates button in Settings → General — manual only, opens
  the releases page; nothing checks in the background.
- Long burn-down and reset-credit lines wrap instead of overflowing in
  English and Japanese.

## 1.0.0 — 2026-11-07

First public release.

- Menu bar rings for OpenAI Codex and Muse (muse.ai): remaining percentage
  plus a compact reset countdown; the ring turns orange under 25% and red
  under 10%.
- Codex panel: 5-hour and weekly windows (hovering the menu bar item swaps
  between them), rate-limit reset credits with expiry, local token and cost
  statistics computed from Codex session logs and priced via models.dev,
  a weekly exhaustion forecast, and a once-a-day digest notification.
- Window keeper: optionally sends a tiny "hello" right after a 5-hour (and,
  optionally, weekly) window resets so a fresh window starts immediately.
  Uses the Codex responses API directly (~20 tokens per ping) with a
  `codex exec resume` fallback; skips automatically when weekly remaining
  drops under 10%.
- Muse panel: weekly usage, tokens-left label and banked (top-up) pool
  balance for up to two accounts, with renameable accounts, a primary
  account, optional automatic primary switching, and one-click opening of
  each account in the Muse app or in an isolated, pre-warmed in-app web
  view.
- Conversation shortcuts: user-defined links that open in the ChatGPT app
  via deep links, falling back to the browser.
- System monitor: per-app memory / CPU / energy top-5 lists with share
  bars measured against real totals (energy is normalized to the chip's
  design peak), one-hour sparklines, a pinnable and resizable panel.
  Sampling runs only while the panel is open.
- Notifications: reset credits expiring in 3 days / 1 day, any quota under
  15%, and window reset completion.
