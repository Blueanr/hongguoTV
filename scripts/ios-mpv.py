# SPDX-License-Identifier: GPL-3.0-only
"""Fetch the same pinned libmpv distribution as PiliPlus; generate XcodeGen deps."""
import hashlib
import pathlib
import tarfile
import urllib.request
import plistlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = "v0.39.0"
SHA256 = "d7a996b2afad622e9bafb53f1f988235938af33fe162840c9c74a1894bde4bfc"
URL = f"https://github.com/gungun974/melodink-libmpv-darwin-build/releases/download/{VERSION}/libmpv-xcframeworks_{VERSION}_ios-universal-video-default.tar.gz"
DEST = ROOT / "ios-native" / "Vendor"
ARCHIVE = DEST / "mpv.tar.gz"

DEST.mkdir(parents=True, exist_ok=True)
if not ARCHIVE.exists() or hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() != SHA256:
    urllib.request.urlretrieve(URL, ARCHIVE)
assert hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() == SHA256, "libmpv checksum mismatch"
with tarfile.open(ARCHIVE) as archive:
    archive.extractall(DEST, filter="data")
directory = DEST / f"libmpv-xcframeworks_{VERSION}_ios-universal-video-default"
frameworks = sorted(directory.glob("*.xcframework"))
assert len(frameworks) == 19
lines = ["targets:", "  HongguoPad:", "    dependencies:"]
for framework in frameworks:
    info = plistlib.loads((framework / "Info.plist").read_bytes())
    assert any(x.get("SupportedPlatformVariant") == "simulator" for x in info["AvailableLibraries"])
    lines.extend([f"      - framework: {framework.relative_to(ROOT / 'ios-native').as_posix()}", "        embed: true", "        codeSign: true"])
(ROOT / "ios-native" / "mpv-dependencies.yml").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"Verified libmpv {VERSION}: {len(frameworks)} device/simulator frameworks")
