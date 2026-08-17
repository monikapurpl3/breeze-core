[← Breeze Core](../README.md)

# Plan: cross-build the odd architectures instead of emulating them

**Status: proposal. Nothing here is implemented.** The proof-of-concept builds
that exist today (riscv64, s390x, ppc64le, Termux x86_64) were all made by
emulating the whole build under QEMU.

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

## 4. The unknown that decides feasibility

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
- Termux is the fiddliest: its CPython is built against Bionic with its own
  paths, and maturin may emit an `android_*` tag where Termux's pip expects
  `linux_aarch64`. Possibly `--compatibility off` plus a tag rewrite.

**This is what a spike should test first**, before any pipeline work.

## 5. Suggested sequence

1. **Spike (half a day).** Cross-build `pydantic-core` for `ppc64le-musl` on the
   host with cargo-zigbuild. Install it inside the emulated ppc64le container
   with `--no-index --find-links`. Success criterion: it imports, and the wall
   time is minutes rather than the ~13 that the emulated compile just took.
   If the tag/ABI wall can't be cleared here, stop — the rest inherits it.
2. **Generalise into `packaging/binary/build-wheelhouse.sh`** with the target
   matrix above; publish each wheelhouse as its own artifact (this *is* the
   MIPS deliverable, so it earns its keep immediately).
3. **Thin out `Dockerfile.musl`**: when a wheelhouse for the target exists,
   install from it and skip `WITH_TOOLCHAIN` entirely — no rust, no gcc, no
   clang workarounds, no cache mounts.
4. **Then MIPS**, which is only reachable this way: `-Z build-std` cross-builds
   the `std` that Rust doesn't ship, on the host, at native speed.
5. **Then Termux arm64**, whose deadlock disappears once the Rust compile is no
   longer emulated.

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

## 7. Decisions for the maintainer

1. **Spike first, or build the pipeline?** I'd spike: one target, one wheel, and
   the tag/ABI question answered before anything is generalised.
2. **zig or musl-cross?** zig is one dependency and covers every musl target
   including 32-bit MIPS; musl-cross is more conventional and more per-target
   setup.
3. **Do the supported amd64/arm64 builds change?** My recommendation: no. They
   use upstream wheels, they don't compile anything, and they are the builds
   people actually install. Leave them alone.
