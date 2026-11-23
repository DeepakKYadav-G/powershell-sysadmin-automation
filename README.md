# PowerShell Sysadmin Automation

PowerShell scripts I use to automate Windows Server administration across multiple remote sites. All IP addresses, names, and credentials in this repo are placeholders (RFC 5737 documentation ranges). Replace them with your own before use.

## Scripts

| Script | What it does |
|---|---|
| [`Deploy-Zabbix-From-HO.ps1`](scripts/Deploy-Zabbix-From-HO.ps1) | Installs Zabbix Agent 6.0.40 on a remote Windows server over WinRM from a central (HO) machine and points it at the Zabbix server |
| [`Sync-StoreBackupsToHO.ps1`](scripts/Sync-StoreBackupsToHO.ps1) | Pulls the latest SQL `.bak` backup from many store servers to a central NAS in parallel, with per-store logging and size verification |

---

## Deploy-Zabbix-From-HO.ps1

Remote rollout of the Zabbix Agent MSI to a store or branch server.

1. Prompts for the target server IP/name, admin credentials, and an optional tunnel IP
2. Tests WinRM, then opens a PowerShell session to the target
3. Copies the MSI and installs it silently with `SERVER` and `SERVERACTIVE`
4. Backs up the MSI-created `zabbix_agentd.conf`, then changes **only** `Server=`, `ServerActive=`, and adds two custom `UserParameter` items
5. Preserves the file's original encoding and line endings (no BOM added)
6. Test-starts the agent in the foreground to validate the config before starting the service
7. Starts the service and prints a final verification

**Server values:** internal server `Server=192.0.2.10`; remote store over VPN `Server=192.0.2.10,<TunnelIP>` (same for `ServerActive`).

**Custom items added:** `folder.zip.count[path]` (number of `.zip` files in a folder) and `folder.latest.info[path]` (creation time and size in MB of the newest file over 1 MB).

**Requirements**
- Windows PowerShell 5.1+, run as Administrator on the HO machine
- WinRM enabled on the target (`Enable-PSRemoting`); if connecting by IP from a non-domain machine, add the target to `TrustedHosts`
- The Zabbix agent MSI next to the script (not included): `zabbix_agent-6.0.40-windows-amd64-openssl.msi`
- Edit `$ZabbixServer` at the top of the script to your Zabbix server IP

```powershell
.\scripts\Deploy-Zabbix-From-HO.ps1
```

---

## Sync-StoreBackupsToHO.ps1

Automates collecting database backups from every store to one central location, instead of copying them by hand.

**What it does, per store (runs several stores in parallel using background jobs)**
1. Connects over PowerShell Remoting
2. Checks the backup folder on the store and creates an SMB share if one doesn't exist
3. Authenticates to the share and finds the newest `.bak` file
4. Creates the NAS destination folder if needed
5. Copies the file with Robocopy (restartable mode, retries, per-store Robocopy log)
6. Verifies the copy by comparing file sizes
7. Cleans up the SMB connection and session

At the end it writes a summary (total, successful, failed, and the error for each failed store). Each store gets its own log file, so parallel jobs never write to the same file.

**Setup**
1. Copy `scripts/stores.example.csv` to `scripts/stores.csv` and fill in your stores:

   | Column | Meaning |
   |---|---|
   | `StoreName` | Label used in logs |
   | `StoreIP` | Store server address |
   | `AdminUsername` / `AdminPassword` | Admin account on the store |
   | `BackupPath` | Local folder on the store that holds the `.bak` files |
   | `NASPath` | Destination folder (UNC path) at HO |

2. Run as Administrator on the HO machine:

```powershell
.\scripts\Sync-StoreBackupsToHO.ps1
.\scripts\Sync-StoreBackupsToHO.ps1 -MaxParallel 5 -CsvPath D:\config\stores.csv
```

**Requirements:** PowerShell 5.1+, WinRM enabled on the stores, SMB (port 445) reachable from HO, and write access to the NAS path.

### Security notes
- `stores.csv` holds plaintext passwords. It is listed in `.gitignore` and must **never** be committed. Keep it in a restricted folder.
- For production use, prefer a dedicated least-privilege service account and an encrypted credential store (for example `Export-Clixml`, which is bound to the user and machine, or the `SecretManagement` module) instead of a password column.
- The script creates the `StoreFullBackup` share on each store and leaves it in place. Remove it afterwards if your policy requires.

## Notes
Test in a lab before running in production.
