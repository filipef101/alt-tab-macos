# alt-tab-macos-free

[lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos) with the Pro gating removed,
rebuilt from upstream automatically. GPL-3.0, in both directions.

## Install

Requires macOS 12 or newer. Universal binary, Apple Silicon and Intel.

```bash
curl -fsSL https://raw.githubusercontent.com/filipef101/alt-tab-macos-free/main/scripts/install.sh | bash
```

It downloads the [latest release](https://github.com/filipef101/alt-tab-macos-free/releases/latest),
verifies the signature, backs up whatever AltTab you already have into
`~/Library/Application Support/AltTab-backups/`, installs, and launches.

No `sudo`, and it doesn't want your password: `/Applications` is writable by admin users and
`tccutil` acts on your own TCC database. If a `curl | bash` one-liner ever asks for a password,
that's your cue to read it first — [this one is 90 lines](scripts/install.sh).

Then grant **Accessibility** in System Settings → Privacy & Security. AltTab cannot switch
windows without it, so this step isn't optional; the installer opens the right pane for you. Add
**Screen Recording** too if you want window thumbnails rather than icons.

<details>
<summary>Manual install, if you'd rather not pipe a script into bash</summary>

```bash
# download and unzip AltTab-<version>-unlocked.zip from the releases page, then:
osascript -e 'quit app "AltTab"'
ditto /Applications/AltTab.app ~/Desktop/AltTab-backup.app   # if you have one already
rm -rf /Applications/AltTab.app
ditto ~/Downloads/AltTab.app /Applications/AltTab.app
xattr -dr com.apple.quarantine /Applications/AltTab.app
tccutil reset Accessibility com.lwouis.alt-tab-macos
tccutil reset ScreenCapture com.lwouis.alt-tab-macos
open /Applications/AltTab.app
```

The `xattr` line matters when you download through a browser. Browsers tag downloads with
`com.apple.quarantine`, and these builds aren't notarized, so Gatekeeper blocks the first launch
with *"Apple could not verify AltTab is free of malware."* Removing the tag avoids that.
Control-clicking the app no longer helps — macOS 15 removed that bypass — so the only GUI route
is System Settings → Privacy & Security → **Open Anyway** after a blocked launch. The installer
script sidesteps all of this by downloading with `curl`, which never sets the flag.

The `tccutil` lines clear the permission entry belonging to your previous AltTab. macOS binds a
grant to the bundle ID *and* the code signature, so a grant made for upstream's Developer ID
build won't transfer: Accessibility looks enabled while the app stays blind.

</details>

Your existing AltTab preferences carry over untouched — same bundle ID, same defaults domain.

## Why this exists

AltTab shipped free under the GPL for years. In v11.0.0 (2026-05-21) it became freemium: a
14-day trial, after which some features you already had stop working.

The interesting part isn't the price, it's the machinery. From `src/pro/scheduling/` upstream:

```
Day1WelcomeLetterWindow   Day4TourPopover        Day12HeadsUpPopover
Day15ProactiveWindow      Day15HardGatePopover   Day15FullUpgradeWindow
Day21ReminderPopover      Day35FinalWindow
```

Eight scheduled prompts across 35 days, plus a "free pass ladder" that lets a locked feature work
once so the upgrade window has a pretext to appear in context. Preferences you set during the
trial aren't merely ignored when it ends: they're snapshotted, silently downgraded, and held
until you pay (`ProFeature.degradable`).

There's also no way back. Upstream's repository currently carries **343 git tags but only 10
GitHub releases**, and all ten are v11.x — the Pro era. Every release predating the paywall has
been removed from the releases page, so the last fully free build, v10.12.0, is no longer
downloadable as a binary from the project that published it for years. The tags survive, so you
can still compile it, which is the only reason that isn't a GPL problem. Draw your own conclusion
about why; the effect is that "just stay on the old version" stopped being an option for anyone
who doesn't own Xcode.

Charging for software is fine. Building a five-week behavioural funnel into a keyboard shortcut
utility is a choice, and deleting the exits is another, and the GPL exists precisely so those
choices don't have to be yours too.

Section 0 of the GPL-3.0 calls this a "covered work" and gives you the right to run, modify, and
redistribute a modified version. Upstream ships the entire licensing system as source in
`src/pro/`. This repository is that source with the gates set to open, published right back under
the same licence.

If you use AltTab daily, [pay upstream](https://alt-tab.app) — the app is genuinely good and
years of maintenance went into it. This fork is for people who'd rather not be nagged eight times
into it.

## What the patch changes

[`scripts/unlock_pro.py`](scripts/unlock_pro.py) rewrites `LicenseManager` so the app is
permanently in the `.pro` state:

- `isProAvailable` always true, `isProLocked` always false — App Icons and Titles styles,
  auto-size, search in the switcher, and the extra shortcuts all work
- `computeState()` returns `.pro`, so no trial clock ever starts and `ProTransitionScheduler`
  arms none of the eight prompts above
- the licence API is never contacted, on any code path

It also repoints Sparkle at [this repo's appcast](appcast.xml) and swaps `SUPublicEDKey` in
`Info.plist` for our own EdDSA public key. Left alone, the app would fetch upstream's feed and
replace itself with the official locked build; with the key swapped it will refuse to install
anything not signed by this repo's release key.

Untouched: AppCenter crash reporting is compiled in but never starts, because the app secret is
only injected by upstream's release CI. Nothing is sent anywhere.

## Updating

In-app updates work: AltTab checks this repo's appcast on its usual schedule, and "Check for
updates…" in the menubar does what you'd expect. Re-running the install command is equally fine.

Permissions survive updates, which is the whole reason releases are signed rather than ad-hoc:

```bash
codesign -d -r- /Applications/AltTab.app
# designated => identifier "com.lwouis.alt-tab-macos" and certificate root = H"893558f1deac936ccceaa806fb1e20d0772e09f8"
```

macOS remembers a permission grant against that requirement. Ad-hoc signing produces
`cdhash H"..."` instead, which changes on every single build — that's why self-built apps
normally lose Accessibility on every update. A certificate pins the requirement to the cert
rather than the bytes, so grants survive.

The fingerprint above is worth checking after any update: it's the only thing distinguishing a
build from this repo from any other app claiming the same bundle ID. The private key lives in
GitHub Actions secrets, never in this repository, and the installer only resets permissions when
the signing identity actually changed.

## How it stays current

| branch | contents |
|---|---|
| `main` | tooling only: the patch script, the build script, the install script, the workflows |
| `unlocked` | generated: pristine upstream tag + patch, force-pushed on every sync |

[`sync.yml`](.github/workflows/sync.yml) runs daily at 06:30 UTC. It compares upstream's latest
release to ours on a cheap Linux runner and stops there when nothing is new, so only a genuine
new version reaches the macOS build job. Nothing is ever merged or rebased — each run re-clones
the pristine upstream tag and re-applies the patch — so upstream changes cannot produce a
conflict, by construction.

The patch anchors on Swift declarations rather than line context. If upstream renames one of the
four required anchors, `unlock_pro.py` exits non-zero and the build goes red rather than quietly
shipping something still locked.

## Known caveats

- **Not notarized.** You're trusting a binary built by this repo's CI. It's reproducible from the
  `unlocked` branch if you'd rather compile it yourself, which is the honest recommendation for
  anything you're about to hand Accessibility permission to.
- **Self-signed, so Gatekeeper never trusts it.** Irrelevant when you install via the script,
  awkward if you download through a browser (see the manual install above).
- **Same bundle ID as upstream**, so it replaces the official app rather than living beside it.
  Don't leave a second AltTab bundle in `/Applications` — macOS resolves bundle IDs to whichever
  copy it feels like.
- **Cosmetic leftovers.** The gradient "PRO" badges still appear next to features in Settings,
  and the Upgrade tab still exists, now cheerfully reporting "Pro activated". Only the gating is
  patched, not the marketing. The menubar's "Get Pro" item does disappear.
- **macOS 12 minimum**, raised from upstream's 10.13 because current Xcode refuses to build the
  older deployment target.
- **The daily sync can pause itself.** GitHub disables scheduled workflows after 60 days without
  repository activity, and bot pushes may not count. If releases go quiet while upstream ships,
  that's why — any commit to `main` wakes it up.

## Building it yourself

```bash
git clone --branch v11.4.3 https://github.com/lwouis/alt-tab-macos.git src
python3 scripts/unlock_pro.py src
bash scripts/build.sh src 11.4.3
```

Produces an ad-hoc-signed `dist/AltTab-11.4.3-unlocked.zip`. Set `SIGN_IDENTITY` (and
`SIGN_KEYCHAIN` if it isn't in the default search list) to sign with your own certificate
instead.

The version argument is load-bearing: upstream's Info.plist takes `CURRENT_PROJECT_VERSION` from
their release CI, and without it `App.version`'s force-cast crashes the app on launch.
