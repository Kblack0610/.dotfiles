# Trader static checks (mypy, ruff)

The trader repo (`~/dev/crypto/freqtrade_trading_attempt`) runs `python -m mypy` and `python -m ruff` from its `package.json`. The Claude stop hook `.claude/hooks/stop-checks.d/20-node-checks.sh` runs them through `pnpm typecheck` and `pnpm lint` on the system python, so the system python needs both modules.

## Quick Setup

```bash
uv pip install --python "$(command -v python)" \
  --target "$(python -c 'import site; print(site.getusersitepackages())')" \
  --upgrade -r ~/dev/crypto/freqtrade_trading_attempt/lab/requirements-dev.txt
python -m mypy --version && python -m ruff --version
```

## Packages

| Package | Source | Purpose |
|---|---|---|
| uv | pacman (when not already on PATH) | installs into the externally managed system python |
| mypy, ruff | trader `lab/requirements-dev.txt` (pinned) | typecheck and lint; CI installs the same file |

## Configuration

The pins go into the user site-packages (`~/.local/lib/python3.X/site-packages`), which the system python reads with no venv. The versions are read from the trader repo's own file, never copied here, so a bump there is picked up on the next install run.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `/usr/bin/python: No module named mypy` in the stop hook | Run the Quick Setup block, or `setup_trader_checks` |
| Hook passes locally but CI lint fails | A pin moved in `lab/requirements-dev.txt`; rerun the install, it upgrades to the pin |
| After a python minor upgrade the modules are gone | The user site path changes with the version; rerun the install |
| Checkout lives elsewhere | Set `TRADER_DIR=<path>` before running the installer |

## Installation Script

`setup_trader_checks()` in `.local/src/installation_scripts/linux/install_arch.sh`, step `dev` in `install_all()`.
