[← Breeze Core](../README.md)

# Voice control: what is possible without a cloud

**Status: exploration. Nothing here is committed except the first option, which
belongs to the Breeze app rather than to Breeze Core.**

The question is "can I control the air conditioning by voice", and it has a much
sharper answer than it first appears, because one architectural constraint
eliminates the two most obvious routes outright.

## The constraint

Breeze Core is LAN-only by design. From the project's own description: no Home
Assistant, **no cloud dependency after initial pairing**. Nothing about the
household's climate leaves the house.

**Alexa Smart Home skills and Google Smart Home actions both require a publicly
reachable HTTPS endpoint plus OAuth**, operated by whoever publishes the
integration. Amazon and Google call *your* server; your server does not call
them. That means:

- a public endpoint exposed to the internet,
- an OAuth authorisation server with account linking,
- every command and state report routed through Amazon's or Google's cloud,
- and an availability commitment, because a voice command that times out is worse
  than no voice control.

That is not a cost/benefit trade-off to weigh. It contradicts the premise of the
project. **Both are excluded**, and anything claiming otherwise is smuggling a
cloud service in.

What follows are the routes that are genuinely local.

## Option 1 — Siri Shortcuts / App Intents (committed, app-side)

**What:** the iOS app declares App Intents — "set unit to N degrees", "turn unit
off", "set unit to cool" — which Siri and the Shortcuts app can invoke.

**Why it works locally:** the intent runs *inside the app*, on the phone, on the
LAN. Siri does the speech recognition; the resulting action is an ordinary local
HTTP request from the same code path the UI uses. No endpoint, no account, no
cloud in the control path.

**Reach:** iPhone, Apple Watch, Lock Screen, CarPlay-less in-car use via "Hey
Siri", HomePod **no** (a HomePod cannot reach an app on your phone).

**Cost:** small. Intent definitions plus a thin dispatch layer onto the existing
API client. Ships as phase 5 of the iOS port —
[breeze/docs/IOS.md](https://github.com/monikapurpl3/breeze/blob/main/docs/IOS.md).

**Android equivalent:** app shortcuts and Assistant app-actions exist but are far
weaker than they used to be; Google has been steadily deprecating the surface.
Worth a look, not worth planning around.

**Limitation worth being honest about:** this is voice control *of your phone*,
not of your home. It does not work from a smart speaker, and it does not work for
a family member who does not have the app.

## Option 2 — a HomeKit (HAP) bridge in Breeze Core

**What:** Breeze Core additionally speaks the HomeKit Accessory Protocol,
appearing as one or more thermostat accessories. Add it in the Home app once;
after that Siri, the Home app, HomePods, Apple Watch and automations all work.

**Why it works locally:** HAP is a LAN protocol. Pairing and control are
device-to-device over the local network. Apple's servers are involved only in
optional remote access via a home hub, which can simply be left out.

**Feasibility:** genuinely good. `HAP-python` is pure Python and would run
alongside the existing asyncio app — the same process, or a sibling service
reading the same `config.json`. **No MFi licence is required for a software
bridge**; this is exactly what Homebridge has done for a decade.

**Reach:** the whole Apple household, including speakers. Nothing for Android
users, which is the catch — this project's primary client is an Android app.

**Cost:** a day or two. The natural shape is a `HomeKitBridge` that reuses
`devices/control.py:apply_to_unit`, the same seam the scheduler already uses, so
voice, schedule and HTTP all converge on one code path.

## Option 3 — a Matter bridge in Breeze Core

**What:** Breeze Core exposes each AC as a Matter bridged device.

**Why it is the strategic answer:** one implementation serves **Apple Home,
Google Home, Alexa and SmartThings simultaneously**, and Matter's control path is
local — the ecosystem apps commission the device over the LAN and then talk to it
directly. It is the only option that gives Android/Google and Amazon households
voice control without a cloud endpoint.

**Modelling:** Matter's device library fits Breeze almost suspiciously well.
The **Thermostat** device type covers mode and setpoint; a **Fan** cluster covers
fan speed; occupancy/temperature attributes cover the indoor and outdoor sensor
readings the app already displays. `operational_mode` maps onto
`SystemMode`, `target_temperature` onto the occupied setpoint attributes, and the
0.5° step matches Matter's centidegree representation without loss.

**Feasibility:** the hard part. The mature Matter SDK is Google's `connectedhomeip`
— C++, large, and awkward to vendor into a small Python project. The Python
bindings in that tree are primarily *controller*-side; writing a bridged **device**
in Python is less well-trodden. Options worth investigating before committing:
building against `connectedhomeip`'s Python device bindings, shipping the bridge
as a separate optional component with its own build (an ipk/deb, not part of the
frozen bundle), or wrapping an existing bridge project.

**Cost:** substantially more than option 2, and it would not fit the "single
self-contained PyInstaller bundle" distribution model the project relies on —
which is itself an argument for shipping it as an optional add-on rather than
folding it into `breeze-core`.

## The posture question, stated plainly

Options 2 and 3 both make the air conditioners visible in Apple's, Google's or
Amazon's apps. The traffic stays on the LAN, but the *user experience* becomes
"my AC is in the Google Home app", which is a change in character for a project
whose selling point is that it answers to nobody. Worth deciding on purpose
rather than discovering after the fact.

A reasonable middle position: implement a bridge, keep it **off by default**,
behind an explicit setting, documented as "this exposes your units to <ecosystem>;
control stays local, discovery does not have to happen at all if you never turn
this on".

## Recommendation

1. **Do option 1 now**, as part of the iOS port. It is cheap, local, and the same
   work that substitutes for CarPlay.
2. **Consider option 2 next** if the household is Apple-heavy — it is a day or
   two of pure-Python work reusing an existing seam, and it brings HomePods and
   Apple Watch along.
3. **Treat option 3 as a project of its own**, not a feature. It is the right
   long-term answer for reach, and the wrong thing to start while it would be the
   most complex component in the repository.
4. **Never do Alexa or Google Smart Home skills.** They cannot be done without
   becoming a cloud service.

## Also worth knowing

- **`msmart-ng` is not the constraint here.** All three options sit above the
  existing API surface, so none of them requires touching device I/O.
- **The scheduler already proved the seam.** `devices/control.py:apply_to_unit`
  is shared by the HTTP route and the scheduler; a bridge would be the third
  caller, and keeping all three on one path is the reason that extraction was
  worth doing.
- **Authentication does not map onto voice.** The device-pairing model (API key
  plus a per-device Ed25519 credential, admin-approved on the LAN) has no
  equivalent in HAP or Matter, which have their own pairing. A bridge is
  effectively a *trusted local client* and should hold its own credential like
  any other device — not bypass authentication internally.
