#!/usr/bin/env bash
# Installeur d'un serveur de production ecluse.
#
# Généré par `make installeur` depuis ecluse@996f97e24b131813f644b898b220f09da4af2bc1 — ne pas modifier ici :
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

COMMIT="996f97e24b131813f644b898b220f09da4af2bc1"
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
f97/vP95//Mf6+f/AZxPjdAAGAEA
