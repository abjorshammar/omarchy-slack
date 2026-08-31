# Omarchy Slack — Omarchy plugin

Two entry points (`kinds: ["bar-widget", "panel"]`), id `bottelet.slack`:

- `BarWidget.qml` — bar icon with a mention badge. Polls unread counts on its
  own timer; clicking runs `omarchy-shell shell toggle bottelet.slack` to
  summon the app. Watches `~/.cache/omarchy-slack/seen.json` so the badge
  clears the moment a conversation is read in the app.
- `Panel.qml` — the app (`kind: panel`, `keepLoaded`): a real movable,
  resizable `FloatingWindow` (the same model as the Spotify plugin) with a
  sidebar (workspace, presence, DND snooze, filter, conversations) and a chat
  pane (history, compose, settings). Also owns sign-in: browser OAuth via
  `scripts/slack.sh login`, or a pasted token. Hyprland tiles new toplevels
  by default; add `windowrulev2 = float, title:^(Omarchy Slack)$` to float it.

Shared plumbing:

- `Model.js` — command building (argv arrays only), JSON parsing,
  Slack-mrkdwn→plain-text, sorting/filtering, seen-map application.
- `scripts/slack.sh` — the only thing that talks to Slack. Owns the token
  (keyring via `secret-tool`, else `~/.config/omarchy-slack/token` 0600),
  validates every id/ts against regexes, caps response sizes, caches history
  (Slack's 1-req/min limit for personal apps), records read markers in
  `seen.json`, and always prints exactly one JSON object.
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
  caching, rate-limit fallback, listener behavior, secrets hygiene.

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

- `~/.config/omarchy-slack/token` — 0600 fallback token (keyring preferred)
- `~/.config/omarchy-slack/oauth.json` — optional own-app OAuth override
  (`client_id`, `proxy_url`, optional `port`, and optional
  `sync_read_state: true` to add the four `*:write` scopes to the browser
  flow's consent screen)
- `~/.cache/omarchy-slack/` — users.json (display names), hist-*.json
  (60 s history cache), seen.json (read markers)

## Tests

```sh
tests/run.sh
```

No network, no token: a stub `curl` serves canned Slack responses.
