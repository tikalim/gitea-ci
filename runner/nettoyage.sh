#!/usr/bin/env bash
# Nettoyage après chaque job (post_task_script du runner, exécuté comme l'utilisateur ci) : la VM revient à l'état
# d'une machine neuve pour le job suivant. Les images sont gardées (cache de construction) ; un minuteur hebdomadaire
# retire celles de plus de 7 jours. Conteneurs, volumes et réseaux étiquetés ci.conserver=true sont épargnés : la VM du
# runner doit rester dédiée à la CI, cette étiquette n'est qu'un garde-fou.
set -uo pipefail
log() { echo "gitea-ci-nettoyage: $*"; }
GARDER="label=ci.conserver=true"

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  mapfile -t tous < <(docker ps -aq --no-trunc)
  mapfile -t gardes < <(docker ps -aq --no-trunc --filter "$GARDER")
  a_retirer=()
  for c in "${tous[@]}"; do [[ " ${gardes[*]} " == *" $c "* ]] || a_retirer+=("$c"); done
  [ ${#a_retirer[@]} -eq 0 ] || { log "conteneurs Docker retirés : ${#a_retirer[@]}"; docker rm -f -v "${a_retirer[@]}" >/dev/null; }
  docker volume prune -af --filter "label!=ci.conserver=true" >/dev/null
  docker network prune -f --filter "label!=ci.conserver=true" >/dev/null
  docker builder prune -f --filter until=168h >/dev/null 2>&1 || true
fi
if command -v podman >/dev/null; then
  mapfile -t ptous < <(podman ps -aq --no-trunc 2>/dev/null)
  mapfile -t pgardes < <(podman ps -aq --no-trunc --filter "$GARDER" 2>/dev/null)
  for c in "${ptous[@]}"; do [[ " ${pgardes[*]} " == *" $c "* ]] || podman rm -f -t 5 "$c" >/dev/null 2>&1; done
  podman volume prune -f --filter "label!=ci.conserver=true" >/dev/null 2>&1 || true
  podman network prune -f --filter "label!=ci.conserver=true" >/dev/null 2>&1 || true
fi
# Processus lancés en arrière-plan par un job (serveur de démonstration de la passe ZAP) et restés vivants
pkill -u "$(id -u)" -f "scripts\.demo_serve[r]" 2>/dev/null || true
exit 0
