# samba

Read-only SMB/CIFS share of the qBittorrent downloads directory, authenticated
as the local user.

| File | Installed as | Purpose |
| --- | --- | --- |
| `smb.conf` | `/etc/samba/smb.conf` | `[downloads]` share, read-only, `valid users = rahul` |
| `setup.sh` | — | idempotent installer / `--check` |

## Apply

```sh
apps/samba/setup.sh --check   # verify, change nothing
apps/samba/setup.sh           # needs root: config, Samba account, boolean, firewall, enable smb
```

`setup.sh` prompts once for a Samba password; use that same password from
Windows. Then browse `\\rmpc\downloads` and log in as `rmpc\rahul`.

## What it does

Everything is done with packages already on the host — no custom unit, no
custom SELinux policy, no ACL surgery:

- **Config**: writes `/etc/samba/smb.conf` (backup at `/etc/samba/smb.conf.orig`)
  and runs the distro's own `smb.service`; an older duplicate
  `/etc/systemd/system/smb.service` is removed if present.
- **Account**: `smbpasswd -a rahul`. Windows refuses guest SMB sessions, so an
  authenticated account is mandatory; the share is not `guest ok`.
- **SELinux**: enables the stock `samba_export_all_ro` boolean. podman's `:z`
  mount labels the downloads directory `container_file_t`, which belongs to
  Samba's `non_security_file_type`, so the stock boolean grants `smbd_t` the
  read access it needs — no `minipc_samba` module.
  - Keep the downloads mount on `:z`, never `:Z`: `:Z` adds MCS categories
    (`s0:cN,cM`) that `smbd`'s `s0` context cannot satisfy.
- **Firewall**: `firewall-cmd --permanent --add-service=samba` (139/445 tcp).

## Verify

```sh
smbclient -L localhost -U rahul    # lists the `downloads` share
smbclient //localhost/downloads -U rahul -c ls
```

## Windows client

Log in as `rmpc\rahul` with the Samba password. If a cached *guest* session
fails, clear it first: `net use \\rmpc\ /delete`.

### Important Note

When directly connecting MiniPC over LAN to desktop, I observed this behaviour where due to DHCP on both machine, different IPs were being assigned to each. 

We can make the minipc act as DHCP server by running the following command:

```
# fetch ethernet interface
nmcli device status

# Set eno1 to auto-assign IPs:
sudo nmcli connection modify "Wired connection 1" ipv4.method shared

# restart
sudo nmcli connection up "Wired connection 1"
```

You can then connect to the samba shared folder on Windows by using the IP or the machine name as follows:
```
\\rmpc.local\

or

# Find IP assigned to ethernet in windows with: ipconfig
\\10.42.0.118\
```

