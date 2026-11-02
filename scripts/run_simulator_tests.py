"""Run actual hosted app tests on an available iPhone simulator."""
import json
import subprocess
from pathlib import Path

devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
phones = [item for runtime, items in devices["devices"].items() if "iOS" in runtime
          for item in items if item.get("isAvailable") and "iPhone" in item["name"]]
if not phones:
    raise SystemExit("An iPhone simulator is required for first-launch regression tests")
device = sorted(phones, key=lambda item: ("Pro Max" not in item["name"], item["name"]))[0]
Path("build").mkdir(exist_ok=True)
print("Running first-launch tests on", device["name"], flush=True)
command = ["xcodebuild", "test", "-project", "Sever.xcodeproj", "-scheme", "Sever",
           "-configuration", "Debug", "-destination", "id=" + device["udid"],
           "-resultBundlePath", "build/Sever-tests.xcresult", "-parallel-testing-enabled", "NO",
           "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="]
with Path("build-simulator.log").open("w", encoding="utf-8") as output:
    result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=1500)
if result.returncode:
    lines = Path("build-simulator.log").read_text(errors="replace").splitlines()
    for line in lines:
        if "error:" in line or "failed" in line.lower():
            print(line)
    raise SystemExit(result.returncode)
print("Hosted iPhone simulator regression tests passed")
