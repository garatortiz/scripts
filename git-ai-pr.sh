#!/bin/bash
# git-ai-pr.sh
# Genera título + descripción de PR con el LLM configurado (GIT_AI_PROVIDER)
# a partir del diff contra la rama base.
# Crea la PR en GitHub (gh) o Forgejo (API REST directa vía curl) según el remote detectado.
#
# Requiere para Forgejo: FORGEJO_URL y FORGEJO_TOKEN en el entorno (ver .zshrc).
#
# Uso: gapr [rama_base] [pathspecs...]
#   gapr                     -> usa main (o $GIT_AI_BASE_BRANCH) con blacklist por defecto
#   gapr develop             -> usa develop como base
#   gapr main 'src/*'        -> usa main y filtra solo por src/*
#   gapr develop .husky/*    -> usa develop y filtra solo por .husky/*

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/llm-common.sh
source "$SCRIPT_DIR/lib/llm-common.sh"

check_dependencies

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "No estás dentro de un repositorio git (cwd: $(pwd))."
    exit 1
fi

BASE_BRANCH="${1:-${GIT_AI_BASE_BRANCH:-main}}"
CURRENT_BRANCH=$(git branch --show-current)

# Si se pasan más parámetros ($2, $3...), se usan como pathspecs.
# De lo contrario, cae en un blacklist por defecto para incluir todo excepto basura/builds.
if [ "$#" -gt 1 ]; then
    shift 1
    DIFF_PATHSPECS=("$@")
else
    DIFF_PATHSPECS=(':!postman/*' ':!dist/*' ':!*.lock' ':!pnpm-lock.yaml' ':!package-lock.json')
fi

if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ]; then
    fail "Estás en $BASE_BRANCH. Cambiá a una rama de feature para crear la PR."
    exit 1
fi

info "Actualizando referencia de '$BASE_BRANCH' desde el remoto..."
git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || warn "No se pudo hacer fetch de $BASE_BRANCH, uso la referencia local."

if git rev-parse --verify -q "origin/$BASE_BRANCH" >/dev/null; then
    DIFF_BASE="origin/$BASE_BRANCH"
else
    DIFF_BASE="$BASE_BRANCH"
fi

info "Analizando cambios de '$CURRENT_BRANCH' contra '$DIFF_BASE'..."
DIFF=$(git diff "$DIFF_BASE"...HEAD -- "${DIFF_PATHSPECS[@]}")

if [ -z "$DIFF" ]; then
    fail "No hay diferencias entre '$CURRENT_BRANCH' y '$DIFF_BASE' (con los pathspecs configurados: ${DIFF_PATHSPECS[*]})."
    exit 1
fi

CHANGED_FILES=$(git diff --name-only "$DIFF_BASE"...HEAD -- "${DIFF_PATHSPECS[@]}")
check_sensitive_files "$CHANGED_FILES"

DIFF_SIZE=$(echo -n "$DIFF" | wc -c)
MAX_DIFF_CHARS="${MAX_DIFF_CHARS:-40000}"

if [ "$DIFF_SIZE" -gt "$MAX_DIFF_CHARS" ]; then
    warn "Diff de ${DIFF_SIZE} caracteres, supera el límite (${MAX_DIFF_CHARS}). Truncando y agregando resumen de archivos."
    STAT_SUMMARY=$(git diff --stat "$DIFF_BASE"...HEAD -- "${DIFF_PATHSPECS[@]}")
    DIFF="RESUMEN DE ARCHIVOS (diff completo excede el límite):
$STAT_SUMMARY

DIFF PARCIAL (primeros ${MAX_DIFF_CHARS} caracteres):
$(echo -n "$DIFF" | head -c "$MAX_DIFF_CHARS")"
fi

check_llm_ready

SYSTEM_PROMPT='You are a strict Tech Lead. Generate a Pull Request title and description in JSON format based on the provided git diff.

CRITICAL TITLE RULES:
1. Format: <type>(<scope>): <short summary> OR <type>: <short summary>
2. Allowed <type> values ONLY: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.
3. Allowed <scope>: lowercase alphanumeric characters and hyphens ONLY (e.g., auth, user-api). NO paths, slashes, or uppercase. Omit if changes span multiple areas.
4. Short Summary: MUST be strictly lowercase (including the first letter), imperative mood ("add" not "added", "fix" not "fixed"), NO period at the end.
5. Max length: 72 characters STRICT hard limit.

CRITICAL BODY RULES (Markdown format in English):
1. Hard wrap ALL lines in the body at MAXIMUM 100 characters.
2. Maintain clear Markdown formatting using headers and bullet points.
3. Follow the requested PR Template structure if provided in the context; otherwise use the standard sections (Description, Main Changes, Review Notes / Impact).

MANDATORY JSON OUTPUT FORMAT:
- Return ONLY a raw, valid JSON object.
- Absolute prohibition: NO markdown code fences (no ```json), NO introductory text, NO wrapping commentary.
- Exact JSON shape:
{"title": "type(scope): concise imperative summary", "body": "## Description\n...\n\n## Main Changes\n...\n\n## Review Notes / Impact\n..."}

FEW-SHOT EXAMPLE OF VALID OUTPUT:
{"title": "feat(auth): add google oauth login support", "body": "## Description\nAdds Google OAuth2 authentication flow to allow users to sign in with their Google accounts.\n\n## Main Changes\n- Add passport-google-oauth20 strategy in auth module\n- Create /auth/google and /auth/google/callback endpoints\n\n## Review Notes / Impact\n- Requires GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in .env"}
'

info "Generando contenido de la PR con $(llm_describe)..."
AI_OUTPUT=$(call_llm_chat "$SYSTEM_PROMPT" "$DIFF")
AI_OUTPUT=$(printf '%s\n' "$AI_OUTPUT" | strip_code_fences)

PR_TITLE=""
PR_BODY=""

if echo "$AI_OUTPUT" | jq -e . >/dev/null 2>&1; then
    PR_TITLE=$(echo "$AI_OUTPUT" | jq -r '.title // empty')
    PR_BODY=$(echo "$AI_OUTPUT" | jq -r '.body // empty')
else
    warn "$(llm_provider_name) no devolvió JSON válido, uso fallback de parseo de texto."
    PR_TITLE=$(echo "$AI_OUTPUT" | grep -im1 "^title:" | sed -E 's/^[Tt]itle:\s*//' | xargs)
    PR_BODY=$(echo "$AI_OUTPUT" | grep -v -im1 "^title:")
fi

if [ -z "$PR_TITLE" ]; then
    PR_TITLE="feat: changes in $CURRENT_BRANCH"
    warn "No se pudo extraer el título generado, se usa uno por defecto. Revisalo antes de confirmar."
fi

if [ -z "$PR_BODY" ]; then
    PR_BODY="## Description

_Fill in manually, automatic generation failed._

## Main Changes
-

## Review Notes / Impact
-"
fi

if [ ${#PR_TITLE} -gt 72 ]; then
    PR_TITLE="${PR_TITLE:0:72}"
    PR_TITLE="${PR_TITLE% *}…"
    warn "Título truncado a 72 caracteres."
fi

TEMP_BODY_FILE=$(mktemp)
echo "$PR_BODY" > "$TEMP_BODY_FILE"

echo ""
echo "============================================="
echo "🚀 PREVIEW DE LA PR ($(llm_describe))"
echo "============================================="
echo "Título: $PR_TITLE"
echo ""
echo "Cuerpo:"
echo "$PR_BODY"
echo "============================================="
echo ""

read -r -p "¿Aplicar (a), editar cuerpo (e) o cancelar (c)? " CONFIRM

case "$CONFIRM" in
    a|A) ;;
    e|E)
        ${EDITOR:-vim} "$TEMP_BODY_FILE"
        PR_BODY=$(cat "$TEMP_BODY_FILE")
        ;;
    *)
        fail "PR cancelada."
        rm -f "$TEMP_BODY_FILE"
        exit 0
        ;;
esac

info "Sincronizando la rama con el remoto..."
git push origin "$CURRENT_BRANCH"

REMOTE_TYPE=$(detect_remote_type)
info "Remote detectado: $REMOTE_TYPE"

if [ "$REMOTE_TYPE" = "github" ]; then
    if ! command -v gh >/dev/null 2>&1; then
        fail "gh no está instalado. Instalalo o creá la PR manualmente."
        exit 1
    fi
    gh pr create --title "$PR_TITLE" --body-file "$TEMP_BODY_FILE" --base "$BASE_BRANCH"
    ok "Pull Request creada."
else
    create_forgejo_pr "$PR_TITLE" "$PR_BODY" "$BASE_BRANCH" "$CURRENT_BRANCH"
fi

rm -f "$TEMP_BODY_FILE"