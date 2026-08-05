#!/usr/bin/env python3
"""Generate the Sparkle appcast for a release.

Usage: make_appcast.py <zip> <version> <download-url> <output.xml>

The EdDSA private key comes from $SPARKLE_ED_PRIVATE_KEY (a PEM). Sparkle signs the raw bytes of
the archive with ed25519 and compares against SUPublicEDKey in the app's Info.plist, so a build
signed with any other key simply won't install — which is what keeps upstream's official releases
from landing on top of this one.
"""
import base64
import os
import shutil
import subprocess
import sys
import tempfile
from email.utils import formatdate
from pathlib import Path
from xml.sax.saxutils import escape


def openssl():
    """LibreSSL ships as /usr/bin/openssl and can't do `pkeyutl -rawin`, so find a real OpenSSL."""
    for candidate in ("/opt/homebrew/opt/openssl@3/bin/openssl",
                      "/usr/local/opt/openssl@3/bin/openssl",
                      shutil.which("openssl3") or "",
                      shutil.which("openssl") or ""):
        if candidate and Path(candidate).exists():
            version = subprocess.run([candidate, "version"], capture_output=True, text=True).stdout
            if version.startswith("OpenSSL 3") or version.startswith("OpenSSL 4"):
                return candidate
    raise SystemExit("ERROR: need OpenSSL 3+ for ed25519 signing (LibreSSL can't do -rawin)")


def sign(archive, key_pem):
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as f:
        f.write(key_pem)
        key_path = f.name
    try:
        sig = subprocess.run(
            [openssl(), "pkeyutl", "-sign", "-inkey", key_path, "-rawin", "-in", str(archive)],
            capture_output=True, check=True).stdout
    finally:
        os.unlink(key_path)
    if len(sig) != 64:
        raise SystemExit(f"ERROR: expected a 64-byte ed25519 signature, got {len(sig)}")
    return base64.b64encode(sig).decode()


def main():
    archive, version, url, out = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
    key_pem = os.environ.get("SPARKLE_ED_PRIVATE_KEY", "")
    if not key_pem:
        raise SystemExit("ERROR: SPARKLE_ED_PRIVATE_KEY is not set")

    signature = sign(archive, key_pem)
    out.write_text(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>AltTab (unlocked)</title>
    <link>{escape(url.rsplit('/download/', 1)[0])}</link>
    <description>Builds of alt-tab-macos with the Pro gating removed.</description>
    <language>en</language>
    <item>
      <title>{escape(version)}</title>
      <pubDate>{formatdate(localtime=False, usegmt=True)}</pubDate>
      <sparkle:version>{escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/filipef101/alt-tab-macos-free/releases/tag/v{escape(version)}-unlocked</sparkle:releaseNotesLink>
      <enclosure url="{escape(url)}"
                 sparkle:version="{escape(version)}"
                 sparkle:shortVersionString="{escape(version)}"
                 length="{archive.stat().st_size}"
                 type="application/octet-stream"
                 sparkle:edSignature="{escape(signature)}" />
    </item>
  </channel>
</rss>
""")
    print(f"appcast for {version}, edSignature {signature[:16]}…")


if __name__ == "__main__":
    main()
