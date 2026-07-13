# Mini pin - floating overlay status bar

A second Waybar instance that floats **over** fullscreen windows (RustDesk remote,
games) because it lives on Hyprland's `overlay` layer. It gives an at-a-glance view
of the local machine fleet, AI agents, and timebox, plus one-tap action buttons -
without leaving whatever is fullscreen.

It is separate from the main bar (which runs as the `waybar.service` systemd user
unit). The pin is toggle-on-demand and never autostarts.

## Use

- `Super+Shift+M`  - toggle the pin on/off (restores the last size)
- `Super+Shift+,`  - swap minimal <-> bigger view (also the on-bar chevron / )
- Left-click the machines dots - ssh host picker
- Right-click the machines dots - force a re-probe
- Bigger view buttons:  restow dotfiles,  git pull (dotfiles + notes),
   agent-panel,  ssh picker

## Leader menu (tmux-style prefix)

`Super+A` opens a which-key popup; single keys fire actions; submaps nest 3 deep.
`esc` = up one level, `q` = exit. Defined in `hypr/conf.d/leader.conf`.

```
Super+A                L1 pinbar      t toggle | s size | a agents | h ssh | u utils> | esc/q exit
  u utils              L2 pinbar-utils    r reload | t timebox> | y sync> | g git> | esc back | q exit
    t timebox          L3 pinbar-timebox  p pause | r resume | x stop | o status | s switch | esc back
    y sync             L3 pinbar-sync     d restow dotfiles | n pull notes | esc back | q exit
    g git              L3 pinbar-git      p pull dot+notes | s git status | esc back | q exit
```

Views: **min** = agents + timebox (glance); **big** = + machines/fleet infra, cpu/mem,
action buttons. Swap with the on-bar chevron, `Super+Shift+,`, or leader `s`.

**Swap the leader key:** in `leader.conf`, comment the active bind pair and uncomment
another (Super+A is the default - all left-hand, low accidental-hit risk; Super+;
is right-hand/tmux-ish; Super+Space is comfiest but easiest to fat-finger).

**Add a leaf:** in the target submap add three lines - `bind = , <key>, exec, <cmd>`,
`bind = , <key>, exec, ~/.config/waybar/pin-hint.sh close`, `bind = , <key>, submap, reset`
- then add the key to that level's legend in `pin-hint.sh`.

## Views

- **Minimal** (`config.pin-min`, ~380px): fleet dots + agents + timebox + chevron.
- **Bigger** (`config.pin-full`, ~940px): full labels + cpu/mem + action buttons.

Both are single-row (a Waybar bar is one horizontal row). A multi-row card would
need eww; intentionally out of scope.

## Files

- `machines.sh`      - fleet probe module (`min|full`) + `pick` ssh chooser
- `config.pin-min`   - minimal bar
- `config.pin-full`  - bigger bar
- `pin.sh`           - toggle / resize state machine (`/tmp/waybar-pin.state`)
- `style.css`        - `window#waybar.pin` + `#custom-machines` + button styles
- `hypr/conf.d/keybindings.conf` - the `Super+Shift+M` / `Super+Shift+,` binds
- `hypr/conf.d/rules.conf`       - floats the `floating-term` popup terminals

## Add a machine

Edit the `FLEET` array at the top of `machines.sh`:

```
FLEET=(
    "ssh-alias|shortlabel|longlabel"
    ...
)
```

The alias must exist in `~/.ssh/config`; the host:port is resolved live via
`ssh -G <alias>` and probed with bash `/dev/tcp` behind `timeout 1` (nc-free).

## Add an action button

In `config.pin-full`, add a `custom/act-*` module (static `format` icon + an
`on-click` exec), then list it in `modules-center` and add a matching CSS rule in
`style.css`.
