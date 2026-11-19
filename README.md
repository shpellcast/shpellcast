# shpellcast

Cast your command's output somewhere else.

shpellcast turns any command's live output into a private web page. Pipe a long-running job into it, get a link back, and share that link instead of screenshots or SSH access. Send output with `nc` or `curl` using tools you may already have.

- **Live.** Output appears as it is printed, progress bars included.
- **Nothing to install on the producer.** Use `nc` or `curl`, which most machines already have.
- **Unguessable links.** Each link carries 128 random bits and no sign-in is required. Treat a link like a password.
- **Expires on its own.** Links last 24 hours after output stops, by default.
- **One binary.** A single static Go program. No database, no accounts.

---

## Using shpellcast

Start at the [public shpellcast instance](https://shpellcast.godtech.in/). You can stream immediately with the nc or curl you already have, without a shpellcast install or account. If your team runs its own instance, use its hostname and ports.

### Send a command's output

Append this to a command in your terminal:

```sh
 | nc shpellcast.godtech.in 9696
```

Try it with a sample:

```sh
printf 'Hello from my terminal\n' | nc shpellcast.godtech.in 9696
```

For a deployment script, add `2>&1` before the pipe to include stderr:

```sh
./deploy.sh 2>&1 | nc shpellcast.godtech.in 9696
```

The link is printed straight away, before any output arrives:

```
https://shpellcast.godtech.in/s/<cast-id>
```

Open the URL printed by your command and share it with whoever needs to follow along. Anyone with the link can watch until it expires. Raw nc traffic uses plain TCP. Use curl over HTTPS for encryption in transit and keep sensitive output out of public casts.

When the command finishes, the stream closes and the page shows a seal with the duration, size and line count. If your `nc` keeps the connection open after its input ends, add `-N` (OpenBSD `nc`) or `-q 0` (traditional `netcat`) so the cast closes when the command does.

With `curl`, which works on any system with curl:

```sh
./backup.sh 2>&1 | curl -fsSN -T - https://shpellcast.godtech.in/ingest
```

If you have the shpellcast binary on the producer, the optional `cast` command adds a brief terminal flourish when it opens your link:

```sh
./deploy.sh 2>&1 | shpellcast cast --server https://shpellcast.godtech.in
```

The link is printed immediately on stdout while the command continues to stream. When stdout and stderr both go to a terminal, stderr shows the spell, the link lifetime, and a reminder that anyone with the link can watch. Use `--quiet` for a plain URL or `--json` for one object with `url` and, when the server supplies it, `ttl` (for example, `"24h0m0s"`). The cast process keeps running until the upload ends. Set `SHPELLCAST_PUBLIC_URL` to supply the server address by default. Existing `curl` and `nc` commands still return a single plain URL.

### What viewers see

- **Waiting.** "The portal is open. Waiting for output."
- **Running.** Output flows in along a muted green margin while the cast is live.
- **Quiet.** If nothing arrives for ten seconds, a marker shows how long it has been quiet.
- **Following.** The page follows the newest line. Scroll up to read; press **Jump to live** to return.
- **Finished.** A seal closes the run: `✦ Cast sealed · 47s · 3.1 KB · 21 lines`.
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

The installer reads from your terminal, including when the script is piped through `curl`. It asks:

1. **How people will reach it.** HTTPS is the default. Enter your public DNS name or full origin. For a plain HTTP trial you can accept the detected local IPv4 address and web port.
2. **Reverse proxy.** Caddy gets HTTPS certificates automatically. nginx needs a separate certificate step. Choose `external` if your own proxy runs on this server. Choose `none` for direct HTTP or when a proxy on another host handles HTTPS.
3. **Web port** (default `8080`) and **nc port** (default `9696`).
4. **Link lifetime** (default `24h`).
5. **Disk saving** (default yes), so links survive restarts.

Review the plan and answer `y` to apply it. The completion screen reports local service health, the public URL, and status and log commands. For HTTPS, run the printed public health check once DNS and certificates are ready.

Re-running the installer upgrades the binary and restarts the service using your saved settings and proxy configuration. Set `SHPELLCAST_REDUCED_MOTION=1` to disable terminal animation and `NO_COLOR=1` to disable ANSI colors in the installer and cast client. When using `sudo`, pass these through with `sudo env SHPELLCAST_REDUCED_MOTION=1 NO_COLOR=1 bash`.

### Unattended install

For scripts, CI, or configuration management, pass flags and no questions are asked:

```sh
curl -fsSL https://raw.githubusercontent.com/shpellcast/shpellcast/v1/install.sh | sudo bash -s -- \
  --public-url https://cast.example.com \
  --proxy caddy \
  --ttl 24h \
  --disk-save \
  --yes
```

| Flag | Meaning | Default |
|---|---|---|
| `--public-url URL` | HTTP(S) origin people open. Used in every link. | Required for fresh unattended installs |
| `--proxy none\|external\|caddy\|nginx` | Web proxy setup. `external` binds the HTTP backend to loopback for your own local proxy. | `none` |
| `--tcp-port PORT` | Port for nc | `9696` |
| `--http-port PORT` | Port for web pages | `8080` |
| `--ttl DURATION` | Link lifetime after output stops | `24h` |
| `--disk-save` / `--no-disk-save` | Keep full output on disk or keep recent output in memory only | on |
| `--binary PATH` | Use a locally built Linux binary | download from the release |
| `--yes` | Run without any prompts | off |

A fresh install without a terminal requires `--public-url`. Include the web port in the URL for direct HTTP on a nonstandard port, for example `--public-url http://192.168.1.10:8080`. An unattended upgrade uses the saved config and needs no URL flag. To change saved settings, edit the configuration file. If managed proxy setup failed, re-run with `--proxy caddy` or `--proxy nginx` to retry using the saved address and ports.

### What the installer does

- Downloads the binary for your CPU (`amd64` or `arm64`) from the latest release into `/usr/local/bin/shpellcast`.
- Creates a `shpellcast` system user with no login shell.
- Writes settings to `/etc/shpellcast/shpellcast.env`. Existing files are never overwritten.
- Installs a hardened systemd unit and starts the service.
- On a fresh install with a managed proxy, adds a Caddy site to the existing config or creates an nginx site file, then reloads the proxy. An existing Caddyfile is backed up before applying changes.
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
cast.example.com {
	reverse_proxy 127.0.0.1:8080 {
		flush_interval -1
	}
}
```

Caddy gets and renews certificates by itself. Ports 80 and 443 must be open to the internet.

**nginx** (installed by the wizard, or copy `deploy/nginx.conf.example`): disable request and response buffering for live streaming. Add HTTPS with certbot:

```sh
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d cast.example.com
```

**Your own proxy** (`--proxy external`): forward to `http://127.0.0.1:8080` or the web port you selected. Configure TLS on the proxy and disable request and response buffering. The `nc` port is a separate plain TCP listener.

### Settings

Edit `/etc/shpellcast/shpellcast.env`, then run `sudo systemctl restart shpellcast`.

| Variable | Meaning | Default |
|---|---|---|
| `SHPELLCAST_PUBLIC_URL` | Base address used in links | set by installer |
| `SHPELLCAST_HTTP_ADDR` | Web listen address | `127.0.0.1:8080` behind a proxy, `0.0.0.0:8080` otherwise |
| `SHPELLCAST_TCP_ADDR` | nc listen address | `0.0.0.0:9696` |
| `SHPELLCAST_TTL` | Link lifetime after output stops | `24h` |
| `SHPELLCAST_DATA_DIR` | Directory for full output; empty means memory only | `/var/lib/shpellcast` |
| `SHPELLCAST_MAX_STREAMS` | Casts running at once. New ones are refused above this. | `10000` |
| `SHPELLCAST_BUFFER_BYTES` | History kept in memory per cast | `262144` |
| `SHPELLCAST_INDEX_HOME` | Set to `true` to allow search indexing of the homepage | `false` |

Memory use is roughly `SHPELLCAST_MAX_STREAMS × SHPELLCAST_BUFFER_BYTES` in the worst case. With the defaults that is about 2.5 GB, so lower one of them on small servers.

Enable `SHPELLCAST_INDEX_HOME` on the deployment that serves your official public homepage. After a restart, check the public URL with `curl -I https://cast.example.com/` and confirm that your proxy also allows homepage indexing. Cast pages, event feeds, and raw downloads keep their `noindex` directive. Anyone with a cast link can still read its output.

### Operating it

```sh
sudo systemctl status shpellcast        # is it running?
sudo journalctl -u shpellcast -f        # live logs
curl -fsS http://127.0.0.1:8080/healthz # quick health check
```

### Firewall

Open these ports, adjusting for your setup:

- `9696/tcp` for nc
- `80/tcp` and `443/tcp` for Caddy, nginx, or your own public web proxy as configured
- `8080/tcp` only if you run with `--proxy none`

### Upgrading

Re-run the installer command. It replaces the binary, keeps your settings, and restarts the service.

### Building from source

Requires Go 1.22 or newer.

```sh
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o shpellcast .
./shpellcast -public-url http://localhost:8080
```

Then send output to `localhost:9696` with `nc`, or open the link it prints.

---

## Project layout

```
main.go          startup, configuration and routes
stream.go        casts: bounded history, live fan-out, expiry, restart recovery
ingest.go        nc listener, curl upload, live event feed, raw download
cast.go          optional terminal client for HTTP uploads
index.html       landing page
assets/          landing and viewer pages, styles and scripts
install.sh       guided and unattended installer
deploy/          systemd unit and Caddy/nginx examples
```

## Licence

MIT. See [LICENSE](LICENSE).
