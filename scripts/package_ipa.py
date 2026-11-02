"""Package an unsigned archive and check that both iOS targets are present."""
import plistlib
import sys
import zipfile
from pathlib import Path


def package(archive: Path, output: Path) -> None:
    application = archive / "Products" / "Applications" / "Sever.app"
    xray = application / "PlugIns" / "SeverXrayTunnel.appex"
    openvpn = application / "PlugIns" / "SeverOpenVPNTunnel.appex"
    for bundle in (application, xray, openvpn):
        with (bundle / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        executable = info.get("CFBundleExecutable")
        if not executable or not (bundle / executable).is_file():
            raise RuntimeError(f"Bundle executable is missing: {bundle.name}")
    if output.exists():
        raise RuntimeError("Output already exists; move it aside before repackaging")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as ipa:
        for item in application.rglob("*"):
            if item.is_file():
                ipa.write(item, Path("Payload") / application.name / item.relative_to(application))
    print("Unsigned IPA created:", output)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: package_ipa.py <Sever.xcarchive> <output.ipa>")
    package(Path(sys.argv[1]), Path(sys.argv[2]))
