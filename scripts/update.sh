#!/bin/bash
set -e

echo "🔄 Mise à jour du serveur Matrix..."

# Sauvegarder avant mise à jour
./scripts/backup.sh

# Mettre à jour les images
echo "📥 Téléchargement des nouvelles images..."
docker-compose pull

# Redémarrer les services
echo "🔄 Redémarrage des services..."
docker-compose down
docker-compose up -d

echo "⏳ Attente du redémarrage..."
sleep 30

# Vérifier que tout fonctionne
echo "🔍 Vérification des services..."
docker-compose ps

echo "✅ Mise à jour terminée !"