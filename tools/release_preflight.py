"""Offline resource checks; run before simulator tests and TestFlight packaging."""
import json
import plistlib
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    catalog = ROOT / "Sources/Metronome/Resources/Assets.xcassets/AppIcon.appiconset"
    images = json.loads((catalog / "Contents.json").read_text())["images"]
    icons = [image["filename"] for image in images if image.get("filename")]
    assert icons, "App icon is missing"
    for name in icons:
        data = (catalog / name).read_bytes()
        assert data[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {name}"
        width, height, depth, color = struct.unpack(">IIBB", data[16:26])
        assert (width, height, depth, color) == (1024, 1024, 8, 2), "Icon must be 1024px RGB without alpha"
    clips = [str(n) for n in range(1, 33)] + ["and", "e", "a", "trip", "let"]
    for clip in clips:
        path = ROOT / f"Resources/Voice/voice_{clip}.wav"
        with wave.open(str(path), "rb") as audio:
            assert audio.getnframes() > 0, f"Empty voice sample: {clip}"
            assert audio.getnchannels() == 1, f"Expected mono voice sample: {clip}"
    with (ROOT / "Resources/PrivacyInfo.xcprivacy").open("rb") as source:
        privacy = plistlib.load(source)
    assert privacy["NSPrivacyTracking"] is False
    assert privacy["NSPrivacyCollectedDataTypes"] == []
    assert any(item["NSPrivacyAccessedAPIType"] == "NSPrivacyAccessedAPICategoryUserDefaults"
               and "CA92.1" in item["NSPrivacyAccessedAPITypeReasons"]
               for item in privacy["NSPrivacyAccessedAPITypes"])
    print(f"Release resources passed: {len(icons)} icon(s), {len(clips)} voice clips, privacy manifest.")


if __name__ == "__main__":
    main()
