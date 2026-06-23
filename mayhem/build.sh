#!/usr/bin/env bash
#
# fips203/mayhem/build.sh — build integritychain/fips203's cargo-fuzz targets as sanitized
# libFuzzer binaries, replicating OSS-Fuzz's Rust path (infra/base-images/base-builder/compile +
# projects/fips203/build.sh which runs `cargo fuzz build`).
#
# fips203 is a pure-Rust ML-KEM (Kyber) crate. cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is exactly what OSS-Fuzz's
#     `compile` sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
#
# Targets (fuzz/fuzz_targets/*.rs):
#   ml_kem_fuzz  — the OSS-Fuzz target. Decodes an `arbitrary` FuzzInput (seeds d/z/e + xor masks
#                  for ek/dk/ct/ss) and drives keygen_from_seed/encaps/decaps + try_from_bytes
#                  deserialization across ml_kem_512/768/1024.
#   fuzz_all     — also shipped in the repo. Consumes a fixed 3328-byte blob as a replay-RNG +
#                  xor masks and drives the ml_kem_512 keygen/encaps/decaps/validate surface.
#
# We build BOTH (additive — the OSS-Fuzz build.sh only ships ml_kem_fuzz) and copy each produced
# binary to /mayhem/<target>.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# The cargo-fuzz crate lives in fuzz/ (cargo-fuzz convention).
FUZZ_TARGETS=(ml_kem_fuzz fuzz_all)
TRIPLE="x86_64-unknown-linux-gnu"

# DWARF < 4 debug info (SPEC §6.2 item 10): cargo-fuzz links librustc-nightly_rt.asan.a (DWARF5)
# via --whole-archive, placing it at .debug_info offset 0. -Zdwarf-version=3 alone does NOT win
# because the ASan runtime CU lands first. The cc-wrapper injects a DWARF3 anchor.o as the very
# first linker input, pushing the ASan runtime CU back, so readelf sees DWARF3 at offset 0.
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=2 -Zdwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address -Cforce-frame-pointers ${RUST_DEBUG_FLAGS}"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

# `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's build.sh (catches overflow/debug
# asserts during fuzzing). cargo-fuzz reads the targets from fuzz/Cargo.toml. We build per-target so
# a single bad target doesn't mask the others, and so each binary path is deterministic.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  # Use the image's DEFAULT toolchain (Dockerfile pins it to the required nightly); a `+toolchain`
  # override would make rustup try to install a different channel into the read-only shared /opt/rust.
  # cargo-fuzz 0.12 doesn't accept --jobs (nor forward it via `--`); it builds with cargo's default
  # parallelism. Job count is controlled instead via CARGO_BUILD_JOBS in the environment (above).
  cargo fuzz build -O --debug-assertions "$t"
  bin="$SRC/fuzz/target/$TRIPLE/release/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la /mayhem/ml_kem_fuzz /mayhem/fuzz_all 2>&1 || true
