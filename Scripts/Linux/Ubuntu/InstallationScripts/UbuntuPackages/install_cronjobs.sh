#https://stackoverflow.com/questions/4880290/how-do-i-create-a-crontab-through-a-script
(crontab -l 2>/dev/null; echo "*/5 * * * * /bin/sh /home/kblack0610/Scripts/Linux/Ubuntu/update_wallpaper.sh -with args") | crontab -

