# alt-tab-macos, unlocked

[lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos) with the Pro gating removed,
rebuilt from upstream automatically. GPL-3.0, in both directions.

[**Download the latest build →**](https://github.com/filipef101/alt-tab-macos/releases/latest)

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

## Permissions, and the one annoying part

Builds are **ad-hoc signed** — no Apple Developer ID, no notarization. macOS therefore identifies
the app by code hash, and every new build is a new identity, so Accessibility and Screen Recording
grants don't survive an update:

```bash
tccutil reset Accessibility com.lwouis.alt-tab-macos
tccutil reset ScreenCapture com.lwouis.alt-tab-macos
```

Then relaunch and grant again. Signing with a stable self-signed certificate would fix this
permanently, at the cost of keeping a `.p12` in repository secrets.

Same bundle ID as upstream, so it takes over an existing install and keeps your preferences.

## Building it yourself

```bash
git clone --branch v11.4.3 https://github.com/lwouis/alt-tab-macos.git src
python3 scripts/unlock_pro.py src
bash scripts/build.sh src 11.4.3
```

The version argument is load-bearing: upstream's Info.plist takes `CURRENT_PROJECT_VERSION` from
their release CI, and without it `App.version`'s force-cast crashes the app on launch.
