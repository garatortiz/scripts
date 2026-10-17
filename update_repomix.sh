#!/bin/bash
set -uo pipefail

# ============================================
# 🛠️ Repomix Report Generator
# 📦 Generates individual Repomix reports per project/app from origin/main.
# 🐳 Compiles a dedicated Docker infrastructure overview.
# 🔄 Extracts and aggregates GitHub Actions .yaml workflows.
# ☁️ Synchronizes all generated outputs to Google Drive via rclone.
# ============================================

# --- 1. Entorno para cron (node/npx/rclone no siempre están en PATH) ---
export HOME="${HOME:-/home/$(whoami)}"

if [ -s "$HOME/.nvm/nvm.sh" ]; then
  # shellcheck source=/dev/null
  source "$HOME/.nvm/nvm.sh"
  nvm use default >/dev/null 2>&1 || true
fi

nvm_node="$(nvm version default 2>/dev/null || echo current)"
export PATH="$HOME/.nvm/versions/node/${nvm_node}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# --- 2. Configuración ---
# Rutas y destino de Drive viven en config.sh (no se versiona).
# Copiá config.sh.example y completá los valores.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/config.sh" ]; then
  echo "Falta $SCRIPT_DIR/config.sh. Copiá config.sh.example y completá las rutas." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

: "${SILPH_CORE_DIR:?Definí SILPH_CORE_DIR en config.sh}"
: "${KANTO_APPS_DIR:?Definí KANTO_APPS_DIR en config.sh}"
: "${KANTO_ROOT_DIR:?Definí KANTO_ROOT_DIR en config.sh}"
: "${DOCKER_INFRA_DIR:?Definí DOCKER_INFRA_DIR en config.sh}"
: "${OUTPUT_DIR:?Definí OUTPUT_DIR en config.sh}"
: "${DRIVE_FOLDER:?Definí DRIVE_FOLDER en config.sh}"
RCLONE_CONF="${RCLONE_CONF:-$HOME/.config/rclone/rclone.conf}"

WORKFLOWS_DIR="$OUTPUT_DIR/github-actions"
INFRA_DIR="$OUTPUT_DIR/infra"

LOG_FILE="${LOG_FILE:-$OUTPUT_DIR/repomix-report.log}"
mkdir -p "$OUTPUT_DIR" "$WORKFLOWS_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- 3. Helpers ---

# Genera un reporte repomix para un directorio dado.
# Uso: repomix_report <dir> <output_file> [args extra de repomix...]
repomix_report() {
  local dir="$1" output="$2"
  shift 2
  if [ ! -d "$dir" ]; then
    log "FALTA: no existe $dir"
    return 1
  fi
  if ! (cd "$dir" && npx --yes repomix --output "$output" "$@"); then
    log "ERROR generando reporte para $dir"
    return 1
  fi
}

# Worktrees temporales de origin/main. El checkout local no se toca.
WT_REPOS=()
WT_PATHS=()
MAIN_WT=""

cleanup_worktrees() {
  local i repo path
  [ "${#WT_PATHS[@]}" -eq 0 ] && return 0
  for i in "${!WT_PATHS[@]}"; do
    repo="${WT_REPOS[$i]}"
    path="${WT_PATHS[$i]}"
    git -C "$repo" worktree remove --force "$path" >/dev/null 2>&1 || rm -rf "$path"
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
  done
}
trap cleanup_worktrees EXIT

# Deja en MAIN_WT un worktree detached de origin/main.
# Uso: use_origin_main <repo> && ... "$MAIN_WT"
use_origin_main() {
  local repo="$1"
  local wt sha
  MAIN_WT=""
  if [ ! -d "$repo" ]; then
    log "FALTA: no existe $repo"
    return 1
  fi
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "ERROR: $repo no es un repositorio git. Se omite el reporte."
    return 1
  fi
  log "Fetch origin/main en $repo"
  if ! git -C "$repo" fetch origin main --quiet; then
    log "ERROR: fetch de origin/main falló en $repo. Se omite el reporte."
    return 1
  fi
  if ! git -C "$repo" rev-parse --verify --quiet origin/main >/dev/null; then
    log "ERROR: origin/main no existe en $repo. Se omite el reporte."
    return 1
  fi
  wt="$(mktemp -d "${TMPDIR:-/tmp}/repomix-wt.XXXXXX")"
  if ! git -C "$repo" worktree add --detach "$wt" origin/main --quiet; then
    log "ERROR: no se pudo crear el worktree de origin/main en $repo"
    rm -rf "$wt"
    return 1
  fi
  WT_REPOS+=("$repo")
  WT_PATHS+=("$wt")
  MAIN_WT="$wt"
  sha="$(git -C "$wt" rev-parse --short HEAD)"
  log "Reporte desde origin/main @ ${sha} ($repo)"
}

# Genera un reporte separado SOLO con los workflows de CI de un repo
# (GitHub Actions y/o Forgejo Actions), si existen.
# Uso: workflows_report <dir> <nombre>
workflows_report() {
  local dir="$1" name="$2"
  local include_patterns=()

  [ -d "$dir/.github/workflows" ] && include_patterns+=("**/.github/workflows/**")
  [ -d "$dir/.forgejo/workflows" ] && include_patterns+=("**/.forgejo/workflows/**")

  if [ "${#include_patterns[@]}" -eq 0 ]; then
    return 0
  fi

  log " -> Workflows de CI encontrados en $name"
  local include_arg
  include_arg="$(IFS=,; echo "${include_patterns[*]}")"
  repomix_report "$dir" "$WORKFLOWS_DIR/workflows-${name}-repomix.txt" \
    --include "$include_arg"
}

# --- 4. Limpieza de reportes previos ---
rm -f "$OUTPUT_DIR"/*.txt
rm -f "$WORKFLOWS_DIR"/*.txt

log "======= Generando Reportes Repomix ======="

# 1. API Core
if use_origin_main "$SILPH_CORE_DIR"; then
  log "Procesando API Core..."
  repomix_report "$MAIN_WT" "$OUTPUT_DIR/api-core-repomix.txt"
  workflows_report "$MAIN_WT" "api-core"
fi

# 2. Apps del monorepo Kanto (un solo worktree; las apps no tienen git propio)
if use_origin_main "$KANTO_ROOT_DIR"; then
  KANTO_WT="$MAIN_WT"
  KANTO_TOP="$(git -C "$KANTO_ROOT_DIR" rev-parse --show-toplevel)"
  if ! KANTO_APPS_REL="$(realpath --relative-to="$KANTO_TOP" "$KANTO_APPS_DIR")"; then
    log "FALTA: no se pudo resolver $KANTO_APPS_DIR dentro de $KANTO_TOP"
    KANTO_APPS_REL=""
  fi
  case "$KANTO_APPS_REL" in
    ""|/*|..|../*)
      log "FALTA: $KANTO_APPS_DIR no está dentro del repo de Kanto"
      ;;
    *)
      KANTO_APPS_WT="$KANTO_WT/$KANTO_APPS_REL"
      if [ -d "$KANTO_APPS_WT" ]; then
        log "Procesando aplicaciones en Kanto..."
        for APP_PATH in "$KANTO_APPS_WT"/*; do
          [ -d "$APP_PATH" ] || continue
          APP_NAME="$(basename "$APP_PATH")"
          if [ -f "$APP_PATH/package.json" ] || [ -d "$APP_PATH/.git" ]; then
            log " -> Generando reporte para app: $APP_NAME"
            repomix_report "$APP_PATH" "$OUTPUT_DIR/app-${APP_NAME}-repomix.txt"
          fi
        done
      else
        log "FALTA: no existe $KANTO_APPS_REL en origin/main de $KANTO_ROOT_DIR"
      fi
      ;;
  esac
  workflows_report "$KANTO_WT" "kanto"
fi

# 3. Docker Infra
if use_origin_main "$DOCKER_INFRA_DIR"; then
  log "Procesando infraestructura Docker..."
  mkdir -p "$INFRA_DIR"
  repomix_report "$MAIN_WT" "$INFRA_DIR/docker-infra-repomix.txt" \
    --ignore "data/**,postgres_data/**,.env,.env.*,**/.git/**,forgejo/forgejo-data/**,forgejo/runner-data/**,**/*.log"
  workflows_report "$MAIN_WT" "docker-infra"
fi

log "======= Sincronizando con Google Drive ======="
# OJO: "sync" deja el destino como espejo del origen, es decir que borra en
# Drive cualquier archivo que ya no exista en $OUTPUT_DIR. Si preferís
# acumular histórico sin borrar nada, cambiá "sync" por "copy".
if command -v rclone >/dev/null 2>&1; then
  rclone --config "$RCLONE_CONF" sync "$OUTPUT_DIR" "$DRIVE_FOLDER"
  log "¡Todo listo y actualizado en Drive!"
else
  log "ERROR: rclone no está en el PATH, se omite la sincronización"
fi