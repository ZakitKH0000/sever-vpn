"""Create a reviewable source bundle without local audits, credentials or SDK binaries."""
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {"LibXray.xcframework", "__pycache__"}


def sources():
    for file in (".gitignore", "package.json", "project.yml", "README.md", "LICENSE", "THIRD_PARTY.md", "requirements-dev.txt"):
        yield ROOT / file
    for directory in ("ios", "scripts", "tests", ".github", "Packages"):
        for path in (ROOT / directory).rglob("*"):
            if path.is_file() and not any(part in EXCLUDED for part in path.relative_to(ROOT).parts):
                yield path
    yield ROOT / "docs/device-checklist.md"


if __name__ == "__main__":
    output = ROOT / "build/Sever-source.zip"
    output.parent.mkdir(exist_ok=True)
    if output.exists():
        raise SystemExit("Source bundle already exists; move it aside before creating another")
    paths = sorted(sources())
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in paths:
            archive.write(path, "Sever/" + path.relative_to(ROOT).as_posix())
    print(f"Source bundle: {len(paths)} files; {output.stat().st_size} bytes")
