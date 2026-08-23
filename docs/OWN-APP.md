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

If you also want the browser flow against your own app:

1. Add a **Redirect URL** on OAuth & Permissions:
   `https://bottelet.github.io/omarchy-slack/oauth.html`
   (or host `docs/oauth.html` yourself — any HTTPS page that forwards the
   query string to `http://127.0.0.1:41879/callback` works).
2. Write `~/.config/omarchy-slack/oauth.json`:

   ```json
   {
     "client_id": "1234567890.1234567890123",
     "client_secret": "…",
     "port": 41879,
     "redirect": "https://bottelet.github.io/omarchy-slack/oauth.html"
   }
   ```

The user config takes precedence over the plugin's shipped credentials.

## Optional read-state sync scopes

Add `channels:write`, `groups:write`, `im:write`, `mpim:write` to the user
scopes if you want conversations you read here marked read in your other
Slack clients too.
