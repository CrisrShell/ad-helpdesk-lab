# 02  UBU01 clock one hour fast (VMware hardware clock in local time)

| Field | Value |
|---|---|
| **Type** | Lab infrastructure fault |
| **Priority** | P3: wrong timestamps in logs and inventory; would break Kerberos for domain-integrated services |
| **Status** | Resolved |
| **Affected** | UBU01 (Ubuntu Server, VMware Workstation) |

---

## Symptom
UBU01 showed a time exactly **one hour ahead** of the real time, and chrony reported a 3600 s offset against DC01.
```
$ timedatectl
               Local time: Thu 2026-10-08 19:43:43 BST     ← real time was 18:43 BST
           Universal time: Thu 2026-10-08 18:43:43 UTC
                 RTC time: Thu 2026-10-08 18:43:44
          RTC in local TZ: no

$ chronyc sources
^? DC01.ad.nebula.internal     1   6   17   2   +3600s[ +3600s] +/- 10.0s
```

## Scope
- Only UBU01 (Linux). DC01 and CL01 (Windows) showed the correct time.
- The offset was **exactly 1 hour** during **British Summer Time** (UTC+1).

## Hypotheses
1. Wrong time zone on UBU01
2. A bad time source pushing the wrong time
3. The hardware clock (RTC) set in local time but read as UTC

## Tests
| # | Test | Result | Conclusion |
|---|---|---|---|
| 1 | `timedatectl` → Time zone | `Europe/London (BST, +0100)` | Time zone correct → **H1 rejected** |
| 2 | `chronyc sources` | All sources `^?` (none selected) | Chrony isn't changing the clock → **H2 rejected** |
| 3 | `timedatectl` → RTC vs real time | RTC = 18:43 when real **UTC** was 17:43 | The RTC holds **local** time (BST) |
| 4 | `timedatectl` → RTC in local TZ | `no` | Linux reads the RTC as **UTC** |

## Root cause
VMware Workstation started the VM's hardware clock (RTC) at the **host's local time** (BST). Ubuntu reads the RTC as **UTC** (the Linux standard), so it treated 18:43 BST as 18:43 UTC and showed 19:43 BST, exactly one hour ahead during summer time.

Windows guests read the RTC as local time, which is why DC01 and CL01 were correct. The fault only shows up on Linux guests, and only while the host's time zone differs from UTC.

Chrony couldn't correct it because no time source was trusted (see KB 01, finding C).

## Fix
Tell VMware to give this VM a **UTC** hardware clock:
1. Shut down UBU01: `sudo poweroff`
2. Add this line to the end of `Documents\VMs\UBU01\UBU01.vmx`:
   ```
   rtc.diffFromUTC = "0"
   ```
3. Power UBU01 back on.

## Verification
```
$ timedatectl
               Local time: Thu 2026-10-08 18:58:35 BST     ← matches real time
           Universal time: Thu 2026-10-08 17:58:35 UTC
                 RTC time: Thu 2026-10-08 17:58:35         ← RTC now equals UTC
```
`System clock synchronized: no` remains until DC01 has an external time source (KB 01, C). That's expected and doesn't affect this fix.

## Prevention
- Add `rtc.diffFromUTC = "0"` to **every Linux VM** in VMware Workstation (EDGE01 and future Ubuntu VMs).
- Domain members sync time from the DC: UBU01's chrony uses DC01 only, with the Canonical public pools disabled.

## Lessons
- **An exact 1-hour error points to time zones or UTC vs local time**, not to clock drift. Read the size of the error as a clue.
- **Windows and Linux interpret the hardware clock differently** (local vs UTC). This is the classic dual-boot clock bug, here between a hypervisor and its guest.
- **Fix the cause at boot**, rather than relying on NTP to correct it afterwards. Chrony slews large errors slowly, which would take days for 3600 s.

**Related:** KB 01 (restricted-network connectivity, NTP finding)
**Skills:** Linux time management · chrony · VMware configuration · root-cause analysis
