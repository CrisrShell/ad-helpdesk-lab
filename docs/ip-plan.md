### The lab network was created in VMware

The lab gets its own isolated network, `10.10.10.0/24`. A small VyOS VM, **EDGE01**, gives it internet access.

In **VMware → Edit → Virtual Network Editor → Change Settings**:
1. Click **Add Network**, choose **VMnet10**, and set it to **Host-only**.
2. **Untick** "Use local DHCP service". The domain controller will run DHCP instead.
3. Set the subnet to `10.10.10.0`, mask `255.255.255.0`.

The laptop gets a virtual adapter on this network at `10.10.10.1`, so you can open lab web pages straight from your browser.

**Address scheme**:

| Host | IP | Role |
|---|---|---|
| Laptop | 10.10.10.1 | VMware host adapter |
| DC01 | 10.10.10.10 | AD DS, DNS, DHCP |
| UBU01 | 10.10.10.20 | GLPI, Zabbix, Keycloak (Docker) |
| CL01 / CL02 | DHCP .100–.199 | Windows 11 clients |
| EDGE01 | 10.10.10.254 | Corp LAN gateway and NAT to internet |

---

- DC: Domain Controller

- UBU: Ubuntu Server

- CL: Client

- EDGE: Edge Router
