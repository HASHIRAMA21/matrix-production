#!/bin/bash

set -e

# Couleurs pour les messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_header() {
    echo
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo
}

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Configuration des variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
ENV_FILE="$PROJECT_DIR/.env"

print_header "DÉPLOIEMENT MATRIX SYNAPSE - UBUNTU 24 VPS"

# Vérifications préliminaires
log "Vérification du système..."

# Vérifier si c'est Ubuntu
if ! grep -q "Ubuntu" /etc/os-release; then
    error "Ce script est conçu pour Ubuntu. Système détecté: $(lsb_release -d | cut -f2)"
    exit 1
fi

# Vérifier si c'est la racine du projet
if [ ! -f "$COMPOSE_FILE" ]; then
    error "Fichier docker-compose.yml introuvable dans $PROJECT_DIR"
    error "Exécutez ce script depuis la racine du projet Matrix"
    exit 1
fi

# Vérifier les privilèges
if [ "$EUID" -eq 0 ]; then
    warn "Ce script ne doit PAS être exécuté en root"
    warn "Exécutez-le en tant qu'utilisateur normal avec sudo disponible"
    exit 1
fi

# Vérifier sudo
if ! sudo -n true 2>/dev/null; then
    error "Ce script nécessite l'accès sudo"
    exit 1
fi

success "Système Ubuntu détecté et vérifications passées"

print_header "INSTALLATION DES DÉPENDANCES SYSTÈME"

log "Mise à jour des paquets système..."
sudo apt update -qq

log "Installation des paquets requis..."
sudo apt install -y \
    curl \
    wget \
    git \
    apache2-utils \
    openssl \
    ca-certificates \
    gnupg \
    lsb-release \
    ufw \
    fail2ban \
    unattended-upgrades

# Installation Docker si nécessaire
if ! command -v docker &> /dev/null; then
    log "Installation de Docker..."

    # Ajout de la clé GPG officielle Docker
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    # Ajout du dépôt Docker
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Installation Docker
    sudo apt update -qq
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Ajout de l'utilisateur au groupe docker
    sudo usermod -aG docker $USER

    success "Docker installé avec succès"
    DOCKER_INSTALLED=true
else
    success "Docker déjà installé"
fi

# Installation Docker Compose si nécessaire (version standalone)
if ! command -v docker-compose &> /dev/null; then
    log "Installation de Docker Compose..."

    # Installation via pip pour avoir la dernière version
    sudo apt install -y python3-pip
    sudo pip3 install docker-compose

    success "Docker Compose installé avec succès"
else
    success "Docker Compose déjà installé"
fi

print_header "CONFIGURATION DU FIREWALL UFW"

log "Configuration des règles de pare-feu..."

# Reset UFW
sudo ufw --force reset

# Politique par défaut
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH
sudo ufw allow ssh
sudo ufw allow 22/tcp

# HTTP/HTTPS
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Matrix Federation
sudo ufw allow 8448/tcp

# TURN/STUN
sudo ufw allow 3478/tcp
sudo ufw allow 3478/udp
sudo ufw allow 5349/tcp
sudo ufw allow 5349/udp
sudo ufw allow 49152:65535/tcp
sudo ufw allow 49152:65535/udp

# Activation
sudo ufw --force enable

success "Firewall configuré avec succès"

print_header "PRÉPARATION DU PROJET MATRIX"

cd "$PROJECT_DIR"

# Vérification du fichier .env
if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$ENV_FILE.example" ]; then
        log "Copie du fichier .env.example vers .env..."
        cp "$ENV_FILE.example" "$ENV_FILE"

        error "IMPORTANT: Vous devez éditer le fichier .env avec vos vraies valeurs"
        error "Le déploiement s'arrête ici. Après édition, relancez le script."
        echo
        echo -e "${YELLOW}Fichiers à éditer:${NC}"
        echo "  1. $ENV_FILE (OBLIGATOIRE)"
        echo "  2. Configurez vos DNS pour pointer vers cette machine"
        echo
        echo -e "${YELLOW}Puis relancez:${NC} $0"
        exit 0
    else
        error "Fichier .env.example introuvable"
        exit 1
    fi
fi

# Vérification que .env contient de vraies valeurs
log "Vérification de la configuration .env..."
if grep -q "CHANGEZ_MOI\|votre-domaine.com\|exemple" "$ENV_FILE"; then
    error "Le fichier .env contient encore des valeurs d'exemple"
    error "Veuillez éditer $ENV_FILE avec vos vraies valeurs"
    exit 1
fi

success "Configuration .env validée"

# Création du réseau Docker externe
log "Création du réseau Docker 'web'..."
if ! docker network ls | grep -q "web"; then
    docker network create web
    success "Réseau Docker 'web' créé"
else
    success "Réseau Docker 'web' existant"
fi

# Génération de la configuration Synapse
log "Génération de la configuration Synapse..."
if [ -f "$SCRIPT_DIR/generate-config.sh" ]; then
    bash "$SCRIPT_DIR/generate-config.sh"
else
    error "Script generate-config.sh introuvable"
    exit 1
fi

# ============================================================================
# DÉPLOIEMENT
# ============================================================================
print_header "DÉPLOIEMENT DE MATRIX SYNAPSE"

log "Arrêt des conteneurs existants..."
docker-compose down --remove-orphans 2>/dev/null || true

log "Suppression des volumes orphelins..."
docker volume prune -f

log "Construction et démarrage des services..."
docker-compose up -d --build

log "Attente du démarrage des services..."
sleep 30

# Vérification du statut des services
log "Vérification du statut des services..."
if docker-compose ps | grep -q "unhealthy\|Exit"; then
    error "Certains services ne démarrent pas correctement"
    echo
    echo "État des conteneurs:"
    docker-compose ps
    echo
    echo "Logs des services en erreur:"
    docker-compose logs --tail=50
    exit 1
fi

success "Tous les services sont démarrés"

print_header "CRÉATION D'UN UTILISATEUR ADMINISTRATEUR"

log "Chargement de la configuration..."
set -a
source "$ENV_FILE"
set +a

echo
echo -e "${YELLOW}Voulez-vous créer un utilisateur administrateur maintenant ? [y/N]${NC}"
read -r CREATE_ADMIN

if [[ $CREATE_ADMIN =~ ^[Yy]$ ]]; then
    echo
    echo -e "${CYAN}Création d'un utilisateur administrateur Matrix${NC}"
    echo

    # Demande des informations utilisateur
    read -p "Nom d'utilisateur (sans @): " USERNAME
    read -p "Mot de passe: " -s PASSWORD
    echo
    read -p "Confirmer le mot de passe: " -s PASSWORD_CONFIRM
    echo

    if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
        error "Les mots de passe ne correspondent pas"
    else
        log "Création de l'utilisateur @$USERNAME:$SYNAPSE_SERVER_NAME..."

        docker exec -it matrix_synapse register_new_matrix_user \
            -u "$USERNAME" \
            -p "$PASSWORD" \
            -a \
            -c /data/homeserver.yaml \
            http://localhost:8008

        success "Utilisateur @$USERNAME:$SYNAPSE_SERVER_NAME créé avec succès"
    fi
fi

print_header "DÉPLOIEMENT TERMINÉ !"

echo -e "${GREEN}${BOLD}Matrix Synapse est maintenant déployé et opérationnel !${NC}"
echo
echo -e "${CYAN}📋 INFORMATIONS IMPORTANTES:${NC}"
echo
echo -e "${BOLD}🌐 Services disponibles:${NC}"
echo "  • Matrix Server: https://$SYNAPSE_SERVER_NAME"
echo "  • Client Element: https://element.$SYNAPSE_SERVER_NAME"
echo "  • Grafana: https://grafana.$SYNAPSE_SERVER_NAME"
echo "  • Prometheus: https://prometheus.$SYNAPSE_SERVER_NAME"
echo "  • Traefik Dashboard: https://traefik.$SYNAPSE_SERVER_NAME"
echo
echo -e "${BOLD}🔧 Commandes utiles:${NC}"
echo "  • Voir les logs: docker-compose logs -f"
echo "  • État des services: docker-compose ps"
echo "  • Redémarrer: docker-compose restart"
echo "  • Mise à jour: docker-compose pull && docker-compose up -d"
echo
echo -e "${BOLD}👤 Création d'utilisateurs:${NC}"
echo "  docker exec -it matrix_synapse register_new_matrix_user \\"
echo "    -u nom_utilisateur -p mot_de_passe -a -c /data/homeserver.yaml http://localhost:8008"
echo
echo -e "${YELLOW}⚠️  SÉCURITÉ:${NC}"
echo "  • Changez régulièrement les mots de passe"
echo "  • Surveillez les logs avec: docker-compose logs -f"
echo "  • Mises à jour automatiques activées pour la sécurité"
echo "  • Fail2ban configuré pour SSH et web"
echo
echo -e "${GREEN}✅ Installation terminée avec succès !${NC}"

# Redémarrage nécessaire si Docker vient d'être installé
if [ ! -z "$DOCKER_INSTALLED" ]; then
    echo
    warn "Un redémarrage est recommandé pour finaliser l'installation de Docker"
    echo "Commande: sudo reboot"
fi