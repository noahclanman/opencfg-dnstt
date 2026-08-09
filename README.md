# OpenCFG DNSTT Manager

A simple DNSTT / SlowDNS manager for SSH, Dropbear, Xray, V2Ray, and 3x-ui.

Made for people who are tired of manually reinstalling and editing DNSTT every time they set up a new VPS.

This script installs and manages DNSTT using its own systemd service and keeps away from your existing SSH, Webmin, 3x-ui, Xray, Nginx, OpenVPN, and firewall configuration.

> Developed by **Shinusterben / OpenCFG**

---

## Features

- Install and configure DNSTT
- SSH / Dropbear backend support
- Xray / V2Ray / 3x-ui backend support
- Custom TCP backend support
- Change backend port without reinstalling
- Change tunnel domain and nameserver
- Generate DNSTT server keys
- Regenerate keys from the menu
- Show public key and current configuration
- Start, stop, restart, and check DNSTT status
- View DNSTT logs
- Rebuild DNSTT from upstream source
- Runs using a dedicated systemd service
- Automatic startup after reboot
- Direct UDP port `53` listener

---

## Safe for Existing VPN Setups

This manager was designed to avoid breaking existing VPS configurations.

It does **not** automatically modify:

- `iptables`
- `ip6tables`
- `nftables`
- `ufw`
- `firewalld`
- `/etc/rc.local`
- `/etc/resolv.conf`
- `systemd-resolved`
- SSH configuration
- Dropbear configuration
- Webmin
- 3x-ui
- Xray
- Nginx
- OpenVPN

It also does not automatically restart those services.

The only service managed by this script is:

```bash
opencfg-dnstt.service
```

OpenCFG also keeps its own DNSTT binary under `/usr/local/lib/opencfg-dnstt/`. It does not adopt or delete `/usr/local/bin/dnstt-server` from another SlowDNS/DNSTT installer.

---

## How It Works

DNSTT listens directly on:

```text
UDP 53
```

and forwards the tunnel connection to your selected local TCP service.

Example for Xray / V2Ray:

```text
DNS Client
    |
    v
UDP 53
    |
    v
DNSTT
    |
    v
127.0.0.1:443
    |
    v
Xray / V2Ray
```

Example for SSH:

```text
DNS Client
    |
    v
UDP 53
    |
    v
DNSTT
    |
    v
127.0.0.1:22
    |
    v
OpenSSH
```

You can also point it to Dropbear or another TCP service.

---

## Requirements

Recommended:

- Debian 11+
- Debian 12
- Debian 13
- Ubuntu 22.04+
- Ubuntu 24.04+
- Root access
- Public IPv4 address
- A domain you control
- UDP port `53` available on the VPS
- `amd64` / `x86_64` or `arm64` / `aarch64` CPU

The installer currently uses `apt-get` and automatically bootstraps a private Go toolchain for supported CPU architectures.

---

## Installation

Download the script:

```bash
wget https://raw.githubusercontent.com/noahclanman/opencfg-dnstt/main/opencfg-dnstt.sh
```

Give it permission:

```bash
chmod +x opencfg-dnstt.sh
```

Run it:

```bash
sudo ./opencfg-dnstt.sh
```

After installation, you can open the manager anytime using:

```bash
opencfg-dnstt
```

---

## Menu

```text
╔════════════════════════════════════════════════════════════╗
║                 OpenCFG DNSTT Manager                     ║
║                  by Shinusterben / OpenCFG                 ║
╚════════════════════════════════════════════════════════════╝

[01] Install / Reconfigure DNSTT
[02] Show configuration + public key
[03] Change backend (SSH / V2Ray / custom)
[04] Change tunnel domain / NS
[05] Start DNSTT
[06] Restart DNSTT
[07] Stop DNSTT
[08] Service status
[09] View recent logs
[10] Regenerate DNSTT keys
[11] Rebuild official DNSTT from source
[12] DNS setup help
[13] Uninstall OpenCFG DNSTT
[00] Exit
```

---

## V2Ray / Xray / 3x-ui Setup

If your Xray inbound is running on:

```text
443
```

select:

```text
2) Xray / V2Ray / 3x-ui
```

Then use:

```text
Backend host: 127.0.0.1
Backend port: 443
```

Example:

```text
Tunnel domain: dns.example.com
Nameserver: ns.example.com
Backend: 127.0.0.1:443
```

DNSTT will receive DNS tunnel traffic on UDP `53` and forward it to Xray on TCP `443`.

Your Xray configuration does not need to be moved to another port just because DNSTT uses UDP `53`.

TCP `443` and UDP `53` are separate ports/protocols.

---

## SSH Setup

For OpenSSH:

```text
Backend host: 127.0.0.1
Backend port: 22
```

For Dropbear, use your Dropbear port.

Example:

```text
Backend host: 127.0.0.1
Backend port: 550
```

Backend hostnames, IPv4, and IPv6 literals are supported. IPv6 addresses are automatically formatted correctly as `[address]:port` when passed to DNSTT.

---

## DNS Configuration

Example VPS:

```text
VPS IP:        203.0.113.10
NS hostname:   ns.example.com
Tunnel domain: dns.example.com
```

Create these DNS records:

```text
Type    Name               Value
A       ns.example.com     203.0.113.10
NS      dns.example.com    ns.example.com
```

The nameserver hostname should normally be outside the delegated tunnel subdomain.

Good:

```text
Tunnel: dns.example.com
NS:     ns.example.com
```

Avoid:

```text
Tunnel: dns.example.com
NS:     ns.dns.example.com
```

---

## Cloudflare

If your domain uses Cloudflare, the nameserver A record should be:

```text
DNS Only
```

Do not proxy it through the Cloudflare orange cloud.

Example:

```text
ns.example.com -> VPS IP
Proxy Status: DNS Only
```

---

## Firewall / Security Group

The script intentionally does **not** create firewall rules.

You need to allow:

```text
UDP 53
```

in your VPS provider firewall or security group.

Examples include:

- AWS Security Groups
- Google Cloud Firewall
- Oracle Cloud Security Lists
- DigitalOcean Cloud Firewall
- Vultr Firewall
- Hetzner Firewall
- Contabo firewall rules

Do not blindly flush or replace your existing firewall rules just to make DNSTT work.

---

## Useful Commands

Open manager:

```bash
opencfg-dnstt
```

Show configuration:

```bash
opencfg-dnstt --info
```

Start:

```bash
opencfg-dnstt --start
```

Stop:

```bash
opencfg-dnstt --stop
```

Restart:

```bash
opencfg-dnstt --restart
```

Status:

```bash
opencfg-dnstt --status
```

Logs:

```bash
opencfg-dnstt --logs
```

You can also use systemd directly:

```bash
systemctl status opencfg-dnstt
```

```bash
systemctl restart opencfg-dnstt
```

```bash
journalctl -u opencfg-dnstt -f
```

---

## Configuration Files

Main configuration:

```text
/etc/opencfg-dnstt/config
```

Private key:

```text
/etc/opencfg-dnstt/server.key
```

Public key:

```text
/etc/opencfg-dnstt/server.pub
```

DNSTT binary (owned only by OpenCFG):

```text
/usr/local/lib/opencfg-dnstt/dnstt-server
```

Manager:

```text
/usr/local/sbin/opencfg-dnstt
```

Systemd service:

```text
/etc/systemd/system/opencfg-dnstt.service
```

---

## Port 53 Already in Use

Check UDP port `53`:

```bash
ss -lunp | grep ':53'
```

If another program is using the same IP on UDP `53`, OpenCFG DNSTT will not automatically kill or modify that service.

This is intentional.

Find the conflict first and decide which service should own UDP `53`.

---

## Important

DNSTT is only the transport layer.

Your backend must already be working.

For example, if you configure:

```text
127.0.0.1:443
```

something must actually be listening on TCP port `443`.

Check:

```bash
ss -lntp | grep ':443'
```

For SSH:

```bash
ss -lntp | grep ':22'
```

---

## Uninstall

Open:

```bash
opencfg-dnstt
```

and select:

```text
[13] Uninstall OpenCFG DNSTT
```

The uninstaller removes only OpenCFG DNSTT files and its service.

It does not remove your:

- SSH server
- Dropbear
- Xray
- V2Ray
- 3x-ui
- Webmin
- Nginx
- OpenVPN
- firewall rules

---

## DNSTT

This project uses the open-source DNSTT implementation by David Fifield.

Official project:

```text
https://www.bamsoftware.com/software/dnstt/
```

DNSTT source:

```text
https://www.bamsoftware.com/git/dnstt.git
```

---

## Disclaimer

Use this project only on servers, domains, and networks you own or have permission to manage.

No firewall configuration is automatically applied by this project. VPS providers and networks may have their own restrictions on UDP port `53`, DNS tunneling, or related traffic.

---

## OpenCFG

OpenCFG DNSTT Manager  
by **Shinusterben / OpenCFG**
