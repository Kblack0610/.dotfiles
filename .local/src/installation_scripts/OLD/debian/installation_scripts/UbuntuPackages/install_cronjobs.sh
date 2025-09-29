#https://stackoverflow.com/questions/4880290/how-do-i-create-a-crontab-through-a-script
(crontab -l 2>/dev/null; echo "*/5 * * * * /bin/sh /home/kblack0610/.local/bin/installation_scripts/linux/ubuntu/post_installation_scripts/UbuntuPackages/update_wallpaper.sh -with args") | crontab -
#also need one for screen manager
(crontab -l 2>/dev/null; echo "* */1 * * * /bin/sh /home/kblack0610/.local/bin/misc/screen_power_manager/screen_power_manager.sh -with args") | crontab -
