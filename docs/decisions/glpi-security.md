# GLPI security decisions

Short decision records for the GLPI deployment on UBU01. Each entry states what was decided, why, and what production would do differently.

---

## D1 – Inventory authentication: none

| | |
|---|---|
| **Date** | 2026-10-09 |
| **Status** | Accepted (lab only) |
| **Setting** | Administration → Inventory → Authorization header: **None** |

**Context.** GLPI Agents on Windows machines send hardware and software inventory to GLPI over HTTP. GLPI can require agents to authenticate first.

**Options considered**

| Option | How it works | Security |
|---|---|---|
| None | GLPI accepts inventory from any agent that can reach it | Lowest |
| Basic | Each agent sends a username and password | Medium |
| OAuth client credentials | Each agent obtains a token from GLPI | Highest |

**Decision.** No authentication.

**Rationale**
- GLPI sits on an isolated lab network (VMnet10, `10.10.10.0/24`). Only lab machines can reach it.
- The only risk is a device on that network submitting **false inventory data**. In a lab that holds no real data, the impact is negligible.
- It keeps agent deployment to a single install command, so the focus stays on inventory itself.

**Production alternative.** Use **OAuth client credentials**, and serve GLPI over **HTTPS**, so agent credentials and inventory data can't be intercepted or forged.

**Revisit when** GLPI is reachable from any network outside the lab.

---

## D2 – Default accounts

| | |
|---|---|
| **Date** | 2026-10-09 |
| **Status** | Accepted |

**Context.** GLPI creates four accounts at install. **Each one's password is the same as its username**, a well-known weakness that attackers try first.

| Account | Profile | Action taken |
|---|---|---|
| `glpi` | Super-Admin | Password changed; stored in the password manager |
| `tech` | Technician | Password changed; kept for testing the technician view |
| `normal` | Normal user | Disabled (`Active: No`) |
| `post-only` | Self-Service | Disabled (`Active: No`) |

**Rationale.** *Least privilege*: an account that isn't needed shouldn't be usable. Disabling an account rather than deleting it keeps it available for later testing, with no risk while it's inactive.

**Production alternative.** Create named accounts for each administrator, synced from Active Directory (LDAP), and disable all four defaults. Every action is then traceable to a real person.

**Lesson recorded.** During this build, a password reset done directly in the database caused a login failure. Because GLPI held no data yet, it was rebuilt rather than debugged (time-boxed). Credentials are now changed **only through the GLPI interface**, which updates both the password hash and its metadata.
