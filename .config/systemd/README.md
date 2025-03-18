Create a ~/.config/systemd/user/set-random-wallpaper.service containing:
```
[Unit]
Description=Set random wallpaper
PartOf=graphical-session.target
ConditionEnvironment=DISPLAY

[Service]
Type=exec
ExecStart=%h/Scripts/set-random-wallpaper.py %h/Pictures/Wallpapers/
```
# Load it into your systemd instance:
```
systemctl --user daemon-reload
```
# and test that it works:
```
systemctl --user start set-random-wallpaper.service
```
# Next you can create a corresponding ~/.config/systemd/user/set-random-wallpaper.timer containing:
```
[Unit]
Description=Set random wallpaper
After=graphical-session-pre.target
PartOf=graphical-session.target

[Timer]
OnCalendar=minutely
AccuracySec=1

[Install]
WantedBy=graphical-session.target
```
# Again, load it into your systemd instance:
```
systemctl --user daemon-reload
```
# Then enable and start it:
```
systemctl --user enable --now set-random-wallpaper.timer
```

# There's no need for the script to pull environment variables out of the manager. It will be run with the correct environment from the start. 
# All of this is set up so that timer will be launched when your graphical session is started, and it will be stopped when the graphical session is stopped. It won't even bother trying to run the script when you are not logged in, or when you are logged in only upon a text-mode session. This is better than blindly running it once a minute whether you even have a desktop environment or not.
# (Also, as a minor point, XAUTHORITY is completely optional. That is, X programs will use a default value if it is not set. This is completely unlike DISPLAY. This is why I've only checked for the presence of DISPLAY in ConditionEnvironment=.)


#### NOTE: persistence
https://unix.stackexchange.com/questions/631248/systemctl-persistent-timer-and-service-when-computer-turned-off

#### NOTE: issues with timers:
may have to unable linger for user service to start
loginctl show-user kblack0610
loginctl enable-linger kblack0610
