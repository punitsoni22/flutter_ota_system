#!/bin/sh
# Copyright 2026 The Punit Authors
# SPDX-License-Identifier: Apache-2.0

# Daily backup: database, patch/release files and the signing key, into ./backups (keeps 14 days).
# cron: 0 3 * * * cd /opt/flutter_ota_system/deploy && ./backup.sh >> backups/backup.log 2>&1
set -eu
cd "$(dirname "$0")"
mkdir -p backups
stamp=$(date +%Y%m%d-%H%M%S)
dc="docker compose ${COMPOSE_PROJECT:+-p $COMPOSE_PROJECT} -f docker-compose.prod.yml"
$dc exec -T postgres pg_dump -U ota -d ota --format=custom > "backups/db-$stamp.dump"
$dc exec -T api tar -C /data -czf - artifacts keys > "backups/files-$stamp.tgz"
find backups -name 'db-*.dump' -mtime +14 -delete
find backups -name 'files-*.tgz' -mtime +14 -delete
echo "backup $stamp ok"
