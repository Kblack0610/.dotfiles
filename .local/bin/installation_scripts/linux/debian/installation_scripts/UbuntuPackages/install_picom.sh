#use xcompmgr now

#this might work below, but you can just insall from apt
sudo apt install picom
# Debian specific command. The next few commands are for all distros
#sudo apt install libxext-dev libxcb1-dev libxcb-damage0-dev libxcb-xfixes0-dev libxcb-shape0-dev libxcb-render-util0-dev libxcb-render0-dev libxcb-randr0-dev libxcb-composite0-dev libxcb-image0-dev libxcb-present-dev libxcb-xinerama0-dev libxcb-glx0-dev libpixman-1-dev libdbus-1-dev libconfig-dev libgl1-mesa-dev  libpcre2-dev  libevdev-dev uthash-dev libev-dev libx11-xcb-dev

# clone the project and go into it
#git clone https://github.com/yshui/picom && cd picom

# Use the meson build system (written in python), to make a ninja build 
#meson --buildtype=release . build

# Use the ninja build file to proceed
#ninja -C build

# Copy the resultant binary into PATH
#cp build/src /usr/local/bin

# Run picom in the background (this command can be added to the autostart)
picom & 
