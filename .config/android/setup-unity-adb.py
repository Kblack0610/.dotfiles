#!/usr/bin/env python3
"""Configure Linux Unity editors to share /usr/bin/adb with other clients."""

import argparse
import base64
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET


def configure(sdk, prefs, adb):
    if not adb.is_file():
        raise ValueError(f"System adb is missing: {adb}. Install android-tools first.")
    for component in ("platform-tools", "platforms", "build-tools", "cmdline-tools"):
        if not (sdk / component).is_dir():
            raise ValueError(f"SDK is missing {component}: {sdk}")
    tree = ET.parse(prefs)
    root = tree.getroot()
    if root.tag != "unity_prefs":
        raise ValueError(f"Unexpected Unity preferences format: {prefs}")
    values = {
        "AndroidSdkRoot": ("string", base64.b64encode(str(sdk).encode()).decode()),
        "SdkUseEmbedded": ("int", "0"),
        "AndroidADBKillExternalInstance": ("int", "0"),
        "AndroidADBKillServerOnExit": ("int", "0"),
    }
    changed = False
    for name, (kind, value) in values.items():
        matches = root.findall(f"pref[@name='{name}']")
        if len(matches) > 1:
            raise ValueError(f"Duplicate Unity preference: {name}")
        node = matches[0] if matches else ET.SubElement(root, "pref", name=name)
        if node.get("type") != kind or node.text != value:
            node.set("type", kind)
            node.text = value
            changed = True
    sdk_adb = sdk / "platform-tools/adb"
    if sdk_adb.resolve() != adb.resolve():
        # Replace the SDK's competing binary; Unity's installed modules stay intact.
        sdk_adb.unlink(missing_ok=True)
        sdk_adb.symlink_to(adb)
    if changed:
        tree.write(prefs, encoding="utf-8")
    print(f"Unity SDK: {sdk}; adb: {sdk_adb.resolve()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path, help="Existing shared Android SDK root")
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("This setup supports Linux only")
    editors = subprocess.run(["pgrep", "-x", "Unity"], capture_output=True)
    if editors.returncode != 1:
        parser.error("Close all Unity editors and test runs before configuring adb")
    try:
        configure(args.sdk.expanduser().resolve(), Path.home() / ".local/share/unity3d/prefs", Path("/usr/bin/adb"))
    except (OSError, ValueError, ET.ParseError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
