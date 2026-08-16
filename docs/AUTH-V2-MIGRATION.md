[← Breeze Core](../README.md)

# Plan: moving the web UI and CLIs to auth v2 (Ed25519)

**Status: proposal. Nothing here is implemented.**

The goal is to be able to set `AC_MIN_AUTH_VERSION=2` and revoke every v1
credential. Today that's impossible: the bundled web panel and the diagnostic
CLI can only speak v1, so a fleet always contains bearer-token devices, and
re-pairing them just mints another one.

It's a security upgrade, not just tidiness. **v1 sends the same bearer token on
every request** — anyone who can read one request can replay it forever, until
the token expires or is revoked. **v2 signs each request** with a key that
never leaves the device; the signature covers the method, path, timestamp,
nonce and body hash, so a captured request can't be replayed or altered.

**Contents:**
[What speaks what](#1-what-speaks-what-today) ·
[The contract](#2-the-contract-a-client-must-reproduce) ·
[Part 1 — CLI](#3-part-1--the-python-cli) ·
[Part 2 — web UI](#4-part-2--the-web-panel) ·
[Part 3 — the zsh tool](#5-part-3--the-zsh-tool-a-decision-not-a-task) ·
[Rollout](#6-rollout-order) ·
[Risks](#7-risks-and-what-to-do-about-them) ·
[Tests](#8-how-it-gets-verified) ·
[Effort](#9-effort) ·
[Open decisions](#10-decisions-i-need-from-you)

---

## 1. What speaks what today

| Client | Auth | Can it upgrade in place? |
|---|---|---|
| Breeze (Android) | **v2** since 2.0 | already done — it self-upgrades v1 → v2 on launch |
| Web panel (`static/`) | v1 bearer only | not yet — this plan, part 2 |
| `breeze-core diag` / `approve` | v1 bearer only | not yet — this plan, part 1 |
| `tools/ac-diag.zsh` | v1 bearer only | see part 3 |

On the maintainer's live server that's 6 v1 credentials out of 11: two stale
(one used only on the day it was enrolled, one used once), three that are
browser sessions of the web panel, and one belonging to the diagnostic CLI.
The stale two can be revoked at any time; the other four are what block the
clamp.

---

## 2. The contract a client must reproduce

Defined by `meow_ac/security/signing.py` and verified in
`meow_ac/security/device_token.py`. Both new clients must produce exactly this
— the Android app is the working reference implementation.

**Canonical string** (newline-joined, then signed as raw bytes):

```
breeze-auth-v2\n{METHOD}\n{path?query}\n{timestamp}\n{nonce}\n{sha3_512(body) hex}
```

**Headers** sent alongside the usual `X-API-Key`:

| Header | Value |
|---|---|
| `X-Breeze-Auth-Version` | `2` |
| `X-Breeze-Key-Id` | the server's `token_id` for this device |
| `X-Breeze-Timestamp` | epoch seconds, as a string |
| `X-Breeze-Nonce` | random, unique per request |
| `X-Breeze-Signature` | base64url of the 64-byte Ed25519 signature |

Rules that bite if you get them wrong: the timestamp must be within
`AC_AUTH_SKEW_SECONDS` (default 60) **either way**; a nonce is single-use
within that window; the body hash is **SHA3-512, not SHA-512**; and keys and
signatures are **base64url without padding**. An empty body still hashes — it's
`sha3_512(b"")`, not an empty string.

Getting any of this wrong produces a `401` with a machine-readable `reason`
(`bad_signature`, `clock_skew`, `replay`, `incomplete_signature`) — see
[API.md](API.md#why-an-auth-failure-happened--the-401-body). That table is the
debugging aid for this work.

---

## 3. Part 1 — the Python CLI

The easy half. **No new dependencies:** `pycryptodome` already ships with
msmart-ng and provides both primitives (verified: `Crypto.Signature.eddsa` and
`Crypto.Hash.SHA3_512` import fine in the current venv).

**Files**

- `meow_ac/cli/signing.py` *(new)* — mirror of the app's signer: generate a
  keypair, load/save the seed, produce the five headers for a request.
- `meow_ac/cli/client.py` — `req()` currently sets `Authorization: Bearer`
  when a token is cached. It gains a v2 branch that signs instead. Keep the v1
  branch: the CLI must still work against a server older than 3.0.0.
- `meow_ac/cli/main.py` / `diag.py` — a `--auth-version` escape hatch and a
  line in the diag output reporting which profile is in use.

**Credential storage.** Today: a bare token in
`${XDG_CONFIG_HOME:-~/.config}/ac-diag/token`, mode 600. Add
`ac-diag/key.json` holding `{key_id, seed_b64, auth_version: 2}` at the same
mode. Keep the old file readable so an existing install keeps working, and so
`tools/ac-diag.zsh` (which shares that path) isn't broken by the upgrade.

**Migration path — no admin approval needed.** The CLI already holds a valid
v1 credential, so it can call `POST /api/auth/upgrade` with its bearer token
and a freshly generated public key. The server re-keys the record **in place**,
keeping the same `token_id`. No pairing code, no LAN approval, no new entry in
the device list. This is exactly what the Android app does.

For a *fresh* install with no credential, enrol directly at v2 by sending
`auth_version: 2` and the public key to `/api/auth/enroll/start` — which still
needs the usual admin approval, as any new device does.

---

## 4. Part 2 — the web panel

Harder, but the result is better than the app's: the private key can be made
**non-extractable**, so no JavaScript — including injected JavaScript — can
ever read it back.

**Measured in this project's browser (Chrome 148), not assumed:**

| Capability | Result |
|---|---|
| `crypto.subtle` Ed25519 | supported — 32-byte public key, 64-byte signature |
| private key `extractable: false` | honoured; `exportKey` refused with `InvalidAccessError` |
| public key export | works (`raw`, 32 bytes) |
| `CryptoKey` structured-cloneable | yes → storable in IndexedDB |
| `crypto.subtle.digest('SHA3-512')` | **absent** (`NotSupportedError`) |

So WebCrypto covers the signing and the key storage, and the only gap is the
hash.

**Files**

- `static/js/sha3.js` *(new)* — a small Keccak/SHA3-512 implementation, plain
  ES module, no build step, no CDN (the CSP is `default-src 'self'` and there
  is deliberately no bundler). Roughly 80–120 lines. Must ship with NIST test
  vectors exercised in the browser console or a test page.
- `static/js/signer.js` *(new)* — generate the keypair (`extractable: false`),
  persist the `CryptoKey` + `key_id` in IndexedDB, build the canonical string,
  return the headers.
- `static/js/api.js` — `apiFetch()` is already the single choke point every
  request goes through (deliberately so). It gains: if a v2 credential exists,
  sign; else fall back to the bearer token. **Nothing else in the UI changes** —
  that's the payoff of the existing rule that no module calls `fetch()` directly.
- `static/js/enroll.js` — enrol at v2 when the browser supports it, and offer
  the in-place upgrade when an existing v1 token is present.

**Why IndexedDB and not localStorage.** `localStorage` stores strings, so a
key there would have to be extractable — i.e. readable by any script that gets
a foothold. A non-extractable `CryptoKey` in IndexedDB can be *used* to sign
and never read. The cost: clearing site data destroys the key, and re-pairing
then needs an admin on the LAN. That's the same trade the app makes, and worth
saying in the UI.

**Clock skew.** Browsers drift too. The 401 body carries `server_time` on a
`clock_skew` rejection; do what the app does — learn the offset, retry once,
don't discard the credential. `ApiClient._error()` in the app is the model.

**Support fallback.** Feature-detect Ed25519 (`generateKey` in a try/catch) and
stay on v1 if the browser can't do it. That's safe while
`AC_MIN_AUTH_VERSION=1`; once clamped to 2, such a browser simply can't be used
— which is a reason to check the household's browsers before clamping.

---

## 5. Part 3 — the zsh tool (a decision, not a task)

`tools/ac-diag.zsh` is HTTP-only via curl and shares the CLI's token cache.
Signing there is *possible* — `openssl pkeyutl -sign -rawin` does Ed25519 and
`openssl dgst -sha3-512` does the hash, both in OpenSSL 3 — but it means
managing key files in shell, and the script is deliberately dependency-light.

Three options, in order of my preference:

1. **Leave it v1 and document it as such.** The binary `breeze-core diag`
   supersedes it and would be v2 after part 1. Simplest; costs nothing.
2. **Migrate it with openssl**, gated on OpenSSL 3 being present.
3. **Retire it**, pointing users at `breeze-core diag`.

Whichever is chosen, it must be settled *before* the clamp: after
`AC_MIN_AUTH_VERSION=2`, a v1-only script gets `426 Upgrade Required` on every
control call.

---

## 6. Rollout order

Nothing here requires server changes — 3.0.5 already speaks both versions.

1. **Ship the CLI (part 1).** Run `breeze-core diag --auto` against the live
   server; its credential upgrades in place, same `token_id`.
2. **Ship the web panel (part 2).** Open it in each browser that uses it; each
   one upgrades its own credential in place on first load.
3. **Verify** with `GET /api/auth/devices` that every remaining record says
   `auth_version: 2`. Any that don't are either stale or a client nobody
   migrated — investigate before continuing.
4. **Revoke the stragglers** (`breeze-core revoke <token_id>`), starting with
   the two known-stale ones.
5. **Clamp:** set `AC_MIN_AUTH_VERSION=2` in `/etc/breeze-core/breeze-core.env`
   and restart. v1 control requests now get `426`, and v1 enrolment is refused
   outright so no new legacy credential can be minted.
6. **Keep the escape hatch in mind:** if something was missed, dropping the
   clamp back to 1 and restarting restores v1 immediately. Nothing is destroyed
   by clamping.

---

## 7. Risks and what to do about them

| Risk | Mitigation |
|---|---|
| A browser without WebCrypto Ed25519 (older Safari, an embedded WebView, a kiosk) | Feature-detect and stay v1; check every browser in the household *before* step 5 |
| Clearing site data wipes a non-extractable key | Expected; re-pair needs LAN approval. Say so in the UI near the pairing screen |
| Private browsing may block IndexedDB | Detect and fall back to v1 (or refuse to pair, with a clear message) |
| A hand-rolled SHA3 is a correctness risk | NIST vectors in the test page; cross-check against Python's `hashlib.sha3_512` for the same inputs |
| Clock skew on a desktop that's been asleep | Learn `server_time` from the 401 and retry once, as the app does |
| Clamping locks out something forgotten | Step 3 verifies first; the clamp is reversible with one env line |
| CLI and zsh share a credential path | Keep the v1 token file intact; the v2 key lives in a separate file |

---

## 8. How it gets verified

- **Unit tests** (`tests/test_auth_v2.py` already has the harness): the CLI
  signer produces headers the real app accepts — same pattern as the existing
  reference client in that file.
- **Cross-implementation vector:** one fixed (key, method, path, timestamp,
  nonce, body) tuple, with the expected canonical string and signature, checked
  in Python **and** in the browser. This is the single most valuable test here —
  it's what catches a base64url padding slip or a SHA-512/SHA3-512 mix-up.
- **NIST SHA3-512 vectors** for the JS hash, including the empty input.
- **Live checks** against the real server: upgrade in place, confirm the
  `token_id` is unchanged and `auth_version` flipped to 2; then a control call,
  a deliberate stale-timestamp call (expect `clock_skew`), and a replayed nonce
  (expect `replay`).
- **The clamp rehearsal:** set `AC_MIN_AUTH_VERSION=2` on a scratch instance
  with a temp config and confirm both migrated clients still work.

---

## 9. Effort

| Piece | Rough size |
|---|---|
| CLI signer + client branch + storage | ~150 lines, no new deps |
| SHA3-512 in JS + vectors | ~120 lines |
| Browser signer + IndexedDB + `apiFetch` branch | ~150 lines |
| Enrolment/upgrade UI wiring | ~60 lines |
| Tests (unit + cross-implementation + browser) | ~150 lines |
| Docs (API.md, HARDENING.md, README auth section) | small |

Half a day-ish of focused work, most of it in the browser half. The CLI alone
is an hour and is independently useful.

---

## 10. Decisions I need from you

1. **Both parts, or CLI first?** The CLI is quick and low-risk; the web panel
   is where the real work is.
2. **What happens to `tools/ac-diag.zsh`** — leave at v1, migrate with openssl,
   or retire it (§5).
3. **Do you want the clamp at the end?** Migrating is useful on its own;
   `AC_MIN_AUTH_VERSION=2` is the step that actually forbids v1, and it's the
   one that can lock out a browser nobody checked.
4. **Which browsers matter?** Anything in the household that opens the panel
   needs Ed25519 in WebCrypto, or it stays on v1 forever.
