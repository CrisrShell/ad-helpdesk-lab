# 1.3 H: GLPI Agent – automatic asset inventory

**Goal:** every Windows machine reports its hardware and software to GLPI automatically, so the service desk always knows what each computer has.

**Machines:** DC01 and CL01 → GLPI on UBU01 (`http://10.10.10.20`)

---

## Key concepts

| Term | Simple meaning |
|---|---|
| **Asset inventory** | A live list of every device: its hardware, operating system and installed software |
| **Agent** | A small program that runs in the background on each computer and reports to a central server |
| **Service** | A Windows program that starts automatically and runs without anyone logged in (`glpi-agent`) |
| **MSI** | The standard Windows installer package format, which IT can install silently on many PCs at once |
| **Inventory run** | One report from the agent to GLPI. By default, once every 24 hours |

**Why it matters for a service desk:** when a user calls with a problem, the technician can open the ticket and see the user's machine (OS version, RAM, disk, installed software) without asking the user or visiting the desk.

---

## Steps

### 1. Prepare GLPI
- **Administration → Inventory → Enable inventory**. GLPI ignores agents until this is on.
- **Authorization header: None.** A deliberate lab decision (see `docs/decisions/glpi-security.md`, D1).

### 2. Download the agent (laptop)
`github.com/glpi-project/glpi-agent/releases` → latest **`GLPI-Agent-<version>-x64.msi`** → drag it into each VM.

### 3. Install (DC01 and CL01, PowerShell as Administrator)
```powershell
cd $HOME\Downloads
msiexec /i GLPI-Agent-<version>-x64.msi /quiet SERVER="http://10.10.10.20/" RUNNOW=1
```

| Part | Meaning |
|---|---|
| `msiexec /i` | Windows' installer engine; `/i` = install |
| `/quiet` | No wizard: a silent install, the way software is deployed at scale |
| `SERVER=` | Where to send inventory: the GLPI server |
| `RUNNOW=1` | Send the first inventory immediately, instead of waiting for the schedule |

### 4. Verify
```powershell
Get-Service glpi-agent                        # Status: Running
Test-NetConnection 10.10.10.20 -Port 80       # TcpTestSucceeded : True (GLPI reachable)
```
In GLPI: **Assets → Computers** lists **DC01** and **CL01**. Open each one to see the OS, components and software.

---

## Useful commands

```powershell
& "C:\Program Files\GLPI-Agent\glpi-agent.bat" --force                     # send an inventory now
Get-Content "C:\Program Files\GLPI-Agent\logs\glpi-agent.log" -Tail 20     # what the agent did
```

**Reading the log**

| Line | Meaning |
|---|---|
| `supports GLPI Agent protocol` | Agent and GLPI are talking ✅ |
| `New inventory from DC01-…` | Inventory sent ✅ |
| `next run: <date>` | When it reports next (every 24 h) |
| `not ready yet, but run is forced` | Normal when using `--force` before the scheduled time |

---

## Issues met

| Symptom | Cause | Fix |
|---|---|---|
| DC01 missing at first, although the log showed `New inventory` | Checked before GLPI had finished processing | Refresh the page; `--force` to confirm |
| CL01 couldn't reach GLPI (`SourceAddress` empty) | CL01 had no usable IP: DC01's DHCP wasn't serving after boot | KB 03: restart DHCP, set it to delayed start, `ipconfig /renew` |
| `A parameter cannot be found … 'Port'` | Typed `Test-Connection` (ping only) instead of `Test-NetConnection` | Use `Test-NetConnection` to test a port |

---

## Result
- [x] Agent installed and running on DC01 and CL01
- [x] Both computers in **Assets → Computers** with full hardware and software details
- [x] Evidence: `docs/img/glpi-computers.png`
