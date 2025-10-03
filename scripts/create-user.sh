#!/bin/bash


set -e

# Couleurs pour les messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Vérification que le conteneur Synapse fonctionne
if ! docker ps | grep -q "matrix_synapse"; then
    error "Le conteneur Matrix Synapse n'est pas démarré"
    error "Démarrez-le avec: docker-compose up -d"
    exit 1
fi

# Chargement des variables d'environnement si disponibles
ENV_FILE="../.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

echo
echo -e "${BLUE}============================================================================${NC}"
echo -e "${BLUE}           CRÉATION D'UTILISATEUR MATRIX SYNAPSE${NC}"
echo -e "${BLUE}============================================================================${NC}"
echo

# Demande des informations utilisateur
echo -e "${YELLOW}Entrez les informations du nouvel utilisateur:${NC}"
echo

read -p "Nom d'utilisateur (sans @): " USERNAME

# Validation du nom d'utilisateur
if [[ ! "$USERNAME" =~ ^[a-z0-9._-]+$ ]]; then
    error "Le nom d'utilisateur doit contenir uniquement des lettres minuscules, chiffres, points, underscores et tirets"
    exit 1
fi

read -p "Mot de passe: " -s PASSWORD
echo
read -p "Confirmer le mot de passe: " -s PASSWORD_CONFIRM
echo

if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
    error "Les mots de passe ne correspondent pas"
    exit 1
fi

if [ ${#PASSWORD} -lt 8 ]; then
    error "Le mot de passe doit contenir au moins 8 caractères"
    exit 1
fi

echo
read -p "Cet utilisateur doit-il être administrateur ? [y/N]: " IS_ADMIN

# Préparation des options
ADMIN_FLAG=""
if [[ $IS_ADMIN =~ ^[Yy]$ ]]; then
    ADMIN_FLAG="-a"
    warn "Cet utilisateur aura des privilèges administrateur"
fi

# Affichage du serveur configuré
if [ ! -z "$SYNAPSE_SERVER_NAME" ]; then
    echo
    log "Serveur Matrix configuré: $SYNAPSE_SERVER_NAME"
    log "L'utilisateur sera créé comme: @$USERNAME:$SYNAPSE_SERVER_NAME"
else
    warn "Variable SYNAPSE_SERVER_NAME non trouvée dans .env"
fi

echo
read -p "Confirmer la création de cet utilisateur ? [y/N]: " CONFIRM

if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo "Création annulée."
    exit 0
fi

echo
log "Création de l'utilisateur en cours..."

# Création de l'utilisateur
if docker exec -i matrix_synapse register_new_matrix_user \
    -u "$USERNAME" \
    -p "$PASSWORD" \
    $ADMIN_FLAG \
    -c /data/homeserver.yaml \
    http://localhost:8008; then

    echo
    echo -e "${GREEN}✅ Utilisateur créé avec succès !${NC}"
    echo

    if [ ! -z "$SYNAPSE_SERVER_NAME" ]; then
        echo -e "${BLUE}Informations de connexion:${NC}"
        echo "  • Utilisateur: @$USERNAME:$SYNAPSE_SERVER_NAME"
        echo "  • Serveur: https://$SYNAPSE_SERVER_NAME"
        echo "  • Client web: https://element.$SYNAPSE_SERVER_NAME"
    fi

    if [[ $IS_ADMIN =~ ^[Yy]$ ]]; then
        echo
        echo -e "${YELLOW}Cet utilisateur a des privilèges administrateur et peut:${NC}"
        echo "  • Gérer les autres utilisateurs"
        echo "  • Accéder aux outils d'administration"
        echo "  • Modifier les paramètres du serveur"
    fi

    echo
    echo -e "${BLUE}Pour se connecter:${NC}"
    echo "  1. Ouvrez votre client Matrix (Element, par exemple)"
    echo "  2. Sélectionnez 'Connexion personnalisée'"
    echo "  3. Serveur: https://$SYNAPSE_SERVER_NAME"
    echo "  4. Utilisez les identifiants créés"

else
    echo
    error "Erreur lors de la création de l'utilisateur"
    echo
    echo "Causes possibles:"
    echo "  • Le nom d'utilisateur existe déjà"
    echo "  • Le serveur Matrix n'est pas accessible"
    echo "  • Configuration incorrecte"
    echo
    echo "Vérifiez les logs avec: docker-compose logs matrix_synapse"
    exit 1
fi