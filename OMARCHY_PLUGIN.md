# Omarchy Slack — Omarchy plugin

Two entry points (`kinds: ["bar-widget", "panel"]`), id `bottelet.slack`:

- `BarWidget.qml` — bar icon with a mention badge summing unread DMs across
  every signed-in workspace (`counts-all`, one process, not one per
  workspace). Polls on its own timer; clicking runs
  `omarchy-shell shell toggle bottelet.slack` to summon the app. Watches
  `~/.cache/omarchy-slack/seen.json` so the badge clears the moment a
  conversation is read in the app.
- `Panel.qml` — the app (`kind: panel`, `keepLoaded`): a real movable,
  resizable `FloatingWindow` (the same model as the Spotify plugin) with an
  optional workspace rail, a sidebar (workspace, presence, DND snooze,
  filter, conversations) and a chat pane (history, compose, settings). Also
  owns sign-in: browser OAuth via `scripts/slack.sh login`, or a pasted
  token. Hyprland tiles new toplevels by default; add
  `windowrulev2 = float, title:^(Omarchy Slack)$` to float it.

## Multiple workspaces

Slack's team id is the namespace key for every token, cache and API call.

- The **rail** of workspace tiles renders only when more than one workspace is
  signed in (`root.multiWorkspace`); with one, the layout is what it always
  was. The one piece of switching UI that is always present is
  ⚙ → *Add another workspace*, since it is the only route from one to two.
- Every `slack.sh` command takes an optional **leading `--team <id>`** and
  falls back to the active workspace in the registry when it is absent —
  which is what keeps single-workspace call sites working untouched. The QML
  side always passes it explicitly, and payloads carry `team_id` back so a
  reply that lands after a switch can be dropped rather than misrendered.
- `counts-all` polls every workspace **in parallel** and returns them in one
  payload, so neither the rail nor the bar badge fans out into a process per
  workspace. Rate limits are per app *per workspace*, so the budgets do not
  compete. A workspace can be kept signed in but out of the poll with
  `"poll": false` in the registry.
- Team ids become a path component and a keyring attribute, so they are
  validated (`^[TE][A-Z0-9]{2,30}$`) before any filesystem or secret-store
  use, and a token is never stored before `auth.test` says which workspace it
  belongs to.
- The test suite runs the token store twice: once with no `secret-tool` (the
  0600 file fallback) and once against a stub that reproduces libsecret's
  subset matching, because the keyring path has failure modes the file path
  does not.
- Upgrading from a single-workspace install migrates itself on the first
  `status`, reusing the `auth.test` that command already makes.

Shared plumbing:

- `Model.js` — command building (argv arrays only, each naming its
  workspace), JSON parsing, Slack-mrkdwn→plain-text, sorting/filtering,
  seen-map application, per-workspace unread summaries for the rail.
- `scripts/slack.sh` — the only thing that talks to Slack. Owns the tokens
  (keyring via `secret-tool` keyed by team, else
  `~/.config/omarchy-slack/tokens/<team>` 0600), validates every id/ts
  against regexes, caps response sizes, caches history per workspace (Slack's
  1-req/min limit for personal apps), records read markers in `seen.json`,
  and always prints exactly one JSON object.
- `scripts/oauth-callback.py` — one-shot loopback listener for OAuth
  (stdlib only, binds 127.0.0.1, state-validated, 240 s lifetime).
- `config/oauth.json` — ships unconfigured on purpose (the exchange host sees
  the user token, so browser sign-in requires the user's own app + proxy);
  `~/.config/omarchy-slack/oauth.json` enables it.
- `oauth-proxy/` — Cloudflare Worker that holds the client secret and does the
  `code → token` exchange (Slack has no PKCE + requires an HTTPS redirect, so
  the secret can't live in the plugin). Stateless, logs nothing; 302s the token
  to the local listener over loopback. Deploy once (`oauth-proxy/README.md`).
- `tests/run.sh` — offline suite with stub `curl`: routing, validation,
  caching, rate-limit fallback, per-workspace isolation, migration, listener
  behavior, secrets hygiene. Where `node` is available it also executes the
  argv `Model.js` builds against the real script, covering the QML-to-shell
  contract.

## Install

Installs to `~/.config/omarchy/plugins/bottelet.slack/`.

```sh
omarchy plugin add https://github.com/Bottelet/omarchy-slack.git --enable
omarchy bar put bottelet.slack --after omarchy.weather
```

## Summoning

- Bar icon click, or `omarchy-shell shell toggle bottelet.slack` (bindable).
- Overlay contract: `open` / `close` / `dismiss` / `toggle`; `dismiss` calls
  `shell.hide(manifest.id)`.

## Settings

| Key | Type | Meaning |
| --- | --- | --- |
| `refreshMinutes` | integer | Bar badge poll cadence (default 3, min 1) |

The Slack token is deliberately **not** a setting — keyring or 0600 file,
never `shell.json`.

## State on disk

- `~/.config/omarchy-slack/tokens/<team_id>` — 0600 fallback token, one per
  workspace (keyring preferred; keyring attributes are
  `service omarchy-slack key ws-token team <team_id>`). The key value differs
  from the pre-multi-workspace `key token` on purpose: libsecret matches on an
  attribute *subset*, so a `clear … key token` would otherwise also delete
  every per-workspace item that merely carried an extra `team` attribute.
- `~/.config/omarchy-slack/workspaces.json` — the registry: `active` plus one
  entry per workspace (`team_id`, `team`, `user`, `user_id`, `url`, `poll`).
  Display metadata only — never a token, so the UI can draw the rail without
  a network call or a keyring unlock.
- `~/.config/omarchy-slack/oauth.json` — optional own-app OAuth override
  (`client_id`, `proxy_url`, optional `port`, and optional
  `sync_read_state: true` to add the four `*:write` scopes to the browser
  flow's consent screen)
- `~/.cache/omarchy-slack/<team_id>/` — users-v2.json (display names +
  avatar paths), avatars/, hist-*.json and thread-*.json (60 s cache). Per
  workspace because Slack user ids are only unique within one.
- `~/.cache/omarchy-slack/seen.json` — read markers, shared across all
  workspaces and keyed `<team_id>/<channel_id>`, so the bar widget keeps
  watching a single file.

## Subcommands

| Command | Meaning |
| --- | --- |
| `--team <id>` | optional, leading: pick the workspace (default: the active one) |
| `counts [types]` | one workspace's conversations, unreads, presence, DND |
| `counts-all [types]` | every polled workspace, in parallel, in one payload |
| `workspaces` | the registry plus per-workspace `has_token` (no network) |
| `use <id>` | make a workspace active, persisted |
| `history` / `thread` / `send` / `seen` | as before, scoped to the workspace |
| `set-token` / `login` | sign in; the workspace comes from `auth.test` |
| `clear-token [--team <id>\|--all]` | forget one workspace, or all of them |

## Tests

```sh
tests/run.sh
```

No network, no token: a stub `curl` serves canned Slack responses.
