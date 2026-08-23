// Omarchy Slack — OAuth token-exchange proxy (Cloudflare Worker).
//
// Slack has no PKCE and requires an HTTPS redirect, so a public client cannot
// finish OAuth on its own (unlike the Spotify plugin, which uses PKCE +
// loopback). This Worker holds the client secret server-side and performs the
// one step that needs it — the code→token exchange — then hands the token
// straight back to the user's local plugin listener over the loopback address.
//
// It is deliberately stateless and logs nothing: it never stores a token and
// never writes request bodies or tokens to any log. The token exists in the
// Worker only for the duration of one fetch, then is forwarded to
// 127.0.0.1:<port> on the user's own machine.
//
// Secrets (set with `wrangler secret put`):
//   SLACK_CLIENT_ID      — the app's client id (also fine as a plain var)
//   SLACK_CLIENT_SECRET  — the app's client secret
//
// Register this Worker's /callback URL as the app's OAuth Redirect URL:
//   https://<worker-subdomain>.workers.dev/callback

const SLACK_TOKEN_URL = "https://slack.com/api/oauth.v2.access";

// state is "<32-hex nonce>.<loopback port>", round-tripped through Slack so the
// Worker knows which local listener to hand the token to. Both halves are
// strictly validated before use.
function parseState(raw) {
  const s = String(raw || "");
  const m = s.match(/^([0-9a-f]{32})\.(\d{4,5})$/);
  if (!m) return null;
  const port = Number(m[2]);
  if (port < 1024 || port > 65535) return null;
  return { nonce: m[1], port };
}

function page(title, detail) {
  return `<!doctype html><meta charset="utf-8"><title>Omarchy Slack</title>
<style>:root{color-scheme:light dark}body{font-family:system-ui;background:Canvas;color:CanvasText;
display:grid;place-items:center;height:100vh;margin:0}main{max-width:32rem;padding:2rem;
border:1px solid GrayText;border-radius:.5rem}</style>
<main><h1>${title}</h1><p>${detail}</p></main>`;
}

function html(body, status = 200) {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
    },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/callback") {
      return html(page("Omarchy Slack", "This endpoint only handles Slack sign-in callbacks."), 404);
    }

    const err = url.searchParams.get("error");
    if (err) {
      return html(page("Sign-in cancelled", "You can close this tab and return to Omarchy."));
    }

    const code = url.searchParams.get("code") || "";
    const state = parseState(url.searchParams.get("state"));
    if (!/^[A-Za-z0-9._-]{8,600}$/.test(code) || !state) {
      return html(page("Sign-in rejected", "Invalid or expired sign-in request. Please retry from Omarchy Slack."), 400);
    }

    const clientId = env.SLACK_CLIENT_ID;
    const clientSecret = env.SLACK_CLIENT_SECRET;
    if (!clientId || !clientSecret) {
      return html(page("Not configured", "This proxy is missing its Slack credentials."), 500);
    }

    // The redirect_uri sent here must byte-match the one used in the authorize
    // step — this Worker's own /callback.
    const redirectUri = url.origin + "/callback";

    let token = "";
    try {
      const body = new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        code,
        redirect_uri: redirectUri,
      });
      const resp = await fetch(SLACK_TOKEN_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: body.toString(),
      });
      const data = await resp.json();
      if (!data.ok) {
        return html(page("Sign-in failed", "Slack said: " + String(data.error || "unknown error")), 400);
      }
      token = (data.authed_user && data.authed_user.access_token) || "";
    } catch (e) {
      return html(page("Sign-in failed", "Could not reach Slack to complete sign-in."), 502);
    }

    if (!/^xoxp-[A-Za-z0-9-]{10,200}$/.test(token)) {
      return html(page("Sign-in failed", "Slack did not return a user token."), 400);
    }

    // Hand the token to the user's local plugin listener over loopback. The
    // browser performs this redirect locally; Slack never sees this URL, and
    // the token travels only over 127.0.0.1 on the user's own machine.
    const loopback =
      "http://127.0.0.1:" + state.port + "/callback" +
      "?token=" + encodeURIComponent(token) +
      "&state=" + encodeURIComponent(state.nonce);

    return new Response(null, {
      status: 302,
      headers: {
        Location: loopback,
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
      },
    });
  },
};
