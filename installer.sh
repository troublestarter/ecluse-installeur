#!/usr/bin/env bash
# Installeur d'un serveur de production ecluse.
#
# Généré par `make installeur` depuis ecluse@cac1faaf8869c67530777090aa476d01ac1776bd — ne pas modifier ici :
# toute correction se fait dans le dépôt ecluse, puis se régénère.
#
# Usage (Ubuntu Server 24.04 neuve, en root) :
#   sudo bash installer.sh --nom <serveur> --version <AAAA.MM.JJ-commit7>
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

COMMIT="cac1faaf8869c67530777090aa476d01ac1776bd"
NOM=""
ECLUSE_VERSION=""
REGISTRE="${ECLUSE_REGISTRE:-ecluse-registry.my-cosi.info}"
DOSSIER=/opt/ecluse
COMPTE=ecluse

usage() { echo "usage : sudo bash $0 --nom <serveur> --version <AAAA.MM.JJ-commit7>" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --nom) NOM="${2:-}"; shift 2 ;;
    --version) ECLUSE_VERSION="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$NOM" ] && [ -n "$ECLUSE_VERSION" ] || usage
[[ "$NOM" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { echo "nom de serveur invalide : $NOM" >&2; exit 2; }
[[ "$ECLUSE_VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7}$ ]] || { echo "version invalide : $ECLUSE_VERSION" >&2; exit 2; }
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

if swapon --show=NAME --noheadings | grep -q .; then
  echo 'vm.swappiness=1' > /etc/sysctl.d/99-ecluse.conf
  sysctl -q --system
  echo "swap présent : vm.swappiness=1 (CLAUDE.md § 8.4)"
fi
timedatectl set-timezone UTC

if ! id "$COMPTE" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$COMPTE"
fi
usermod -aG docker "$COMPTE"
install -d -o "$COMPTE" -g "$COMPTE" -m 0750 "$DOSSIER"

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
if [ -f tools/maj/agent_installer.py ]; then
  python3 -m tools.maj.agent_installer --compte "$COMPTE" --dossier "$DOSSIER"
else
  echo "cette version ne porte pas l'agent de mise à jour : il s'installera après"
fi
exit 0
__CHARGE_UTILE__
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
/D+Mm7x4ABgBAA==
