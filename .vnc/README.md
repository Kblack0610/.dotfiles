# SERVER

### Linux
-- https://askubuntu.com/questions/168878/how-do-i-install-a-vnc-server
```
sudo apt-get install -y x11vnc
x11vnc -storepasswd
```

### Mac

# CLIENT

### Linux
https://remmina.org/how-to-install-remmina/

- NOTE: In order to have H.264 codecs
```
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install org.freedesktop.Platform
flatpak install org.freedesktop.Platform.openh264
flatpak install --user flathub org.remmina.Remmina
flatpak run --user org.remmina.Remmina
```
### Mac

```
brew install --cask vnc-viewer
```
