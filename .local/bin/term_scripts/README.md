useful command bash stuff

# this is good for outputting all the files that have a certain name into a list to pipe to something else
$ find /home/kblack0610/dev/Games/DodginBalls_root/DodginBalls/Assets/Runtime/Scripts/Managers/Game -name "*.cs" -type f -exec grep -l "namespace BlackNBrown.Managers" {} \;


