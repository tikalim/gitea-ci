#!/usr/bin/env bash
# Amorçage de la CI, une fois le serveur démarré (compose up -d) : idempotent, relançable.
#  1. compte administrateur (mot de passe aléatoire affiché une fois, à changer à la première connexion) ;
#  2. organisation privée (même nom que le propriétaire GitHub) ;
#  3. miroir de chaque dépôt GitHub, relevé toutes les 2 minutes, Actions activé ;
#  4. secret d'organisation GH_STATUS_TOKEN (statut renvoyé sur chaque commit GitHub) et variable DEPOT_GITHUB par dépôt ;
#  5. jeton d'inscription du runner de l'organisation.
# Le jeton GitHub (lecture du code + écriture des statuts de commit, sur ces dépôts seulement) est lu dans un fichier
# ou saisi sans écho ; il n'apparaît ni dans l'historique du shell ni dans les journaux.
#
#   ./amorcer.sh --admin yo --email yo@exemple.fr [--proprietaire tikalim] [--depots "marguerite coquelicot norn"]
#                [--jeton-github-fichier deploy/secrets/github_token] [--lancer]
set -euo pipefail
cd "$(dirname "$0")"
for c in curl jq; do command -v "$c" >/dev/null || { echo "$c requis" >&2; exit 1; }; done
set -a
# shellcheck disable=SC1091
. ./.env
set +a

ADMIN="" EMAIL="" OWNER=tikalim DEPOTS="marguerite coquelicot norn" TOKEN_FILE="" LANCER=0 SOURCE=https://github.com
while [ $# -gt 0 ]; do
  case "$1" in
    --admin) ADMIN=$2; shift 2 ;;
    --email) EMAIL=$2; shift 2 ;;
    --proprietaire) OWNER=$2; shift 2 ;;
    --depots) DEPOTS=$2; shift 2 ;;
    --jeton-github-fichier) TOKEN_FILE=$2; shift 2 ;;
    --lancer) LANCER=1; shift ;;
    --source) SOURCE=${2%/}; shift 2 ;;      # autre forge source (GitHub Enterprise, essais) ; github.com par défaut
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
done
[ -n "$ADMIN" ] && [ -n "$EMAIL" ] || { echo "--admin et --email sont requis" >&2; exit 2; }
[[ "$OWNER" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Propriétaire GitHub invalide" >&2; exit 2; }

if [ -n "$TOKEN_FILE" ]; then GH_TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
else read -r -s -p "Jeton GitHub (Contents: lecture, Commit statuses: écriture) : " GH_TOKEN; echo; fi
[ -n "$GH_TOKEN" ] || { echo "Jeton GitHub vide" >&2; exit 2; }

RT=$(command -v docker || command -v podman)
gitea() { "$RT" compose exec -T gitea gitea "$@"; }
PORT=${GITEA_PORT:-3000}
BIND=${GITEA_BIND:-127.0.0.1}; [ "$BIND" = 0.0.0.0 ] && BIND=127.0.0.1
URL="https://$GITEA_DOMAIN:$PORT/api/v1"
CA=deploy/certs/cert.pem
# Appels vers l'interface d'écoute de l'hôte, certificat vérifié sous le nom GITEA_DOMAIN
api() {   # api <méthode> <chemin> [json] : corps de la réponse ; en cas d'erreur, message de Gitea sur la sortie d'erreur
  local out
  if ! out=$(curl -sS --fail-with-body --cacert "$CA" --resolve "$GITEA_DOMAIN:$PORT:$BIND" \
      -H "Authorization: token $API_TOKEN" -H "Content-Type: application/json" -X "$1" "$URL$2" ${3:+--data-binary "$3"}); then
    echo "   Gitea a refusé $1 $2 : $(jq -r '.message? // .' <<< "$out" 2>/dev/null | head -c 400)" >&2
    return 1
  fi
  printf '%s' "$out"
}
existe() {   # existe <chemin> : vrai si la ressource existe (HTTP 200)
  [ "$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$CA" --resolve "$GITEA_DOMAIN:$PORT:$BIND" \
      -H "Authorization: token $API_TOKEN" "$URL$1")" = 200 ]
}

echo "1. Administrateur $ADMIN"
CREATED=0
if gitea admin user list --admin 2>/dev/null | awk 'NR>1{print $2}' | grep -qx "$ADMIN"; then
  echo "   existe déjà"
else
  # Changement de mot de passe exigé à la fin de l'amorçage seulement : tant qu'il est exigé, l'API refuse le compte
  gitea admin user create --admin --username "$ADMIN" --email "$EMAIL" --random-password --must-change-password=false \
    | grep -i "password" | sed 's/^/   /'
  echo "   (mot de passe ci-dessus : changement demandé à la première connexion ; activez ensuite la double authentification)"
  CREATED=1
fi
TOKEN_NAME="amorcage-$(date +%s)"
API_TOKEN=$(gitea admin user generate-access-token --username "$ADMIN" --token-name "$TOKEN_NAME" \
  --scopes "write:admin,write:organization,write:repository,read:user" --raw | tail -1)
fin() {   # jeton d'amorçage supprimé ; changement de mot de passe exigé (compte créé, ou exigence déjà en place)
  api DELETE "/users/$ADMIN/tokens/$TOKEN_NAME" >/dev/null 2>&1 || true
  [ "$CREATED" = 0 ] || gitea admin user must-change-password "$ADMIN" >/dev/null
}
trap fin EXIT
# Compte existant dont le mot de passe initial n'a pas encore été changé : l'API le refuse. Exigence levée le temps de
# l'amorçage, remise à la fin.
if curl -sS --cacert "$CA" --resolve "$GITEA_DOMAIN:$PORT:$BIND" -H "Authorization: token $API_TOKEN" "$URL/user" \
     | grep -q "must change your password"; then
  gitea admin user must-change-password --unset "$ADMIN" >/dev/null
  CREATED=1
fi

echo "2. Organisation $OWNER"
if existe "/orgs/$OWNER"; then echo "   existe déjà"
else api POST /orgs "$(jq -nc --arg n "$OWNER" '{username:$n, visibility:"private", repo_admin_change_team_access:false}')" >/dev/null; echo "   créée"; fi

echo "3. Miroirs"
for d in $DEPOTS; do
  [[ "$d" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "   dépôt invalide : $d" >&2; exit 2; }
  if existe "/repos/$OWNER/$d"; then
    echo "   $d : existe déjà"
  else
    api POST /repos/migrate "$(jq -nc --arg s "$SOURCE" --arg o "$OWNER" --arg d "$d" --arg t "$GH_TOKEN" '{
      clone_addr: ($s + "/" + $o + "/" + $d + ".git"), service: "git", mirror: true, mirror_interval: "2m",
      auth_username: "x-access-token", auth_password: $t, repo_owner: $o, repo_name: $d, private: true}')" >/dev/null
    echo "   $d : miroir créé"
  fi
  api PATCH "/repos/$OWNER/$d" '{"has_actions":true,"has_issues":false,"has_wiki":false,"has_pull_requests":false,"has_projects":false,"has_releases":false,"has_packages":false}' >/dev/null
  v=$(jq -nc --arg v "$OWNER/$d" '{value:$v}')
  if existe "/repos/$OWNER/$d/actions/variables/DEPOT_GITHUB"; then
    api PUT "/repos/$OWNER/$d/actions/variables/DEPOT_GITHUB" "$(jq -nc --arg v "$OWNER/$d" '{name:"DEPOT_GITHUB",value:$v}')" >/dev/null
  else
    api POST "/repos/$OWNER/$d/actions/variables/DEPOT_GITHUB" "$v" >/dev/null
  fi
done

echo "4. Secret GH_STATUS_TOKEN de l'organisation"
api PUT "/orgs/$OWNER/actions/secrets/GH_STATUS_TOKEN" "$(jq -nc --arg t "$GH_TOKEN" '{data:$t}')" >/dev/null
echo "   enregistré"

echo "5. Jeton d'inscription du runner (organisation $OWNER) :"
api POST "/orgs/$OWNER/actions/runners/registration-token" | jq -r '.token' | sed 's/^/   /'
echo "   à utiliser sur la VM du runner : sudo ./installer-runner.sh --gitea https://$GITEA_DOMAIN:$PORT --jeton <jeton> --ca cert.pem"

if [ "$LANCER" = 1 ]; then
  echo "6. Premier passage sur main (dépôts qui ont .gitea/workflows/ci.yml)"
  for d in $DEPOTS; do
    api POST "/repos/$OWNER/$d/mirror-sync" >/dev/null || true
    if existe "/repos/$OWNER/$d/contents/.gitea/workflows/ci.yml?ref=main" \
       && api POST "/repos/$OWNER/$d/actions/workflows/ci.yml/dispatches" '{"ref":"main"}' >/dev/null; then echo "   $d : lancé"
    else echo "   $d : pas de .gitea/workflows/ci.yml sur main (rien à lancer)"; fi
  done
fi
echo "Terminé. Interface : https://$GITEA_DOMAIN:$PORT/"
