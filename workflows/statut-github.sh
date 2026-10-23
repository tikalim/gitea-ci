#!/usr/bin/env bash
# Statut de la CI Gitea renvoyé sur le commit GitHub (coche sur la PR) : statut de commit, sans GitHub Actions.
#   statut-github.sh <pending|success|failure|error> <description>
# Variables : GH_STATUS_TOKEN (secret de l'organisation Gitea), DEPOT_GITHUB (variable du dépôt, propriétaire/dépôt),
# GITHUB_SHA, GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_NUMBER (fournies par le runner), API_STATUTS
# (facultatif, autre API que https://api.github.com). Un échec d'envoi est signalé sans faire échouer la CI.
set -uo pipefail
state=$1; desc=${2:-}
case "$state" in pending|success|failure|error) ;; *) echo "état invalide : $state" >&2; exit 2 ;; esac
if [ -z "${GH_STATUS_TOKEN:-}" ] || [ -z "${DEPOT_GITHUB:-}" ]; then
  echo "::warning::GH_STATUS_TOKEN ou DEPOT_GITHUB absent : statut non publié sur GitHub"; exit 0
fi
[[ "$DEPOT_GITHUB" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "::warning::DEPOT_GITHUB invalide"; exit 0; }
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "::warning::empreinte de commit invalide"; exit 0; }
api=${API_STATUTS:-https://api.github.com}
cible="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_NUMBER"
corps=$(python3 -c 'import json, sys; print(json.dumps({"state": sys.argv[1], "context": "gitea-ci", "description": sys.argv[2][:140], "target_url": sys.argv[3]}))' \
  "$state" "$desc" "$cible")
# Jeton passé par un fichier d'en-têtes temporaire : jamais sur la ligne de commande (visible dans ps)
h=$(mktemp); trap 'rm -f "$h"' EXIT; chmod 600 "$h"
printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "$GH_STATUS_TOKEN" > "$h"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 --retry 2 -H @"$h" -X POST \
  "$api/repos/$DEPOT_GITHUB/statuses/$GITHUB_SHA" --data-binary "$corps") || code=000
if [ "$code" = 201 ]; then echo "Statut « $state » publié sur $DEPOT_GITHUB@${GITHUB_SHA:0:7}"
else echo "::warning::statut non publié sur GitHub (HTTP $code) : jeton, droits « Commit statuses » ou accès à $api à vérifier"; fi
exit 0
