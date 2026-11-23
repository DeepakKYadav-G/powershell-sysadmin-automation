# PowerShell Sysadmin Automation

PowerShell scripts I use to automate Windows Server administration. All IP addresses in this repo are placeholders from the documentation ranges (RFC 5737). Replace them with your own before use.

## Scripts

| Script | What it does |
|---|---|
| [`Deploy-Zabbix-From-HO.ps1`](scripts/Deploy-Zabbix-From-HO.ps1) | Installs Zabbix Agent 6.0.40 on a remote Windows server over WinRM from a central (HO) machine, then points it at the Zabbix server |

## Deploy-Zabbix-From-HO.ps1

Remote rollout of the Zabbix Agent MSI to a store or branch server.

**What it does**
1. Prompts for the target server IP/name, admin credentials, and an optional tunnel IP
2. Tests WinRM, then opens a PowerShell session to the target
3. Copies the MSI and installs it silently with `SERVER` and `SERVERACTIVE`
4. Backs up the MSI-created `zabbix_agentd.conf`, then changes **only** `Server=`, `ServerActive=`, and adds two custom `UserParameter` items
5. Preserves the file's original encoding and line endings (no BOM added)
6. Test-starts the agent in the foreground to validate the config before starting the service
7. Starts the service and prints a final verification

**Server values**
- Internal server: `Server=192.0.2.10`
- Remote store over VPN: `Server=192.0.2.10,<TunnelIP>` (same for `ServerActive`)

**Custom items added**
- `folder.zip.count[path]`: number of `.zip` files in a folder
- `folder.latest.info[path]`: creation time and size (MB) of the newest file over 1 MB

**Requirements**
- Windows PowerShell 5.1+, run as Administrator on the HO machine
- WinRM enabled on the target (`Enable-PSRemoting`); if connecting by IP from a non-domain machine, add the target to `TrustedHosts`
- The Zabbix agent MSI placed next to the script (not included in this repo):
  `zabbix_agent-6.0.40-windows-amd64-openssl.msi`
- Edit `$ZabbixServer` at the top of the script to your Zabbix server IP

**Usage**
```powershell
.\scripts\Deploy-Zabbix-From-HO.ps1
```

## Notes
Test in a lab before running in production.
