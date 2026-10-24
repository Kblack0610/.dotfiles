#!/usr/bin/env python3
"""Route the Unity playground editor to its own workspace.

Every Unity editor shares one class (`Unityhub-unity-editor-<version>` before
Unity 6.3, `Unity-<version>` from 6000.3 on), so the
only thing that tells projects apart is the title, `Unity - <project> - <scene>
- ...`. A static `workspace` window rule cannot use it: static rules read the
INITIAL title, and the playground editor maps as `Unity - Unity <version>`
before it knows its project (seen 2026-09-28; dodginballs, by contrast, mapped
with its name already in the title). So rules.conf puts every Unity window on
ws3, and this listener moves the playground editor to ws4 on the event that
carries its real title.

It also owns every floating Unity window (menus, Build Settings, Package
Manager, progress bars): one that opens away from its editor's workspace goes to
ws4 when a playground editor has focus, else to ws3. One that opens where it
belongs is left alone. A menu opens on the focused workspace, its editor's, and
must not be moved: a silent move leaves it unfocused, and Unity's menus and
sub-menus then take no hover or clicks (the playground's broke that way from
2026-09-28 until the static float rule went).

Started by exec-once in conf.d/autostart.conf; exits when Hyprland closes the
socket, and the next session's exec-once starts it again.
"""

import json
import os
import re
import socket
import subprocess

PLAYGROUND_WORKSPACE = "4"
GAME_WORKSPACE = "3"
EDITOR_CLASS = re.compile(r"^[Uu]nity([Hh]ub)?-")
PLAYGROUND_PROJECT = re.compile(r"playground", re.IGNORECASE)


def project_of(title):
    """`Unity - <project> - <scene> - ...` -> `<project>`, else None."""
    parts = title.split(" - ")
    return parts[1] if len(parts) > 2 and parts[0] == "Unity" else None


def is_playground_editor(client):
    project = project_of(client.get("title", ""))
    return (
        bool(EDITOR_CLASS.match(client.get("class", "")))
        and not client.get("floating", False)
        and project is not None
        and bool(PLAYGROUND_PROJECT.search(project))
    )


def is_unity_popup(client):
    return bool(EDITOR_CLASS.match(client.get("class", ""))) and client.get("floating", False)


def popup_target(popup, playground_active):
    """The workspace a newly opened floating Unity window belongs on, or None when it is there."""
    target = PLAYGROUND_WORKSPACE if playground_active else GAME_WORKSPACE
    return None if str(popup.get("workspace", {}).get("id")) == target else target


def hyprctl_json(*args):
    out = subprocess.run(["hyprctl", "-j", *args], capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def address_of(data):
    """Event payloads lead with the window address; hyprctl spells it `0x...`."""
    raw = data.split(",", 1)[0]
    return raw if raw.startswith("0x") else "0x" + raw


def move(address, workspace, follow):
    verb = "movetoworkspace" if follow else "movetoworkspacesilent"
    subprocess.run(["hyprctl", "dispatch", verb, f"{workspace},address:{address}"],
                   capture_output=True)


class Router:
    def __init__(self):
        # Editors already routed. Moving each one once means a later scene
        # change or save (both retitle the window) never drags it back after
        # you have put it somewhere else by hand.
        self.routed = set()

    def client(self, address):
        for c in hyprctl_json("clients") or []:
            if c.get("address") == address:
                return c
        return None

    def route_editor(self, c, active_address):
        if c["address"] in self.routed or not is_playground_editor(c):
            return
        self.routed.add(c["address"])
        if str(c.get("workspace", {}).get("id")) != PLAYGROUND_WORKSPACE:
            move(c["address"], PLAYGROUND_WORKSPACE, follow=c["address"] == active_address)

    def active_address(self):
        return (hyprctl_json("activewindow") or {}).get("address")

    def sweep(self):
        active = self.active_address()
        for c in hyprctl_json("clients") or []:
            self.route_editor(c, active)

    def on_event(self, name, data):
        if name == "closewindow":
            self.routed.discard(address_of(data))
            return
        if name not in ("openwindow", "windowtitlev2"):
            return
        address = address_of(data)
        c = self.client(address)
        if c is None:
            return
        active = self.active_address()
        if name == "openwindow" and is_unity_popup(c):
            target = popup_target(c, active in self.routed)
            if target is not None:
                move(address, target, follow=False)
            return
        self.route_editor(c, active)


def main():
    sock_path = os.path.join(os.environ["XDG_RUNTIME_DIR"], "hypr",
                             os.environ["HYPRLAND_INSTANCE_SIGNATURE"], ".socket2.sock")
    router = Router()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(sock_path)
        router.sweep()
        for line in sock.makefile("r", encoding="utf-8", errors="replace"):
            name, _, data = line.rstrip("\n").partition(">>")
            router.on_event(name, data)


if __name__ == "__main__":
    main()
