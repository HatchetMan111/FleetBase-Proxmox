#!/usr/bin/env bash
#
# Fleetbase LXC installer (laeuft IM Container via pct exec).
# Wird vom Host-Script install/fleetbase.sh per pct push + pct exec aufgerufen,
# kann aber auch direkt im Container erneut laufen (idempotent, Update-faehig).
#
#   bash /root/fleetbase-install.sh
#
# Installiert: Docker CE + Compose-Plugin, Git, Fleetbase-Checkout nach
# /opt/fleetbase, Docker-Stack (MySQL 8, Redis, SocketCluster, API, Console,
# httpd), systemd-Unit fleetbase-stack (reboot-sicher), Verifikation.
#
# Upstream: https://github.com/fleetbase/fleetbase
# Ports: 4200 console (Web UI), 8000 api, 38000 socket, 3306 mysql
#
set -euo pipefail

# ---------------------------------------------------------------- Variables --
APP="Fleetbase"
APP_DIR="/opt/fleetbase"
APP_REPO="${APP_REPO:-https://github.com/fleetbase/fleetbase.git}"
APP_BRANCH="${APP_BRANCH:-main}"
CONSOLE_PORT="4200"
API_PORT="8000"
SOCKET_PORT="38000"

# ------------------------------------------------------- Error chain / debug --
# Anforderung: immer komplette Fehlermeldungskette (Stacktrace, stderr/stdout,
# Exit-Codes, Logs), niemals nur letzte Zeile.
trap_err() {
  local ec=$?
  echo "==================================================================" >&2
  echo "[${APP}] INSTALL-FEHLER (exit=${ec})" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Stack  :" >&2
  local i=0
  while caller $i >&2; do ((i++)); done
  echo "--- relevante Logs (falls vorhanden) ---" >&2
  echo ">>> systemctl status docker fleetbase-stack" >&2
  systemctl status docker fleetbase-stack --no-pager 2>&1 | head -n 60 >&2 || true
  echo ">>> docker compose ps" >&2
  if [[ -f "${APP_DIR}/docker-compose.yml" ]]; then
    docker compose -f "${APP_DIR}/docker-compose.yml" ps 2>&1 | head -n 40 >&2 || true
    docker compose -f "${APP_DIR}/docker-compose.yml" logs --tail 80 2>&1 >&2 || true
  fi
  echo ">>> journalctl fleetbase-stack" >&2
  journalctl -u fleetbase-stack --no-pager -n 80 2>&1 >&2 || true
  echo "Tipp: bash -x /root/fleetbase-install.sh 2>&1 | tee /root/fleetbase-install.log" >&2
  echo "==================================================================" >&2
  exit "${ec}"
}
trap trap_err ERR

log() { echo "[${APP}] $*"; }
die() { echo "[${APP}] FEHLER: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------ System ---
log "OS-Check ..."
cat /etc/os-release | head -n3 || true

log "APT: update + Basis-Abhaengigkeiten ..."
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git openssl iproute2 procps iputils-ping \
  gnupg lsb-release

# ------------------------------------------------------------------ Docker ---
# Docker-in-LXC: Host-CT hat nesting=1,keyctl=1 (setzt fleetbase.sh).
if command -v docker >/dev/null 2>&1; then
  log "Docker bereits installiert: $(docker --version) (idempotent, kein Reinstall)."
else
  log "Installiere Docker CE (Debian-Repo) ..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/debian/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck disable=SC1091
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
log "Docker: $(docker --version)"
log "Compose: $(docker compose version)"

systemctl enable docker
systemctl start docker || { journalctl -u docker --no-pager -n 50; die "docker.service startet nicht (LXC braucht nesting=1,keyctl=1)."; }

# ------------------------------------------------------------ App checkout ---
if [[ -d "${APP_DIR}/.git" ]]; then
  log "Repo existiert -> git pull (idempotent/Update) ..."
  git -C "${APP_DIR}" fetch origin "${APP_BRANCH}" --depth 1
  git -C "${APP_DIR}" checkout "${APP_BRANCH}"
  git -C "${APP_DIR}" reset --hard "origin/${APP_BRANCH}"
else
  log "Klone ${APP_REPO} (${APP_BRANCH}) nach ${APP_DIR} ..."
  rm -rf "${APP_DIR}"
  git clone --depth 1 --branch "${APP_BRANCH}" "${APP_REPO}" "${APP_DIR}"
fi
log "Checkout: $(git -C "${APP_DIR}" rev-parse --short HEAD)"
[[ -f "${APP_DIR}/docker-compose.yml" ]] || die "docker-compose.yml fehlt in ${APP_DIR}."

cd "${APP_DIR}"

# --------------------------------------------------- Console/API-Host fix ----
# Fleetbase bindet per Compose auf 0.0.0.0 (Ports 4200/8000) – Web-UI-Anforderung.
# Der offizielle Wizard fragt interaktiv nach HOST; hier non-interactive mit CT-IP,
# damit CONSOLE_HOST/APP_URL direkt auf die LXC-IP zeigen.
CT_IP="$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
[[ -n "${CT_IP:-}" ]] || CT_IP="localhost"
export FLEETBASE_HOST="${FLEETBASE_HOST:-${CT_IP}}"
log "CT-IP: ${CT_IP} -> FLEETBASE_HOST=${FLEETBASE_HOST}"
log "Ports: Console ${CONSOLE_PORT}, API ${API_PORT}, Socket ${SOCKET_PORT}"

if [[ ! -f "${APP_DIR}/docker-compose.override.yml" ]]; then
  log "Erstinstallation: starte offiziellen Wizard non-interactive ..."
  # --non-interactive: localhost-Defaults, bundled MySQL, log-Mailer, local disk.
  # Danach patchen wir HOST-spezifische URLs auf die echte CT-IP.
  printf '\n' | bash scripts/docker-install.sh --non-interactive
else
  log "docker-compose.override.yml existiert -> Wizard wird NICHT erneut gestartet (idempotent)."
fi

# HOST-URLs auf CT-IP patchen (idempotent via sed, nur wenn localhost drinsteht).
if grep -q "localhost" "${APP_DIR}/docker-compose.override.yml" 2>/dev/null; then
  log "Patche docker-compose.override.yml: localhost -> ${CT_IP} ..."
  sed -i "s|://localhost:|://${CT_IP}:|g" "${APP_DIR}/docker-compose.override.yml"
fi
if [[ -f "${APP_DIR}/console/fleetbase.config.json" ]] && grep -q "localhost" "${APP_DIR}/console/fleetbase.config.json"; then
  log "Patche console/fleetbase.config.json auf ${CT_IP} ..."
  sed -i "s|localhost|${CT_IP}|g" "${APP_DIR}/console/fleetbase.config.json" || true
fi

# ------------------------------------------------------- systemd: stack ------
# Reboot-sicher (Anforderung #6): docker.service + fleetbase-stack.service,
# beide systemctl enable, Restart=always, After=network-online.target.
# Container selbst: onboot=1 (setzt Host-Script).
log "Systemd-Unit fleetbase-stack ..."
cat > /etc/systemd/system/fleetbase-stack.service <<EOF
[Unit]
Description=Fleetbase Docker Stack (Compose, Ports 4200/8000)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/docker compose -f ${APP_DIR}/docker-compose.yml -f ${APP_DIR}/docker-compose.override.yml up -d
ExecStop=/usr/bin/docker compose -f ${APP_DIR}/docker-compose.yml -f ${APP_DIR}/docker-compose.override.yml stop
Restart=no

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable fleetbase-stack

# -------------------------------------------------------------- Stack up -----
log "Starte Fleetbase-Stack (docker compose up -d, Images werden ggf. gepullt) ..."
docker compose -f "${APP_DIR}/docker-compose.yml" -f "${APP_DIR}/docker-compose.override.yml" up -d

# deploy.sh nur beim Erstlauf ohne aktive Migration? Upstream-Wizard ruft es
# bereits auf. Hier idempotent: nur wenn application-Container laeuft und
# override frisch ist. Falls deploy.sh schon lief, ist ein zweiter Lauf ok,
# aber langsam – daher nur bei Bedarf (Marker-Datei).
if [[ ! -f "${APP_DIR}/.fleetbase-deployed" ]]; then
  log "Warte auf Datenbank (healthcheck, max 120s) ..."
  for i in $(seq 1 60); do
    DB_CID="$(docker compose -f "${APP_DIR}/docker-compose.yml" ps -q database 2>/dev/null || true)"
    if [[ -n "${DB_CID}" ]] && [[ "$(docker inspect -f '{{.State.Health.Status}}' "${DB_CID}" 2>/dev/null || echo starting)" == "healthy" ]]; then
      log "Datenbank healthy."
      break
    fi
    if [[ "$i" == "60" ]]; then
      docker compose -f "${APP_DIR}/docker-compose.yml" ps
      docker compose -f "${APP_DIR}/docker-compose.yml" logs --tail 100 database || true
      die "Datenbank wurde nicht healthy (120s)."
    fi
    sleep 2
  done
  log "Fuehre deploy.sh in application aus ..."
  docker compose -f "${APP_DIR}/docker-compose.yml" -f "${APP_DIR}/docker-compose.override.yml" exec -T application bash -c "./deploy.sh"
  docker compose -f "${APP_DIR}/docker-compose.yml" -f "${APP_DIR}/docker-compose.override.yml" up -d
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${APP_DIR}/.fleetbase-deployed"
else
  log "Marker .fleetbase-deployed vorhanden -> deploy.sh wird NICHT erneut gestartet (idempotent)."
  docker compose -f "${APP_DIR}/docker-compose.yml" -f "${APP_DIR}/docker-compose.override.yml" up -d
fi

# ----------------------------------------------------------------- Verify ----
log "Verifikation: Service + HTTP-Checks ..."
systemctl is-active --quiet docker \
  || { journalctl -u docker --no-pager -n 50; die "docker.service ist nicht active."; }
log "systemctl is-active docker: $(systemctl is-active docker)"
log "systemctl is-enabled docker: $(systemctl is-enabled docker)"
log "systemctl is-enabled fleetbase-stack: $(systemctl is-enabled fleetbase-stack)"

docker compose -f "${APP_DIR}/docker-compose.yml" ps

# Console (Web UI) auf :4200 – braucht nach Build/Start ggf. 30-60s.
CONSOLE_OK=0
for i in $(seq 1 30); do
  if curl -fsS --max-time 5 "http://127.0.0.1:${CONSOLE_PORT}/" >/dev/null 2>&1; then CONSOLE_OK=1; break; fi
  sleep 5
done
[[ "${CONSOLE_OK}" == "1" ]] || {
  docker compose -f "${APP_DIR}/docker-compose.yml" logs --tail 100 console || true
  die "Console antwortet nicht auf localhost:${CONSOLE_PORT}/."
}
log "Console-Check OK: http://localhost:${CONSOLE_PORT}/ antwortet."

# API auf :8000 (httpd -> application). Darf beim Erststart laenger dauern.
if curl -fsS --max-time 10 "http://127.0.0.1:${API_PORT}/" >/dev/null 2>&1; then
  log "API-Check OK: http://localhost:${API_PORT}/ antwortet."
else
  log "WARNUNG: API antwortet (noch) nicht auf localhost:${API_PORT}/ – deploy/migrations laufen ggf. noch. Logs pruefen:"
  docker compose -f "${APP_DIR}/docker-compose.yml" logs --tail 60 httpd application 2>&1 | head -n 60 || true
fi

echo ""
echo "[${APP}] Fertig. Web UI: http://${CT_IP}:${CONSOLE_PORT}  (API: :${API_PORT})"
echo "[${APP}] Onboarding im Browser abschliessen (Organisation + Admin anlegen)."
