#!/usr/bin/env bash
# Installeur d'un serveur de production ecluse.
#
# Généré par `make installeur` depuis ecluse@8e82dc8972fa35f2ad2376b0e598d026c438c0db — ne pas modifier ici :
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

COMMIT="8e82dc8972fa35f2ad2376b0e598d026c438c0db"
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
