#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import tempfile
import json
import os
from pathlib import Path

from PIL import Image
from PIL import ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ICNS = ROOT / "assets" / "CleanZipIcon.original.icns"
OUTPUT_ICNS = ROOT / "CleanZip.app" / "Contents" / "Resources" / "AppIcon.icns"
OUTPUT_LEGACY_ICNS = ROOT / "CleanZip.app" / "Contents" / "Resources" / "CleanZipIcon.icns"
OUTPUT_SERVICE_ICNS = ROOT / "CleanZipService.service" / "Contents" / "Resources" / "AppIcon.icns"
OUTPUT_SERVICE_LEGACY_ICNS = ROOT / "CleanZipService.service" / "Contents" / "Resources" / "CleanZipIcon.icns"
OUTPUT_ICONSET = ROOT / "CleanZipIcon.iconset"
OUTPUT_ASSETS = ROOT / "Assets.xcassets"
OUTPUT_APPICONSET = OUTPUT_ASSETS / "AppIcon.appiconset"
OUTPUT_ICON_DOCUMENT = ROOT / "AppIcon.icon"
OUTPUT_ICON_DOCUMENT_ASSETS = OUTPUT_ICON_DOCUMENT / "Assets"
OUTPUT_PREVIEW = ROOT / "AppIconPreview.png"
OUTPUT_VARIANTS = ROOT / "AppIconVariants"
LEGACY_ICON_SCALE = 0.82
LEGACY_ANCHOR_ALPHA = 1

RENDITIONS = [
    "Default",
    "Dark",
    "ClearLight",
    "ClearDark",
    "TintedLight",
    "TintedDark",
]

SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def alpha_bounds(image: Image.Image, threshold: int = 0) -> tuple[int, int, int, int]:
    alpha = image.getchannel("A")
    return alpha.point(lambda value: 255 if value > threshold else 0).getbbox() or (0, 0, *image.size)


def rounded_mask(size: int, box: tuple[int, int, int, int], radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def paste_gradient(
    target: Image.Image,
    box: tuple[int, int, int, int],
    radius: int,
    top: tuple[int, int, int],
    bottom: tuple[int, int, int],
) -> None:
    x0, y0, x1, y1 = box
    width = x1 - x0
    height = y1 - y0
    gradient = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    pixels = gradient.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        color = tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
        for x in range(width):
            pixels[x, y] = (*color, 255)
    mask = rounded_mask(width, (0, 0, width, height), radius)
    layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    layer.alpha_composite(gradient)
    target.alpha_composite(Image.composite(layer, Image.new("RGBA", (width, height), (0, 0, 0, 0)), mask), (x0, y0))


def fitted_master(source: Image.Image) -> Image.Image:
    source = source.convert("RGBA")
    left, top, right, bottom = alpha_bounds(source)
    pad = 48
    left = max(0, left - pad)
    top = max(0, top - pad)
    right = min(source.width, right + pad)
    bottom = min(source.height, bottom + pad)
    cropped = source.crop((left, top, right, bottom))

    canvas_size = 1024
    icon_box = (92, 92, 932, 932)
    icon_radius = 190
    target_extent = 760
    scale = min(target_extent / cropped.width, target_extent / cropped.height)
    new_size = (round(cropped.width * scale), round(cropped.height * scale))
    enlarged = cropped.resize(new_size, Image.Resampling.LANCZOS)

    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((92, 108, 932, 948), radius=icon_radius, fill=(0, 0, 0, 44))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(28)))
    paste_gradient(canvas, icon_box, icon_radius, (54, 202, 231), (28, 176, 197))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(icon_box, radius=icon_radius, outline=(255, 255, 255, 138), width=5)
    draw.rounded_rectangle((124, 124, 900, 900), radius=160, outline=(255, 255, 255, 86), width=3)

    origin = ((canvas_size - new_size[0]) // 2, (canvas_size - new_size[1]) // 2)
    canvas.alpha_composite(enlarged, origin)

    mask = rounded_mask(canvas_size, icon_box, icon_radius)
    clipped = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    clipped.alpha_composite(canvas)
    clipped.putalpha(Image.composite(clipped.getchannel("A"), Image.new("L", (canvas_size, canvas_size), 0), mask))
    canvas = clipped
    return canvas


def extract_largest_icon() -> Image.Image:
    with tempfile.TemporaryDirectory(prefix="cleanzip-icon-source.") as tmp:
        iconset = Path(tmp) / "source.iconset"
        subprocess.run(["iconutil", "-c", "iconset", "-o", str(iconset), str(SOURCE_ICNS)], check=True)
        return Image.open(iconset / "icon_512x512@2x.png").convert("RGBA")


def draw_rounded(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], radius: int, fill, outline=None, width: int = 1) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def svg_document(content: str) -> str:
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
{content}
</svg>
"""


def make_liquid_glass_layers() -> dict[str, str]:
    body = svg_document("""  <rect x="246" y="292" width="532" height="500" rx="112" fill="#ddfdff" fill-opacity=".58" stroke="#ffffff" stroke-opacity=".91" stroke-width="12"/>
  <rect x="270" y="324" width="484" height="442" rx="88" fill="#56dcec" fill-opacity=".30" stroke="#ffffff" stroke-opacity=".50" stroke-width="5"/>
  <path d="M296 360L420 260H604L730 360Z" fill="#f4feff" fill-opacity=".56"/>
  <path d="M296 360L420 260H604L730 360" fill="none" stroke="#ffffff" stroke-opacity=".89" stroke-width="10" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M300 360H724" fill="none" stroke="#2db9d4" stroke-opacity=".41" stroke-width="7" stroke-linecap="round"/>
  <rect x="316" y="452" width="392" height="280" rx="60" fill="#34c5e0" fill-opacity=".20" stroke="#ffffff" stroke-opacity=".49" stroke-width="4"/>
  <path d="M306 408L512 472L718 408" fill="none" stroke="#ffffff" stroke-opacity=".21" stroke-width="24" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M326 704H686" fill="none" stroke="#00708c" stroke-opacity=".08" stroke-width="8" stroke-linecap="round"/>
  <path d="M280 392V682" fill="none" stroke="#ffffff" stroke-opacity=".23" stroke-width="16" stroke-linecap="round"/>
  <path d="M744 392V682" fill="none" stroke="#0a7896" stroke-opacity=".12" stroke-width="10" stroke-linecap="round"/>""")

    folds = svg_document("""  <path d="M284 398L420 296L512 370V440Z" fill="#ffffff" fill-opacity=".49"/>
  <path d="M740 398L604 296L512 370V440Z" fill="#ffffff" fill-opacity=".37"/>
  <path d="M420 296L512 370L604 296" fill="none" stroke="#ffffff" stroke-opacity=".88" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M286 402L512 594L738 402" fill="none" stroke="#ffffff" stroke-opacity=".37" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M330 468L512 532L694 468" fill="none" stroke="#008caf" stroke-opacity=".12" stroke-width="18" stroke-linecap="round" stroke-linejoin="round"/>
  <rect x="326" y="466" width="372" height="240" rx="52" fill="#ffffff" fill-opacity=".16"/>
  <ellipse cx="520" cy="369" rx="224" ry="69" fill="#ffffff" fill-opacity=".12"/>""")

    zipper_teeth = []
    for index, y in enumerate(range(308, 712, 38)):
        if index % 2 == 0:
            zipper_teeth.append(f'  <rect x="486" y="{y}" width="26" height="14" rx="4" fill="#41829e" fill-opacity=".93"/>')
            zipper_teeth.append(f'  <rect x="512" y="{y + 18}" width="26" height="14" rx="4" fill="#41829e" fill-opacity=".93"/>')
        else:
            zipper_teeth.append(f'  <rect x="512" y="{y}" width="26" height="14" rx="4" fill="#41829e" fill-opacity=".93"/>')
            zipper_teeth.append(f'  <rect x="486" y="{y + 18}" width="26" height="14" rx="4" fill="#41829e" fill-opacity=".93"/>')
    zipper = svg_document("""  <rect x="476" y="262" width="74" height="498" rx="30" fill="#ecfdff" fill-opacity=".98" stroke="#3a708c" stroke-width="9"/>
  <path d="M494 290V728" fill="none" stroke="#ffffff" stroke-opacity=".47" stroke-width="8" stroke-linecap="round"/>
  <path d="M512 282V742" fill="none" stroke="#1c5876" stroke-opacity=".94" stroke-width="6" stroke-linecap="round"/>
""" + "\n".join(zipper_teeth) + """
  <rect x="468" y="214" width="88" height="96" rx="36" fill="#f1feff" fill-opacity=".97" stroke="#3a708c" stroke-opacity=".99" stroke-width="8"/>
  <path d="M512 306V368" fill="none" stroke="#3a708c" stroke-opacity=".99" stroke-width="8" stroke-linecap="round"/>
  <circle cx="512" cy="252" r="18" fill="#3a7793" fill-opacity=".96"/>
  <circle cx="512" cy="252" r="10" fill="#ebfcff" fill-opacity=".96"/>
  <path d="M489 271C497 236 529 227 541 247" fill="none" stroke="#ffffff" stroke-opacity=".59" stroke-width="6" stroke-linecap="round"/>""")

    return {
        "01-pouch-body.svg": body,
        "02-folds.svg": folds,
        "03-zipper.svg": zipper,
    }


def inset_for_legacy_icon(image: Image.Image) -> Image.Image:
    if LEGACY_ICON_SCALE >= 1:
        return image
    size = image.width
    target = round(size * LEGACY_ICON_SCALE)
    resized = image.resize((target, target), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", image.size, (0, 0, 0, 0))
    origin = ((size - target) // 2, (size - target) // 2)
    canvas.alpha_composite(resized, origin)
    # IconServices normalizes app icons by their alpha bounds. A nearly
    # invisible edge anchor keeps Dock from scaling the static fallback up.
    anchor = ImageDraw.Draw(canvas, "RGBA")
    anchor.rectangle((0, 0, size - 1, size - 1), outline=(255, 255, 255, LEGACY_ANCHOR_ALPHA), width=1)
    return canvas


def locate_ictool() -> Path | None:
    candidates: list[Path] = []
    if env_path := os.environ.get("ICON_COMPOSER_APP"):
        candidates.append(Path(env_path) / "Contents" / "Executables" / "ictool")
    if developer_dir := os.environ.get("DEVELOPER_DIR"):
        developer_path = Path(developer_dir)
        candidates.extend([
            developer_path / "usr" / "bin" / "ictool",
            developer_path / "Applications" / "Icon Composer.app" / "Contents" / "Executables" / "ictool",
            developer_path.parent / "Applications" / "Icon Composer.app" / "Contents" / "Executables" / "ictool",
        ])
    candidates.extend([
        Path("/Applications/Icon Composer.app/Contents/Executables/ictool"),
        Path.home() / "Applications" / "Icon Composer.app" / "Contents" / "Executables" / "ictool",
        Path("/Applications/Xcode.app/Contents/Developer/usr/bin/ictool"),
        Path("/Applications/Xcode.app/Contents/Developer/Applications/Icon Composer.app/Contents/Executables/ictool"),
        Path("/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"),
        Path("/Applications/Xcode-beta.app/Contents/Developer/usr/bin/ictool"),
        Path("/Applications/Xcode-beta.app/Contents/Developer/Applications/Icon Composer.app/Contents/Executables/ictool"),
        Path("/Applications/Xcode-beta.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"),
        Path("/Volumes/Icon Composer 2/Icon Composer.app/Contents/Executables/ictool"),
        Path("/Volumes/Icon Composer/Icon Composer.app/Contents/Executables/ictool"),
    ])
    for xcode in [*Path("/Applications").glob("Xcode*.app"), *Path.home().glob("Applications/Xcode*.app")]:
        candidates.extend([
            xcode / "Contents" / "Developer" / "usr" / "bin" / "ictool",
            xcode / "Contents" / "Developer" / "Applications" / "Icon Composer.app" / "Contents" / "Executables" / "ictool",
            xcode / "Contents" / "Applications" / "Icon Composer.app" / "Contents" / "Executables" / "ictool",
        ])
    for volume in Path("/Volumes").glob("Icon Composer*"):
        candidates.append(volume / "Icon Composer.app" / "Contents" / "Executables" / "ictool")
    xcrun_ictool = subprocess.run(
        ["xcrun", "--find", "ictool"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if xcrun_ictool.returncode == 0 and xcrun_ictool.stdout.strip():
        candidates.append(Path(xcrun_ictool.stdout.strip()))
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def locate_actool() -> Path | None:
    candidates: list[Path] = []
    if env_path := os.environ.get("ACTOOL"):
        candidates.append(Path(env_path))
    if developer_dir := os.environ.get("DEVELOPER_DIR"):
        candidates.append(Path(developer_dir) / "usr" / "bin" / "actool")
    candidates.extend([
        Path("/Applications/Xcode.app/Contents/Developer/usr/bin/actool"),
        Path("/Applications/Xcode-beta.app/Contents/Developer/usr/bin/actool"),
        Path.home() / "Applications" / "Xcode.app" / "Contents" / "Developer" / "usr" / "bin" / "actool",
        Path.home() / "Applications" / "Xcode-beta.app" / "Contents" / "Developer" / "usr" / "bin" / "actool",
    ])
    for candidate in candidates:
        if candidate.exists() and not str(candidate).startswith("/usr/bin"):
            return candidate
    xcrun_actool = subprocess.run(
        ["xcrun", "--find", "actool"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if xcrun_actool.returncode == 0 and xcrun_actool.stdout.strip():
        candidate = Path(xcrun_actool.stdout.strip())
        if candidate.exists() and not str(candidate).startswith("/usr/bin"):
            return candidate
    return None


def write_icon_document() -> None:
    if OUTPUT_ICON_DOCUMENT.exists():
        shutil.rmtree(OUTPUT_ICON_DOCUMENT)
    OUTPUT_ICON_DOCUMENT_ASSETS.mkdir(parents=True)

    for filename, svg in make_liquid_glass_layers().items():
        (OUTPUT_ICON_DOCUMENT_ASSETS / filename).write_text(svg)

    document = {
        "fill-specializations": [
            {
                "value": {
                    "automatic-gradient": "display-p3:0.00000,0.74510,0.85098,1.00000"
                }
            },
            {
                "appearance": "dark",
                "value": {
                    "automatic-gradient": "display-p3:0.00000,0.36078,0.43529,1.00000"
                }
            },
            {
                "appearance": "tinted",
                "value": "automatic"
            }
        ],
        "color-space-for-untagged-svg-colors": "display-p3",
        "groups": [
            {
                "layers": [
                    {
                        "name": "03 Zipper",
                        "image-name": "03-zipper.svg",
                        "glass": True
                    }
                ],
                "lighting": "individual",
                "specular": True,
                "blur-material": 0.14,
                "specular-highlight-placement": [0.22, 0.08],
                "shadow": {
                    "kind": "neutral",
                    "opacity": 0.38
                },
                "translucency": {
                    "enabled": False,
                    "value": 0.0
                }
            },
            {
                "layers": [
                    {
                        "name": "02 Folds",
                        "image-name": "02-folds.svg",
                        "glass": True,
                        "opacity": 0.86
                    }
                ],
                "lighting": "individual",
                "specular": True,
                "blur-material": 0.46,
                "specular-highlight-placement": [0.18, 0.12],
                "shadow": {
                    "kind": "none",
                    "opacity": 0.0
                },
                "translucency": {
                    "enabled": True,
                    "value": 0.42
                }
            },
            {
                "layers": [
                    {
                        "name": "01 Pouch body",
                        "image-name": "01-pouch-body.svg",
                        "glass": True
                    }
                ],
                "lighting": "combined",
                "specular": True,
                "blur-material": 0.62,
                "specular-highlight-placement": [0.16, 0.1],
                "shadow": {
                    "kind": "neutral",
                    "opacity": 0.42
                },
                "translucency": {
                    "enabled": True,
                    "value": 0.58
                }
            }
        ],
        "supported-platforms": {
            "squares": "shared"
        }
    }
    (OUTPUT_ICON_DOCUMENT / "icon.json").write_text(json.dumps(document, indent=2) + "\n")


def export_icon_document_images() -> Image.Image | None:
    ictool = locate_ictool()
    if ictool is None:
        return None
    if OUTPUT_VARIANTS.exists():
        shutil.rmtree(OUTPUT_VARIANTS)
    OUTPUT_VARIANTS.mkdir(parents=True)
    default_output = OUTPUT_VARIANTS / "Default.png"
    for rendition in RENDITIONS:
        output = OUTPUT_VARIANTS / f"{rendition}.png"
        command = [
            str(ictool),
            str(OUTPUT_ICON_DOCUMENT),
            "--export-image",
            "--output-file",
            str(output),
            "--platform",
            "macOS",
            "--rendition",
            rendition,
            "--width",
            "512",
            "--height",
            "512",
            "--scale",
            "2",
            "--design-generation",
            "26",
        ]
        try:
            subprocess.run(command, check=True)
        except subprocess.CalledProcessError as error:
            print(f"Skipping Icon Composer image export; {ictool} does not support this export mode ({error}).")
            return None
    shutil.copy2(default_output, OUTPUT_PREVIEW)
    return Image.open(default_output).convert("RGBA")


def compile_asset_catalog_if_possible() -> Path | None:
    actool = locate_actool()
    if actool is None:
        return None

    resources = ROOT / "CleanZip.app" / "Contents" / "Resources"
    partial_info = ROOT / "assetcatalog_generated_info.plist"
    assets_car = resources / "Assets.car"
    assets_car.unlink(missing_ok=True)
    command = [
        str(actool),
        str(OUTPUT_ICON_DOCUMENT),
        "--compile",
        str(resources),
        "--notices",
        "--warnings",
        "--errors",
        "--output-partial-info-plist",
        str(partial_info),
        "--app-icon",
        "AppIcon",
        "--include-all-app-icons",
        "--enable-on-demand-resources",
        "NO",
        "--enable-icon-stack-fallback-generation=disabled",
        "--development-region",
        "zh_CN",
        "--target-device",
        "mac",
        "--platform",
        "macosx",
        "--minimum-deployment-target",
        os.environ.get("MACOSX_DEPLOYMENT_TARGET", "14.0"),
    ]
    subprocess.run(command, check=True)
    partial_info.unlink(missing_ok=True)
    if assets_car.exists() and (ROOT / "CleanZipService.service" / "Contents" / "Resources").exists():
        shutil.copy2(assets_car, ROOT / "CleanZipService.service" / "Contents" / "Resources" / "Assets.car")
    return assets_car if assets_car.exists() else None


def main() -> None:
    if not SOURCE_ICNS.exists():
        raise SystemExit(f"Missing original icon: {SOURCE_ICNS}")
    if OUTPUT_ICONSET.exists():
        shutil.rmtree(OUTPUT_ICONSET)
    OUTPUT_ICONSET.mkdir(parents=True)
    if OUTPUT_APPICONSET.exists():
        shutil.rmtree(OUTPUT_APPICONSET)
    OUTPUT_APPICONSET.mkdir(parents=True)
    OUTPUT_ASSETS.mkdir(parents=True, exist_ok=True)

    write_icon_document()
    rendered = export_icon_document_images()
    master = inset_for_legacy_icon(rendered) if rendered is not None else fitted_master(extract_largest_icon())
    images = []
    for filename, size in SIZES:
        image = master.resize((size, size), Image.Resampling.LANCZOS)
        image.save(OUTPUT_ICONSET / filename)
        image.save(OUTPUT_APPICONSET / filename)
        point_size = size // 2 if "@2x" in filename else size
        scale = "2x" if "@2x" in filename else "1x"
        images.append({
            "idiom": "mac",
            "size": f"{point_size}x{point_size}",
            "scale": scale,
            "filename": filename
        })

    (OUTPUT_ASSETS / "Contents.json").write_text(json.dumps({
        "info": {"author": "xcode", "version": 1}
    }, indent=2) + "\n")
    (OUTPUT_APPICONSET / "Contents.json").write_text(json.dumps({
        "images": images,
        "info": {"author": "xcode", "version": 1}
    }, indent=2) + "\n")

    OUTPUT_ICNS.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", str(OUTPUT_ICONSET), "-o", str(OUTPUT_ICNS)], check=True)
    shutil.copy2(OUTPUT_ICNS, OUTPUT_LEGACY_ICNS)
    if OUTPUT_SERVICE_ICNS.parent.exists():
        shutil.copy2(OUTPUT_ICNS, OUTPUT_SERVICE_ICNS)
        shutil.copy2(OUTPUT_ICNS, OUTPUT_SERVICE_LEGACY_ICNS)
    for resources in [
        ROOT / "CleanZip.app" / "Contents" / "Resources",
        ROOT / "CleanZipService.service" / "Contents" / "Resources",
    ]:
        if resources.exists():
            destination = resources / OUTPUT_ICON_DOCUMENT.name
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(OUTPUT_ICON_DOCUMENT, destination)
    assets_car = compile_asset_catalog_if_possible()
    if assets_car is None:
        print("No Xcode actool found; wrote AppIcon.icon and static AppIcon.icns fallback.")
    else:
        print(f"Compiled {assets_car}")
    print(OUTPUT_ICNS)


if __name__ == "__main__":
    main()
