# shpellcast

Cast your command's output somewhere else.

shpellcast turns any command's live output into a private web page. Pipe a long-running job into it, get a link back, and share that link instead of screenshots or SSH access. The machine running the job installs nothing new.

- **Live.** Output appears as it is printed, progress bars included.
- **Nothing to install on the producer.** Use `nc` or `curl`, which most machines already have.
- **Unguessable links.** Each link carries 128 random bits and no sign-in is required. Treat a link like a password.
- **Expires on its own.** Links last 24 hours after output stops, by default.
- **One binary.** A single static Go program. No database, no accounts.

---

## Using shpellcast

Your team may already run shpellcast. If so, you only need the address and the nc port.

### Send a command's output

With `nc`:

```sh
./deploy.sh 2>&1 | nc shpellcast.godtech.in 9000
```

The link is printed straight away, before any output arrives:

```
https://shpellcast.godtech.in/s/Qx7_a9Lp2mTz4vWn8KeR1g
```

Open it in any browser. Output appears live.

When the command finishes, the stream closes and the page shows a seal with the duration, size and line count. If your `nc` keeps the connection open after its input ends, add `-N` (OpenBSD `nc`) or `-q 0` (traditional `netcat`) so the cast closes when the command does.

With `curl`, which works on any system with curl:

```sh
./backup.sh 2>&1 | curl -fsSN -T - https://shpellcast.godtech.in/ingest
```

### What viewers see

- **Waiting.** "The link is live. Waiting for the first line."
- **Running.** Output flows in as it arrives. A thin green line moves across the top while the cast is live.
- **Quiet.** If nothing arrives for ten seconds, a marker shows how long it has been quiet.
- **Following.** The page follows the newest line. Scroll up to read; press **Jump to live** to return.
- **Finished.** A seal closes the run: `✦ cast complete · 47s · 3.1 KB · 21 lines`.
- **Expired.** "This cast has faded."

Colours from the command are kept. Use **Download raw** for the plain text.

### Tips

- Send both streams with `2>&1` so errors show up too.
- Anyone with the link can read the output. Don't cast secrets, tokens or personal data.
- A link stops accepting new output once its command ends; it can still be viewed until it expires.

---

## Features

| | |
|---|---|
| Ingest | Raw TCP (`nc`) and HTTP streamed upload (`curl`) |
| Viewing | Live stream, ANSI colours, carriage-return progress bars, auto-scroll with pause, viewer count |
| Downloads | Raw text of any cast |
| Links | 128-bit random IDs, no authentication, 24-hour lifetime after output stops (configurable) |
| Memory | Each cast keeps a bounded history in memory (256 KiB by default) |
| Disk | Optional full-output saving, so links survive restarts |
| Operations | `/healthz` endpoint, systemd unit with hardening, Caddy and nginx examples |
| Scale | Hundreds of concurrent casts on a small server; the cap is configurable (10,000 by default) |

## Honest notes

**Strengths**

- Very low overhead: each cast is a goroutine plus a bounded buffer.
- Simple to reason about: one process, one port for nc, one for the web.
- Nothing to install on producing machines.

**Limits**

- Links are bearer secrets. Anyone who has one can read the output.
- Without disk saving, history is kept in memory only. Restarting the service drops running and recent casts.
- The raw download contains only the kept history unless disk saving is on.
- No search, filtering, or multi-user permissions.
- Not an archive. Use a logging system for long-term retention.
- Plain TCP for nc is not encrypted. Use it on trusted networks, or put the nc port behind a VPN or tunnel for sensitive output.

---

## Self-hosting

Run shpellcast on any Linux server with systemd. Ubuntu and Debian are the intended targets. You need a domain name pointing at the server if you want HTTPS.

### Quick start: guided install

On the server:

```sh
curl -fsSL https://raw.githubusercontent.com/shpellcast/shpellcast/v1/install.sh | sudo bash
```

The installer asks a few questions, each with a default:

1. **How people will reach it:** a domain over HTTPS (recommended), or the server's address over plain HTTP for trying it out.
2. **HTTPS tool:** Caddy (recommended, certificates are automatic), nginx, or none if you already have one.
3. **Web port** (default `8080`) and **nc port** (default `9000`).
4. **Link lifetime** (default `24h`).
5. **Disk saving** (default yes), so links survive restarts.

It then shows a plan and asks you to confirm. Nothing changes until you say yes.

Re-running the installer upgrades the binary and keeps your settings.

### Unattended install

For scripts, CI, or configuration management, pass flags and no questions are asked:

```sh
curl -fsSL https://raw.githubusercontent.com/shpellcast/shpellcast/v1/install.sh | sudo bash -s -- \
  --public-url https://shpellcast.godtech.in \
  --proxy caddy \
  --ttl 24h \
  --disk-save \
  --yes
```

| Flag | Meaning | Default |
|---|---|---|
| `--public-url URL` | Address people open. Used in every link. | `http://<server IP>:8080` |
| `--proxy none\|caddy\|nginx` | HTTPS helper to install and configure | `none` |
| `--tcp-port PORT` | Port for nc | `9000` |
| `--http-port PORT` | Port for web pages | `8080` |
| `--ttl DURATION` | Link lifetime after output stops | `24h` |
| `--disk-save` | Keep full output on disk | on |
| `--yes` | Skip the confirmation | off |

Without a terminal and without `--public-url`, the installer uses the server's IP address over HTTP.

### What the installer does

- Downloads the binary for your CPU (`amd64` or `arm64`) from the latest release into `/usr/local/bin/shpellcast`.
- Creates a `shpellcast` system user with no login shell.
- Writes settings to `/etc/shpellcast/shpellcast.env`. Existing files are never overwritten.
- Installs a hardened systemd unit and starts the service.
- With Caddy or nginx, writes a reverse-proxy config and reloads the server. An existing Caddyfile is backed up first.
- If `ufw` is active, opens the needed ports.
- Checks that the service answers before reporting success.

The branch hosts the installer. The latest published GitHub release supplies the executable assets named `shpellcast-linux-amd64` and `shpellcast-linux-arm64`. To install before a release is available, check out the `v1` branch on the server and run this from the repository root with Go 1.22 or newer:

```sh
CGO_ENABLED=0 go build -trimpath -o shpellcast .
sudo bash ./install.sh --binary ./shpellcast
```

### HTTPS

**Caddy** (chosen by the installer, or copy `deploy/Caddyfile.example`):

```
shpellcast.godtech.in {
	reverse_proxy 127.0.0.1:8080 {
		flush_interval -1
	}
}
```

Caddy gets and renews certificates by itself. Ports 80 and 443 must be open to the internet.

**nginx** (copy `deploy/nginx.conf.example`): buffering must stay off, or live output is held back. Add HTTPS with certbot:

```sh
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d shpellcast.godtech.in
```

The nc port is plain TCP and is not handled by the web proxy. Open it on the firewall.

### Settings

Edit `/etc/shpellcast/shpellcast.env`, then run `sudo systemctl restart shpellcast`.

| Variable | Meaning | Default |
|---|---|---|
| `SHPELLCAST_PUBLIC_URL` | Base address used in links | set by installer |
| `SHPELLCAST_HTTP_ADDR` | Web listen address | `127.0.0.1:8080` behind a proxy, `0.0.0.0:8080` otherwise |
| `SHPELLCAST_TCP_ADDR` | nc listen address | `0.0.0.0:9000` |
| `SHPELLCAST_TTL` | Link lifetime after output stops | `24h` |
| `SHPELLCAST_DATA_DIR` | Directory for full output; empty means memory only | `/var/lib/shpellcast` |
| `SHPELLCAST_MAX_STREAMS` | Casts running at once. New ones are refused above this. | `10000` |
| `SHPELLCAST_BUFFER_BYTES` | History kept in memory per cast | `262144` |

Memory use is roughly `SHPELLCAST_MAX_STREAMS × SHPELLCAST_BUFFER_BYTES` in the worst case. With the defaults that is about 2.5 GB, so lower one of them on small servers.

### Operating it

```sh
sudo systemctl status shpellcast        # is it running?
sudo journalctl -u shpellcast -f        # live logs
curl -fsS http://127.0.0.1:8080/healthz # quick health check
```

### Firewall

Open these ports, adjusting for your setup:

- `9000/tcp` for nc
- `80/tcp` and `443/tcp` if you use Caddy or nginx
- `8080/tcp` only if you run with `--proxy none`

### Upgrading

Re-run the installer command. It replaces the binary, keeps your settings, and restarts the service.

### Building from source

Requires Go 1.22 or newer.

```sh
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o shpellcast .
./shpellcast -public-url http://localhost:8080
```

Then send output to `localhost:9000` with `nc`, or open the link it prints.

---

## Project layout

```
main.go          startup, configuration and routes
stream.go        casts: bounded history, live fan-out, expiry, restart recovery
ingest.go        nc listener, curl upload, live event feed, raw download
index.html       landing page
assets/          landing and viewer pages, styles and scripts
install.sh       guided and unattended installer
deploy/          systemd unit and Caddy/nginx examples
```

## Licence

MIT. See [LICENSE](LICENSE).
