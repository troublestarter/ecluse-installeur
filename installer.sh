#!/usr/bin/env bash
# Installeur d'un serveur de production ecluse.
#
# Généré par `make installeur` depuis ecluse@9941bf8f00660b5d44da4dd7bdf9fae30aa3dc78 — ne pas modifier ici :
# toute correction se fait dans le dépôt ecluse, puis se régénère.
#
# Usage (Ubuntu Server 24.04 neuve, en root) :
#   sudo bash installer.sh --nom <serveur> --version <x.y.z>
#
# `x.y.z` est le numéro commercial d'une version promue (0.3.0) : c'est la
# forme à employer (drubio, 26/10). Le numéro technique `AAAA.MM.JJ-commit7`
# reste accepté, pour un déploiement de test.
#
# Ce qu'il fait, et que relancer la même commande reprend là où il s'était
# arrêté :
#   1. prépare la machine (Docker du dépôt officiel, outils, pas de swap, UTC),
#      sans registre public : les outils viendront de notre registre ;
#      crée le compte `ecluse` et /opt/ecluse ;
#   2. crée l'identité du serveur au registre et affiche l'encadré à envoyer ;
#   3. attend l'acceptation ;
#   4. pose la configuration de la version, signée PROD et vérifiée ;
#   5. puis passe la main à l'installation de la version (réglages,
#      premier démarrage) ;
#   6. installe l'agent de mise à jour (unité systemd sous le compte
#      `ecluse`), si la version le porte.
#
# Aucun secret ici : la clé publique PROD et l'outillage, embarqués à
# l'identique depuis le dépôt (charge utile en fin de fichier).

set -euo pipefail

COMMIT="9941bf8f00660b5d44da4dd7bdf9fae30aa3dc78"
NOM=""
ECLUSE_VERSION=""
REGISTRE="${ECLUSE_REGISTRE:-ecluse-registry.my-cosi.info}"
DOSSIER=/opt/ecluse
COMPTE=ecluse

usage() {
  echo "usage : sudo bash $0 --nom <serveur> --version <x.y.z>" >&2
  echo "        (x.y.z : numéro d'une version promue ; AAAA.MM.JJ-commit7 pour un essai)" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --nom) NOM="${2:-}"; shift 2 ;;
    --version) ECLUSE_VERSION="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$NOM" ] && [ -n "$ECLUSE_VERSION" ] || usage
[[ "$NOM" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { echo "nom de serveur invalide : $NOM" >&2; exit 2; }
[[ "$ECLUSE_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+|[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7})$ ]] \
  || { echo "version invalide : $ECLUSE_VERSION (attendu x.y.z ou AAAA.MM.JJ-commit7)" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "à lancer avec sudo : la préparation de la machine l'exige" >&2; exit 2; }
SHA_INSTALLEUR="$(sha256sum "$0" | cut -d' ' -f1)"

etape() { printf '\n\033[1m── %s\033[0m\n' "$*"; }

# ── 1. La machine (docs/12 § 1 bis) ─────────────────────────────────────────
etape "1. Préparation de la machine"
# **Lu dans un sous-shell, clé par clé** : `/etc/os-release` définit VERSION,
# NAME, ID… Sourcé ici, il remplaçait la version demandée par
# « 24.04.3 LTS (Noble Numbat) » (premier essai sur essai1, 26/10).
OS_RELEASE=/etc/os-release
os_release() {
  ( . "$OS_RELEASE"
    case "$1" in
      ID) printf '%s' "${ID:-}" ;;
      VERSION_CODENAME) printf '%s' "${VERSION_CODENAME:-}" ;;
    esac )
}
OS_ID="$(os_release ID)"
OS_CODENAME="$(os_release VERSION_CODENAME)"
[ "$OS_ID" = ubuntu ] || { echo "Ubuntu Server attendu (trouvé : ${OS_ID:-?})" >&2; exit 1; }

# `mkpasswd` (paquet whois) calcule l'empreinte de l'identité : aucune image
# n'est tirée avant l'acceptation par le registre.
for outil in dig make python3 mkpasswd curl; do
  if ! command -v "$outil" >/dev/null; then
    apt-get update -q
    apt-get install -y -q make python3 bind9-dnsutils whois curl ca-certificates
    break
  fi
done

# Docker installé par snap (proposé à l'installation d'Ubuntu Server) : il
# est confiné et ne voit pas /opt/ecluse, et `docker compose version` y
# répond — il passerait donc pour le bon. On le retire, en le disant, au
# profit du paquet officiel (consigne de drubio, 25/10 : « l'outil n'a qu'à
# gérer cela »). Seul refus : des conteneurs qui tournent sous ce snap, que
# le retrait arrêterait — ce n'est plus une machine neuve.
retirer_le_docker_du_snap() {
  command -v snap >/dev/null 2>&1 || return 0
  snap list docker >/dev/null 2>&1 || return 0
  local actifs
  actifs="$(docker ps -q 2>/dev/null | wc -l)"
  if [ "$actifs" -gt 0 ]; then
    echo "Docker est installé par snap et $actifs conteneur(s) y tournent : le retirer les arrêterait." >&2
    echo "Ce n'est pas une machine neuve. Arrêtez-les ou retirez le snap vous-même (sudo snap remove --purge docker), puis relancez." >&2
    exit 1
  fi
  echo "Docker installé par snap détecté : il est retiré (confiné, il ne voit pas $DOSSIER)."
  echo "Le paquet officiel de Docker le remplace."
  snap remove --purge docker
  hash -r
}
retirer_le_docker_du_snap

if ! docker compose version >/dev/null 2>&1; then
  for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y -q "$p" >/dev/null 2>&1 || true
  done
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${OS_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi
echo "Docker $(docker version --format '{{.Server.Version}}'), $(docker compose version --short)"

# Sur tout serveur, avec ou sans swap (drubio, 28/10 : une seule règle) : un
# swap ajouté plus tard par l'hébergeur ne doit pas trouver `clamd` et les
# autres prêts à partir sur disque (CLAUDE.md § 8.4).
SYSCTL_ECLUSE=/etc/sysctl.d/99-ecluse.conf
echo 'vm.swappiness=1' > "$SYSCTL_ECLUSE"
sysctl -q -p "$SYSCTL_ECLUSE"
echo "vm.swappiness=1 (CLAUDE.md § 8.4)"
timedatectl set-timezone UTC

if ! id "$COMPTE" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$COMPTE"
fi
usermod -aG docker "$COMPTE"
install -d -o "$COMPTE" -g "$COMPTE" -m 0750 "$DOSSIER"
# Le dossier où root seul pose ce que l'agent lit sans pouvoir l'écrire —
# le fichier d'échec volontaire (retour arrière éprouvé en production).
install -d -o root -g root -m 0755 /etc/ecluse
# Ce que `compose.yaml` monte sans que la configuration publiée le porte :
# absent au premier `up`, Docker le crée en root, et l'agent ne peut plus y
# écrire — essai1, 27/10 : la mise à jour vers 0.3.2 refusée deux fois sur
# « Permission denied ». `install -d` rend aussi le bon propriétaire à un
# dossier déjà là. 0755 : les conteneurs lisent sous un autre compte.
# `infra/rspamd/plugins` est vide, donc absent de l'archive (git ne garde
# pas un dossier vide) : même sort sur essai1.
install -d -o "$COMPTE" -g "$COMPTE" -m 0755 "$DOSSIER/.maintenance"
install -d -o "$COMPTE" -g "$COMPTE" -m 0755 "$DOSSIER/infra" "$DOSSIER/infra/rspamd"
install -d -o "$COMPTE" -g "$COMPTE" -m 0755 "$DOSSIER/infra/rspamd/plugins"

# ── 2 à 5. Sous le compte `ecluse`, avec l'outillage embarqué ───────────────
AMORCE="$(mktemp -d)"
trap 'rm -rf "$AMORCE"' EXIT
sed -n '/^__CHARGE_UTILE__$/,$p' "$0" | tail -n +2 | base64 -d | tar -xz -C "$AMORCE"
chown -R "$COMPTE:$COMPTE" "$AMORCE"

cd "$AMORCE"
sudo -u "$COMPTE" -H \
  ECLUSE_REGISTRE="$REGISTRE" \
  ECLUSE_DOSSIER="$DOSSIER" \
  ECLUSE_INSTALLEUR="ecluse-installeur, ecluse@${COMMIT:0:7}, sha256 ${SHA_INSTALLEUR}" \
  python3 -m tools.maj.amorce --nom "$NOM" --version "$ECLUSE_VERSION"

# ── 6. L'agent de mise à jour, en root : son unité systemd ─────────────────
# Depuis la configuration installée et signée, pas depuis l'amorce. Une
# version d'avant l'agent (0.1.0, 0.2.0) ne le porte pas : on le dit, sans
# échouer — il se posera après la mise à jour qui l'apporte.
cd "$DOSSIER"
# `-B` : python lancé en root n'écrit aucun `__pycache__` sous le dossier
# (essai1, 27/10 : un `.pyc` en root sous tools/maj — la famille du retour
# arrière du 23/10, CLAUDE.md § 8.4).
if [ -f tools/maj/agent_installer.py ]; then
  python3 -B -m tools.maj.agent_installer --compte "$COMPTE" --dossier "$DOSSIER"
else
  echo "cette version ne porte pas l'agent de mise à jour : il s'installera après"
fi
# Rien ne reste en root sous le dossier : l'agent, au compte `ecluse`, y
# réécrit la configuration à chaque mise à jour.
chown -R "$COMPTE:$COMPTE" "$DOSSIER"
exit 0
__CHARGE_UTILE__
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
3c+7n3c/737+v/rzfwA0M7aXAEABAA==
