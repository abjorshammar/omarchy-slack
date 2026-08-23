# Omarchy Slack

**Slack in Quickshell — not Chromium.**

Omarchy Slack brings your workspace into a fast, themed Omarchy app: read and
reply to DMs and channels, flip your presence, snooze notifications — while a
mention badge keeps watch in your bar. No Electron, no half-gigabyte client.

![Omarchy Slack](preview.png)

## Features

- **A full app, summoned instantly.** Click the bar icon (or bind a hotkey)
  and Slack opens as a real, movable, resizable window (the same model as the
  Spotify plugin): conversations in the sidebar, messages and a compose box on
  the right. `Esc` closes it.
- **Sign in with your browser.** One click sends you to Slack's own consent
  page; the token comes back to the plugin and goes straight into your
  system keyring. No copy-pasting API keys.
- **A badge that means something.** The bar icon counts unread DMs and group
  DMs in red — every one of those is aimed at you. Channel unreads light the
  icon and dot the sidebar.
- **Presence & Do Not Disturb.** Toggle active/away and snooze notifications
  for an hour from the sidebar.
- **Made for Omarchy.** Every color comes from your active theme, light
  themes included. Keyboard-first: `↑`/`↓` move between conversations, `/`
  filters, `Enter` sends.

## Requirements

- Omarchy (Quattro shell) with a bar. Uses stock tools only: `bash`, `curl`,
  `jq`, `python3`. `secret-tool` (libsecret) is used for keyring storage when
  present, with a `0600` file fallback.
- A Slack account. Free and paid workspaces both work.

## Install

```sh
omarchy plugin add https://github.com/Bottelet/omarchy-slack.git --enable
omarchy bar put bottelet.slack --after omarchy.weather
```

Optional hotkey (Hyprland `bindings.lua`):

```lua
o.bind("SUPER + SHIFT + S", "Slack", "omarchy-shell shell toggle bottelet.slack")
```

Then click the Slack icon and press **Sign in with Slack**. Your browser
opens Slack's consent page; approve it and you're in.

The app opens as a normal window. Hyprland tiles new windows by default; to
have it float like a typical app, add to your Hyprland config:

```
windowrulev2 = float, title:^(Omarchy Slack)$
windowrulev2 = size 980 720, title:^(Omarchy Slack)$
windowrulev2 = center, title:^(Omarchy Slack)$
```

## How sign-in works (and the paste-a-token fallback)

Slack, unlike Spotify, has no PKCE and requires an HTTPS redirect, so a public
client can't finish OAuth entirely on its own. The browser flow works like
this: the plugin starts a listener on `127.0.0.1`, opens Slack's consent page,
and you pick any workspace. Slack redirects to a small **OAuth proxy** (a
stateless Cloudflare Worker that holds only the client secret — see
`oauth-proxy/`), which performs the `code → token` exchange and hands the
token straight back to your local listener over loopback. The token is stored
in your GNOME keyring; the client secret never lives in this repo.

The "Sign in with Slack" button appears once a `proxy_url` is set in
`config/oauth.json` (the publisher deploys the Worker once — see
`oauth-proxy/README.md`).

If you'd rather use your own Slack app — or no proxy is configured — choose
*paste a token instead* and follow `docs/OWN-APP.md` to create a personal
Slack app and paste its User OAuth Token. You can also point
`~/.config/omarchy-slack/oauth.json` at your own app + your own proxy.

### Optional: sync read state to your other Slack clients

Reading a conversation here always clears the badge locally. If you also want
it marked read on your phone and in the Slack apps, the Slack app needs the
extra write scopes (`channels:write`, `groups:write`, `im:write`,
`mpim:write`). They're heavier permissions, so they're not requested by
default; without them Slack keeps its own read state and the plugin quietly
skips the sync.

## Rate limits, honestly

Slack gives personal (non-Marketplace) apps created after May 2025 one
`conversations.history` request per minute, 15 messages at a time. The plugin
is built around that budget: opening a conversation fetches live, refreshes
are cached for a minute, your own replies are appended locally instead of
refetched, and the open conversation re-polls once a minute. Unread counts
use different (roomier) API methods and poll every 3 minutes by default
(`omarchy bar set bottelet.slack refreshMinutes N`).

## Privacy & security

- Your Slack password is only ever typed on Slack's own pages.
- The token lives in your system keyring (`secret-tool`), or in
  `~/.config/omarchy-slack/token` with `0600` permissions when no keyring is
  available — never in `shell.json`, never in the repo.
- The token and the OAuth client secret are passed to `curl` via stdin or
  in-memory header files — they never appear on a command line or in
  `/proc`.
- All requests go to `slack.com` over HTTPS only (`--proto '=https'`),
  responses are size-capped, and every channel id is regex-validated before
  use. Names, errors and reactions render as plain text; message bodies render
  a small, safe mrkdwn subset (bold/italic/strike/code) via `Text.StyledText`
  where the content is fully HTML-escaped first and only a fixed tag whitelist
  (`<b> <i> <s> <font> <br>`) is ever emitted — no `<img>`, `<a>`, or `src`,
  so nothing can fetch a remote resource.
- Avatars are downloaded only from Slack's own image hosts (no redirects
  followed), size-capped, checked to be a real raster format, and converted
  with ImageMagick resource limits before display.
- The OAuth listener binds `127.0.0.1` only, accepts a single
  state-validated callback, and dies after four minutes. The client secret
  lives only in the OAuth proxy (a Cloudflare Worker env var), never in this
  repo; the proxy is stateless and logs nothing. Your token reaches your
  machine over loopback and goes straight into the keyring.
- Message caches and read markers live in `~/.cache/omarchy-slack` with
  `0700`/`0600` permissions — private to your user, like the token.
- Like every native app with browser sign-in (GitHub CLI included), the
  shipped OAuth client credentials are public. They can't read anyone's
  Slack: a token is only ever issued to the person who completes the consent
  screen, and it goes only to their local keyring.
- **Sign out & forget token** (⚙ in the app) removes the token and the local
  message cache (`~/.cache/omarchy-slack`).

## Remove

```sh
omarchy plugin remove bottelet.slack
```

Removing the plugin keeps your token and cache. To wipe those too, use
**Sign out & forget token** first, or run:

```sh
secret-tool clear service omarchy-slack key token
rm -rf ~/.config/omarchy-slack ~/.cache/omarchy-slack
```

To revoke server-side, remove "Omarchy Slack" under your Slack workspace's
**Apps** page.

## Tests

`tests/run.sh` — an offline suite (stub `curl`, no token needed) covering
command routing, input validation, history caching, rate-limit fallbacks,
the OAuth listener, and that secrets never touch a process command line.

---

Omarchy Slack is an independent project and is not affiliated with Slack
Technologies or Salesforce. Slack is a trademark of Slack Technologies, LLC.

Licensed under the [MIT License](LICENSE).
