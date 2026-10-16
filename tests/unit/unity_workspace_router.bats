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
