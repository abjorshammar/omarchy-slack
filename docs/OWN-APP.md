# Using your own Slack app

The plugin normally signs you in through its shipped Slack app. If you prefer
your own (for tighter control, or because your workspace admin restricts
unlisted apps), it takes about two minutes:

1. Open <https://api.slack.com/apps> → **Create New App** → **From a
   manifest**, pick your workspace, and paste:

   ```json
   {
     "display_information": {
       "name": "Omarchy Slack"
     },
     "oauth_config": {
       "scopes": {
         "user": [
           "channels:read", "groups:read", "im:read", "mpim:read",
           "channels:history", "groups:history", "im:history", "mpim:history",
           "chat:write", "users:read", "dnd:read", "dnd:write", "users:write"
         ]
       }
     }
   }
   ```

2. On **OAuth & Permissions**, click **Install to Workspace** and approve.
3. Copy the **User OAuth Token** (`xoxp-…`) and paste it into the plugin via
   *paste a token instead* on the sign-in screen.

That's it — the token path uses exactly the same storage and API plumbing as
the browser flow.

## Browser sign-in with your own app

If you want the "Sign in with Slack" button against your own app, you also need
to run the OAuth proxy (Slack requires an HTTPS redirect and has no PKCE, so
the secret must live server-side — see `oauth-proxy/README.md`). Then:

1. Deploy the proxy with your app's client id + secret as env vars.
2. Add the proxy's `/callback` URL as a **Redirect URL** on your app's
   OAuth & Permissions page, and activate public distribution.
3. Write `~/.config/omarchy-slack/oauth.json` (no secret — it stays in the
   proxy):

   ```json
   {
     "client_id": "1234567890.1234567890123",
     "proxy_url": "https://your-worker.your-subdomain.workers.dev",
     "port": 41879
   }
   ```

The user config takes precedence over the plugin's shipped config.

Simpler alternative: skip the proxy entirely and just paste your app's User
OAuth Token (steps 1–3 at the top of this file). No proxy, no button, but zero
infrastructure.

## Optional read-state sync scopes

Add `channels:write`, `groups:write`, `im:write`, `mpim:write` to the user
scopes if you want conversations you read here marked read in your other
Slack clients too.
