#!/usr/bin/env bash
#
# Build VoiceInk from this checkout with the paywall neutered, and install it
# to ~/Applications. Safe to re-run: existing transcription history, recordings
# and preferences are backed up first and are preserved across the upgrade.
#
#   ./scripts/local-install.sh
#
# Requires: macOS, Xcode, network (first run resolves 28 SPM packages and
# builds whisper.cpp). See CLAUDE.md for the full story.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="com.prakashjoshipax.VoiceInk"
SUPPORT="$HOME/Library/Application Support/$APP_ID"
DEST="$HOME/Applications/VoiceInk.app"
DERIVED="$REPO/.local-build"
BUILT="$DERIVED/Build/Products/Debug/VoiceInk.app"
BACKUP="${VOICEINK_BACKUP:-$HOME/VoiceInk-backup-$(date +%Y-%m-%d)}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
step "Preflight"
[[ "$(uname -s)" == Darwin ]] || die "macOS only"
command -v xcodebuild >/dev/null || die "Xcode is required"
xcodebuild -version >/dev/null 2>&1 ||
  die "xcodebuild is not usable. Fix with: sudo xcode-select -s /Applications/Xcode.app"

# Xcode 26 ships the Metal compiler as a separate component. MLX (a dependency
# since v2.x) compiles ~10 .metal kernels, so the build hard-fails without it.
if ! xcrun metal --version >/dev/null 2>&1; then
  step "Downloading the Metal Toolchain (~700 MB, one time, no password needed)"
  xcodebuild -downloadComponent MetalToolchain
fi

# ------------------------------------------------- confirm the strip is here --
step "Checking this checkout has the paywall strip"
plutil -lint "$REPO/VoiceInk/Info.plist" >/dev/null || die "VoiceInk/Info.plist is malformed"
su_keys=$(plutil -p "$REPO/VoiceInk/Info.plist" | grep -c '"SU' || true)
[[ "$su_keys" -eq 0 ]] ||
  die "$su_keys Sparkle key(s) still present — you are probably not on the local/no-paywall branch (git switch local/no-paywall)"
grep -q 'LOCAL_BUILD' "$REPO/LocalBuild.xcconfig" || die "LocalBuild.xcconfig lost its LOCAL_BUILD flag"
plutil -p "$REPO/VoiceInk/Info.plist" | grep -q '"LSUIElement"' ||
  die "LSUIElement is gone from Info.plist — it sits between the Sparkle keys and must survive the strip"
echo "ok: 0 Sparkle keys, LOCAL_BUILD set, LSUIElement intact"

# ------------------------------------------------------------------- backup --
step "Backing up app data"
if [[ -d "$SUPPORT" ]]; then
  # Quit gracefully. SwiftData keeps recent history in the -wal sidecars and
  # only checkpoints on a clean quit, so never SIGKILL this.
  if pgrep -qx VoiceInk; then
    osascript -e 'tell application "VoiceInk" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -qx VoiceInk || break; sleep 0.5; done
    pgrep -qx VoiceInk && die "VoiceInk would not quit — quit it from the menu bar and re-run"
  fi
  mkdir -p "$BACKUP"
  # A .store and its -wal/-shm sidecars must be copied as a set.
  # cp -c / -Rc are APFS clones: instant, and they cost no extra disk.
  ( cd "$SUPPORT"
    cp -c ./*.store ./*.store-wal ./*.store-shm "$BACKUP/" 2>/dev/null || true
    if [[ -d Recordings && ! -d "$BACKUP/Recordings" ]]; then cp -Rc Recordings "$BACKUP/Recordings"; fi )
  # cfprefsd owns the plist; export/import it rather than copying the file.
  defaults export "$APP_ID" "$BACKUP/prefs.plist" 2>/dev/null || true
  echo "backup: $BACKUP"
  # WhisperModels/ (~500 MB+) is skipped on purpose — it re-downloads.
else
  echo "no existing data — this is a fresh install"
fi

# -------------------------------------------------------------------- build --
step "Building whisper.xcframework (cached in ~/VoiceInk-Dependencies)"
make -C "$REPO" setup

step "Building VoiceInk"
# Deliberately NOT `make local`:
#   - `make local` opens with `rm -rf .local-build`, throwing away SourcePackages/
#     and forcing a cold re-resolve of all 28 packages every single run;
#   - it omits -skipPackagePluginValidation, so it dies on mlx-swift's "CudaBuild"
#     plugin, whose trust prompt cannot be answered from a non-interactive shell.
xcodebuild -project "$REPO/VoiceInk.xcodeproj" -scheme VoiceInk -configuration Debug \
  -derivedDataPath "$DERIVED" \
  -xcconfig "$REPO/LocalBuild.xcconfig" \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$REPO/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
  build

[[ -d "$BUILT" ]] || die "build reported success but no app at $BUILT"

# ------------------------------------------------------------------ install --
step "Installing to $DEST"
# Same path and same bundle id as before is what carries the history over.
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
xattr -cr "$DEST"
"$LSREGISTER" -f "$DEST"

step "Resetting privacy permissions"
# Ad-hoc signing mints a new cdhash on every build, which invalidates every TCC
# grant. lsregister above must run first or tccutil fails with -10814.
tccutil reset All "$APP_ID" || true
tccutil reset All "$APP_ID.RefineXPC" >/dev/null 2>&1 || true

# ------------------------------------------------------------------- verify --
step "Verification"
info="$DEST/Contents/Info.plist"
printf 'version:      %s\n' "$(plutil -extract CFBundleShortVersionString raw "$info")"
printf 'sparkle keys: %s (want 0)\n' "$(plutil -p "$info" | grep -c '"SU' || true)"
printf 'LSUIElement:  %s (want false)\n' "$(plutil -extract LSUIElement raw "$info" 2>/dev/null || echo MISSING)"
if codesign --verify --deep --strict "$DEST" 2>/dev/null; then
  printf 'signature:    ok (%s)\n' "$(codesign -dv "$DEST" 2>&1 | grep -o 'adhoc' || echo signed)"
else
  printf 'signature:    \033[31mFAILED\033[0m\n'
fi
# All three stores carry the same schema, but each populates only its own table:
# transcriptions live in default.store, session metrics in stats.store. Querying
# ZSESSIONMETRIC in default.store returns a truthful-looking 0.
if command -v sqlite3 >/dev/null; then
  count() { [[ -f "$SUPPORT/$1" ]] && sqlite3 -readonly "$SUPPORT/$1" "select count(*) from $2;" 2>/dev/null || echo 'n/a'; }
  printf 'transcripts:  %s\n' "$(count default.store ZTRANSCRIPTION)"
  printf 'sessions:     %s\n' "$(count stats.store ZSESSIONMETRIC)"
  printf 'recordings:   %s\n' "$(ls -1 "$SUPPORT/Recordings" 2>/dev/null | wc -l | tr -d ' ')"
fi

cat <<'NEXT'

==> Done. Remaining steps need you at the keyboard:

  1. open ~/Applications/VoiceInk.app
  2. Grant Microphone, Accessibility, Input Monitoring, Screen Recording and
     Automation when prompted. If Accessibility or Input Monitoring shows a
     ticked box that still does not work, remove the row with the "-" button and
     re-add it — toggling does not clear the stale cdhash.
  3. Walk through onboarding. It always re-runs on an upgrade, because
     OnboardingV2Migration unconditionally clears the completion flag.
  4. Record one dictation. A clean transcript with no "Your trial has ended"
     text appended is the proof the paywall strip holds end to end.

NEXT
