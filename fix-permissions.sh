#!/bin/bash

# Script pour corriger les problèmes de permissions Synapse

echo "🔧 Correction des permissions Synapse..."

# Arrêt du conteneur Synapse
echo "Arrêt du conteneur Synapse..."
docker stop matrix_synapse 2>/dev/null || true
docker rm matrix_synapse 2>/dev/null || true

# Redémarrage des services avec les nouvelles permissions
echo "Redémarrage avec nouvelles permissions..."
./matrix.sh stop
./matrix.sh start

echo "✅ Permissions corrigées !"
echo ""
echo "Vérifiez les logs :"
echo "  docker logs matrix_synapse"