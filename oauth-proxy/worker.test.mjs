// Offline unit test for the OAuth proxy Worker. Run: node worker.test.mjs
// Stubs global fetch (Slack's oauth.v2.access) and asserts the exchange,
// loopback redirect, state validation, and error paths.
import worker from './worker.js'

let pass = 0, fail = 0
const ok = (d, c) => c ? (pass++, console.log('  ok:', d)) : (fail++, console.log('FAIL:', d))

const env = { SLACK_CLIENT_ID: '111.222', SLACK_CLIENT_SECRET: 'sekret' }

globalThis.fetch = async (url, opts) => {
  const body = opts.body
  if (!body.includes('client_secret=sekret')) return { json: async () => ({ ok: false, error: 'bad_secret' }) }
  if (!body.includes('code=goodcode')) return { json: async () => ({ ok: false, error: 'invalid_code' }) }
  return { json: async () => ({ ok: true, authed_user: { access_token: 'xoxp-111-abcdefghij' } }) }
}

const S = 'a'.repeat(32)

let r = await worker.fetch(new Request(`https://w.dev/callback?code=goodcode&state=${S}.41879`), env)
ok('good exchange returns 302', r.status === 302)
const loc = r.headers.get('Location') || ''
ok('redirects to loopback port', loc.startsWith('http://127.0.0.1:41879/callback'))
ok('forwards the token', loc.includes('token=xoxp-111-abcdefghij'))
ok('forwards nonce only (not port-state)', loc.includes(`state=${S}`) && !loc.includes('.41879'))

r = await worker.fetch(new Request('https://w.dev/callback?code=goodcode&state=notvalid'), env)
ok('bad state rejected 400', r.status === 400)

r = await worker.fetch(new Request('https://w.dev/nope'), env)
ok('wrong path 404', r.status === 404)

r = await worker.fetch(new Request(`https://w.dev/callback?code=xxxxxxxxxx&state=${S}.41879`), env)
ok('slack error is not a 302', r.status !== 302)

r = await worker.fetch(new Request(`https://w.dev/callback?code=goodcode&state=${S}.41879`), {})
ok('missing creds -> 500', r.status === 500)

r = await worker.fetch(new Request(`https://w.dev/callback?error=access_denied&state=${S}.41879`), env)
ok('cancel -> 200 no redirect', r.status === 200)

r = await worker.fetch(new Request(`https://w.dev/callback?code=goodcode&state=${S}.99`), env)
ok('out-of-range port rejected', r.status === 400)

console.log(`\npassed ${pass}, failed ${fail}`)
process.exit(fail ? 1 : 0)
