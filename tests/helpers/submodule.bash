# shellcheck shell=bash
# pinned_submodule <superproject dir>: a superproject whose origin/main pins its submodule `module` at a
# pin-merge commit off the submodule's master, with master moved on past it (ar-2445). The submodule is
# <superproject dir>/module; its remote is $SANDBOX/sub.git, pushed to from $SANDBOX/subw.
pinned_submodule() {
  local sup="$1" sub="$1/module" g=(git -c user.email=t@t -c user.name=t -c protocol.file.allow=always)
  git init -q --bare "$SANDBOX/sub.git"
  git clone -q "$SANDBOX/sub.git" "$SANDBOX/subw" 2>/dev/null
  "${g[@]}" -C "$SANDBOX/subw" commit -q --allow-empty -m s0
  git -C "$SANDBOX/subw" push -q origin HEAD:master 2>/dev/null
  git init -q -b main "$sup"
  "${g[@]}" -C "$sup" commit -q --allow-empty -m init
  "${g[@]}" -C "$sup" submodule -q add "$SANDBOX/sub.git" module 2>/dev/null
  "${g[@]}" -C "$sup" commit -q -m pin
  # the superproject's main pins a pin-merge commit in the submodule
  git -C "$sub" checkout -q -b pin-merge
  echo 1 > "$sub/f"; "${g[@]}" -C "$sub" add f; "${g[@]}" -C "$sub" commit -q -m pm
  git -C "$sup" add module; "${g[@]}" -C "$sup" commit -q -m 'pin the pin-merge'
  git -C "$sup" update-ref refs/remotes/origin/main HEAD
  # the submodule's master moves on, so the pin is behind master
  "${g[@]}" -C "$SANDBOX/subw" commit -q --allow-empty -m s1
  git -C "$SANDBOX/subw" push -q origin HEAD:master 2>/dev/null
  git -C "$sub" fetch -q origin
}

# unpinned_commit <submodule dir>: one commit past the pin, on neither branch: unlanded work.
unpinned_commit() {
  echo 2 > "$1/extra"
  git -C "$1" add extra
  git -C "$1" -c user.email=t@t -c user.name=t commit -q -m extra
}
