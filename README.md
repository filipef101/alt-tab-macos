# alt-tab-macos, unlocked

Daily rebuild of [lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos) with the Pro
gating removed. Upstream is GPL-3.0; so is this.

## Branches

| branch | contents |
|---|---|
| `main` | the tooling only: the patch script, the build script, the workflows |
| `unlocked` | generated: pristine upstream tag + the patch applied, force-pushed on every sync |

`unlocked` is regenerated from scratch each run and never merged, so upstream changes can never
produce a conflict. The only way this breaks is if the patch's anchors disappear from upstream's
source, and then `unlock_pro.py` fails loudly rather than shipping a still-locked build.

## What the patch does

`scripts/unlock_pro.py` rewrites `LicenseManager` so the app is permanently in the `.pro` state:

- `isProAvailable` is always true and `isProLocked` always false, so every gated feature
  (App Icons / Titles styles, auto-size, search in the switcher, extra shortcuts) is usable
- `computeState()` returns `.pro`, so no trial clock ever starts and `ProTransitionScheduler`
  arms none of the Day 1 to Day 35 upgrade prompts
- the licence API is never contacted

It also points Sparkle's feed at nothing and turns off automatic update checks, so the build
cannot replace itself with the official (locked) one.

Not touched: AppCenter crash reporting is compiled in but inert, because the app secret is only
injected by upstream's release CI.

## Permissions

Builds are **ad-hoc signed**, so macOS identifies the app by code hash and every new build is a
new identity. After installing an update, Accessibility and Screen Recording grants will not
carry over:

```bash
tccutil reset Accessibility com.lwouis.alt-tab-macos
tccutil reset ScreenCapture com.lwouis.alt-tab-macos
```

then launch the app and grant again. Signing with a stable self-signed certificate would avoid
this; it would mean keeping a `.p12` in repository secrets.

## Building locally

```bash
git clone --branch v11.4.3 https://github.com/lwouis/alt-tab-macos.git src
python3 scripts/unlock_pro.py src
bash scripts/build.sh src 11.4.3
```

The version argument matters: upstream's Info.plist takes `CURRENT_PROJECT_VERSION` from the
release CI, and without it `App.version`'s force-cast crashes on launch.
