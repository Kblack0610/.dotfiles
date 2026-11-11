#!/usr/bin/env bats
# The D-Bus file manager (org.freedesktop.FileManager1, which "show in folder" calls) is the
# same program as Hyprland's $fileManager. Two installed packages claim that name; the user
# service file decides which one starts. Read from the files as text, so no bus is involved.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SERVICE="$REPO_ROOT/.local/share/dbus-1/services/org.freedesktop.FileManager1.service"
  PROGRAMS="$REPO_ROOT/.config/hypr/conf.d/programs.conf"
}

# The value of key $2 in the [D-BUS Service] file $1.
dbus_key() { sed -n "s/^$2=//p" "$1"; }

@test "the user D-Bus service claims org.freedesktop.FileManager1" {
  [ -f "$SERVICE" ] || fail "missing $SERVICE: /usr/share decides, and dolphin can win"
  assert_equal "$(dbus_key "$SERVICE" Name)" "org.freedesktop.FileManager1"
}

@test "FileManager1 starts the program Hyprland names as \$fileManager" {
  fm=$(sed -n 's/^\$fileManager[[:space:]]*=[[:space:]]*//p' "$PROGRAMS")
  [ -n "$fm" ] || fail "no \$fileManager in $PROGRAMS"
  exe=$(dbus_key "$SERVICE" Exec); exe=${exe%% *}; exe=${exe##*/}
  unit=$(dbus_key "$SERVICE" SystemdService)
  assert_equal "${exe,,}" "${fm,,}"
  assert_equal "$unit" "${fm,,}.service"
}
