# Omarchy Slack — OAuth proxy

Slack has no PKCE and requires an HTTPS redirect, so — unlike the Spotify
plugin (PKCE + `http://127.0.0.1` loopback, no secret) — a public Slack client
can't finish OAuth on its own. This tiny Cloudflare Worker performs the one
step that needs the client secret (the `code → token` exchange) and hands the
token straight back to the user's local plugin listener over loopback.

It is stateless and logs nothing: no token is ever stored or logged; it lives
in the Worker only for the duration of one request.

## Deploy (once, ~2 minutes)

```sh
cd oauth-proxy
npm i -g wrangler        # or: npx wrangler ...
wrangler login           # opens your Cloudflare account in a browser
wrangler secret put SLACK_CLIENT_ID       # paste the app's Client ID
wrangler secret put SLACK_CLIENT_SECRET   # paste the app's Client Secret
wrangler deploy
```

`wrangler deploy` prints your Worker URL, e.g.
`https://omarchy-slack-oauth.<your-subdomain>.workers.dev`.

Then, two one-time wiring steps:

1. **Slack app** → OAuth & Permissions → Redirect URLs → add
   `https://omarchy-slack-oauth.<your-subdomain>.workers.dev/callback` and Save.
   Then Manage Distribution → **Activate Public Distribution**.
2. **Plugin** → put the Worker URL in `config/oauth.json` as `proxy_url`
   (no secret goes in the repo — only the client id and this URL).

That's it. Every user who installs the plugin now gets a working
**Sign in with Slack** button for any workspace.

## Free tier

Cloudflare's free plan allows 100,000 requests/day — a sign-in is a couple of
requests, so this never costs anything in practice.

## Rotating the secret

If the client secret is ever exposed, rotate it at api.slack.com and re-run
`wrangler secret put SLACK_CLIENT_SECRET`. Nothing in the repo changes.

## Local test

```sh
wrangler dev      # serves the Worker at http://127.0.0.1:8787
# then hit /callback with a fake code+state to see the validation paths
```
