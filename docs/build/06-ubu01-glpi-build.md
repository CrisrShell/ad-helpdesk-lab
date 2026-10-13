# 1.3: UBU01 + GLPI

**Goal:** an Ubuntu server (UBU01) that hosts **GLPI**, the lab's IT service desk: tickets, knowledge base and asset inventory.

**Before starting:** make sure **EDGE01** (internet) and **DC01** (DNS) are running. Start CL01 only for the agent stage.

| Item | Value |
|---|---|
| Hostname | `ubu01` (FQDN `ubu01.ad.nebula.internal`) |
| IP | `10.10.10.20/24` · gateway `10.10.10.254` · DNS `10.10.10.10` |
| GLPI URL | `http://10.10.10.20` |

---

## A. Create the VM (VMware)
- Choose **Custom**, then **"I will install the OS later"**.
- Select **Ubuntu 64-bit**.

| Setting | Value |
|---|---|
| Name / location | `UBU01` / `Documents\VMs\UBU01` |
| CPU / RAM | 1 × 2 cores / 2048 MB (raise to 4 GB in P4) |
| Network | Custom → **VMnet10** |
| Disk | 40 GB, thin, single file |
| Hardware | Attach the Ubuntu Server 24.04 ISO; remove sound, printer and USB |

**Hardware clock fix (do this before first boot).** Open `Documents\VMs\UBU01\UBU01.vmx` in Notepad and add at the end:
```
rtc.diffFromUTC = "0"
```
VMware starts a VM's hardware clock at the laptop's **local** time, but Linux reads it as **UTC**. Without this line, Ubuntu runs an hour fast during British Summer Time (see KB 02). Add it to every Linux VM.

---

## B. Install Ubuntu Server

| Installer screen | Choice | Why |
|---|---|---|
| Install type | Ubuntu Server (not minimized) | Includes the standard admin tools |
| Network → `ens33` → Edit IPv4 → Manual | Subnet `10.10.10.0/24`, Address `10.10.10.20`, Gateway `10.10.10.254`, Name servers `10.10.10.10`, Search domains `ad.nebula.internal` | A server needs a fixed address. DNS points at the DC, like every lab machine |
| Proxy / mirror | Defaults | — |
| Storage | Use entire disk, with LVM | Fine; the installer only gives part of the disk to `/`, which is fixed in C |
| Profile | Server name `ubu01`, your own username and a strong password | Lowercase is the Linux naming convention |
| Ubuntu Pro | Skip | Not needed |
| SSH | ✅ **Install OpenSSH server** | Lets you manage the server from your laptop |
| Featured snaps | **None**. Don't tick Docker | The snap version of Docker behaves differently; use Docker's official packages instead |

Reboot when prompted.

---

## C. First login and preparation

From the laptop (Windows Terminal):
```powershell
ssh <user>@10.10.10.20
```

### Verify the network
```bash
ip -br a                                         # ens33 shows 10.10.10.20/24
resolvectl status | grep -A2 "DNS Servers"       # 10.10.10.10
getent hosts dc01.ad.nebula.internal             # 10.10.10.10 = internal DNS works
curl -sI https://download.docker.com | head -1   # HTTP/2 200 = internet works
```
Use `curl` rather than `ping` to test internet access: VMware NAT doesn't pass ping from VMs (KB 01).

### Use the whole disk
```bash
df -h /                                                   # ~19G: only half the disk is used
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv    # grow the volume into all free space; -r grows the filesystem too
df -h /                                                   # ~38G
```
**LVM** (Logical Volume Manager) lets you resize storage without reinstalling. Ubuntu's installer leaves free space on purpose; this command claims it.

### Time zone and time source
```bash
sudo timedatectl set-timezone Europe/London
```
This Ubuntu uses **chrony** as its time service. Point it at **DC01 only**: every domain member should take its time from the DC, so all machines agree. Kerberos rejects logons when clocks differ by more than 5 minutes.
```bash
grep -rl canonical /etc/chrony/                              # find the file listing Ubuntu's public time servers
sudo mv /etc/chrony/sources.d/<file>.sources{,.disabled}     # disable it (renamed, easy to undo)
echo 'server 10.10.10.10 iburst' | sudo tee /etc/chrony/sources.d/dc01.sources
sudo chronyc reload sources
chronyc sources                                              # DC01 listed; '^*' = selected and syncing
timedatectl                                                  # "System clock synchronized: yes"
```
`^?` next to DC01 means chrony doesn't trust it yet. That happens while DC01 itself has no external time (for example, on eduroam, where NTP is blocked; KB 01).

### Patch
```bash
sudo apt update && sudo apt -y full-upgrade     # refresh the package list, then install all updates
sudo reboot                                     # applies a new kernel if one was installed
```

---

## D. Register UBU01 in DNS (on DC01)
Windows machines add themselves to the domain's DNS automatically; Linux doesn't. Add the records by hand:
```powershell
Add-DnsServerResourceRecordA -ZoneName ad.nebula.internal -Name ubu01 -IPv4Address 10.10.10.20 -CreatePtr
Resolve-DnsName ubu01.ad.nebula.internal     # name → 10.10.10.20 (A record)
Resolve-DnsName 10.10.10.20                  # 10.10.10.20 → name (PTR record, reverse lookup)
```

---

## E. Install Docker
```bash
curl -fsSL https://get.docker.com | sudo sh     # Docker's official install script (engine + Compose plugin)
sudo usermod -aG docker $USER                   # let your user run docker without sudo
exit                                            # log out and back in so the change applies
```
```bash
docker run --rm hello-world                     # "Hello from Docker!" = working
docker compose version                          # Docker Compose v2.x
```
Membership of the `docker` group is effectively **root access**. Only give it to administrators.

---

## F. Deploy GLPI

### Why Docker?
GLPI is a **web application**: its interface is the web page you open in a browser. It needs a web server, PHP and a database to run. Docker delivers all of that as ready-made **images**, published by the GLPI project itself:

| Term | Meaning |
|---|---|
| **Image** | A packaged, read-only template (GLPI + PHP + web server) |
| **Container** | A running copy of an image, isolated from the rest of the server |
| **Volume** | Storage kept outside the container, so data survives updates and rebuilds |
| **Compose file** | A recipe describing which containers to run and how they connect |

Why this suits the lab: one file rebuilds the whole service, upgrades are a version change, and GLPI won't clash with Zabbix later on the same server.

### 1. Database settings: `.env`
```bash
mkdir -p ~/glpi && cd ~/glpi
nano .env
```
```
GLPI_DB_HOST=db
GLPI_DB_NAME=glpi
GLPI_DB_USER=glpi
GLPI_DB_PASSWORD=<long random password>
```
```bash
chmod 600 .env       # only the owner can read it: it contains a password
```
Keeping secrets in `.env` keeps them **out of the compose file**, so the compose file can be published on GitHub safely.

### 2. The recipe: `docker-compose.yml`
```yaml
services:
  glpi:
    image: glpi/glpi:latest
    restart: unless-stopped
    volumes:
      - glpi_data:/var/glpi          # named volume: Docker sets correct ownership
    env_file: .env                   # DB connection details (never committed)
    depends_on:
      db:
        condition: service_healthy   # start GLPI only once MySQL answers
    ports:
      - "80:80"                      # UBU01 port 80 → container port 80

  db:
    image: mysql:8.4
    restart: unless-stopped
    volumes:
      - ./storage/mysql:/var/lib/mysql   # database files kept on UBU01
    environment:
      MYSQL_RANDOM_ROOT_PASSWORD: "yes"
      MYSQL_DATABASE: ${GLPI_DB_NAME}
      MYSQL_USER: ${GLPI_DB_USER}
      MYSQL_PASSWORD: ${GLPI_DB_PASSWORD}
    healthcheck:
      test: mysqladmin ping -h 127.0.0.1 -u $$MYSQL_USER --password=$$MYSQL_PASSWORD
      interval: 5s

volumes:
  glpi_data:                         # declares the named volume used above
```
YAML is indentation-sensitive: use **spaces, never tabs**.

| Line | Meaning |
|---|---|
| `restart: unless-stopped` | Restart automatically after a crash or reboot |
| `depends_on … service_healthy` | Wait until the database passes its health check before starting GLPI |
| `ports: "80:80"` | Publish GLPI's web page on UBU01's address. MySQL is **not** published: only GLPI can reach it |
| `healthcheck` | Docker regularly asks MySQL "are you alive?" and marks it `healthy` |

### 3. Start it
```bash
docker compose config        # validate the file (output includes the password, so don't share it)
docker compose up -d         # download the images and start both containers in the background
docker compose ps            # db: Up (healthy) · glpi: Up
docker volume ls             # glpi_glpi_data listed
```

### Troubleshooting met during this build

**GLPI stuck in `Restarting`, with `mkdir: cannot create directory '/var/glpi/config': Permission denied`**
- **Cause:** the first version used a **bind mount** (`./storage/glpi`). Docker created that folder as `root`, but GLPI runs as a limited web user, so it couldn't write there and kept crashing.
- **Fix:** switch to a **named volume** (`glpi_data`), which Docker creates with the correct ownership. Then `docker compose down`, remove the empty `storage/glpi` folder, and `docker compose up -d`.

**Install wizard: `Connection refused (HY000/2002)`**
- **Cause:** a wrong SQL server address. `localhost` means the GLPI container itself, and `10.10.10.20` has no MySQL port published.
- **Fix:** enter **`db`**, the **service name**. Containers in the same compose file find each other by service name.

```bash
docker compose logs glpi | tail -20                            # first place to look when something fails
docker compose exec glpi getent hosts db                       # can GLPI resolve the database?
docker compose exec glpi bash -c 'echo > /dev/tcp/db/3306 && echo "port 3306 open"'   # can it reach it?
```

---

## G. Install wizard, first login and hardening

Browse to `http://10.10.10.20` and click **Go to install page**.

| Screen | Entry |
|---|---|
| Language / licence | English (UK) / accept |
| Install or upgrade | **Install** |
| Requirements | All required checks green → continue |
| SQL server | **`db`** |
| SQL user / password | `glpi` / the password from `.env` (`cat ~/glpi/.env`) |
| Database | Select the existing **`glpi`** (MySQL created it at startup) |
| Telemetry | Untick |

Then:
1. Log in as `glpi` / `glpi`.
2. **Change the passwords of all four default accounts** (`glpi`, `tech`, `normal`, `post-only`) under **Administration → Users**. Default credentials are among the most common ways systems get compromised.
3. **Enable inventory:** **Administration → Inventory → Enable inventory** → Save. This lets agents on Windows machines report their hardware and software to GLPI.

Snapshot: `01-glpi-deployed` on UBU01.

---

## Checklist
- [ ] `ssh` to UBU01 works; `ip -br a` shows 10.10.10.20
- [ ] `/` uses the whole disk (~38G)
- [ ] Time zone Europe/London; chrony points at DC01
- [ ] `ubu01.ad.nebula.internal` resolves both ways
- [ ] `docker compose ps`: both containers Up, db healthy
- [ ] GLPI login works; default passwords changed; inventory enabled
- [ ] Snapshot taken

**Next:** install the GLPI Agent on DC01 and CL01, so they appear in **Assets → Computers**.

**Note for later (P4):** Docker-published ports bypass Ubuntu's `ufw` firewall, so port 80 is reachable on every interface. That's acceptable on an isolated lab network; it gets hardened in P4.
