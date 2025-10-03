#!/bin/bash

# Matrix Synapse - Script principal de gestion
# Usage: ./matrix.sh [setup|start|stop|test|logs|clean]

set -e

# Configuration centralisée
MATRIX_DOMAIN="matrix.ndinga237.com"
HTTP_PORT="8081"
HTTPS_PORT="8445"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Vérification des prérequis
check_requirements() {
    log "Vérification des prérequis..."

    command -v docker >/dev/null || error "Docker non installé"
    command -v docker-compose >/dev/null || error "Docker Compose non installé"

    # Vérifier le fichier .env
    [ -f .env ] || error "Fichier .env manquant"

    # Extraire les configurations depuis .env
    POSTGRES_HOST=$(grep "^POSTGRES_HOST=" .env | cut -d'=' -f2)
    POSTGRES_PORT=$(grep "^POSTGRES_PORT=" .env | cut -d'=' -f2)
    REDIS_HOST=$(grep "^REDIS_HOST=" .env | cut -d'=' -f2)
    REDIS_PORT=$(grep "^REDIS_PORT=" .env | cut -d'=' -f2)
    HTTP_PORT=$(grep "^HTTP_PORT=" .env | cut -d'=' -f2)
    HTTPS_PORT=$(grep "^HTTPS_PORT=" .env | cut -d'=' -f2)

    # Vérifier connectivité aux services distants
    if [[ "$POSTGRES_HOST" != "VotreIPPostgreSQL" ]]; then
        nc -z "$POSTGRES_HOST" "$POSTGRES_PORT" || error "PostgreSQL non accessible ($POSTGRES_HOST:$POSTGRES_PORT)"
    else
        warning "Configurez POSTGRES_HOST dans .env avec l'IP réelle"
    fi

    if [[ "$REDIS_HOST" != "VotreIPRedis" ]]; then
        nc -z "$REDIS_HOST" "$REDIS_PORT" || error "Redis non accessible ($REDIS_HOST:$REDIS_PORT)"
    else
        warning "Configurez REDIS_HOST dans .env avec l'IP réelle"
    fi

    # Vérifier ports locaux disponibles
    for port in $HTTP_PORT $HTTPS_PORT 8448 3478 5349; do
        nc -z localhost $port 2>/dev/null && error "Port $port déjà utilisé"
    done

    success "Prérequis validés"
}

# Configuration initiale
setup() {
    log "Configuration Matrix Synapse..."

    check_requirements

    # Génération du .env si nécessaire
    if [ ! -f .env ]; then
        log "Génération du fichier .env..."
        generate_env
    else
        warning "Fichier .env existant - utilisez 'clean' pour le régénérer"
    fi

    # Configuration PostgreSQL
    setup_postgresql

    # Test de connectivité
    test_connectivity

    success "Configuration terminée !"
    log "Utilisez './matrix.sh start' pour démarrer les services"
}

# Génération du fichier .env
generate_env() {
    cat > .env << EOF
# Configuration Matrix Synapse
DOMAIN=$MATRIX_DOMAIN
SYNAPSE_SERVER_NAME=$MATRIX_DOMAIN

# URLs Matrix
PUBLIC_BASEURL=https://$MATRIX_DOMAIN/
WEB_CLIENT_LOCATION=https://element.$MATRIX_DOMAIN/

# Base de données PostgreSQL (peut être sur VPS séparée)
POSTGRES_HOST=VotreIPPostgreSQL
POSTGRES_PORT=5432
POSTGRES_DB=synapse
POSTGRES_USER=synapse_user
POSTGRES_PASSWORD=$(openssl rand -base64 32)

# Redis (peut être sur VPS séparée)
REDIS_HOST=VotreIPRedis
REDIS_PORT=6379
REDIS_PASSWORD=

# Ports Matrix
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT

# Secrets
TURN_SECRET=$(openssl rand -base64 32)
REGISTRATION_SHARED_SECRET=$(openssl rand -base64 32)
PROMETHEUS_PASSWORD=$(openssl rand -base64 20)

# Email
SMTP_HOST=smtp.$MATRIX_DOMAIN
SMTP_PORT=587
SMTP_USER=noreply@$MATRIX_DOMAIN
SMTP_PASSWORD=$(openssl rand -base64 20)
EMAIL_PATTERN=.*@${MATRIX_DOMAIN#*.}

# Traefik
TRAEFIK_DASHBOARD_USER=admin
TRAEFIK_DASHBOARD_PASSWORD_HASH=\$(openssl rand -base64 20 | htpasswd -nbiB admin)

# Système
TZ=Europe/Paris
SYNAPSE_VERSION=latest
EOF

    success "Fichier .env généré"
    warning "Modifiez les mots de passe PostgreSQL et Redis dans .env"
}

# Configuration PostgreSQL
setup_postgresql() {
    log "Configuration PostgreSQL..."

    POSTGRES_HOST=$(grep "^POSTGRES_HOST=" .env | cut -d'=' -f2)
    POSTGRES_PASSWORD=$(grep "^POSTGRES_PASSWORD=" .env | cut -d'=' -f2)

    if [[ "$POSTGRES_HOST" == "VotreIPPostgreSQL" ]]; then
        warning "Configurez d'abord POSTGRES_HOST dans .env"
        return
    fi

    # Création du script SQL temporaire
    cat > /tmp/matrix_setup.sql << EOF
CREATE USER synapse_user WITH PASSWORD '$POSTGRES_PASSWORD';
CREATE DATABASE synapse WITH OWNER synapse_user ENCODING 'UTF8' LC_COLLATE = 'C' LC_CTYPE = 'C' TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE synapse TO synapse_user;
EOF

    # Tentative de connexion distante
    if command -v psql >/dev/null; then
        if PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -U postgres -f /tmp/matrix_setup.sql 2>/dev/null; then
            success "Base de données PostgreSQL configurée sur $POSTGRES_HOST"
        else
            warning "Impossible de configurer PostgreSQL automatiquement"
            log "Exécutez manuellement sur $POSTGRES_HOST :"
            cat /tmp/matrix_setup.sql
        fi
    else
        warning "psql non installé - configuration manuelle requise"
        log "Script SQL à exécuter sur $POSTGRES_HOST :"
        cat /tmp/matrix_setup.sql
    fi

    rm -f /tmp/matrix_setup.sql
}

# Configuration dynamique de homeserver.yaml
configure_homeserver() {
    log "Configuration dynamique de homeserver.yaml..."

    REDIS_PASSWORD=$(grep "^REDIS_PASSWORD=" .env | cut -d'=' -f2)

    # Copie du template
    cp synapse/config/homeserver.yaml synapse/config/homeserver.yaml.bak 2>/dev/null || true

    # Ajout conditionnel du mot de passe Redis
    if [ -n "$REDIS_PASSWORD" ]; then
        log "Redis avec authentification"
        # Ajouter la ligne password après port
        sed '/port: !ENV REDIS_PORT/a\  password: !ENV REDIS_PASSWORD' synapse/config/homeserver.yaml > synapse/config/homeserver.yaml.tmp
        mv synapse/config/homeserver.yaml.tmp synapse/config/homeserver.yaml
    else
        log "Redis sans authentification"
        # S'assurer qu'il n'y a pas de ligne password
        sed '/password: !ENV REDIS_PASSWORD/d' synapse/config/homeserver.yaml > synapse/config/homeserver.yaml.tmp
        mv synapse/config/homeserver.yaml.tmp synapse/config/homeserver.yaml
    fi

    success "homeserver.yaml configuré"
}

# Validation de la configuration
validate_config() {
    log "Validation de la configuration..."

    [ -f .env ] || error "Fichier .env manquant"

    # Variables obligatoires
    local required_vars=(
        "DOMAIN" "POSTGRES_HOST" "POSTGRES_PASSWORD"
        "REDIS_HOST" "TURN_SECRET"
        "REGISTRATION_SHARED_SECRET"
    )

    for var in "${required_vars[@]}"; do
        if ! grep -q "^$var=" .env || grep -q "^$var=Votre" .env; then
            error "Variable $var non configurée dans .env"
        fi
    done

    # Configuration dynamique de homeserver.yaml
    configure_homeserver

    success "Configuration valide"
}

# Test de connectivité
test_connectivity() {
    log "Test de connectivité..."

    [ -f .env ] || { warning "Fichier .env manquant"; return; }

    POSTGRES_HOST=$(grep "^POSTGRES_HOST=" .env | cut -d'=' -f2)
    REDIS_HOST=$(grep "^REDIS_HOST=" .env | cut -d'=' -f2)

    # Test connectivité directe
    if [[ "$POSTGRES_HOST" != "VotreIPPostgreSQL" ]]; then
        if nc -z "$POSTGRES_HOST" 5432 2>/dev/null; then
            success "PostgreSQL accessible ($POSTGRES_HOST:5432)"
        else
            warning "PostgreSQL non accessible ($POSTGRES_HOST:5432)"
        fi
    fi

    if [[ "$REDIS_HOST" != "VotreIPRedis" ]]; then
        if nc -z "$REDIS_HOST" 6379 2>/dev/null; then
            success "Redis accessible ($REDIS_HOST:6379)"

            # Test d'authentification si redis-cli disponible
            if command -v redis-cli >/dev/null; then
                REDIS_PASSWORD=$(grep "^REDIS_PASSWORD=" .env | cut -d'=' -f2)
                if [ -n "$REDIS_PASSWORD" ]; then
                    if redis-cli -h "$REDIS_HOST" -p 6379 -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q "PONG"; then
                        success "Redis authentification OK"
                    else
                        warning "Problème authentification Redis"
                    fi
                else
                    if redis-cli -h "$REDIS_HOST" -p 6379 ping 2>/dev/null | grep -q "PONG"; then
                        success "Redis connexion OK (sans auth)"
                    else
                        warning "Redis nécessite peut-être une authentification"
                    fi
                fi
            fi
        else
            warning "Redis non accessible ($REDIS_HOST:6379)"
        fi
    fi

    # Test depuis conteneur si services Matrix démarrés
    if docker ps --filter "name=matrix_synapse" --filter "status=running" | grep -q "matrix_synapse"; then
        log "Test depuis conteneur Synapse..."

        if docker exec matrix_synapse nc -z "$POSTGRES_HOST" 5432 2>/dev/null; then
            success "PostgreSQL accessible depuis conteneur"
        else
            warning "PostgreSQL non accessible depuis conteneur"
        fi

        if docker exec matrix_synapse nc -z "$REDIS_HOST" 6379 2>/dev/null; then
            success "Redis accessible depuis conteneur"

            # Test spécifique Redis (avec ou sans auth)
            REDIS_PASSWORD=$(grep "^REDIS_PASSWORD=" .env | cut -d'=' -f2)

            # Installation de redis-cli si nécessaire
            if ! docker exec matrix_synapse which redis-cli >/dev/null 2>&1; then
                log "Installation de redis-cli dans le conteneur..."
                docker exec matrix_synapse apt-get update -qq && docker exec matrix_synapse apt-get install -y -qq redis-tools >/dev/null 2>&1
            fi

            if [ -n "$REDIS_PASSWORD" ]; then
                if docker exec matrix_synapse redis-cli -h "$REDIS_HOST" -p 6379 -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q "PONG"; then
                    success "Redis authentification OK"
                else
                    warning "Problème authentification Redis"
                fi
            else
                if docker exec matrix_synapse redis-cli -h "$REDIS_HOST" -p 6379 ping 2>/dev/null | grep -q "PONG"; then
                    success "Redis connexion OK (sans auth)"
                else
                    warning "Problème connexion Redis"
                fi
            fi
        else
            warning "Redis non accessible depuis conteneur"
        fi
    fi
}

# Démarrage des services
start() {
    log "Démarrage des services Matrix..."

    [ ! -f .env ] && error "Fichier .env manquant - exécutez './matrix.sh setup'"

    # Validation de la configuration
    validate_config

    # Création des réseaux si nécessaires
    if ! docker network ls | grep -q "matrix-network"; then
        log "Création du réseau matrix-network..."
        docker network create matrix-network
    fi

    if ! docker network ls | grep -q "web"; then
        log "Création du réseau web..."
        docker network create web
    fi

    # Arrêt des services existants
    docker-compose down --remove-orphans 2>/dev/null || true

    # Démarrage ordonné avec apparmor=unconfined pour Synapse
    docker-compose up -d volume-permissions && sleep 5
    docker-compose up -d traefik && sleep 10
    docker-compose up -d synapse && sleep 15
    docker-compose up -d coturn prometheus grafana

    success "Services démarrés"

    # Récupération des ports depuis .env
    HTTPS_PORT=$(grep "^HTTPS_PORT=" .env 2>/dev/null | cut -d'=' -f2 || echo "8445")

    log "Services Matrix démarrés :"
    log "  - Traefik : https://$MATRIX_DOMAIN:$HTTPS_PORT"
    log "  - Matrix API : http://localhost:$HTTPS_PORT"
    log ""
    warning "Configurez nginx VPS avec : ./matrix.sh setup-nginx"
    log "Puis accès via nginx VPS :"
    log "  - Matrix : https://$MATRIX_DOMAIN"
    log "  - Element : https://element.$MATRIX_DOMAIN"

    # Affichage du statut
    show_status
}

# Arrêt des services
stop() {
    log "Arrêt des services Matrix..."
    docker-compose down
    success "Services arrêtés"
}

# Affichage des logs
logs() {
    service=${1:-synapse}
    log "Logs du service $service..."
    docker-compose logs -f $service
}

# Affichage du statut
show_status() {
    log "Statut des services:"
    docker-compose ps

    echo ""
    log "URLs d'accès:"
    echo "  Matrix Synapse : https://$MATRIX_DOMAIN:$HTTPS_PORT"
    echo "  Element Web    : https://element.$MATRIX_DOMAIN:$HTTPS_PORT"
    echo "  Traefik        : https://traefik.$MATRIX_DOMAIN:$HTTPS_PORT"
}

# Test complet
test() {
    log "Test complet du système..."

    check_requirements
    test_connectivity

    # Test des services Docker si ils tournent
    if docker-compose ps | grep -q "Up"; then
        log "Test des conteneurs..."
        for service in traefik synapse; do
            if docker-compose ps $service | grep -q "Up"; then
                success "Service $service opérationnel"
            else
                warning "Service $service non démarré"
            fi
        done
    else
        warning "Aucun service Matrix en cours d'exécution"
    fi

    success "Tests terminés"
}

# Nettoyage
clean() {
    log "Nettoyage du système..."

    # Arrêt et suppression
    docker-compose down --volumes --remove-orphans 2>/dev/null || true

    # Suppression des fichiers générés
    rm -f .env

    # Nettoyage Docker
    docker system prune -f

    success "Nettoyage terminé"
}

# Aide
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  setup           Configuration initiale"
    echo "  start           Démarrer les services"
    echo "  stop            Arrêter les services"
    echo "  test            Tester le système"
    echo "  validate        Valider la configuration"
    echo "  logs            Afficher les logs [service]"
    echo "  create-synapse  Créer Synapse avec apparmor=unconfined"
    echo "  setup-nginx     Configurer nginx VPS existant"
    echo "  clean           Nettoyer complètement"
    echo "  status          Afficher le statut"
    echo ""
    echo "Examples:"
    echo "  $0 setup          # Configuration initiale"
    echo "  $0 start          # Démarrer Matrix"
    echo "  $0 logs synapse   # Logs de Synapse"
    echo "  $0 clean          # Nettoyage complet"
}

# Création manuelle du conteneur Synapse
create_synapse() {
    log "Création manuelle du conteneur Synapse..."

    [ ! -f .env ] && error "Fichier .env manquant"

    # Création du réseau si nécessaire
    if ! docker network ls | grep -q "matrix-network"; then
        docker network create matrix-network
    fi

    # Arrêt du conteneur existant
    docker stop matrix_synapse 2>/dev/null || true
    docker rm matrix_synapse 2>/dev/null || true

    # Variables depuis .env
    POSTGRES_HOST=$(grep "^POSTGRES_HOST=" .env | cut -d'=' -f2)
    REDIS_HOST=$(grep "^REDIS_HOST=" .env | cut -d'=' -f2)

    # Création du conteneur avec apparmor=unconfined (sans user restriction)
    docker run -d \
        --name matrix_synapse \
        --restart unless-stopped \
        --security-opt apparmor=unconfined \
        --network matrix-network \
        --add-host "postgres.host:$POSTGRES_HOST" \
        --add-host "redis.host:$REDIS_HOST" \
        -v matrix_synapse_data:/data \
        -v "$(pwd)/synapse/config/homeserver.yaml:/data/homeserver.yaml:ro" \
        -v "$(pwd)/synapse/config/log.config:/data/log.config:ro" \
        -v "$(pwd)/synapse/keys:/data/keys:ro" \
        -v "$(pwd)/synapse/data/media_store:/data/media_store" \
        -v "$(pwd)/synapse/data/logs:/data/logs" \
        -v "$(pwd)/synapse/data/uploads:/data/uploads" \
        --env-file .env \
        -e SYNAPSE_CONFIG_PATH=/data/homeserver.yaml \
        matrixdotorg/synapse:latest

    success "Conteneur Synapse créé avec apparmor=unconfined"
}

# Configuration nginx VPS
setup_nginx() {
    log "Configuration nginx VPS..."

    if [ ! -d "/etc/nginx/sites-available" ]; then
        error "nginx non détecté sur cette VPS"
    fi

    # Adaptation des chemins dans les configurations
    CURRENT_DIR=$(pwd)
    DOMAIN=$(grep "^DOMAIN=" .env | cut -d'=' -f2)

    # Adaptation du fichier matrix
    sed "s|matrix.ndinga237.com|$DOMAIN|g" matrix.nginx.conf > /tmp/matrix.conf

    # Adaptation du fichier element
    sed -e "s|element.matrix.ndinga237.com|element.$DOMAIN|g" \
        -e "s|/home/vincess/DEVOPS/matrix-production/element|$CURRENT_DIR/element|g" \
        element.nginx.conf > /tmp/element.conf

    # Copie des configurations adaptées
    if sudo cp /tmp/matrix.conf /etc/nginx/sites-available/matrix.conf; then
        success "Configuration matrix copiée"
    fi

    if sudo cp /tmp/element.conf /etc/nginx/sites-available/element.conf; then
        success "Configuration element copiée"
    fi

    # Nettoyage
    rm -f /tmp/matrix.conf /tmp/element.conf

    # Activation des sites
    sudo ln -sf /etc/nginx/sites-available/matrix.conf /etc/nginx/sites-enabled/ 2>/dev/null
    sudo ln -sf /etc/nginx/sites-available/element.conf /etc/nginx/sites-enabled/ 2>/dev/null

    # Test de la configuration
    if sudo nginx -t; then
        success "Configuration nginx valide"
        log "Redémarrez nginx : sudo systemctl reload nginx"
    else
        error "Erreur dans la configuration nginx"
        log "Vérifiez les certificats SSL dans :"
        log "  /etc/nginx/sites-available/matrix.conf"
        log "  /etc/nginx/sites-available/element.conf"
    fi

    warning "Adaptez les certificats SSL si nécessaire"
}

# Point d'entrée principal
case "${1:-}" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    test) test ;;
    validate) validate_config ;;
    logs) logs $2 ;;
    status) show_status ;;
    create-synapse) create_synapse ;;
    setup-nginx) setup_nginx ;;
    clean) clean ;;
    *) usage ;;
esac