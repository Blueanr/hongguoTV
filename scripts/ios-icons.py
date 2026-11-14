"""Generate Apple icon slots from the repository's original brand artwork.
All configuration is here so builds require no command-line parameters.
"""
from pathlib import Path
import json
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets/brand/logo-pixel.png"
ASSETS = ROOT / "ios-native/Resources/Assets.xcassets"
OUTPUT = ASSETS / "AppIcon.appiconset"
BACKGROUND = (24, 24, 28)
SLOTS = {
    "iphone": [(20, 2), (20, 3), (29, 2), (29, 3), (40, 2), (40, 3), (60, 2), (60, 3)],
    "ipad": [(20, 1), (20, 2), (29, 1), (29, 2), (40, 1), (40, 2), (76, 1), (76, 2), (83.5, 2)],
    "ios-marketing": [(1024, 1)],
}

def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    source = Image.open(SOURCE).convert("RGBA")
    entries = []
    for idiom, slots in SLOTS.items():
        for size, scale in slots:
            pixels = int(size * scale)
            name = f"icon-{idiom}-{size}-{scale}.png"
            icon = Image.new("RGB", (pixels, pixels), BACKGROUND)
            artwork = source.copy()
            artwork.thumbnail((pixels, pixels), Image.Resampling.NEAREST)
            icon.paste(artwork, ((pixels - artwork.width) // 2, (pixels - artwork.height) // 2), artwork)
            icon.save(OUTPUT / name)
            entries.append({"idiom": idiom, "size": f"{size}x{size}", "scale": f"{scale}x", "filename": name})
    info = {"author": "xcode", "version": 1}
    (OUTPUT / "Contents.json").write_text(json.dumps({"images": entries, "info": info}), encoding="utf-8")
    (ASSETS / "Contents.json").write_text(json.dumps({"info": info}), encoding="utf-8")

if __name__ == "__main__":
    main()
