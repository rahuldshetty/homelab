# samba

Read-only SMB/CIFS share of the qBittorrent downloads directory for Windows
clients. Anonymous (guest) access, with every file operation forced to the
`nobody` user.

| File | Installed as | Purpose |
| --- | --- | --- |
| `smb.conf` | `/etc/samba/smb.conf` | `[downloads]` share, read-only, `force user = nobody` |
| `smb.service` | `/etc/systemd/system/smb.service` | host-level `smbd` unit |
| `setup.sh` | — | idempotent installer / `--check` |

## Apply

```sh
apps/samba/setup.sh --check   # verify, change nothing
apps/samba/setup.sh           # needs root: config, ACLs, firewall, enable smb
```

Then browse `\\<host>\downloads` from Windows.

## Why this is not a `scripts/stack.sh` app

`stack.sh` deploys rootless **containers** as **user** services. `force user =
nobody` requires smbd to run as root (CAP_SETUID), and the Samba package ships a
system unit, so this app is standalone and applied directly.

## Requirements it cannot fix itself

- **DAC**: `$HOME` and `media/downloads` are `0700`. `setup.sh` grants `nobody`
  traverse/read with ACLs (including a default ACL so new downloads inherit it).
- **SELinux**: podman mounts the downloads dir with `:Z`, which labels it
  `container_file_t`. Under SELinux `enforcing` (`getenforce`), `smbd_t` cannot
  read that type, so the share will return access-denied. Options:
  - Label the directory `samba_share_t` and drop `:Z` from the downloads mount in
    `apps/qbittorrent/qbittorrent.container` (then relabel with
    `semanage fcontext`/`restorecon`), **or**
  - keep the podman label and add a small SELinux policy allowing `smbd_t` to
    read `container_file_t`.
  `setup.sh` only warns; pick one during review.
- **Firewall**: allowed by `setup.sh` (`--add-service=samba`, i.e. 139/445 tcp).

## Windows client note

Modern Windows blocks anonymous SMB by default (insecure guest logons). Either
enable guest access on the client, or provide credentials by adding a Samba user
(`smbpasswd -a`) and a `valid users` line. The share as written is anonymous.
