"""Offline syntax/metadata checks. This does not replace an Xcode build."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".tools" / "python"))
import tree_sitter
import tree_sitter_swift
import tree_sitter_objc
import yaml

parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
errors = []
swift_files = list((ROOT / "ios").rglob("*.swift")) + [ROOT / "Packages/XrayBinary/Package.swift", ROOT / "scripts/check_javascriptcore.swift"]
for path in swift_files:
    tree = parser.parse(path.read_bytes())
    if tree.root_node.has_error:
        def collect(node):
            if node.type == "ERROR" or node.is_missing:
                errors.append(f"{path.relative_to(ROOT)}:{node.start_point.row + 1}: {node.type}")
            for child in node.children:
                collect(child)
        collect(tree.root_node)

objc_parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_objc.language()))
objc_path = ROOT / "ios/Tunnel/PacketTunnelProvider.m"
for xray in (True, False):
    active = [True]
    output = []
    for line in objc_path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("#if "):
            condition = xray if stripped == "#if SEVER_XRAY" else not xray
            active.append(active[-1] and condition)
        elif stripped == "#else":
            active[-1] = active[-2] and not active[-1]
        elif stripped == "#endif":
            active.pop()
        elif active[-1]:
            output.append(line)
    tree = objc_parser.parse("\n".join(output).encode())
    if tree.root_node.has_error:
        errors.append(f"Objective-C syntax check failed: {'Xray' if xray else 'OpenVPN'} branch")

spec = yaml.safe_load((ROOT / "project.yml").read_text(encoding="utf-8"))
assert len(spec["targets"]) == 4
for name, target in spec["targets"].items():
    if name == "SeverTests":
        continue
    assert target["entitlements"]["properties"]["com.apple.developer.networking.networkextension"] == ["packet-tunnel-provider"]
    assert target["entitlements"]["properties"]["keychain-access-groups"] == ["$(AppIdentifierPrefix)dev.sever.vpn.shared"]
workflow = yaml.load((ROOT / ".github/workflows/build-ios.yml").read_text(), Loader=yaml.BaseLoader)
assert "workflow_dispatch" in workflow["on"]
assert workflow["permissions"]["contents"] == "read"
assert (ROOT / "Packages/XrayBinary/LibXray.xcframework/ios-arm64/Headers/libXray.h").exists()
if errors:
    print("\n".join(errors))
    raise SystemExit(1)
print(json.dumps({"swiftSyntaxFiles": len(swift_files), "objectiveCBranches": 2, "syntaxErrors": 0, "iOSTargets": len(spec["targets"]), "workflowParsed": True}))
