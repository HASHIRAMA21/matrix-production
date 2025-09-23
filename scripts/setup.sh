#!/bin/bash
set -e

echo "🚀 Configuration du serveur Matrix en production..."

# Vérifier les prérequis
if ! command -v docker &> /dev/null; then
    echo "❌ Docker n'est pas installé"
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    echo "❌ Docker Compose n'est pas installé"
    exit 1
fi

# Vérifier le fichier .env
if [ ! -f .env ]; then
    echo "❌ Fichier .env manquant"
    echo "Copiez .env.example vers .env et configurez-le"
    exit 1
fi

# Charger les variables d'environnement
source .env

# Créer le réseau Docker
docker network create web 2>/dev/null || true

# Générer les secrets si ils n'existent pas
if [ -z "$TURN_SECRET" ]; then
    echo "⚠️  Génération d'un secret TURN..."
    TURN_SECRET=$(openssl rand -hex 32)
    sed -i "s/votre_secret_turn_tres_long_et_securise/$TURN_SECRET/" .env
fi

if [ -z "$REGISTRATION_SHARED_SECRET" ]; then
    echo "⚠️  Génération d'un secret d'enregistrement..."
    REG_SECRET=$(openssl rand -hex 32)
    sed -i "s/votre_secret_registration_tres_long/$REG_SECRET/" .env
fi

# Générer la configuration Synapse si elle n'existe pas
if [ ! -f synapse/homeserver.yaml ]; then
    echo "📝 Génération de la configuration Synapse..."
    docker run -it --rm \
        -v "$(pwd)/synapse:/data" \
        -e SYNAPSE_SERVER_NAME="$SYNAPSE_SERVER_NAME" \
        -e SYNAPSE_REPORT_STATS=no \
        matrixdotorg/synapse:latest generate
    
    # Remplacer par notre configuration
    cp synapse/homeserver.yaml.template synapse/homeserver.yaml
    sed -i "s/matrix\.exemple\.com/$DOMAIN/g" synapse/homeserver.yaml
fi

# Configurer les permissions
chmod 600 .env
chmod -R 755 synapse/
chmod -R 755 traefik/

# Démarrer les services
echo "🐳 Démarrage des services..."
docker-compose up -d

echo "⏳ Attente du démarrage des services..."
sleep 30

# Vérifier que les services sont actifs
echo "🔍 Vérification des services..."
docker-compose ps

echo ""
echo "✅ Installation terminée !"
echo ""
echo "🌐 Accès web:"
echo "   - Matrix: https://$DOMAIN"
echo "   - Element: https://element.$DOMAIN"
echo "   - Traefik: https://traefik.$DOMAIN"
echo "   - Grafana: https://grafana.$DOMAIN"
echo ""
echo "👤 Pour créer un utilisateur admin:"
echo "   docker exec -it matrix_synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008"
echo ""