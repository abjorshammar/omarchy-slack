# Changelog

## Unreleased

- **Multiple workspaces.** Sign in to more than one Slack workspace and
  switch between them, the way the native apps do. A rail of workspace tiles
  appears down the left of the app — but only once there are two or more, so
  a single-workspace install looks exactly as it did. `Ctrl+1…9` switches;
  each tile carries its own unread badge; switching remembers the
  conversation you left open in each workspace.
- The bar badge now counts unread DMs across **every** signed-in workspace,
  so a DM in a workspace you are not looking at still reaches you. Hovering
  breaks the count down per workspace.
- Tokens, message caches, user names and avatars are namespaced per
  workspace (Slack user ids are only unique within a workspace, so a shared
  cache would show the wrong name and face on a DM). Read markers stay in one
  shared file, keyed `<team>/<channel>`.
- Existing single-workspace installs migrate themselves on first run — the
  token, caches and read markers move under the workspace they belong to. No
  re-authentication, no extra API call. Avatar paths stored inside the user
  cache are rewritten too, since they are absolute and `resolve_users` never
  refetches a user it already knows.
- Per-workspace tokens use the keyring key `ws-token`, not the legacy `token`
  plus a `team` attribute: `secret-tool` matches on an attribute *subset*, so
  anything clearing the legacy key would also have deleted every
  per-workspace token — including, during migration, the one just written.
- Add a workspace from ⚙ → **Add another workspace**, or the `+` tile on the
  rail. Sign out of one workspace, or all of them, from the same page.
- `scripts/slack.sh` takes an optional leading `--team <id>` on every command
  and defaults to the active workspace; new `counts-all`, `workspaces` and
  `use` subcommands.
- Browser sign-in can request the read-state-sync write scopes by opting in
  with `"sync_read_state": true` in `oauth.json`; `login-available` reports the
  exact scope list it will ask for.

- Fixed: a conversation whose newest message is a *threaded* reply could never
  be marked read. `conversations.history` returns only top-level messages, so
  the read marker stopped short of the conversation head and the unread badge
  stayed lit forever — and `conversations.mark` was called with a ts behind
  Slack's own `last_read`, making it a no-op even with the optional write
  scopes. Slack assistant/app DMs hit this on every reply.
- Fixed: `Esc` inside a conversation called `backToList()`, which was never
  defined, so it threw instead of returning to the conversation list.

## Unreleased

- Much faster unread polling. The per-conversation `conversations.info` and
  per-user `users.info` fan-outs, previously one `curl` (and several `jq`)
  per item, are now issued as parallel batches (`curl -Z`, capped at 4
  concurrent — rate-safe), and each batch's responses are assembled in a
  single `jq` pass instead of an accumulator rebuilt per item. Avatar
  downloads are batched the same way. A warm counts cycle drops from ~9s to
  ~2s; a cold open (empty caches) from ~15s to under 4s, with ~10× fewer
  processes spawned. Output is byte-for-byte unchanged.

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
