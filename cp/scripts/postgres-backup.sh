#!/bin/sh
set -eu

: "${BACKUP_DIR:?BACKUP_DIR must name a mounted backup directory}"
: "${DATABASE_URL:?DATABASE_URL must be set}"
umask 077
mkdir -p "$BACKUP_DIR"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
pg_dump --format=custom --no-owner --file "$BACKUP_DIR/control-plane-$stamp.dump" "$DATABASE_URL"
find "$BACKUP_DIR" -type f -name 'control-plane-*.dump' -mtime +"${BACKUP_RETENTION_DAYS:-30}" -delete
