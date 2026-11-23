"""Offline APK identity and DEX string evidence; no app execution or decompilation."""
import hashlib
import json
import struct
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APK = ROOT / "hongguotv-kotlin-0.16.13-android6-arm64-v8a.apk"
OUTPUT = ROOT / "outputs/ios/android-reference.json"
EXPECTED_SHA256 = "9d95782a2a34f913c887f68413472f0aabe85d0c86c49e18d19a3ce0ca42f544"
MARKERS = ("/novel/player/multi_video_model/player/v1", "/reading/bookapi/video_tab/multi_video_model/v1/", "v04.10.03", "7.4.3.32", "MobilePlayback", "disable_video_relate_book")


def main():
    digest = hashlib.sha256(APK.read_bytes()).hexdigest()
    findings = []
    with zipfile.ZipFile(APK) as archive:
        assert archive.testzip() is None, "Corrupt archive"
        for name in archive.namelist():
            if not (name.startswith("classes") and name.endswith(".dex")):
                continue
            data = archive.read(name)
            assert data[:4] == b"dex\n"
            count, offset = struct.unpack_from("<II", data, 56)
            for i in range(count):
                position = struct.unpack_from("<I", data, offset + i * 4)[0]
                start = position
                while data[position] & 128:
                    position += 1
                position += 1
                value = data[position:data.index(b"\0", position)].decode("utf-8", errors="replace")
                if any(marker in value for marker in MARKERS):
                    findings.append({"member": name, "offset": start, "string": value})
    report = {"apk": APK.name, "sha256": digest, "matches_release_digest": digest == EXPECTED_SHA256,
              "release": "kotlin-v0.16.13", "source_revision": "ac3a1e2e866b2a917651575ba507adfe62344932",
              "evidence": "ZIP/DEX static strings via local Python; not execution or full decompilation", "findings": findings}
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
