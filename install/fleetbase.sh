#!/usr/bin/env bash
#
# Fleetbase one-liner for Proxmox VE (Community-Scripts style)
# Host-side: creates/updates an LXC container and installs Fleetbase inside.
#
# App: Fleetbase – modular logistics / supply-chain OS (PHP Laravel API +
#      Ember console + MySQL 8 + Redis + SocketCluster, Docker Compose)
#      Console :4200, API :8000 (via httpd), Socket :38000, MySQL :3306
# Upstream: https://github.com/fleetbase/fleetbase
#
# Einzeiler:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FleetBase-Proxmox/main/install/fleetbase.sh)"
#
# Alternative mit expliziter CT-ID / Ressourcen:
#   CTID=103 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FleetBase-Proxmox/main/install/fleetbase.sh)"
#   CTID=103 CPU=2 RAM=6144 DISK=16 bash -c "$(wget -qLO - .../fleetbase.sh)"
#
set -euo pipefail

# ---------------------------------------------------------------- Variables --
APP="Fleetbase"
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/FleetBase-Proxmox/main}"
INNER_SCRIPT_PATH="install/fleetbase-install.sh"

CTID="${CTID:-103}"
# Bewusst CT_HOSTNAME statt HOSTNAME: $HOSTNAME ist auf dem Proxmox-Host immer
# schon gesetzt (System-Hostname, z.B. "Prox") und wuerde mit ${HOSTNAME:-...}
# den Default "fleetbase" ueberschreiben -> CT hiese "prox" statt "fleetbase".
CT_HOSTNAME="${CT_HOSTNAME:-fleetbase}"
CPU="${CPU:-2}"
RAM="${RAM:-6144}"
SWAP="${SWAP:-512}"
DISK="${DISK:-16}"
STORAGE="${STORAGE:-local-lvm}"            # rootfs storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # vztmpl storage
BRIDGE="${BRIDGE:-vmbr0}"
OS_TEMPLATE="${OS_TEMPLATE:-}"             # leer = auto (debian-12-standard)
# Privileged (0) ist hier Default – bewusst, nicht aus Bequemlichkeit:
# Das Image fleetbase/fleetbase-api enthaelt Dateien mit UIDs > 700 Mio.
# (z.B. alte npm-Artefakte), die sich im 65536er-idmap eines unprivilegierten
# CTs nicht abbilden lassen -> containerd bricht ab mit
# "failed to Lchown ... invalid argument (Hint: ... subuid/subgid)".
# Mit UNPRIVILEGED=1 laeuft das Script bis zum Image-Pull und scheitert dort.
UNPRIVILEGED="${UNPRIVILEGED:-0}"
ONBOOT="${ONBOOT:-1}"

CONSOLE_PORT="4200"
API_PORT="8000"
SOCKET_PORT="38000"

# ------------------------------------------------------- Error chain / debug --
# Volle Fehlermeldungskette statt nur letzter Zeile (Anforderung #4).
# Bei Installationsfehlern: mit 'bash -x ...' erneut laufen lassen.
trap_err() {
  local ec=$?
  echo "==================================================================" >&2
  echo "[${APP}] FEHLER (exit=${ec})" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Stack  :" >&2
  local i=0
  while caller $i >&2; do ((i++)); done
  echo "Hinweis: Re-run mit Debug-Log:" >&2
  # shellcheck disable=SC2016
  echo '  bash -x -c "$(wget -qLO - .../fleetbase.sh)" 2>&1 | tee /root/fleetbase-host.log' >&2
  echo "==================================================================" >&2
  exit "${ec}"
}
trap trap_err ERR

log()  { echo "[${APP}] $*"; }
die()  { echo "[${APP}] FEHLER: $*" >&2; exit 1; }

log "Starte ${APP}-Installation als LXC (CT ${CTID:-103}, Hostname ${CT_HOSTNAME:-fleetbase})."
log "Hinweis: Gesamtlaufzeit ca. 15-25 Minuten (Template + Docker-Images ~2-3 GB + deploy.sh), je nach CPU/Netzwerk/Disk – bitte nicht abbrechen."

# ------------------------------------------------------------------ Checks ---
[[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-Host ausfuehren."
command -v pct >/dev/null 2>&1 || die "pct nicht gefunden. Auf dem Proxmox-Host ausfuehren."
command -v pveam >/dev/null 2>&1 || die "pveam nicht gefunden. Auf dem Proxmox-Host ausfuehren."

# CTID aus $1 erlauben: 'bash fleetbase.sh 103'
if [[ "${1:-}" =~ ^[0-9]{2,}$ ]]; then CTID="$1"; fi

# CT-ID wählbar (Default 103). pct status kennt nur CTs, daher zusätzlich
# qm status pruefen. Ist die Wunsch-ID als QEMU-VM belegt, automatisch auf die
# nächste freie ID ausweichen (max. 100 Versuche), statt hart abzubrechen.
# Existierender CT mit gleicher ID wird weiterverwendet (idempotent, s.u.).
if qm status "${CTID}" >/dev/null 2>&1; then
  log "WARNUNG: ID ${CTID} ist als QEMU-VM belegt -> suche naechste freie ID ..."
  BUMPED=0
  for ((try = 0; try < 100; try++)); do
    CTID=$((CTID + 1))
    if ! qm status "${CTID}" >/dev/null 2>&1 && ! pct status "${CTID}" >/dev/null 2>&1; then
      BUMPED=1
      break
    fi
  done
  [[ "${BUMPED}" == "1" ]] || die "Keine freie CT-ID im Bereich gefunden. Bitte CTID manuell setzen, z.B. CTID=200."
  log "Weiche auf freie ID ${CTID} aus (Hostname ${CT_HOSTNAME})."
fi
log "CT-ID: ${CTID}"

# Storage-Warnung: local-lvm ist auf diesem Host knapp (thin-provisioned).
# Kein harter Abbruch – thin erlaubt Overcommit – aber Hinweis ausgeben.
if command -v pvesm >/dev/null 2>&1; then
  log "Storage-Status:"
  pvesm status 2>/dev/null | head -n 20 || true
fi

# ------------------------------------------------------- Template handling ---
log "Aktualisiere Template-Liste (pveam update) ..."
pveam update

if [[ -z "${OS_TEMPLATE}" ]]; then
  # Debian 12 (Bookworm): bewährt für Docker-in-LXC, passt zu Fleetbase
  # (PHP/MySQL/Redis als Container, keine Distro-Abhängigkeit im CT).
  # Auf diesem Host vorhanden: debian-12-standard_12.12-1_amd64.tar.zst
  OS_TEMPLATE="$(pveam available --section system 2>/dev/null \
    | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1 || true)"
  [[ -n "${OS_TEMPLATE}" ]] || die "Kein debian-12-standard Template in 'pveam available' gefunden."
fi
log "OS-Template: ${TEMPLATE_STORAGE}:vztmpl/${OS_TEMPLATE}"

if ! pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${OS_TEMPLATE}"; then
  log "Lade Template ${OS_TEMPLATE} ..."
  pveam download "${TEMPLATE_STORAGE}" "${OS_TEMPLATE}"
else
  log "Template bereits vorhanden, kein Download noetig (idempotent)."
fi

# ------------------------------------------------------- Container create ----
# Docker-in-LXC braucht nesting + keyctl (Community-Scripts-Standard,
# vgl. paperclip CT101: features=nesting=1,keyctl=1).
if pct status "${CTID}" >/dev/null 2>&1; then
  log "Container ${CTID} existiert bereits -> kein pct create (idempotent)."
  # Der Privilegien-Modus laesst sich nachtraeglich nicht flippen
  # (Besitzrechte auf der Disk). Passt er nicht zum Wunsch, muss der CT neu
  # erstellt werden – sonst scheitert spaeter der Image-Pull (unprivileged)
  # bzw. die Isolation entspricht nicht dem Wunsch (privileged).
  CT_PRIV="$(pct config "${CTID}" 2>/dev/null | awk -F': *' '/^unprivileged:/ {print $2}' || true)"
  [[ -z "${CT_PRIV}" ]] && CT_PRIV="1"
  if [[ "${CT_PRIV}" != "${UNPRIVILEGED}" ]]; then
    die "Container ${CTID} existiert mit unprivileged=${CT_PRIV}, gewuenscht ist ${UNPRIVILEGED}. Bitte neu erstellen: pct stop ${CTID} && pct destroy ${CTID} && Einzeiler erneut laufen lassen."
  fi
else
  log "Erstelle LXC ${CTID} (${CPU} vCPU, ${RAM} MB RAM, ${DISK}G Disk) ..."
  pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${OS_TEMPLATE}" \
    --hostname "${CT_HOSTNAME}" \
    --cores "${CPU}" \
    --memory "${RAM}" \
    --swap "${SWAP}" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --ostype debian \
    --unprivileged "${UNPRIVILEGED}" \
    --features "nesting=1,keyctl=1" \
    --onboot "${ONBOOT}" \
    --start 0
  log "Container ${CTID} erstellt."
fi

# onboot + features immer sicherstellen (reboot-sicher, Anforderung #6)
pct set "${CTID}" --onboot "${ONBOOT}" || true
# features koennen bei existierendem CT fehlen -> nachsetzen (idempotent)
pct set "${CTID}" --features "nesting=1,keyctl=1" || true

# ------------------------------------------------------------------ Start ----
if [[ "$(pct status "${CTID}" | awk '{print $2}')" != "running" ]]; then
  log "Starte Container ${CTID} ..."
  pct start "${CTID}"
else
  log "Container ${CTID} laeuft bereits."
fi

log "Warte auf Netzwerk im Container ..."
for i in $(seq 1 30); do
  if pct exec "${CTID}" -- ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then break; fi
  if [[ "$i" == "30" ]]; then die "Container hat kein Netzwerk (ping 8.8.8.8 schlaegt fehl)."; fi
  sleep 2
done

# ------------------------------------------------------- Inner script push ---
TMP_INNER="$(mktemp)"
trap 'rm -f "${TMP_INNER:-}"' EXIT
INNER_URL="${REPO_RAW_BASE}/${INNER_SCRIPT_PATH}"
log "Lade Installer: ${INNER_URL}"
if ! wget -qO "${TMP_INNER}" "${INNER_URL}"; then
  die "Konnte ${INNER_URL} nicht laden. REPO_RAW_BASE pruefen (derzeit: ${REPO_RAW_BASE})."
fi
bash -n "${TMP_INNER}" || die "Syntaxfehler im geladenen Installer (bash -n fehlgeschlagen)."
pct push "${CTID}" "${TMP_INNER}" /root/fleetbase-install.sh
rm -f "${TMP_INNER}"; trap - EXIT

log "Fuehre Installation im Container aus (kann 10-20 Min dauern: Docker-Images + deploy.sh) ..."
pct exec "${CTID}" -- bash /root/fleetbase-install.sh

# ------------------------------------------------------------------ Verify ---
CT_IP="$(pct exec "${CTID}" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
[[ -n "${CT_IP:-}" ]] || CT_IP="<LXC-IP>"

echo ""
echo "=================================================================="
echo " ${APP} Installation abgeschlossen"
echo "=================================================================="
echo " Container : ${CTID} (${CT_HOSTNAME})"
echo " Console   : http://${CT_IP}:${CONSOLE_PORT}  (Web UI)"
echo " API       : http://${CT_IP}:${API_PORT}      (httpd -> application)"
echo " Socket    : http://${CT_IP}:${SOCKET_PORT}"

if [[ "${CT_IP}" != "<LXC-IP>" ]]; then
  if wget -qO- --timeout=10 "http://${CT_IP}:${CONSOLE_PORT}" >/dev/null 2>&1; then
    echo " Check    : Console antwortet auf Port ${CONSOLE_PORT} (OK)"
  else
    echo " Check    : Console antwortet NICHT (Fehlerkette oben pruefen)."
    echo "            Im Container: systemctl status docker fleetbase-stack; docker compose -f /opt/fleetbase/docker-compose.yml ps; journalctl -u fleetbase-stack -e --no-pager"
  fi
  if wget -qO- --timeout=10 "http://${CT_IP}:${API_PORT}" >/dev/null 2>&1; then
    echo " Check    : API antwortet auf Port ${API_PORT} (OK)"
  else
    echo " Check    : API antwortet (noch) NICHT – deploy.sh braucht ggf. laenger."
  fi
fi
echo ""
echo " Naechste Schritte:"
echo "  1) Onboarding im Browser abschliessen:"
echo "       http://${CT_IP}:${CONSOLE_PORT}  -> Organisation + Admin anlegen"
echo "  2) Update (idempotent):"
echo "       pct exec ${CTID} -- bash /root/fleetbase-install.sh"
echo "  3) Reboot-Test:"
echo "       pct reboot ${CTID} && sleep 30 && pct exec ${CTID} -- systemctl is-active docker fleetbase-stack"
echo "  4) Loeschen:"
echo "       pct stop ${CTID} && pct destroy ${CTID}"
echo "=================================================================="
