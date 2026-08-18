[← Breeze Core](../README.md)

# Plan: a Flutter web client that clamps onto Breeze Core

**Status: plan only. Nothing here is implemented, and by design none of it lands
on `main` or in this repository's server tree.**

## What this is — and what it is emphatically not

It is **not a fork of the server**. It is a *third client*, alongside the Android
app and the vanilla-JS web UI, speaking the same three `/api/*` endpoints. A
parasite: it clamps onto a Breeze Core someone is already running, and that
server neither knows nor cares it exists. Delete it and everything keeps working,
which is the same contract the existing clients honour.

The appeal is straightforward: the Flutter app already has the good controls —
the temperature dial, fan, flap, mode, power, the indoor/outdoor climate bar, the
Nerd screen, profiles, Ed25519 v2 auth — as Dart code drawn with `CustomPainter`.
Compiling that to the web gets the browser panel to app parity for a fraction of
what rewriting it in vanilla JS would cost, and iOS users on the web UI get the
same experience as Android users have in the app.

## Where it lives

**A separate repository, not a branch, and never `main`.**

A branch of this repo would drag the entire server tree along for a client that
touches none of it, and would imply eventually merging back — which is exactly
what must not happen, because of the constraint in the next section. A separate
repo (say `breeze-web`) that depends on the published API contract is the honest
shape. If the lineage matters, forking this repo on GitHub and deleting
`meow_ac/` is fine; the point is that the server's `main` never grows a build
step.

## The two constraints that decide the whole design

### 1. It must be served same-origin, because CORS is not on the table

`create_app()` deliberately has no CORS middleware, and the reason is documented
inline: the UI is same-origin, and permissive CORS would let any other page on
the LAN drive the API. That is load-bearing and this plan does not get to relax
it.

So a Flutter client hosted on its own origin — a different port, bolero, a dev
server — **cannot talk to Breeze Core at all**. Browsers will block it, and the
fix is not "add CORS".

That leaves one workable shape: **build elsewhere, serve from the server's own
origin**. The build output (`build/web/`) is static files, so:

- ship it as a tarball users drop into place, or
- ship it as an optional package (`breeze-core-web-flutter`) that installs the
  files and mounts them at a second path,
- and mount it at something like `/flutter/` so the existing panel stays at `/`
  and neither replaces the other.

That is also the migration story: both UIs can be served at once, from the same
origin, and people can switch by changing the URL.

### 2. It cannot be served under the current CSP without loosening it

`SecurityHeadersMiddleware` sets `default-src 'self'` with no inline scripts, and
CLAUDE.md is explicit that adding either forces loosening the CSP. Flutter Web's
bootstrap uses an inline script, and the CanvasKit/WASM renderer additionally
needs `wasm-unsafe-eval`.

This is solvable but must be deliberate: a **separate, narrower CSP applied only
to the `/flutter/` mount**, leaving the policy over `/` untouched. What it must
not become is a global relaxation that weakens the existing panel to accommodate
the new one. If that is unacceptable, the honest conclusion is that the Flutter
client is served by something else on the same origin (a reverse proxy path), not
by Breeze Core.

## What the Flutter route gets for free — including one thing the JS route cannot

Reusing the app's Dart is worth more than the widgets:

- **Controls, layout, climate bar, Nerd screen, profiles** — all `CustomPainter`
  or plain Dart, all platform-neutral.
- **`ApiClient`, SSE consumption, poll fallback, the 401 reason-code handling** —
  the parts that took the longest to get right.
- **Auth v2 signing, which is the interesting one.** The vanilla-JS migration is
  blocked on a real wall: WebCrypto has Ed25519, but it has **no SHA3-512**, and
  the v2 canonical string hashes the body with SHA3-512. A Flutter client has no
  such problem — `cryptography` and `pointycastle` are Dart and compile to
  JS/WASM, so the *same* signing code the app uses runs in the browser. That
  quietly removes the blocker from
  [AUTH-V2-MIGRATION.md](AUTH-V2-MIGRATION.md) for this client.

**The catch, and it is a real one:** a browser has no Keychain and no Android
Keystore. An Ed25519 private key in a Flutter web client lives in IndexedDB,
readable by any script that achieves XSS on that origin. That is strictly weaker
than either existing client, and it argues for treating a browser credential as
lower-trust — a shorter TTL than the household's 3650 days, and a label that
makes it obvious in `/api/auth/devices` which credential is the browser's.

## Screen philosophy: desktop side-by-side, phone stacked

The current panel already does this and it must survive: the grid is
`repeat(auto-fit, minmax(340px, 1fr))` collapsing to one column under 620px, so
units sit **next to each other on a desktop and under each other on a phone**.

Note that this is *not* what the Android app does — the app is one unit per
screen with `PageView` swiping, which suits a phone and would be wrong on a
1440px monitor. So the Flutter client cannot simply reuse the app's top-level
navigation: it needs a `LayoutBuilder` that chooses a responsive grid on wide
viewports and the stacked/swipe arrangement on narrow ones. Everything *inside*
a unit card carries over unchanged.

## Cost, honestly

- **Payload.** The current UI is 1,531 lines of hand-written JS and CSS served as
  ~40 KB of text. A Flutter web build is megabytes — roughly 1.5–2 MB with the
  HTML renderer, considerably more with CanvasKit. On a LAN that is a non-issue
  on second load and noticeable on first. On a router with extroot it is a
  genuine consideration.
- **A build step enters the picture** — just not in this repo. The parasite has
  `flutter build web` in its own CI; Breeze Core keeps its "no build step, native
  ES modules" property, which is the whole reason for keeping them apart.
- **Two UIs to maintain.** Mitigated by the vanilla panel staying deliberately
  simple: it now streams state, has beep and the Nerd panel, and does not need to
  chase every app feature. If the Flutter client succeeds, the vanilla one
  becomes the small dependency-free fallback rather than the flagship — a
  reasonable division, and worth deciding on purpose rather than by neglect.

## Suggested sequence

1. **Spike the CORS/CSP question first**, because everything depends on it: build
   the app for web, drop it into a directory served by Breeze Core at
   `/flutter/`, and see what the CSP blocks. If it cannot be served same-origin
   under an acceptable policy, the plan changes shape entirely and it is better to
   learn that in an afternoon.
2. **Prove auth v2 in the browser** — enrol, sign one request with the Dart path,
   confirm the server accepts it. That is the claim most worth checking early,
   and it is the one that makes this route better than a JS rewrite.
3. **Responsive shell**: `LayoutBuilder`, grid on wide, stacked on narrow.
4. **Port the unit card** — mostly moving `CustomPainter` code.
5. **The rest**: profiles, Nerd, programs, diagnostics.
6. **Distribution**: publish `build/web` as a tarball on bolero next to the PoC
   artifacts, or as an optional package. Frozen and versioned separately from the
   server, like a client should be.

## Open questions

1. **Same-origin mount path** — `/flutter/`? `/ui2/`? Whatever it is, it should
   not be `/`, so both UIs coexist during the trial.
2. **Renderer** — HTML (smaller, weaker fidelity for custom painting) or CanvasKit
   (bigger, pixel-identical to the app)? Given the whole point is reusing
   `CustomPainter` work, CanvasKit is the honest default and the payload cost has
   to be accepted or measured.
3. **Should browser credentials get a shorter TTL** than app credentials, given
   IndexedDB cannot protect a key the way a Keystore can?
4. **Does the vanilla panel stay the default** at `/` indefinitely? Recommended
   yes, at least until the Flutter client has run in the household for a while.
