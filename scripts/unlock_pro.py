#!/usr/bin/env python3
"""Re-appliable unlock patch for a pristine alt-tab-macos checkout.

Anchors on Swift declarations rather than line context, so it survives most upstream churn.
A missing required anchor is a hard failure: better a red build than a silently locked one.

Usage: unlock_pro.py <path-to-alt-tab-macos-checkout>
"""
import re
import sys
from pathlib import Path

applied, skipped = [], []


def replace_body(source, signature, new_body, label, required=True):
    """Replace the brace-delimited body that follows `signature` (matched literally)."""
    start = source.find(signature)
    if start == -1:
        return record(source, label, required, f"signature not found: {signature!r}")
    open_brace = source.index("{", start + len(signature) - 1)
    depth, i = 0, open_brace
    while i < len(source):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    else:
        raise SystemExit(f"unbalanced braces after {signature!r}")
    applied.append(label)
    return source[:open_brace].rstrip() + new_body + source[i + 1:]


def replace_regex(source, pattern, replacement, label, required=True):
    patched, count = re.subn(pattern, replacement, source, count=1)
    if count == 0:
        return record(source, label, required, f"no match for {pattern!r}")
    applied.append(label)
    return patched


def record(source, label, required, reason):
    if required:
        raise SystemExit(f"ERROR: unlock patch anchor drifted — {label}: {reason}")
    skipped.append(f"{label} ({reason})")
    return source


def patch_license_manager(root):
    path = root / "src/pro/license/LicenseManager.swift"
    s = path.read_text()
    # The app boots straight into the licensed state: no trial clock, and `ProTransitionScheduler`
    # arms none of the Day 1 → Day 35 upgrade prompts because it bails out on `.pro`.
    s = replace_regex(s, r"(private\(set\) var state: LicenseState = )\.\w+",
                      r"\1.pro", "state defaults to .pro")
    s = replace_body(s, "var isProAvailable: Bool", " { true }", "isProAvailable")
    s = replace_body(s, "var isProLocked: Bool", " { false }", "isProLocked")
    s = replace_body(s, "func computeState() -> LicenseState", " { .pro }", "computeState")
    # Belt and braces: nothing can put the app back into a trial/expired state.
    s = replace_body(s, "func computeTrialState() -> LicenseState", " { .pro }",
                     "computeTrialState", required=False)
    # No licence to check, so never call the licence API.
    s = replace_body(s, "func revalidateWithServer()", " { }", "revalidateWithServer", required=False)
    s = replace_body(s, "func scheduleAsyncRevalidationIfNeeded()", " { }",
                     "scheduleAsyncRevalidationIfNeeded", required=False)
    path.write_text(s)


# Our appcast and the public half of the EdDSA key CI signs it with. Pointing Sparkle here does
# double duty: updates keep working, and the app can no longer fetch upstream's feed and replace
# itself with the official locked build. Both values are public by design.
APPCAST_URL = "https://raw.githubusercontent.com/filipef101/alt-tab-macos-free/main/appcast.xml"
SPARKLE_PUBLIC_KEY = "ZOx0zSag7m9xuMlglaT7NPnwTcOcVLdDdYsC52UxkfQ="


def patch_sparkle(root):
    path = root / "src/vendors/SparkleDelegate.swift"
    s = replace_body(path.read_text(), "func feedURLString(for updater: SPUUpdater) -> String?",
                     f' {{\n        return "{APPCAST_URL}"\n    }}', "Sparkle feed URL")
    path.write_text(s)
    # Sparkle refuses any update whose EdDSA signature doesn't verify against this key, so
    # swapping it is what stops upstream-signed builds from installing over this one.
    plist = root / "Info.plist"
    s = replace_regex(plist.read_text(),
                      r"(<key>SUPublicEDKey</key>\s*<string>)[^<]*(</string>)",
                      lambda m: m.group(1) + SPARKLE_PUBLIC_KEY + m.group(2), "SUPublicEDKey")
    plist.write_text(s)


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    if not (root / "src/pro/license/LicenseManager.swift").exists():
        raise SystemExit(f"ERROR: {root} does not look like an alt-tab-macos checkout")
    patch_license_manager(root)
    patch_sparkle(root)
    print(f"unlocked {root}")
    for label in applied:
        print(f"  applied: {label}")
    for label in skipped:
        print(f"  skipped: {label}")


if __name__ == "__main__":
    main()
