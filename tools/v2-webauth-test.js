// Prove the panel's v2 signing works against a real server.
//
//   bun tools/v2-webauth-test.js [base-url] [api-key]
//
// This imports the SHIPPED modules — static/js/sha3.js and the
// signRequestHeaders() from static/js/signer.js — generates an Ed25519 key with
// the same WebCrypto API a browser uses, enrols it, and then makes signed
// requests that a live Breeze Core has to verify. A reimplementation of the
// signing here would prove nothing about the code the panel loads.
//
// What it cannot cover: IndexedDB persistence and the DOM, which need a browser.

import { signRequestHeaders } from "../static/js/signer.js";

const BASE = process.argv[2] || "http://127.0.0.1:18999";
const KEY = process.argv[3] || "timer-test-key";

const b64u = (bytes) => {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

let failures = 0;
const ok = (msg) => console.log(`  ok    ${msg}`);
const bad = (msg) => { failures++; console.log(`  FAIL  ${msg}`); };

// --- 1. a key pair, exactly as the panel makes one -------------------------
const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"]);
const publicKeyB64 = b64u(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)));
publicKeyB64.length === 43
  ? ok(`public key exports as 32 raw bytes (${publicKeyB64.slice(0, 12)}…)`)
  : bad(`public key is ${publicKeyB64.length} b64 chars, expected 43`);

// The private key must be unexportable — that is the point of doing this in a
// browser rather than holding a seed.
try {
  await crypto.subtle.exportKey("raw", pair.privateKey);
  bad("the private key was exportable — it must not be");
} catch {
  ok("the private key cannot be exported, even by the page that made it");
}

// --- 2. enrol it as a v2 device -------------------------------------------
const start = await (await fetch(`${BASE}/api/auth/enroll/start`, {
  method: "POST",
  headers: { "X-API-Key": KEY, "Content-Type": "application/json" },
  body: JSON.stringify({ label: "web-panel-v2-test", auth_version: 2, public_key: publicKeyB64 }),
})).json();
if (!start.user_code) {
  bad(`enrolment did not start: ${JSON.stringify(start)}`);
  process.exit(1);
}
ok(`enrolment started (code ${start.user_code})`);

await fetch(`${BASE}/api/auth/enroll/approve`, {
  method: "POST",
  headers: { "X-API-Key": KEY, "Content-Type": "application/json" },
  body: JSON.stringify({ code: start.user_code }),
});
const poll = await (await fetch(`${BASE}/api/auth/enroll/poll`, {
  method: "POST",
  headers: { "X-API-Key": KEY, "Content-Type": "application/json" },
  body: JSON.stringify({ session_id: start.session_id }),
})).json();

// A v2 enrolment returns a key id and NO bearer token: there is no shared
// secret to hand out.
const keyId = poll.key_id || poll.token_id;
keyId ? ok(`approved, key id ${keyId}`) : bad(`no key id in poll response: ${JSON.stringify(poll)}`);
poll.device_token
  ? bad("a v2 enrolment handed back a bearer token as well")
  : ok("no bearer token issued for a v2 enrolment");

// --- 3. signed requests ----------------------------------------------------
async function signed(method, path, bodyObj) {
  const body = bodyObj === undefined ? "" : JSON.stringify(bodyObj);
  const headers = {
    "X-API-Key": KEY,
    ...(await signRequestHeaders({ privateKey: pair.privateKey, keyId, method, path, body })),
  };
  if (bodyObj !== undefined) headers["Content-Type"] = "application/json";
  return fetch(`${BASE}${path}`, { method, headers, body: bodyObj === undefined ? undefined : body });
}

let r = await signed("GET", "/api/units");
r.status === 200 ? ok("GET /api/units accepted a signed request")
                 : bad(`GET /api/units -> ${r.status} ${await r.text()}`);

// A body changes the digest, so this exercises the whole canonical string.
r = await signed("POST", "/api/timers", { unit_ids: ["111222333"], minutes: 20 });
if (r.status === 201) {
  const t = await r.json();
  ok(`POST with a body verified (timer ${t.id}, ${t.seconds_remaining}s)`);
  r = await signed("DELETE", `/api/timers/${t.id}`);
  r.status === 204 ? ok("DELETE verified") : bad(`DELETE -> ${r.status}`);
} else {
  bad(`POST /api/timers -> ${r.status} ${await r.text()}`);
}

// A query string is part of what gets signed; signing the bare path would pass
// locally and fail on any request that has one.
r = await signed("GET", "/api/units/state?fresh=1");
[200, 404, 422].includes(r.status)
  ? ok(`query string signed correctly (${r.status}, not 401)`)
  : bad(`query-string request -> ${r.status}`);

// --- 4. the rejections that matter ----------------------------------------
// Tamper with the signature: one flipped character must fail.
{
  const headers = {
    "X-API-Key": KEY,
    ...(await signRequestHeaders({ privateKey: pair.privateKey, keyId, method: "GET", path: "/api/units" })),
  };
  const sig = headers["X-Breeze-Signature"];
  headers["X-Breeze-Signature"] = (sig[0] === "A" ? "B" : "A") + sig.slice(1);
  const res = await fetch(`${BASE}/api/units`, { headers });
  res.status === 401 ? ok("a tampered signature is rejected") : bad(`tampered signature -> ${res.status}`);
}

// Replay: the same nonce twice. The second must be refused, or the whole
// timestamp+nonce construction is decoration.
{
  const headers = {
    "X-API-Key": KEY,
    ...(await signRequestHeaders({ privateKey: pair.privateKey, keyId, method: "GET", path: "/api/units" })),
  };
  const first = await fetch(`${BASE}/api/units`, { headers });
  const second = await fetch(`${BASE}/api/units`, { headers });
  first.status === 200 && second.status === 401
    ? ok("a replayed nonce is rejected (first 200, second 401)")
    : bad(`replay: first ${first.status}, second ${second.status}`);
  if (second.status === 401) {
    const why = await second.json();
    why?.detail?.error === "replay"
      ? ok(`and it says why: ${why.detail.error}, retryable=${why.detail.retryable}`)
      : bad(`replay reason was ${JSON.stringify(why?.detail)}`);
  }
}

// A stale timestamp must be refused, and must come back with server_time so a
// client can correct its clock instead of concluding its key is dead.
{
  const headers = {
    "X-API-Key": KEY,
    ...(await signRequestHeaders({
      privateKey: pair.privateKey, keyId, method: "GET", path: "/api/units",
      clockOffsetSeconds: -3600,
    })),
  };
  const res = await fetch(`${BASE}/api/units`, { headers });
  const why = await res.json().catch(() => null);
  res.status === 401 && why?.detail?.error === "clock_skew"
    ? ok(`an hour-old timestamp is rejected as clock_skew (server_time ${why.detail.server_time})`)
    : bad(`stale timestamp -> ${res.status} ${JSON.stringify(why)}`);
}

console.log(failures === 0 ? "\n  all checks passed" : `\n  ${failures} check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
