#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Fonction d'affichage des messages
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Vérification que le script est exécuté depuis la racine du projet
if [ ! -f "docker-compose.yml" ]; then
    error "Ce script doit être exécuté depuis la racine du projet Matrix"
    exit 1
fi

# Chargement des variables d'environnement
if [ ! -f ".env" ]; then
    error "Fichier .env introuvable"
    exit 1
fi

log "Chargement des variables d'environnement..."
set -a
source .env
set +a

REQUIRED_VARS=(
    "DOMAIN"
    "SYNAPSE_SERVER_NAME"
    "POSTGRES_DB"
    "POSTGRES_USER"
    "POSTGRES_PASSWORD"
    "REDIS_PASSWORD"
    "TURN_SECRET"
    "REGISTRATION_SHARED_SECRET"
)

log "Vérification des variables d'environnement requises..."
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        error "Variable d'environnement $var non définie"
        exit 1
    fi
    # Vérification que ce ne sont pas des placeholders
    if [[ "${!var}" =~ "votre_" ]] || [[ "${!var}" =~ "exemple" ]]; then
        error "La variable $var contient encore une valeur d'exemple: ${!var}"
        error "Veuillez mettre à jour le fichier .env avec de vraies valeurs"
        exit 1
    fi
done

DOMAIN_BASE=$(echo "$DOMAIN" | sed 's/^matrix\.//')

# Création des répertoires nécessaires
log "Création des répertoires de configuration..."
mkdir -p synapse/config
mkdir -p synapse/keys

# Génération du fichier homeserver.yaml
log "Génération du fichier homeserver.yaml..."
envsubst < synapse/homeserver.yaml.template > synapse/config/homeserver.yaml

# Substitution supplémentaire pour DOMAIN_BASE
sed -i.bak "s/\${DOMAIN_BASE}/$DOMAIN_BASE/g" synapse/config/homeserver.yaml
rm synapse/config/homeserver.yaml.bak 2>/dev/null || true

# Génération de la clé de signature si elle n'existe pas
SIGNING_KEY_FILE="synapse/keys/${SYNAPSE_SERVER_NAME}.signing.key"
if [ ! -f "$SIGNING_KEY_FILE" ]; then
    log "Génération de la clé de signature Synapse..."

    # Génération via Docker avec les bonnes permissions
    docker run --rm \
        -v "$(pwd)/synapse/keys:/keys" \
        -e SYNAPSE_SERVER_NAME="$SYNAPSE_SERVER_NAME" \
        matrixdotorg/synapse:latest \
        generate_signing_key -o "/keys/${SYNAPSE_SERVER_NAME}.signing.key"

    # Définition des permissions correctes
    chmod 640 "$SIGNING_KEY_FILE"

    log "Clé de signature générée: $SIGNING_KEY_FILE"
else
    log "Clé de signature existante trouvée: $SIGNING_KEY_FILE"
fi

# Ajout de la référence à la clé de signature dans la config
echo "" >> synapse/config/homeserver.yaml
echo "# Signing key" >> synapse/config/homeserver.yaml
echo "signing_key_path: \"/data/keys/${SYNAPSE_SERVER_NAME}.signing.key\"" >> synapse/config/homeserver.yaml

# Génération du fichier log.config
log "Génération du fichier log.config..."
cat > synapse/config/log.config << 'EOF'
version: 1

formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
  file:
    class: logging.handlers.TimedRotatingFileHandler
    formatter: precise
    filename: /data/logs/homeserver.log
    when: midnight
    backupCount: 3
    encoding: utf8

  console:
    class: logging.StreamHandler
    formatter: precise

loggers:
    synapse.storage.SQL:
        level: INFO

root:
    level: INFO
    handlers: [file, console]

disable_existing_loggers: false
EOF

# Création des répertoires de données nécessaires
log "Préparation des répertoires de données..."
mkdir -p synapse/data/{media_store,logs,uploads}

# Génération des secrets s'ils sont manquants dans .env
log "Vérification des secrets..."

# Fonction pour générer un secret aléaoire
generate_secret() {
    openssl rand -hex 32
}

# Vérification et génération des secrets si nécessaire
SECRETS_UPDATED=false

if [[ "$TURN_SECRET" =~ "votre_secret" ]] || [ ${#TURN_SECRET} -lt 32 ]; then
    NEW_TURN_SECRET=$(generate_secret)
    sed -i.bak "s|TURN_SECRET=.*|TURN_SECRET=$NEW_TURN_SECRET|" .env
    export TURN_SECRET="$NEW_TURN_SECRET"
    SECRETS_UPDATED=true
    log "Nouveau secret TURN généré"
fi

if [[ "$REGISTRATION_SHARED_SECRET" =~ "votre_secret" ]] || [ ${#REGISTRATION_SHARED_SECRET} -lt 32 ]; then
    NEW_REG_SECRET=$(generate_secret)
    sed -i.bak "s|REGISTRATION_SHARED_SECRET=.*|REGISTRATION_SHARED_SECRET=$NEW_REG_SECRET|" .env
    export REGISTRATION_SHARED_SECRET="$NEW_REG_SECRET"
    SECRETS_UPDATED=true
    log "Nouveau secret d'enregistrement généré"
fi

# Nettoyage des fichiers de sauvegarde
rm .env.bak 2>/dev/null || true

if [ "$SECRETS_UPDATED" = true ]; then
    warn "Des secrets ont été générés. Veuillez relancer ce script pour appliquer les changements"
    warn "Ou redémarrez les conteneurs après génération complète"
fi

# Affichage du résumé
log "Configuration générée avec succès!"
echo
echo -e "${BLUE}Fichiers générés:${NC}"
echo "  - synapse/config/homeserver.yaml"
echo "  - synapse/config/log.config"
echo "  - synapse/keys/${SYNAPSE_SERVER_NAME}.signing.key"
echo
echo -e "${BLUE}Domaines configurés:${NC}"
echo "  - Serveur Matrix: https://$DOMAIN"
echo "  - Client Element: https://element.$DOMAIN"
echo "  - Domaine de base: $DOMAIN_BASE"
echo
echo -e "${GREEN}La configuration est prête pour le déploiement!${NC}"
echo "Vous pouvez maintenant exécuter: docker-compose up -d"