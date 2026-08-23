# Changelog

## 1.0.0

Initial release.

- Full Slack app as an Omarchy `panel`: a movable, resizable FloatingWindow
  (same model as the Spotify plugin) with a conversation sidebar (DMs, group
  DMs, channels), message view, inline replies, filter, keyboard navigation.
- Bar widget with a mention badge (unread DMs/group DMs) and unread-channel
  indicator; click summons the app, middle-click refreshes.
- Sign in with Slack in the browser (OAuth, loopback listener, HTTPS bounce
  page), with a paste-a-token fallback and own-app support
  (docs/OWN-APP.md).
- Token stored in the system keyring (secret-tool), 0600 file fallback;
  secrets never on argv.
- Presence toggle and 1-hour Do Not Disturb snooze.
- Read markers shared between app and badge (seen.json), with best-effort
  conversations.mark sync when the optional write scopes are granted.
- Built within Slack's post-May-2025 personal-app rate limits: 60 s history
  cache, local echo for sent messages, capped unread polling.
- Offline test suite (stub curl): 48 checks over routing, validation,
  caching, rate-limit fallback, OAuth listener, secrets hygiene.
