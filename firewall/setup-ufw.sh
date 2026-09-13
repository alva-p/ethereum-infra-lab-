#!/usr/bin/env bash
# Reglas de firewall para los puertos que expone ESTE proyecto.
#
# ADVERTENCIA (2026-09-12): este homelab corre muchos otros servicios que hoy
# no tienen reglas propias (Jellyfin, TeamSpeak, family-storage, Portainer,
# Wazuh, etc. - ver README de homelab-security-lab para el inventario). `ufw`
# esta inactivo en el server real. Este script queda documentado a proposito
# SIN ejecutar `ufw enable`: activarlo con "default deny incoming" cortaria el
# acceso a todo lo demas si antes no se agrega una regla por cada servicio.
#
# Para probarlo de verdad: revisar primero que reglas hacen falta para el
# resto del homelab, y recien ahi correr esto + `ufw enable` a mano.
set -euo pipefail

ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp comment 'SSH'
ufw allow 8090/tcp comment 'nginx (grafana)'
ufw allow 30303/tcp comment 'nethermind p2p'
ufw allow 30303/udp comment 'nethermind discovery'
ufw allow 9010/tcp comment 'lighthouse p2p'
ufw allow 9010/udp comment 'lighthouse discovery'

# 8545 (RPC), 8551 (Engine API), 5052 (beacon HTTP), 9090 (prometheus), 3000
# (grafana directo, sin pasar por nginx) quedan cerrados a internet a
# proposito: solo se acceden dentro de la red docker o via ssh tunnel. No
# agregar `ufw allow` para estos sin revisar RUNBOOK.md primero.

echo "Reglas cargadas en modo dry-run (ufw no queda activado)."
echo "Para aplicar de verdad en este homelab: revisar los puertos del resto"
echo "de los servicios y recien despues correr 'sudo ufw enable' a mano."
ufw show added
