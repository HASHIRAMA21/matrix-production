#!/bin/bash
set -e

BACKUP_DIR="/backup/matrix"
DATE=$(date +%Y%m%d_%H%M%S)

echo " Sauvegarde Matrix - $DATE"

# Créer le dossier de sauvegarde
mkdir -p "$BACKUP_DIR"

# Sauvegarder PostgreSQL
echo " Sauvegarde PostgreSQL..."
docker exec matrix_postgres pg_dump -U synapse_user synapse | gzip > "$BACKUP_DIR/postgres_$DATE.sql.gz"

# Sauvegarder les données Synapse
echo " Sauvegarde données Synapse..."
docker run --rm -v matrix-production_synapse_data:/data -v "$BACKUP_DIR":/backup alpine tar czf "/backup/synapse_data_$DATE.tar.gz" -C /data .

# Sauvegarder Redis
echo " Sauvegarde Redis..."
docker exec matrix_redis redis-cli --rdb /data/dump.rdb
docker run --rm -v matrix-production_redis_data:/data -v "$BACKUP_DIR":/backup alpine cp /data/dump.rdb "/backup/redis_$DATE.rdb"

# Sauvegarder la configuration
echo " Sauvegarde configuration..."
tar czf "$BACKUP_DIR/config_$DATE.tar.gz" synapse/ traefik/ nginx/ .env

# Nettoyer les anciennes sauvegardes (garder 7 jours)
find "$BACKUP_DIR" -name "*.gz" -mtime +7 -delete
find "$BACKUP_DIR" -name "*.rdb" -mtime +7 -delete

echo " Sauvegarde terminée: $BACKUP_DIR"