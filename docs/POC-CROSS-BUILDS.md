[← Breeze Core](../README.md)

# Plan: cross-build the odd architectures instead of emulating them

**Status: implemented for Termux (aarch64, x86_64); still a proposal for the musl
targets and MIPS.** riscv64, s390x, ppc64le and Termux x86_64 were built by
emulating everything under QEMU. **Termux aarch64 — the target that deadlocked
twice under emulation and could not be built at all — now builds via the
two-stage route described here**, and §8 records what it actually cost.

## 1. Why we didn't do this in the first place — and why that stopped being right

Worth stating plainly, because "why not cross-compile?" is the obvious question
and the answer is path dependence rather than a design decision.

The pipeline began as amd64 + arm64, where **every dependency already has a
prebuilt wheel upstream**. Nothing is compiled there; emulation is needed only
for PyInstaller's freeze step, which is minutes. When riscv64 arrived — the
first target where everything had to be compiled from source — the existing
Dockerfile was extended rather than rethought, because emulation still *worked*.
It took two hours, which felt like the price of an exotic architecture.

What changed is that emulation stopped merely being slow and started being
unreliable, in ways that cost an attempt each to diagnose:

| Target | What emulation did |
|---|---|
| riscv64 | worked, ~2 h, dominated by pydantic-core's Rust compile |
| s390x | worked in ~45 min, but only after **gcc segfaulted in `cc1`** compiling PyInstaller's bootloader (clang survived) |
| ppc64le | **gcc segfaulted in `collect2`** linking pycryptodome, then again from rustc's own link step — three separate compiler knobs before it got through |
| Termux arm64 | **deadlocked twice**: qemu-user's futex handling wedges under a parallel cargo build. `-j4` died in pydantic-core, and only `-j1` made progress |
| MIPS | not attempted — Rust has no prebuilt `std` for any MIPS target (tier 3) |

Three of those five are *compiler* failures under emulation, and the fourth is
an *emulator* failure. None of them are failures of the code being built. That's
the argument for moving the compiling off the emulator.

## 2. What can be cross-built, and what genuinely cannot

The split is sharper than it first looks.

**Cross-buildable — this is where all the time goes:**

- `pydantic-core` (Rust, via maturin) — the single biggest cost on every
  wheel-less target, and the one that deadlocks.
- `pycryptodome`, `brotli` (C extensions).
- `uvloop`, `httptools`, `watchfiles` — although the odd-arch builds drop these
  by using plain `uvicorn` rather than `uvicorn[standard]`.

**Not cross-buildable — must run on the target:**

- **PyInstaller's freeze step.** It is not a cross-compiler: it imports the
  application's modules to analyse them, and embeds *the target's* interpreter
  and shared objects. It has to run where those live.
- **PyInstaller's bootloader** is a per-triple C binary. In principle
  cross-compilable with waf, but it's a handful of small C files — cheap to
  build on the target, and not worth the risk of a subtly wrong binary.

So the target still has to run something. The point is that it should only run
the *cheap* things.

## 3. Proposed shape: a wheelhouse, then a thin emulated stage

```
  Stage A — native, all cores, no emulation
    cross-build every native wheel for <target>  ->  packaging/out/wheelhouse/<target>/
  Stage B — emulated, minutes
    pip install --no-index --find-links wheelhouse/<target>   (nothing compiles)
    compile the PyInstaller bootloader (small C, single-threaded)
    pyinstaller  ->  bundle
```

Stage A never touches QEMU, so the gcc ICEs and the futex deadlock can't
happen: they are properties of the emulator, not of the code. Stage B has
nothing left that spawns a compiler storm.

**Toolchains for stage A:**

| Family | Rust | C |
|---|---|---|
| musl (s390x, ppc64le, riscv64) | `cargo-zigbuild` (zig ships the musl sysroots) or `musl-cross` | `zig cc` as `CC` |
| Android (aarch64, x86_64) | Rust `*-linux-android` targets + NDK linker | NDK clang |
| MIPS (mips64el, mipsel) | nightly + `-Z build-std` (no prebuilt `std` — tier 3) | `zig cc` (zig supports 32-bit mips) |

`cargo-zigbuild` is the interesting one: it makes "compile Rust for a musl
target you don't have a toolchain for" a one-liner, which is precisely the
problem here.

## 4. The unknown that decides feasibility — now measured

**Wheel tags and ABI.** A cross-built wheel has to be installable by the
*target's* pip, which means the tag and the ABI must match the interpreter that
will import it:

- pyo3 cross-compiles only with `PYO3_CROSS_LIB_DIR` / `PYO3_CROSS_PYTHON_VERSION`
  pointing at the target interpreter's libs — obtainable from the emulated
  container once, then reused.
- `abi3` helps a lot where it's available: pycryptodome already publishes
  `cp37-abi3`, so one wheel covers every CPython 3.x on that arch.
- pydantic-core builds against a specific CPython minor version, so the
  wheelhouse is keyed by *(arch, python-minor)*, not arch alone.

`packaging/termux/probe-target.sh` answers this for Termux by asking the target
instead of reasoning about it — it installs nothing but `python` in an emulated
container and prints the tags and ABI. **Two of this document's assumptions were
wrong, both in our favour:**

| Assumed above | Measured on `termux/termux-docker:aarch64` |
|---|---|
| maturin's `android_*` tag may need rewriting to `linux_aarch64` | pip's *preferred* tags **are** `cp314-cp314-android_24_arm64_v8a` / `android_arm64_v8a`. Native Android output is directly installable; no rewrite. |
| cross-building for Android needs the ~700 MB NDK | Termux ships an **`ndk-sysroot`** package (r29, API 24) — on-device compilation is first-class there. A few MB, and it arrives as a dependency of `python`. |

The rest of the target, for the record: CPython **3.14.6**, `SOABI
cpython-314-aarch64-linux-android`, `EXT_SUFFIX
.cpython-314-aarch64-linux-android.so`, `get_platform()
android-24-arm64_v8a`, `_PYTHON_SYSCONFIGDATA_NAME
_sysconfigdata__android_aarch64-linux-android`, `sys.platform` = `android`.
`aarch64-linux-android` is a **tier 2** Rust target, so `std` is prebuilt and
none of the MIPS `-Z build-std` machinery applies.

Two further consequences worth keeping:

- **Android's linker refuses undefined symbols in a shared object**, so a
  CPython extension must link `libpython3.14.so` explicitly — unlike glibc/musl,
  where leaving them undefined is normal. `packaging/termux/export-sysroot.sh`
  exports it alongside the sysroot for that reason.
- The probe also checks whether the target's own repository already has the
  package, which is cheaper than any build: **`python-brotli` is prebuilt**
  (1.2.0-2), as is `python-cryptography`. `python-pydantic-core` and
  `python-pycryptodome` are not — so pydantic-core is the one that has to be
  cross-built, and it is also the one that deadlocks. Convenient.

## 5. Suggested sequence

1. ~~**Spike.**~~ **Done — on Termux aarch64 rather than ppc64le**, because that
   was the target actually blocked rather than merely slow. The tag/ABI wall was
   cleared (§4), so the approach is proven end to end; see §7 for the numbers.
2. **Generalise into `packaging/binary/build-wheelhouse.sh`** with the target
   matrix above; publish each wheelhouse as its own artifact (this *is* the
   MIPS deliverable, so it earns its keep immediately). The Termux scripts are
   the working template: probe → export sysroot → cross-build → thin emulated
   freeze.
3. **Thin out `Dockerfile.musl`**: when a wheelhouse for the target exists,
   install from it and skip `WITH_TOOLCHAIN` entirely — no rust, no gcc, no
   clang workarounds, no cache mounts. s390x and ppc64le already work without
   this, so it buys build time rather than capability.
4. **Then MIPS**, which is only reachable this way: `-Z build-std` cross-builds
   the `std` that Rust doesn't ship, on the host, at native speed. Unlike
   Android, MIPS Linux targets are **tier 3** — that is the one place the harder
   Rust machinery is unavoidable.

## 6. What this is expected to buy

- riscv64: ~2 h → minutes for the wheels, plus a short emulated freeze.
- ppc64le / s390x: no clang/gcc/linker workarounds at all — those exist purely
  because the compiler runs under emulation.
- Termux arm64: unblocked rather than merely slow.
- MIPS: possible rather than impossible.
- And one honest cost: **cross-built binaries are less obviously trustworthy
  than natively built ones.** The mitigation stays what it is today — run
  `breeze-core version` on the target, under emulation, before publishing
  anything. That check is cheap and it is the whole reason these are labelled
  proof-of-concept.

## 7. What it actually cost, on the one target that had failed

Termux aarch64, end to end, with the scripts in `packaging/termux/`:

| Step | Where | Time |
|---|---|---|
| `probe-target.sh` — ask the target what it accepts | emulated | ~4 min |
| `export-sysroot.sh` — pull out a cross toolchain (124 MB) | emulated | ~4 min |
| `cross-wheel.sh` — **compile pydantic-core** | **native** | **55 s** |
| `build-bundle.sh` — install wheels, build bootloader, freeze | emulated | ~22 min |

The 55 seconds is the headline: that same compile is what wedged qemu-user
indefinitely, twice. The emulated stage that remains contains no cargo at all —
`rust` is no longer even installed, which also removes a 239 MB download.

Verified, in this order, because each step proves something the previous one
does not:

1. The wheel is `pydantic_core-2.46.4-cp314-cp314-android_24_arm64_v8a.whl`, and
   `file` reports its extension module as *ELF 64-bit LSB shared object, ARM
   aarch64, for Android 24, built by NDK r29* — with `libpython3.14.so` in its
   DT_NEEDED, as Android requires.
2. Installed by the **target's own pip** in a container with no compiler
   present, then exercised: `SchemaValidator({"type":"int","ge":16,"le":30})`
   accepts 22 and raises `ValidationError` for 99. Rust logic, running on the
   target.
3. The published tarball extracts and runs on a clean emulated Termux guest:
   `Breeze Core 3.0.5 (commit 6f4cb29)`.

### Three traps that cost an attempt each

Recorded because none of them announce themselves, and two produced *convincing
but wrong* conclusions:

- **`-isystem` is not a sysroot.** It adds a search path without removing the
  host's, so Bionic's `limits.h` → `#include_next` → clang builtin → host glibc
  → `bits/libc-header-start.h` not found. A glibc error while cross-compiling
  for Android. Fix: a real `--sysroot`, with `/ndk/usr` symlinked to the Termux
  prefix so the layout matches what clang expects.
- **termux-docker discards `docker -e` variables** in its entrypoint —
  `-e MARKER=survived` yields `MARKER=EMPTY`. So `POC_CARGO_JOBS` reached *none*
  of the earlier attempts: the run believed to be throttled to `-j1` and the
  later `-j4` "gamble" were both unthrottled, and the deadlock evidence from
  them was measuring the same configuration twice. Settings now travel as a file
  inside the tar.
- **`pkg` rotates mirrors** on every invocation regardless of `sources.list`; one
  run pulled from six different hosts and crawled. `apt-get` honours the pin.

And one bug in the tooling itself: `poc-watchdog.sh` killed a *healthy* build
five minutes into a 239 MB download, because near-0% CPU during a download is
indistinguishable from a qemu deadlock by CPU alone. It now requires no CPU
**and** no I/O movement before declaring a stall.

## 8. Decisions for the maintainer

1. **Spike first, or build the pipeline?** I'd spike: one target, one wheel, and
   the tag/ABI question answered before anything is generalised.
2. **zig or musl-cross?** zig is one dependency and covers every musl target
   including 32-bit MIPS; musl-cross is more conventional and more per-target
   setup.
3. **Do the supported amd64/arm64 builds change?** My recommendation: no. They
   use upstream wheels, they don't compile anything, and they are the builds
   people actually install. Leave them alone.
