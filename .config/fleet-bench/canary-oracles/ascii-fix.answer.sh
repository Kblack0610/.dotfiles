# fleet-bench canary verify: the known answer to an ascii-fix task, written into the tree
# (`bash -s -- <file>`), so verify can prove its oracle passes on a correct fix. Never run on a session's tree.
sed -i -e 's/\xe2\x80\x94/-/g' -e 's/\xe2\x80\x93/-/g' -e 's/\xe2\x86\x92/->/g' -e 's/\xe2\x89\xa4/<=/g' \
  -e 's/\xe2\x97\x8f/*/g' -e 's/\xe2\x8c\x83/Ctrl+/g' -e 's/\xe2\x8c\x98/Cmd+/g' -e 's/\xe2\x80\xa6/.../g' "$1"
