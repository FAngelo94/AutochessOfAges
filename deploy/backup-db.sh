#!/usr/bin/env bash
#
# backup-db.sh — pg_dump notturno del Postgres locale verso una Hetzner Storage
# Box. Questo e' l'UNICO backup che esiste (self-hosted): la prova di restore di
# SETUP_VPS.md passo 10 e' obbligatoria, non consigliata.
#
# Installazione:
#   sudo install -m 700 deploy/backup-db.sh /opt/autochess/backup-db.sh
#   sudo crontab -e   ->   17 3 * * *  /opt/autochess/backup-db.sh >> /var/log/autochess-backup.log 2>&1
#
# Richiede: postgresql-client (pg_dump), openssh-client (scp/ssh), gzip.
# Legge le variabili da /etc/autochess/env (BACKUP_DB_URL, BACKUP_SSH_TARGET,
# BACKUP_SSH_PORT). La chiave SSH dell'utente che lancia il cron deve essere
# gia' autorizzata sulla Storage Box.
#
# IMPORTANTE: un backup non testato non e' un backup. Vedi SETUP_VPS.md passo 10.

set -euo pipefail

ENV_FILE="/etc/autochess/env"
[ -r "$ENV_FILE" ] || { echo "manca $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${BACKUP_DB_URL:?BACKUP_DB_URL non impostata}"
: "${BACKUP_SSH_TARGET:?BACKUP_SSH_TARGET non impostata}"
BACKUP_SSH_PORT="${BACKUP_SSH_PORT:-23}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

STAMP="$(date -u +%Y%m%d-%H%M%S)"
DUMP="$WORKDIR/autochess-${STAMP}.sql.gz"

echo "[$(date -u +%FT%TZ)] pg_dump -> $(basename "$DUMP")"
pg_dump --no-owner --no-privileges "$BACKUP_DB_URL" | gzip -9 > "$DUMP"

SIZE="$(stat -c %s "$DUMP")"
[ "$SIZE" -gt 1024 ] || { echo "dump sospettosamente piccolo ($SIZE byte), abort"; exit 1; }

echo "[$(date -u +%FT%TZ)] upload -> $BACKUP_SSH_TARGET"
scp -P "$BACKUP_SSH_PORT" -q "$DUMP" "$BACKUP_SSH_TARGET/"

# retention: elimina i dump piu' vecchi di RETENTION_DAYS sulla Storage Box.
# (find via SFTP non c'e'; si usa una shell remota se disponibile, altrimenti
#  la Storage Box Hetzner accetta comandi ssh limitati come questo)
echo "[$(date -u +%FT%TZ)] retention: >${RETENTION_DAYS} giorni"
REMOTE_HOST="${BACKUP_SSH_TARGET%%:*}"
REMOTE_PATH="${BACKUP_SSH_TARGET#*:}"
ssh -p "$BACKUP_SSH_PORT" "$REMOTE_HOST" \
  "find '$REMOTE_PATH' -name 'autochess-*.sql.gz' -mtime +${RETENTION_DAYS} -delete" \
  || echo "WARN: retention remota fallita (shell remota non disponibile?) — potare a mano"

echo "[$(date -u +%FT%TZ)] fatto."
