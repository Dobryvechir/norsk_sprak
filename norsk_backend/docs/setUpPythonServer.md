# Setting up the Python server (Linux)

How the backend runs on the production server `root@91.190.155.187`
(Ubuntu 26.04, systemd 259), and every step done to set it up so that it
starts automatically after a reboot and restarts after a crash.

## Layout on the server

```
/var/www/movna/
├── .env               # configuration (secrets) — read from this folder
├── .env.bak           # backup of .env before the APP_SECRET fix
├── app/               # the backend code (copy of norsk_backend/app)
├── data/              # DATA_DIR: metadata, local audio, temp files
├── venv/              # Python virtual environment (Python 3.14)
├── requirements.txt
├── app.log            # server output (stdout + stderr)
├── k.sh               # restarts the service
└── k.sh.bak           # the old nohup-based start script
```

The app listens on `127.0.0.1:8500` (localhost only, so a reverse proxy
such as nginx must forward public traffic to it).

## Step 1 — Fix the `.env` file

**Problem:** the app crashed at startup with
`RuntimeError: APP_SECRET must be at least 32 characters`.

**Cause:** the server's `.env` contained `API_SECRET=…` instead of
`APP_SECRET=…`. The app only reads `APP_SECRET` (see `app/config.py`),
so it saw an empty secret.

`.env` is read from the **current working directory** of the process
(`env_file=".env"` in `app/config.py`), so it must be in
`/var/www/movna/`, and the app must be started from that folder.

**Done:**

```bash
cd /var/www/movna
cp .env .env.bak
sed -i "s/^API_SECRET=/APP_SECRET=/" .env
```

Note: the server `.env` also contains `CLIENT_ID` and `CLIENT_S`, which the
app does not use (they are ignored).

## Step 2 — Create a systemd service

Before, the app was started by `k.sh` with `nohup … &`. That process does
not survive a reboot and is not restarted if it crashes. systemd handles both.

Created `/etc/systemd/system/movna.service`:

```ini
[Unit]
Description=Movna backend (FastAPI / uvicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/var/www/movna
ExecStart=/var/www/movna/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8500
Restart=always
RestartSec=3
StandardOutput=append:/var/www/movna/app.log
StandardError=append:/var/www/movna/app.log

[Install]
WantedBy=multi-user.target
```

What the important lines do:

| Setting | Purpose |
|---|---|
| `WorkingDirectory=/var/www/movna` | The app finds `.env` and `./data` here. |
| `ExecStart=…/venv/bin/uvicorn …` | Same command as the old `k.sh`, using the venv. |
| `Restart=always` + `RestartSec=3` | Restart 3 seconds after any exit or crash. |
| `StandardOutput/StandardError=append:…` | Keep logging to `app.log` as before. |
| `WantedBy=multi-user.target` | Start automatically at boot (once enabled). |

The service runs as `root`, like the old script did.

Checked the file for errors:

```bash
systemd-analyze verify /etc/systemd/system/movna.service
```

## Step 3 — Replace the old process with the service

```bash
kill <pid of the old nohup uvicorn>      # free port 8500
systemctl daemon-reload                  # load the new unit file
systemctl enable --now movna             # start now + start at every boot
```

## Step 4 — Verify

```bash
systemctl is-enabled movna     # -> enabled   (starts after reboot)
systemctl is-active movna      # -> active
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8500/docs   # -> 200
```

**Crash test:** killed the process hard and checked that systemd brought it
back:

```bash
kill -9 $(systemctl show -p MainPID --value movna)
sleep 6
systemctl is-active movna      # -> active (new PID)
```

Result: PID 9671 was killed, systemd started PID 9735, `/docs` returned 200.

The server was **not** rebooted as a test. `is-enabled = enabled` is what
makes it start at boot. To confirm, run `reboot`, wait, then run
`systemctl status movna`.

## Step 5 — Update `k.sh`

The old `k.sh` (saved as `k.sh.bak`) started a second uvicorn with `nohup`,
which would now fail because the service already uses port 8500. It now
restarts the service instead:

```sh
#!/bin/sh
# The app runs as the systemd service "movna" (see /etc/systemd/system/movna.service).
systemctl restart movna
systemctl --no-pager status movna | head -5
```

So the usual routine still works: `cd /var/www/movna && ./k.sh`.

## Everyday commands

```bash
systemctl status movna          # is it running? recent log lines
systemctl restart movna         # restart (e.g. after uploading new code or editing .env)
systemctl stop movna            # stop (it stays stopped until start/reboot)
systemctl start movna
systemctl disable movna         # do not start at boot any more
tail -f /var/www/movna/app.log  # follow the app output
journalctl -u movna -n 50       # systemd's own messages (start/stop/restart)
```

## Deploying new code

From Windows (in `norsk_backend`):

```powershell
scp -r .\app root@91.190.155.187:/var/www/movna/
scp .\requirements.txt root@91.190.155.187:/var/www/movna/
ssh root@91.190.155.187 "cd /var/www/movna && ./venv/bin/pip install -r requirements.txt && systemctl restart movna"
```

`.env` is not in git and is not copied by `scp -r .\app`. Edit it on the
server directly, then run `systemctl restart movna`.

## Recommended follow-ups (not done yet)

- Tighten permissions: `/var/www/movna`, `app` and `data` are `drwx---rwx`
  (any user can read and write). Suggested:
  `chmod 700 /var/www/movna /var/www/movna/app /var/www/movna/data && chmod 600 /var/www/movna/.env`.
- Run the service as a dedicated non-root user (`User=movna` in the unit
  file, with that user owning `/var/www/movna`).
- Set up log rotation for `app.log` (for example a `/etc/logrotate.d/movna`
  entry with `copytruncate`), because `append:` lets it grow forever.
