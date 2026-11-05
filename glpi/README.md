# GLPI on Docker (UBU01)

GLPI, the lab's IT service desk (tickets, knowledge base, asset inventory), runs as two Docker containers on **UBU01** (`10.10.10.20`).

```
Browser ──http:80──▶ [ glpi container ] ──3306 (internal only)──▶ [ db container: MySQL 8.4 ]
                          │                                              │
                     glpi_data volume                             ./storage/mysql
                     (config, uploads)                            (database files)
```

---

## Key concepts

| Term | Simple meaning |
|---|---|
| **Docker** | Runs applications in isolated, self-contained packages, so they don't clash with each other or with the server |
| **Image** | A ready-made, read-only package of an application and everything it needs (e.g. `glpi/glpi`, `mysql:8.4`) |
| **Container** | A running copy of an image. It can be stopped, deleted and recreated without losing data stored in volumes |
| **Volume** | Storage that lives **outside** the container, so data survives updates and rebuilds |
| **Docker Compose** | Describes several containers and how they connect, in one file (`docker-compose.yml`) |
| **`.env` file** | Holds secrets (the DB password) separately, so the compose file can be shared publicly |

**Why Docker for GLPI?**
- **Reproducible:** this folder rebuilds the service exactly.
- **Isolated:** GLPI's PHP and MySQL won't conflict with other tools later added to UBU01 (e.g. Zabbix).
- **Easy upgrades and rollback:** change an image version.
- **The images come from the GLPI and MySQL projects themselves.**

---

## Files

| File | Purpose | In Git? |
|---|---|---|
| `docker-compose.yml` | The recipe: which containers, ports, volumes, health check | ✅ |
| `.env.example` | Template showing the settings needed, with fake values | ✅ |
| `.env` | Real settings, including the DB password (`chmod 600`) | ❌ never |
| `storage/mysql/` | Database files on UBU01 | ❌ never |

### `.env.example`
```
GLPI_DB_HOST=db
GLPI_DB_NAME=glpi
GLPI_DB_USER=glpi
GLPI_DB_PASSWORD=change-me
```
`GLPI_DB_HOST=db` is the **service name** from the compose file. Containers in the same compose project find each other by service name, through Docker's internal DNS.

### Key lines in `docker-compose.yml`

| Line | Meaning |
|---|---|
| `restart: unless-stopped` | Start automatically after a reboot or crash, unless stopped by hand |
| `glpi_data:/var/glpi` | **Named volume:** Docker creates and owns it with correct permissions |
| `./storage/mysql:/var/lib/mysql` | **Bind mount:** a folder on UBU01, mapped into the container |
| `depends_on … service_healthy` | Start GLPI only after MySQL passes its health check |
| `ports: "80:80"` | Publish GLPI on UBU01's port 80. MySQL has **no** published port, so only GLPI can reach it |
| `healthcheck` | Docker regularly checks that MySQL answers, and marks it `healthy` |

---

## Deploy (from scratch)
```bash
curl -fsSL https://get.docker.com | sudo sh     # install Docker (official script)
sudo usermod -aG docker $USER                   # run docker without sudo (= root-level access)
# log out and back in
mkdir -p ~/glpi && cd ~/glpi                    # put docker-compose.yml here
cp .env.example .env && nano .env && chmod 600 .env   # set a real password
docker compose up -d                            # download images, start in background
```
Then open `http://10.10.10.20` → install wizard → SQL server **`db`** → database **`glpi`**.

---

## Everyday commands (run in `~/glpi`)

| Command | What it does |
|---|---|
| `docker compose ps` | Status of both containers (expect `Up`, db `healthy`) |
| `docker compose logs glpi \| tail -20` | Last 20 log lines: **the first place to look** when something fails |
| `docker compose logs -f glpi` | Follow logs live (Ctrl+C to stop) |
| `docker compose restart glpi` | Restart only GLPI |
| `docker compose up -d` | Create or start everything (safe to re-run) |
| `docker compose stop` | Stop the containers, keeping them (they won't auto-start until `up -d`) |
| `docker compose down` | Stop **and remove** the containers; **data in volumes is kept** |
| `docker compose down -v` | ⚠️ Also **deletes the volumes**: GLPI data is lost |
| `docker compose exec glpi bash` | Open a shell **inside** the GLPI container |
| `docker volume ls` | List volumes (`glpi_glpi_data`) |

**Shutting down UBU01:** `sudo poweroff` is enough. Docker stops both containers cleanly, and `restart: unless-stopped` brings them back at the next boot.

---

## Issues met during deployment

| Symptom | Cause | Fix |
|---|---|---|
| GLPI `Restarting`, log: `mkdir: cannot create directory '/var/glpi/config': Permission denied` | A **bind mount** folder (`./storage/glpi`) was created by Docker as `root`; GLPI runs as a limited user and couldn't write | Use a **named volume** (`glpi_data`); Docker sets correct ownership |
| Install wizard: `Connection refused (HY000/2002)` | Wrong SQL server: `localhost`/`10.10.10.20` don't host MySQL from GLPI's point of view | Use the service name **`db`** |
| Admin login failed after a password reset done directly in the database | Editing the database bypassed GLPI's own password handling | Rebuilt GLPI (it held no data yet); passwords are now changed only through the GLPI interface |

```bash
docker compose exec glpi getent hosts db                                             # can GLPI resolve the database?
docker compose exec glpi bash -c 'echo > /dev/tcp/db/3306 && echo "port 3306 open"'  # can it reach it?
```

---

## Security notes (lab)
- `.env` is `chmod 600` (owner-only) and excluded from Git.
- MySQL isn't exposed outside Docker; only GLPI can talk to it.
- Default GLPI accounts: `glpi` and `tech` have new passwords; `normal` and `post-only` are disabled.
- Inventory authentication is off, which is acceptable on an isolated lab network (see `docs/decisions/glpi-security.md`).
- **Known gap (P4):** Docker-published ports bypass Ubuntu's `ufw` firewall; GLPI runs on plain HTTP.
