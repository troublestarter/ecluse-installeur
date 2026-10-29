#!/usr/bin/env bash
# Installeur d'un serveur de production ecluse.
#
# Généré par `make installeur` depuis ecluse@9ea838dffa6574af74bfcd275ef2ea315fa4341c — ne pas modifier ici :
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

COMMIT="9ea838dffa6574af74bfcd275ef2ea315fa4341c"
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
