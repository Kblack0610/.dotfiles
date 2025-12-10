# Printing Setup (CUPS + Network Discovery)

Setup for printing to network printers (e.g., Brother MFC-J1360DW) on Arch Linux.

## Quick Setup

```bash
# Install packages
sudo pacman -S cups cups-pdf avahi nss-mdns

# Enable services
sudo systemctl enable --now cups avahi-daemon

# Configure mDNS in nsswitch.conf
sudo perl -i -pe 's/^(hosts:\s+mymachines)(?!\s+mdns_minimal)/$1 mdns_minimal [NOTFOUND=return]/' /etc/nsswitch.conf

# Restart services
sudo systemctl restart avahi-daemon cups
```

## Packages

| Package     | Purpose                                      |
|-------------|----------------------------------------------|
| cups        | Common Unix Printing System                  |
| cups-pdf    | Virtual PDF printer                          |
| avahi       | mDNS/DNS-SD service discovery (Bonjour)      |
| nss-mdns    | NSS plugin for mDNS hostname resolution      |

## Configuration

### /etc/nsswitch.conf

The `hosts:` line must include `mdns_minimal [NOTFOUND=return]` for network printer discovery:

```
hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns
```

### Services

```bash
# Check service status
systemctl status cups avahi-daemon

# Restart if needed
sudo systemctl restart cups avahi-daemon
```

## Troubleshooting

### Check for discovered printers
```bash
avahi-browse -a -t | grep -i print
```

### List configured printers
```bash
lpstat -a
```

### CUPS Web Interface
Access at: http://localhost:631

- Administration > Add Printer (to manually add)
- Printers > (select printer) > Print Test Page

### Printer not showing up?

1. Verify services are running:
   ```bash
   systemctl status cups avahi-daemon
   ```

2. Check nsswitch.conf has mDNS configured:
   ```bash
   grep "^hosts:" /etc/nsswitch.conf
   ```

3. Verify printer is on the network:
   ```bash
   avahi-browse -a -t | grep -i print
   ```

4. Restart services:
   ```bash
   sudo systemctl restart avahi-daemon cups
   ```

## Installation Script

This setup is automated in the dotfiles installation:
- `.local/src/installation_scripts/linux/install_arch.sh` - `setup_printing()` function
