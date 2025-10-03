#!/bin/bash

# Génération des configurations de sécurité pour VPS distantes

SYNAPSE_VPS_IP="${1:-IP_VPS_SYNAPSE}"

echo "======================================================================"
echo "🔒 CONFIGURATION SÉCURITÉ POUR VPS DISTANTES"
echo "======================================================================"

echo "Pour VPS PostgreSQL :"
echo "Modifier /etc/postgresql/*/main/postgresql.conf :"
echo "listen_addresses = 'localhost,$SYNAPSE_VPS_IP'"
echo ""
echo "Modifier /etc/postgresql/*/main/pg_hba.conf :"
echo "host    synapse    synapse_user    $SYNAPSE_VPS_IP/32    md5"
echo ""
echo "Firewall (ufw) :"
echo "sudo ufw allow from $SYNAPSE_VPS_IP to any port 5432"
echo "sudo systemctl restart postgresql"
echo ""

echo "======================================================================"
echo ""
echo "Pour VPS Redis :"
echo "Modifier /etc/redis/redis.conf :"
echo "bind 127.0.0.1 $SYNAPSE_VPS_IP"
echo "requirepass VotreMotDePasseRedis"
echo "protected-mode yes"
echo ""
echo "Firewall (ufw) :"
echo "sudo ufw allow from $SYNAPSE_VPS_IP to any port 6379"
echo "sudo systemctl restart redis"
echo ""

echo "======================================================================"
echo ""
echo "Test de connectivité depuis VPS Synapse :"
echo "nc -z IP_POSTGRES 5432"
echo "nc -z IP_REDIS 6379"