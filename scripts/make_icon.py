"""Render the project's geometric compass mark. Requires Pillow only for regeneration."""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".tools" / "python"))
from PIL import Image, ImageDraw

image = Image.new("RGB", (1024, 1024), (9, 14, 22))
draw = ImageDraw.Draw(image)
draw.ellipse((155, 155, 869, 869), outline=(35, 61, 66), width=7)
draw.ellipse((195, 195, 829, 829), outline=(57, 112, 111), width=3)
draw.polygon([(512, 210), (658, 710), (512, 625), (366, 710)], fill=(102, 222, 189))
draw.polygon([(512, 210), (512, 625), (658, 710)], fill=(66, 165, 153))
draw.rounded_rectangle((489, 835, 535, 851), radius=8, fill=(102, 222, 189))
folder = ROOT / "ios" / "Sever" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
folder.mkdir(parents=True, exist_ok=True)
image.save(folder / "AppIcon.png")
(folder / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2))
(folder.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))
print("Generated 1024px opaque application icon")
