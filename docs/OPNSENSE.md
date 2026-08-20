[← Breeze Core](../README.md)

# OPNsense: the `os-breeze-core` plugin

Tier 1 port, built every release between the BSD packages and OpenWrt. It is a
proper plugin — a page under **Services**, service control through configd, an rc
script — not a bare `pkg add` of the FreeBSD package.

## Why the FreeBSD package cannot just be reused

Three things about OPNsense, each checked against their repository rather than
assumed. They are the whole reason this port has its own build.

| | Finding | Consequence |
|---|---|---|
| **ABI** | OPNsense 24.7 → 25.7 are all `FreeBSD:14:amd64` | our FreeBSD VM is 15.1 → `FreeBSD:15:amd64`. `pkg` refuses it outright, and forcing it would install extensions linked against 15-era libraries. FreeBSD promises *forward* compatibility, not backward, so this is the wrong direction. Everything must build in a FreeBSD **14** userland. |
| **Python** | they ship **python311** (3.11.14) | the venv must be 3.11. A 3.12 tree cannot import a single `cpython-311.so`. |
| **Dependencies** | **none** of ours are packaged — no fastapi, uvicorn, pydantic, pydantic-core, starlette, msmart-ng, pycryptodome — **and no `rust`, and no `py311-pip`** | nothing can be compiled *or fetched* on the firewall. The plugin must vendor a complete tree and depend on `python311` alone. |

They do ship `py311-cryptography`, `py311-sqlite3` and `py311-setuptools`, which
is not enough to matter: without pip there is no way to install the rest anyway.

## Shape of the artifact

```
os-breeze-core-<ver>.pkg          ABI FreeBSD:14:amd64, depends: python311
├── /usr/local/lib/breeze-core/   vendored venv + meow_ac + static  (~19 MB)
│   └── serve.sh                  service launcher (sets its own environment)
├── /usr/local/bin/breeze-core    CLI wrapper (setup / approve / diag)
├── /usr/local/etc/rc.d/breeze_core
└── /usr/local/opnsense/          MVC page, menu, ACL, configd actions, template
```

The venv is built **at its final path** inside the chroot, because a venv bakes
absolute paths into `pyvenv.cfg` and every console script — building elsewhere
and relocating gives a tree that only appears to work.

Settings kept deliberately small: **enabled, listen address, port**. The API key
and the paired-unit list live in Breeze Core's own `config.json`, written by its
panel and its pairing flow. Templating over that from the GUI would clobber
credentials on every save.

## Build and verify

```bash
packaging/opnsense/build-plugin.sh    # -> packaging/out/opnsense/os-breeze-core-<ver>.pkg
packaging/opnsense/verify-plugin.sh   # installs it into a clean FreeBSD 14 root
```

The verifier deliberately reproduces what OPNsense *actually* offers: a FreeBSD 14
userland with **python311 and nothing else** — no rust, no pip, no compiler. If
the package needs any of them at install time, it is broken for the target and
this catches it.

**What cannot be verified here:** the GUI. The MVC page, menu entry and configd
wiring need OPNsense's own PHP stack, so the PHP is lint-checked and the XML
parsed, but "the page renders and the toggle works" has to be confirmed on a real
install. Anything below the GUI line — install, ABI, dependency resolution, the
vendored runtime, the rc script, the HTTP endpoint — is verified.

## The GUI contracts, checked against their source

The GUI is the part no chroot can exercise, so each place the plugin has to agree
with OPNsense's own PHP was read out of `opnsense/core` rather than assumed. All
four are cheap to get wrong and silent when wrong.

| What | The contract | Where it bites |
|---|---|---|
| **Rendered settings** | `load_rc_config()` sources `${_d}/rc.conf.d/$name` for `_d` in `/etc` and `${local_startup%/rc.d}` = `/usr/local/etc`, and nowhere else | the template must land on `/usr/local/etc/rc.conf.d/breeze_core`. Anywhere tidier and the rc script keeps its built-in defaults: the GUI's address and port never reach uvicorn, with no error anywhere, because every value is still valid |
| **Service buttons** | `updateServiceControlUI(name)` fills `#service_status_container`, which `layouts/default.volt` already provides beside the page title | the page needs no markup of its own — its absence is correct, not an omission |
| **Status light** | `statusAction()` is `strpos($configd_output, 'is running')` / `'not running'` | the rc script's wording *is* an API. Reword it and the service works while the GUI shows "unknown" forever |
| **Save → apply** | `reconfigureAction()` calls stop, `template reload <template>`, then start **or reload** | a `reload` configd action has to exist. uvicorn has no config-reload signal, so it is honestly mapped to `onerestart` |

The status wording is asserted by `verify-plugin.sh` — it greps the rc script's
own output for the two strings the PHP looks for, which is the one GUI contract
that can be checked without a GUI. The rendered-settings path is covered too: the
rc test writes what configd would render and passes **no** environment, so the
service must pick the port up from the file or the HTTP check fails.

## Traps, all of which cost a build

Recorded because none of them announce themselves, and several look like a
different problem entirely.

- **devfs must be mounted in the chroot.** Without it cargo fails absurdly: it
  pipes source to `rustc -` on stdin, that read misbehaves with no `/dev`, and
  rustc ends up parsing an error *message* as source — surfacing as
  `E0554: #![feature] may not be used on the stable release channel`, which sends
  you hunting for a nightly/toolchain problem that does not exist (rustc was
  1.96.1).
- **`pkg create` needs an explicit plist.** Given only `-M` and `-r` it packages
  the manifest and nothing else, **exits 0**, and hands you a 1160-byte
  "package".
- **Stage only our own tree.** Copying `$ROOT/usr/local/lib` wholesale drags in
  everything `pkg` installed in the build root, rust's libraries included: a
  168 MB plugin from a 19 MB payload.
- **`daemon -u` drops privileges before writing the pidfile**, so a pidfile in
  `/var/run` fails with `ppidfile: Permission denied`. It lives in
  `/var/run/breeze_core/`, created owned by the service account.
- **`daemon -u` also wipes the environment** (it calls `setusercontext`), so
  `PYTHONPATH` and `AC_CONFIG` exported from `start_precmd` never reach uvicorn
  and it dies with `ModuleNotFoundError` before anything is logged. `serve.sh`
  sets its own environment for that reason.
- **`daemon -c` chdirs to `/`**, so relying on cwd for the import path does not
  work either — hence `PYTHONPATH`, not `cd`.
- **`daemon -f` sends the failure to `/dev/null`.** Every one of the above looked
  identical from the outside: `breeze_core is not running`. Debug with `-o
  /tmp/x.log`, or the cause is invisible.
- **`meow_ac` has no `__main__`** — the CLI module is `meow_ac.cli`, which is what
  the BSD installer uses. `-m meow_ac` fails outright, and the GUI page tells the
  admin to run `breeze-core pair`.
- **The source tar is built on Windows**, which records no POSIX execute bit, so
  anything that must be executable is chmod-ed explicitly in the build.
- **Test on a port that cannot collide.** The builder VM may be running Breeze
  Core itself from the FreeBSD package work; a chroot shares the host network
  stack, so `8420` gives `address already in use` and looks like a broken rc
  script. The verifier uses 18420.
- **Tearing down a FreeBSD test root** needs `umount` of devfs first and
  `chflags -R noschg` — base files like `/sbin/init` and `libexec/ld-elf.so.1`
  are immutable and `rm` fails as root without it.
- **`${name}_user` is rc.subr magic.** Setting `breeze_core_user` makes rc.subr
  wrap the command in `su -m`, which then collides with `daemon -u` and the
  service never starts. The knob is named `breeze_core_runas` for that reason.
- **`procname` must be `/usr/sbin/daemon`**, not the interpreter: the pid in the
  pidfile is daemon's, so with the interpreter as `procname` the status check
  compares the wrong binary and always says "not running" — while the service is
  up and serving.
- **`pkill` unprivileged fails silently.** The service runs as its own account,
  so a bare `pkill` gets "Operation not permitted", `|| true` swallows it, and the
  stray from the previous run keeps the port. The next run then fails to bind and
  the *stray* answers the HTTP check — a 500 from a server whose tree was deleted
  underneath it, which reads as a broken package. Kill with `doas`, and match
  `lib/breeze-core` specifically: the builder also runs the FreeBSD *package* from
  `/usr/local/breeze-core`, and a loose pattern kills that too.
- **`pkill -f "$TEST"` matches nothing.** Inside the chroot the argv is
  `/usr/local/lib/...` — the test root's path appears nowhere in it.
- **A failure between start and teardown poisons the next run.** Under `set -e`
  the script exits before unmounting devfs, so the following run inherits a
  mounted root, and `rm -rf` recurses into live devfs ("Operation not supported"
  per node, then "Device busy"). The rc block ends in `|| bad` so teardown always
  runs, and teardown refuses to `rm` while devfs is mounted.
- **Don't use `fetch(1)` for the HTTP check.** Its `--header` support varies by
  release, and an unsupported option is indistinguishable from a dead server —
  this check printed nothing at all while the service was fine. The vendored
  interpreter is already there; use it.
- **Run the probe from a file, not `python -c`.** It sits inside
  `chroot ... sh -c "..."`, and a nested double quote ends the outer string,
  leaving python a bare `-c`: *"Argument expected for the -c option"*.
- **Don't hand the rc script its settings through the environment in tests.**
  Exporting `breeze_core_port=` bypasses the entire config path, which is how a
  template rendered to a path `load_rc_config` never reads went unnoticed. The
  test renders the file and sets nothing.

## Installing it on a firewall

```sh
# OPNsense shell, as root
fetch https://bolero.salataputarica.hr.eu.org/opnsense/os-breeze-core-latest.pkg
pkg add os-breeze-core-latest.pkg
```

A version-stamped copy and `.sha256` files sit alongside it in
[/opnsense/](https://bolero.salataputarica.hr.eu.org/opnsense/). The plugin is
deliberately outside the signed FreeBSD repository: that repo is
`FreeBSD:15:amd64` and this package is `14`, so `pkg` would refuse it there.

Then:

1. **Services → Breeze Core** in the GUI: set the listen address and enable it.
2. `breeze-core pair` — discover and pair the air conditioners.
3. `breeze-core approve` — admit a phone or browser. Approval is LAN-only by
   design.

Keep the bind address on a LAN interface (or 127.0.0.1 behind the OPNsense
reverse proxy for TLS). Do not expose it on WAN: pairing approval trusts the
local network.
