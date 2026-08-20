#!/bin/sh
set -eu

: "${RESTORE_DATABASE_URL:?RESTORE_DATABASE_URL must name an isolated database}"
: "${BACKUP_FILE:?BACKUP_FILE must name a PostgreSQL custom-format backup}"
case "$RESTORE_DATABASE_URL" in
  *localhost*|*127.0.0.1*|*".test"*) ;;
  *) echo "RESTORE_DATABASE_URL must point to an isolated local or test database" >&2; exit 2 ;;
esac
pg_restore --clean --if-exists --no-owner --dbname "$RESTORE_DATABASE_URL" "$BACKUP_FILE"
psql "$RESTORE_DATABASE_URL" -v ON_ERROR_STOP=1 -c 'SELECT COUNT(*) AS users FROM users;'
echo "Restore drill completed. Perform login, enrollment, and revocation checks before accepting this backup."
