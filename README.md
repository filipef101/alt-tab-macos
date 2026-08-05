# alt-tab-macos, unlocked

[lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos) with the Pro gating removed,
rebuilt from upstream automatically. GPL-3.0, in both directions.

[**Download the latest build →**](https://github.com/filipef101/alt-tab-macos/releases/latest)

## Install

Requires macOS 12 or newer. Universal (Apple Silicon and Intel).

1. Download `AltTab-<version>-unlocked.zip` from
   [releases](https://github.com/filipef101/alt-tab-macos/releases/latest) and unzip it.
2. If you already run the official AltTab, quit it and keep a copy first — this replaces it,
   because it uses the same bundle ID:
   ```bash
   osascript -e 'quit app "AltTab"'
   ditto /Applications/AltTab.app ~/Desktop/AltTab-official-backup.app
   ```
3. Install it, clear the quarantine flag, and clear the old permission grant:
   ```bash
   rm -rf /Applications/AltTab.app
   ditto ~/Downloads/AltTab.app /Applications/AltTab.app
   xattr -dr com.apple.quarantine /Applications/AltTab.app
   tccutil reset Accessibility com.lwouis.alt-tab-macos
   tccutil reset ScreenCapture com.lwouis.alt-tab-macos
   ```
4. Launch it, then grant **Accessibility** in System Settings → Privacy & Security (required —
   AltTab can't switch windows without it), and **Screen Recording** if you want window
   thumbnails rather than icons.

Both middle steps are load-bearing, and each fails in its own confusing way if you skip it:

- **Without `xattr`**, macOS refuses to open it: *"Apple could not verify AltTab is free of
  malware"*. That's Gatekeeper, and it's expected — these builds are ad-hoc signed, with no
  Apple Developer ID and no notarization. The command strips the download flag that triggers the
  check. You can also allow it once via System Settings → Privacy & Security → **Open Anyway**.
- **Without `tccutil`**, Accessibility silently doesn't work. macOS ties a permission grant to a
  bundle ID *and* its code signature, and the existing grant belongs to upstream's Developer ID
  signature. The toggle can look enabled while the app stays blind. Resetting deletes the stale
  entry so your new grant actually binds.

Your existing AltTab preferences carry over untouched — same bundle ID, same defaults domain.

To go back to the official build at any time: delete `/Applications/AltTab.app`, restore your
backup (or reinstall from [alt-tab.app](https://alt-tab.app)), and run the same two `tccutil`
commands again.

## Why this exists

AltTab shipped free under the GPL for years. In v11.0.0 (2026-05-21) it became freemium: a
14-day trial, after which some features you already had stop working.

The interesting part isn't the price, it's the machinery. From `src/pro/scheduling/` upstream:

```
Day1WelcomeLetterWindow   Day4TourPopover        Day12HeadsUpPopover
Day15ProactiveWindow      Day15HardGatePopover   Day15FullUpgradeWindow
Day21ReminderPopover      Day35FinalWindow
```

Eight scheduled prompts across 35 days, plus a "free pass ladder" that lets a locked feature
work once so the upgrade window has a pretext to appear in context. Preferences you set during
the trial aren't just ignored when it ends: they're snapshotted, silently downgraded, and held
for ransom until you pay (`ProFeature.degradable`).

Charging for software is fine. Building a five-week behavioural funnel into a keyboard shortcut
utility is a choice, and the GPL exists precisely so that choice doesn't have to be yours too.

Section 0 of the GPL-3.0 calls this a "covered work" and gives you the right to run, modify, and
redistribute a modified version. Upstream ships the entire licensing system as source in
`src/pro/`. This repository is that source, with the gates set to open, and its own source is
published right back under the same licence.

If you use AltTab daily, [pay upstream](https://alt-tab.app) — the app is genuinely good and
years of maintenance went into it. This fork is for people who'd rather not be nagged eight
times into it.

## What the patch actually changes

`scripts/unlock_pro.py` rewrites `LicenseManager` so the app is permanently in the `.pro` state:

- `isProAvailable` always true, `isProLocked` always false — App Icons and Titles styles,
  auto-size, search in the switcher, and the extra shortcuts all work
- `computeState()` returns `.pro`, so no trial clock ever starts and `ProTransitionScheduler`
  arms none of the eight prompts above
- the licence API is never contacted, on any code path

It also points Sparkle's feed at nothing and turns off automatic update checks. Without that,
the app cheerfully downloads upstream's official signed release and overwrites itself, undoing
all of the above while you're not looking.

Untouched: AppCenter crash reporting is compiled in but inert, since the app secret is only
injected by upstream's release CI.

## How it stays current

| branch | contents |
|---|---|
| `main` | tooling only: the patch script, the build script, the workflows |
| `unlocked` | generated: pristine upstream tag + patch, force-pushed on every sync |

[`sync.yml`](.github/workflows/sync.yml) runs daily. It compares upstream's latest release to
ours on a cheap runner and stops there when nothing is new; only a genuine new version reaches
the macOS build job. Nothing is ever merged or rebased — each run clones the pristine upstream
tag and re-applies the patch — so upstream changes cannot produce a conflict, by construction.

The patch anchors on Swift declarations rather than line context. If upstream renames one of the
four required anchors, `unlock_pro.py` exits non-zero and the build goes red, rather than quietly
shipping something still locked.

## Updating

There is no auto-update — Sparkle is deliberately disabled, so this build can't quietly replace
itself with the official locked one. Grab the newer zip from
[releases](https://github.com/filipef101/alt-tab-macos/releases/latest) and repeat steps 3 and 4
of the install. Yes, including `tccutil`: ad-hoc signing means macOS identifies the app by code
hash, so **every** build is a new identity and permission grants never survive an update.

Signing with a stable self-signed certificate would fix that permanently, at the cost of keeping
a `.p12` in repository secrets. Open an issue if you'd rather have it that way.

## Known caveats

- **Not notarized.** Every download needs the quarantine flag cleared, and you're trusting a
  binary built by this repo's CI. The build is fully reproducible from the `unlocked` branch if
  you'd rather compile it yourself, which is the honest recommendation for anything you'll
  give Accessibility permission to.
- **Permissions reset on every update**, as above.
- **Same bundle ID as upstream**, so it replaces the official app rather than living beside it.
  Don't leave a second AltTab bundle lying around in `/Applications` — macOS picks whichever one
  it feels like when something launches by bundle ID.
- **Cosmetic leftovers.** The gradient "PRO" badges still appear next to features in Settings,
  and the Upgrade tab still exists, now reporting "Pro activated". Only the gating is patched,
  not the marketing. The menubar's "Get Pro" item does disappear.
- **Deployment target raised to macOS 12**, from upstream's 10.13. Current Xcode refuses to build
  the older target, so pre-Monterey Macs are out.
- **Crash reporting is inert.** AppCenter is compiled in but never starts, since the app secret
  is only injected by upstream's release CI. Nothing is sent anywhere.
- **The daily sync can pause itself.** GitHub disables scheduled workflows after 60 days without
  repository activity, and bot pushes may not count. If releases go quiet while upstream ships,
  that's why — any commit to `main` wakes it up.

## Building it yourself

```bash
git clone --branch v11.4.3 https://github.com/lwouis/alt-tab-macos.git src
python3 scripts/unlock_pro.py src
bash scripts/build.sh src 11.4.3
```

The version argument is load-bearing: upstream's Info.plist takes `CURRENT_PROJECT_VERSION` from
their release CI, and without it `App.version`'s force-cast crashes the app on launch.
