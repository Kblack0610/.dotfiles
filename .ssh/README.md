# Linux
```
sudo apt install openssh-server
sudo systemctl start ssh
```

# Mac
Use remote login from settings


users:
kblack-homelab (linux): 192.168.1.240
kennethblack (mac): 192.168.1.162

---

# Work / multi-account git setup

Pattern for keeping personal and work git accounts cleanly separated on one
machine without the personal key "leaking" into work auth (and vice-versa).

## Layout

- `~/.ssh/config` (this file's symlinked sibling) — shared, in dotfiles. Has
  `Include ~/.ssh/config.local` at the top.
- `~/.ssh/config.local` — **machine-local**, gitignored. Holds work host
  aliases and any per-machine quirks. Mode `0600`.
- `~/.ssh/id_rsa_nova` — work-only key (RSA 2048 per Nova's onboarding guide).
- `~/.gitconfig` — shared, has `[includeIf "gitdir:~/dev/"]` pointing at
  `~/.gitconfig-work`.
- `~/.gitconfig-work` — **machine-local**, sets work `user.email`. Anything
  cloned under `~/dev/` automatically commits with the work identity.

## Adding a new work host (template for `~/.ssh/config.local`)

```
Host bitbucket-nova
    HostName bitbucket.org
    User git
    IdentityFile ~/.ssh/id_rsa_nova
    IdentitiesOnly yes
```

`IdentitiesOnly yes` is the critical bit — without it ssh-agent offers every
key it has and Bitbucket may auth you as the wrong account.

## Generating the work key

```
ssh-keygen -t rsa -b 2048 -C "kenneth-nova-healix-$(hostname)" -f ~/.ssh/id_rsa_nova
cat ~/.ssh/id_rsa_nova.pub   # add to Bitbucket → Personal settings → SSH keys
```

## Cloning

Use the host alias instead of `bitbucket.org`:

```
cd ~/dev
git clone git@bitbucket-nova:nova-healix/csa-monorepo.git
```

## Verifying

```
ssh -T git@bitbucket-nova                       # should greet your work user
cd ~/dev/csa-monorepo && git config user.email  # should be the work email
```

## On a fresh machine

The dotfiles only carry the `Include` line and the `includeIf` block; the
actual work creds (`config.local`, `id_rsa_nova`, `.gitconfig-work`) are
gitignored and must be regenerated per-machine.

