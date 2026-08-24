# VoiceInk — local build, paywall neutered

Fork of [`Beingpax/VoiceInk`](https://github.com/Beingpax/VoiceInk) (`upstream`) at
[`maseko-lucky-9/VoiceInk`](https://github.com/maseko-lucky-9/VoiceInk) (`origin`).

**Branch `local/no-paywall` is the one that matters.** It is `upstream/main` plus a single
10-line commit. Everything else here is upstream, unmodified.

## Set up on a new Mac

```bash
git clone -b local/no-paywall git@github.com:maseko-lucky-9/VoiceInk.git
cd VoiceInk
git remote add upstream git@github.com:Beingpax/VoiceInk.git
./scripts/local-install.sh
```

That is the whole procedure. The script is idempotent — re-run it to upgrade. It backs up
app data, builds, installs to `~/Applications/VoiceInk.app`, resets the privacy grants, and
prints a verification block. What it cannot do is granting TCC permissions and recording a
test dictation; it tells you those at the end.

First run is slow: it resolves 28 SPM packages, builds `whisper.cpp`, and may download the
Metal Toolchain (~700 MB). Network is a hard prerequisite. Later runs reuse all of it.

`main` on the fork is stale — 300+ commits behind upstream, carrying an older and much
larger strip that no longer applies. Do not build from it.

## What the strip actually is

One file, five keys: `SUFeedURL`, `SUPublicEDKey`, `SUEnableInstallerLauncherService`,
`SUEnableAutomaticChecks` and `SUScheduledCheckInterval`, deleted from `VoiceInk/Info.plist`.
Without a feed URL, Sparkle can never replace this build with the official paywalled release.
Sparkle 2.9.2 does not crash without one (`startUpdater:` passes `requireFeedURL:NO`);
"Check for Updates" just shows a config-error dialog, which is cosmetic.

**There is no license patch, and there must not be one.** Since upstream commit `3763440`
("Improve local build handling") the paywall is gated off by upstream itself under
`#if LOCAL_BUILD`, which `LocalBuild.xcconfig` sets:

- `LicenseViewModel.init` skips `loadPersistentState()` and sets `licenseState = .licensed`;
  `resolvedState()` returns `.licensed`; `hasVerifiedLicense` is `true`.
- `OnboardingCoordinator` redirects the `.license` stage to `.trust`, so there is no license
  step in onboarding at all.
- `KeychainService` has its `UserDefaults` fallback back, so cloud-provider API keys survive
  a relaunch on an ad-hoc-signed build.

The earlier ~18-file deletion is what got silently reverted the last time this fork synced
from upstream. A small diff rebases cleanly forever; a large one does not. Keep it small.

**Delete Sparkle keys by name, never by line range** — `LSUIElement` sits between
`SUPublicEDKey` and `SUEnableAutomaticChecks` and must survive. The script checks for it.

## Build gotchas

`make local` does not work on v2.x. Two reasons, both from the MLX dependency:

1. It dies at `Validate plug-in "CudaBuild" in package "mlx-swift"` — SwiftPM plugin trust
   cannot be prompted for in a non-interactive shell. Needs
   `-skipPackagePluginValidation -skipMacroValidation`.
2. It opens with `rm -rf .local-build`, which destroys `SourcePackages/checkouts` and forces
   a cold re-resolve of all 28 packages on every invocation.

`scripts/local-install.sh` calls `xcodebuild` directly with the right flags. Do not "fix"
this by editing the `Makefile` — that is an upstream file and editing it reintroduces the
rebase conflicts the small diff exists to avoid.

Xcode 26 ships the Metal compiler separately. Without it the build fails with
`cannot execute tool 'metal' due to missing Metal Toolchain`. Fix:
`xcodebuild -downloadComponent MetalToolchain` (no password required). The script does this
automatically when `xcrun metal --version` fails.

Do not run `make clean` to retry a failed build — it is `rm -rf ~/VoiceInk-Dependencies`,
which throws away the whisper.cpp checkout too.

## Data safety

History lives outside the bundle, keyed by the bundle id `com.prakashjoshipax.VoiceInk`,
which never changes. Reinstalling to the same path with the same bundle id is what carries it
over. A v1.79 → v2.11 upgrade was verified lossless: 925 transcriptions, 896 session metrics
and 927 recordings all survived, and `powerModeName`/`powerModeEmoji` → `modeName`/`modeEmoji`
executed as a true `@Attribute(originalName:)` rename.

Rules worth not relearning:

- There are three stores and all three carry the *same* schema, but each populates only its
  own table: transcriptions in `default.store`, session metrics in `stats.store`, dictionary in
  `dictionary.store`. `select count(*) from ZSESSIONMETRIC` against `default.store` returns a
  perfectly truthful-looking `0`. Check the right store before concluding data was lost.
- Quit from the menu bar, never SIGKILL. Recent history lives only in the `-wal` sidecars
  until a clean quit checkpoints it. Copy `.store`, `-wal` and `-shm` as a set.
- `ditto` has **no** `--exclude` flag. Use `cp -c` / `cp -Rc` (APFS clones, instant and free).
- Restore preferences with `defaults import`, never `cp` — `cfprefsd` owns that file and will
  overwrite a hand-copied one from its in-memory cache.
- Run `lsregister -f` on the new bundle **before** `tccutil reset`, or tccutil fails `-10814`
  because LaunchServices still maps the bundle id to the deleted path.
- `OnboardingV2Migration.prepareIfNeeded` unconditionally deletes `hasCompletedOnboarding`, so
  every upgrade re-runs onboarding and `clearModeStorage()` wipes `modeConfigurationsV2`,
  `powerModeConfigurationsV2`, `activeConfigurationId` and per-mode shortcuts. Export the prefs
  plist first — the script does.
- `TranscriptionAutoCleanupService` deletes every recording not referenced by a `Transcription`
  row. It is inert only because `IsTranscriptionCleanupEnabled` defaults to false — a bool in
  the plist this upgrade rewrites. That is why `Recordings/` gets cloned, not trusted.

Full uninstall footprint: `~/Library/Application Support/com.prakashjoshipax.VoiceInk/`,
`~/Library/Application Support/{VoiceInk,FluidAudio}/`,
`~/Library/Preferences/com.prakashjoshipax.VoiceInk.plist`, and the TCC grants.

## Picking up new upstream releases

```bash
git fetch upstream --prune
git rebase upstream/main       # a 10-line replay, not a merge
./scripts/local-install.sh
```

If the rebase conflicts on `Info.plist`, take upstream's version and re-delete the five `SU*`
keys by name. Before assuming a license patch is needed again, check that the `#if LOCAL_BUILD`
gates listed above still exist — if upstream ever removes them, that is a real change in scope
and worth stopping to discuss rather than silently reviving the old 18-file strip.

## Verification — required, not optional

Never call a rebuild done on the strength of the code alone. The script prints the first four;
you have to do the last two by hand:

1. `plutil -p ~/Applications/VoiceInk.app/Contents/Info.plist | grep -c '"SU'` → `0`
2. `LSUIElement` still present
3. `codesign --verify --deep --strict` passes, signature is ad-hoc
4. Transcription count is unchanged from before the upgrade
5. Old transcriptions render with their text in the History pane
6. **A recorded dictation transcribes to the actual speech, with no
   `Your trial has ended. Upgrade to VoiceInk Pro at tryvoiceink.com/buy` appended.** That
   string is injected in `TranscriptionDelivery.swift`, so a clean transcript is the proof.

## Rollback

Restore the stores and `Recordings/` from `~/VoiceInk-backup-<date>/`, then
`defaults import com.prakashjoshipax.VoiceInk ~/VoiceInk-backup-<date>/prefs.plist`,
and reinstall from the previous commit.

## Limits of a local build

No iCloud dictionary sync, and no auto-update — that is the point. Pull and re-run the script
to update. Ad-hoc signing mints a new cdhash on every build, so TCC grants reset every time;
the script resets them explicitly so macOS re-prompts instead of silently denying.
