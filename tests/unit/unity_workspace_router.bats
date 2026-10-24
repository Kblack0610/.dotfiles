#!/usr/bin/env bats
# The Hyprland Unity router's popup decision (.config/hypr/scripts/unity-workspace-router.py).
# A Unity menu is its own floating window; moving one that already opened beside its editor
# leaves it unfocused, and the playground's menu bar then took no hover or clicks.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  ROUTER="$BATS_TEST_DIRNAME/../../.config/hypr/scripts/unity-workspace-router.py"
}

# popup_target(<workspace the popup opened on>, <playground editor active: True|False>)
target() {
  python3 -I - "$ROUTER" "$1" "$2" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("router", sys.argv[1])
router = importlib.util.module_from_spec(spec)
spec.loader.exec_module(router)
print(router.popup_target({"workspace": {"id": int(sys.argv[2])}}, sys.argv[3] == "True"))
EOF
}

@test "a menu that opens beside the playground editor is left alone" {
  run target 4 True
  assert_success
  assert_output "None"
}

@test "a menu that opens beside a game editor on ws3 is left alone" {
  run target 3 False
  assert_output "None"
}

@test "a playground dialog that opens elsewhere goes to ws4" {
  run target 1 True
  assert_output "4"
}

@test "any other Unity dialog that opens elsewhere goes to ws3" {
  run target 1 False
  assert_output "3"
}

# is_playground_editor on a tiled editor with <class> and <title>
editor() {
  python3 -I - "$ROUTER" "$1" "$2" <<'EOF2'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("router", sys.argv[1])
router = importlib.util.module_from_spec(spec)
spec.loader.exec_module(router)
print(router.is_playground_editor({"class": sys.argv[2], "title": sys.argv[3], "floating": False}))
EOF2
}

@test "a Unity 6.0 playground editor (Unityhub-unity-editor-<v>) is recognised" {
  run editor "Unityhub-unity-editor-6000.0.72f1" "Unity - unity-core-playground - Main - Linux"
  assert_output "True"
}

@test "a Unity 6.3 playground editor (Unity-<v>) is recognised" {
  run editor "Unity-6000.3.27f1" "Unity - unity-core-playground - SchoolHD - Windows, Mac, Linux"
  assert_output "True"
}

@test "the Unity Hub window is never treated as an editor" {
  run editor "unityhub" "Unity - unity-core-playground - Main - Linux"
  assert_output "False"
}

@test "a game editor is not the playground" {
  run editor "Unity-6000.3.27f1" "Unity - dodginballs - Main - Linux"
  assert_output "False"
}
