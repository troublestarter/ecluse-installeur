#!/usr/bin/env bash
# Installeur d'un serveur de production ecluse.
#
# Généré par `make installeur` depuis ecluse@0d91a3290a2a688b4a54062e7a18cd3977ca8db2 — ne pas modifier ici :
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

COMMIT="0d91a3290a2a688b4a54062e7a18cd3977ca8db2"
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
n/ef95/rP/8LTjCnOwBAAQA=
