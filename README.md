# Fleetbase für Proxmox VE (Community-Scripts-Stil)

Lokale, einzeilige Installation von [Fleetbase](https://github.com/fleetbase/fleetbase)
(modulares Logistics/Supply-Chain-OS: PHP-Laravel-API + Ember-Console + MySQL 8 + Redis + SocketCluster)
als **LXC-Container** auf Proxmox VE.

- **Standard:** LXC CT 103, Debian 12, 2 vCPU, 6 GB RAM, 16 GB Disk (thin), 512 MB Swap,
  **privileged**, `nesting=1,keyctl=1` (Docker-in-LXC), `onboot: 1`, `vmbr0` DHCP
  - Privileged ist bewusst Default: `fleetbase/fleetbase-api` enthält Dateien mit
    UIDs > 700 Mio., die in den 65536er-idmap eines unprivilegierten CTs nicht passen
    (containerd: `failed to Lchown … invalid argument`). Mit `UNPRIVILEGED=1`
    bricht der Image-Pull ab.
- **Modus:** Docker Compose (Upstream-`docker-compose.yml` + generierte `docker-compose.override.yml`),
  offizieller Wizard `scripts/docker-install.sh --non-interactive`, danach CT-IP-Patch
- **Web UI:** `http://<LXC-IP>:4200` (Console), API `http://<LXC-IP>:8000`, Socket `:38000`
- **Reboot-sicher:** `docker.service` + `fleetbase-stack.service` (`systemctl enable`), Container `onboot: 1`

> Warum LXC statt VM? Host `Prox` (PVE 9.1.2) hat nur 2x AMD GX-222GC + 12 GB RAM,
> `local-lvm` ist zu 83 % voll (nur ~3 GB frei), kein Debian-ISO vorhanden
> (nur Ubuntu-Cloud-Image), aber `debian-12-standard` Templates liegen auf `local`.
> Docker-in-LXC ist Community-Scripts-Standard (vgl. paperclip CT 101:
> `nesting=1,keyctl=1`) und spart gegenüber einer VM mehrere GB Disk + RAM-Overhead.
> Bei Dauerlast lässt sich der Stack 1:1 in eine VM umziehen (`/opt/fleetbase` + Compose-Files kopieren).

## Installation (Einzeiler)

Auf dem **Proxmox-Host als root** ausführen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FleetBase-Proxmox/main/install/fleetbase.sh)"
```

> Ist die Default-ID 103 belegt (QEMU-VM oder CT), weicht das Script automatisch
> auf die nächste freie ID aus (z. B. 104) und meldet das im Log. Existierender
> CT mit gleicher ID wird wiederverwendet (Update statt Neu-Erstellung).
>
> Falls nach einem Update noch die alte Version anzukommen scheint
> (`Andere CTID waehlen` statt `Weiche auf freie ID`): das ist der
> GitHub-Raw-CDN-Cache (~5 Min). Prüfen mit
> `wget -qO- <URL> | grep -c "Weiche auf freie ID"` (muss `1` ergeben),
> oder mit Cache-Buster laden: URL + `?nocache=2` anhängen.

Nützliche Varianten:

```bash
# andere CT-ID / Ressourcen (Variablen oben im Script, alle per Env übersteuerbar)
CTID=103 CPU=2 RAM=6144 DISK=16 STORAGE=local-lvm BRIDGE=vmbr0 \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FleetBase-Proxmox/main/install/fleetbase.sh)"

# anderer Upstream-Branch/Fork von Fleetbase (im Container-Script)
APP_REPO=https://github.com/fleetbase/fleetbase.git APP_BRANCH=main \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FleetBase-Proxmox/main/install/fleetbase.sh)"

# Debug-Log bei Fehlern (volle Kette, Anforderung #4)
bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FleetBase-Proxmox/main/install/fleetbase.sh)" 2>&1 | tee /root/fleetbase-host.log
pct exec 103 -- bash -x /root/fleetbase-install.sh 2>&1 | tee /root/fleetbase-install.log
```

Erwartete Ausgabe (Ende):

```text
[Fleetbase] Fertig. Web UI: http://<LXC-IP>:4200  (API: :8000)
==================================================================
 Fleetbase Installation abgeschlossen
==================================================================
 Container : 103 (fleetbase)
 Console   : http://<LXC-IP>:4200  (Web UI)
 API       : http://<LXC-IP>:8000      (httpd -> application)
 Socket    : http://<LXC-IP>:38000
 Check    : Console antwortet auf Port 4200 (OK)
 Check    : API antwortet auf Port 8000 (OK)

 Naechste Schritte:
  1) Onboarding im Browser abschliessen:
       http://<LXC-IP>:4200  -> Organisation + Admin anlegen
```

Danach: `http://<LXC-IP>:4200` öffnen, Onboarding-Wizard abschließen (Organisation + Admin).
Die API liegt auf `:8000`, der Socket auf `:38000`.

## Update

Idempotent — einfach erneut laufen lassen (Host-Script erkennt existierenden Container,
Container-Script macht `git pull` + `docker compose up -d`, `deploy.sh` nur beim Erstlauf):

```bash
# auf dem Proxmox-Host
pct exec 103 -- bash /root/fleetbase-install.sh
```

Für ein echtes Fleetbase-Upgrade (neuer Upstream-Stand + Migrationen):

```bash
pct enter 103
cd /opt/fleetbase
rm -f .fleetbase-deployed   # erzwingt deploy.sh beim nächsten Install-Lauf
bash /root/fleetbase-install.sh
```

## Reboot-Test

```bash
pct reboot 103
sleep 30
pct exec 103 -- systemctl is-active docker fleetbase-stack
pct exec 103 -- docker compose -f /opt/fleetbase/docker-compose.yml ps
pct exec 103 -- curl -fsS http://127.0.0.1:4200/ -o /dev/null -w "console %{http_code}\n"
pct exec 103 -- curl -fsS http://127.0.0.1:8000/ -o /dev/null -w "api %{http_code}\n"
```

## Deinstallation

```bash
pct stop 103
pct destroy 103
```

## Troubleshooting

- `failed to Lchown ... invalid argument (Hint: ... subuid/subgid)` beim
  `fleetbase-api`-Pull: CT läuft unprivileged (z. B. vor dem Privileged-Default
  erstellt). Privilegien lassen sich nicht nachträglich flippen — CT löschen
  und Einzeiler erneut laufen lassen (erstellt jetzt privileged):
  ```bash
  pct stop 104 && pct destroy 104
  bash -c "$(wget -qLO - 'https://raw.githubusercontent.com/HatchetMan111/FleetBase-Proxmox/main/install/fleetbase.sh?nocache=3')"
  ```

## Dateien

| Datei | Zweck |
|---|---|
| `install/fleetbase.sh` | Host-Script: Template, `pct create` (nesting/keyctl, onboot), `pct push` + `pct exec`, Verifikation, finale URL |
| `install/fleetbase-install.sh` | LXC-Script: Docker + Compose, Fleetbase-Checkout `/opt/fleetbase`, Wizard non-interactive, CT-IP-Patch, systemd, Checks |
| `install/fleetbase-stack.service` | Referenz der installierten systemd-Unit (`After=docker.service network-online.target`, `WantedBy=multi-user.target`) |

Alle Scripts: `set -euo pipefail`, idempotent, volle Fehlerkette
(Befehl + `caller`-Stack + `systemctl`/`docker compose logs`/`journalctl`-Auszüge).
