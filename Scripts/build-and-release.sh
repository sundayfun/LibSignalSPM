#!/usr/bin/env bash
#
# build-and-release.sh — Build LibSignal xcframework and publish a GitHub release
#
# Usage: ./Scripts/build-and-release.sh <tag>
#   e.g. ./Scripts/build-and-release.sh v0.77.0

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

LIBSIGNAL_REPO="https://github.com/nicegram/nicegram-libsignal.git"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DEVICE_SLICE="ios-arm64"
SIM_SLICE="ios-arm64_x86_64-simulator"

RUST_TARGETS=(
    "aarch64-apple-ios"
    "aarch64-apple-ios-sim"
    "x86_64-apple-ios"
)

# ── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { printf "${CYAN}▸${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
die()   { printf "${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

# ── Args ─────────────────────────────────────────────────────────────────────

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
    log "No tag specified, fetching latest release from GitHub..."
    TAG=$(git ls-remote --tags --sort=-v:refname "$LIBSIGNAL_REPO" 'v*' \
        | head -1 | sed 's|.*/||; s/\^{}$//')
    if [[ -z "$TAG" ]]; then
        die "Failed to fetch latest tag from $LIBSIGNAL_REPO"
    fi
    ok "Latest release: $TAG"
fi

# Strip 'v' prefix for semver
SEMVER="${TAG#v}"

# ── Preflight ────────────────────────────────────────────────────────────────

log "Preflight checks..."

for cmd in rustup cargo cbindgen xcodebuild lipo git gh swift; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd"
done

for target in "${RUST_TARGETS[@]}"; do
    if ! rustup target list --installed | grep -q "^${target}$"; then
        log "Installing Rust target: $target"
        rustup target add "$target"
    fi
done

ok "Preflight passed"

# ── Clone ────────────────────────────────────────────────────────────────────

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

log "Cloning libsignal $TAG into $WORK_DIR..."
git clone --depth 1 --branch "$TAG" "$LIBSIGNAL_REPO" "$WORK_DIR/libsignal"
ok "Clone complete"

SIGNAL_DIR="$WORK_DIR/libsignal"
RUST_DIR="$SIGNAL_DIR/rust"
FFI_DIR="$RUST_DIR/bridge/ffi"

[[ -d "$FFI_DIR" ]] || die "Expected $FFI_DIR not found — repo structure may have changed"

# ── Build ────────────────────────────────────────────────────────────────────

log "Building libsignal_ffi for ${#RUST_TARGETS[@]} targets (this will take a while)..."

for target in "${RUST_TARGETS[@]}"; do
    log "  Building: $target"
    cargo build \
        --manifest-path "$FFI_DIR/Cargo.toml" \
        --target "$target" \
        --release \
        2>&1 | tail -1
    ok "  Built: $target"
done

ok "All targets built"

# ── Locate build artifacts ───────────────────────────────────────────────────

CARGO_TARGET_DIR="$SIGNAL_DIR/target"

LIB_DEVICE="$CARGO_TARGET_DIR/aarch64-apple-ios/release/libsignal_ffi.a"
LIB_SIM_ARM="$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libsignal_ffi.a"
LIB_SIM_X86="$CARGO_TARGET_DIR/x86_64-apple-ios/release/libsignal_ffi.a"

for lib in "$LIB_DEVICE" "$LIB_SIM_ARM" "$LIB_SIM_X86"; do
    [[ -f "$lib" ]] || die "Build artifact missing: $lib"
done

# ── Headers ──────────────────────────────────────────────────────────────────

log "Generating headers..."

HEADER_DIR="$WORK_DIR/headers"
mkdir -p "$HEADER_DIR"

CBINDGEN_TOML="$FFI_DIR/cbindgen.toml"
if [[ -f "$CBINDGEN_TOML" ]]; then
    cbindgen --config "$CBINDGEN_TOML" \
        --crate libsignal-ffi \
        --manifest-path "$FFI_DIR/Cargo.toml" \
        --output "$HEADER_DIR/signal_ffi.h" \
        --quiet \
        || true
fi

if [[ ! -s "$HEADER_DIR/signal_ffi.h" ]]; then
    for candidate in \
        "$FFI_DIR/signal_ffi.h" \
        "$SIGNAL_DIR/swift/Sources/SignalFfi/signal_ffi.h" \
        "$SIGNAL_DIR/LibSignalClient/signal_ffi.h"; do
        if [[ -f "$candidate" ]]; then
            cp "$candidate" "$HEADER_DIR/signal_ffi.h"
            break
        fi
    done
fi

[[ -s "$HEADER_DIR/signal_ffi.h" ]] || die "Failed to generate or find signal_ffi.h"

TESTING_HEADER="$FFI_DIR/signal_ffi_testing.h"
if [[ ! -f "$TESTING_HEADER" ]]; then
    for candidate in \
        "$SIGNAL_DIR/swift/Sources/SignalFfi/signal_ffi_testing.h" \
        "$SIGNAL_DIR/LibSignalClient/signal_ffi_testing.h"; do
        if [[ -f "$candidate" ]]; then
            TESTING_HEADER="$candidate"
            break
        fi
    done
fi

if [[ -f "$TESTING_HEADER" ]]; then
    cp "$TESTING_HEADER" "$HEADER_DIR/signal_ffi_testing.h"
else
    warn "signal_ffi_testing.h not found — creating empty stub"
    touch "$HEADER_DIR/signal_ffi_testing.h"
fi

ok "Headers ready"

# ── Fat binary (simulator) ──────────────────────────────────────────────────

log "Creating fat binary for simulator (arm64 + x86_64)..."
LIB_SIM_FAT="$WORK_DIR/libsignal_ffi_sim.a"
lipo -create "$LIB_SIM_ARM" "$LIB_SIM_X86" -output "$LIB_SIM_FAT"
ok "Fat binary created"

# ── Assemble xcframework ────────────────────────────────────────────────────

log "Assembling xcframework..."

NEW_XCFW="$WORK_DIR/SignalFfi.xcframework"

# --- Device slice ---
SLICE_DEVICE="$NEW_XCFW/$DEVICE_SLICE"
mkdir -p "$SLICE_DEVICE/Headers" "$SLICE_DEVICE/Modules"
cp "$LIB_DEVICE" "$SLICE_DEVICE/libsignal_ffi.a"
cp "$HEADER_DIR/signal_ffi.h" "$SLICE_DEVICE/Headers/"
cp "$HEADER_DIR/signal_ffi_testing.h" "$SLICE_DEVICE/Headers/"

cat > "$SLICE_DEVICE/Headers/module.modulemap" <<'MMAP'
module SignalFfi {
    header "signal_ffi.h"
    header "signal_ffi_testing.h"
    export *
}
MMAP

cat > "$SLICE_DEVICE/Modules/module.modulemap" <<'MMAP'
module SignalFfi {
    header "../Headers/signal_ffi.h"
    header "../Headers/signal_ffi_testing.h"
    export *
}
MMAP

# --- Simulator slice ---
SLICE_SIM="$NEW_XCFW/$SIM_SLICE"
mkdir -p "$SLICE_SIM/Headers" "$SLICE_SIM/Modules"
cp "$LIB_SIM_FAT" "$SLICE_SIM/libsignal_ffi.a"
cp "$HEADER_DIR/signal_ffi.h" "$SLICE_SIM/Headers/"
cp "$HEADER_DIR/signal_ffi_testing.h" "$SLICE_SIM/Headers/"

cat > "$SLICE_SIM/Headers/module.modulemap" <<'MMAP'
module SignalFfi {
    header "signal_ffi.h"
    header "signal_ffi_testing.h"
    export *
}
MMAP

cat > "$SLICE_SIM/Modules/module.modulemap" <<'MMAP'
module SignalFfi {
    header "../Headers/signal_ffi.h"
    header "../Headers/signal_ffi_testing.h"
    export *
}
MMAP

# --- Info.plist ---
cat > "$NEW_XCFW/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>libsignal_ffi.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
		<dict>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64_x86_64-simulator</string>
			<key>LibraryPath</key>
			<string>libsignal_ffi.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
			<key>SupportedPlatformVariant</key>
			<string>simulator</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST

ok "xcframework assembled"

# ── Update Swift sources ────────────────────────────────────────────────────

log "Locating Swift sources..."

NEW_SWIFT_SRC=""
for candidate in \
    "$SIGNAL_DIR/swift/Sources/LibSignalClient" \
    "$SIGNAL_DIR/Sources/LibSignalClient" \
    "$SIGNAL_DIR/LibSignalClient/Sources"; do
    if [[ -d "$candidate" ]] && ls "$candidate"/*.swift >/dev/null 2>&1; then
        NEW_SWIFT_SRC="$candidate"
        break
    fi
done

[[ -n "$NEW_SWIFT_SRC" ]] || die "Could not find Swift sources in cloned repo"

log "Updating Swift sources..."
rm -rf "$REPO_ROOT/Sources/LibSignalClient"
mkdir -p "$REPO_ROOT/Sources/LibSignalClient"
find "$NEW_SWIFT_SRC" -name '*.swift' -not -path '*/Tests/*' -exec cp {} "$REPO_ROOT/Sources/LibSignalClient/" \;

NEW_SWIFT_COUNT=$(find "$REPO_ROOT/Sources/LibSignalClient" -name '*.swift' | wc -l | tr -d ' ')
ok "Swift sources updated ($NEW_SWIFT_COUNT files)"

# ── Replace xcframework ─────────────────────────────────────────────────────

log "Replacing xcframework..."
rm -rf "$REPO_ROOT/SignalFfi.xcframework"
cp -a "$NEW_XCFW" "$REPO_ROOT/SignalFfi.xcframework"

DEVICE_SIZE=$(du -sh "$REPO_ROOT/SignalFfi.xcframework/$DEVICE_SLICE/libsignal_ffi.a" | cut -f1)
SIM_SIZE=$(du -sh "$REPO_ROOT/SignalFfi.xcframework/$SIM_SLICE/libsignal_ffi.a" | cut -f1)

ok "xcframework replaced (device: $DEVICE_SIZE, sim: $SIM_SIZE)"

# ── Commit, tag & push ─────────────────────────────────────────────────────

log "Committing changes..."

cd "$REPO_ROOT"
git add -A
git commit -m "release: $TAG — update xcframework and Swift sources"

log "Creating tag $TAG..."
git tag "$TAG"

log "Pushing to origin..."
git push origin main --tags

ok "Pushed $TAG"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}═══ LibSignal Release Summary ═══${NC}\n"
echo "  Tag:          $TAG"
echo "  Semver:       $SEMVER"
echo "  Device .a:    $DEVICE_SIZE"
echo "  Simulator .a: $SIM_SIZE"
echo "  Swift files:  $NEW_SWIFT_COUNT"
echo ""
ok "Done! Update consuming projects to use version $SEMVER"
