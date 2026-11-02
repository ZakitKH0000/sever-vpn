"""Fetch the pinned official Xray Apple framework; no programs are executed."""
from __future__ import annotations

import hashlib
import json
import shutil
import sys
import urllib.request
import uuid
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
URL = "https://github.com/XTLS/libXray/releases/download/v26.10.31/libxray-apple-cgo.zip"
SHA256 = "2666babc1a91d8570a49bc817487338e7a71f17618e02a601e861928d254b95a"
DESTINATION = ROOT / "Packages" / "XrayBinary" / "LibXray.xcframework"


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main() -> None:
    marker = DESTINATION / ".sever-source.json"
    if marker.exists() and json.loads(marker.read_text())["sha256"] == SHA256:
        print("Pinned LibXray framework is already prepared.")
        return
    if DESTINATION.exists():
        raise RuntimeError("Framework directory already exists. Move it aside before preparing dependencies.")
    downloads = ROOT / ".tools" / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / (SHA256 + ".zip")
    if not archive.exists():
        partial = downloads / (str(uuid.uuid4()) + ".partial")
        request = urllib.request.Request(URL, headers={"User-Agent": "Sever-build/0.1"})
        print("Downloading official LibXray v26.10.31 (about 102 MB)...", flush=True)
        with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as output:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > 150 * 1024 * 1024:
                    raise RuntimeError("Archive exceeds expected size limit")
                output.write(chunk)
        if digest(partial) != SHA256:
            raise RuntimeError("LibXray archive checksum does not match the pinned GitHub release digest")
        partial.rename(archive)
    if digest(archive) != SHA256:
        raise RuntimeError("Cached archive checksum mismatch")
    staging = downloads / ("extract-" + str(uuid.uuid4()))
    staging.mkdir()
    with zipfile.ZipFile(archive) as bundle:
        selected = []
        for member in bundle.infolist():
            parts = PurePosixPath(member.filename).parts
            if ".." in parts or PurePosixPath(member.filename).is_absolute():
                raise RuntimeError("Unsafe archive path")
            if "LibXray.xcframework" in parts:
                if (member.external_attr >> 16) & 0o170000 == 0o120000:
                    raise RuntimeError("Symbolic link in framework archive")
                selected.append(member)
        if not selected or sum(item.file_size for item in selected) > 750 * 1024 * 1024:
            raise RuntimeError("Expected framework missing or archive too large")
        for member in selected:
            parts = PurePosixPath(member.filename).parts
            relative = Path(*parts[parts.index("LibXray.xcframework") + 1 :])
            target = staging / relative
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(member) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
    if not (staging / "Info.plist").exists():
        raise RuntimeError("Invalid xcframework archive layout")
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    (staging / ".sever-source.json").write_text(json.dumps({"url": URL, "sha256": SHA256}), encoding="utf-8")
    staging.rename(DESTINATION)
    print("LibXray checksum verified; framework prepared.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Dependency preparation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
