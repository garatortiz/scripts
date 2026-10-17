#!/bin/bash
# git-ai-commit.sh
# Genera un mensaje de commit (Conventional Commits) a partir del diff en stage,
# usando el LLM configurado vía GIT_AI_PROVIDER (ollama | gemini | groq).
#
# Uso: gac  (alias sugerido en .zshrc)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/llm-common.sh
source "$SCRIPT_DIR/lib/llm-common.sh"

check_dependencies

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "No estás dentro de un repositorio git (cwd: $(pwd))."
    exit 1
fi

# 1. Obtener el diff del stage
DIFF=$(git diff --cached -- . ':!*.lock' ':!pnpm-lock.yaml' ':!package-lock.json' ':!dist/*' ':!*.min.js')
if [ -z "$DIFF" ]; then
    fail "No hay cambios en el stage. Usa 'git add' primero."
    exit 1
fi

check_sensitive_files
check_llm_ready

# 2. Reglas de negocio/estilo
MAX_TITLE_LEN=72

SYSTEM_PROMPT='You are a Git expert following the Conventional Commits specification. Generate a commit message based on the provided diff.

STRICT TITLE RULES:
1. Format: <type>(<scope>): <subject> OR <type>: <subject>
2. Allowed <type> ONLY: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.
3. Allowed <scope>: lowercase alphanumeric characters and hyphens ONLY (e.g. auth, user-api). NEVER use uppercase, slashes, paths, or file extensions. Omit scope if changes cover multiple areas.
4. <subject> rules:
   - MUST be strictly lowercased (including the first letter).
   - MUST use imperative mood ("add" NOT "added/adds", "fix" NOT "fixed/fixes", "change" NOT "changed").
   - MUST NOT end with a period.
5. Title hard length limit: MAXIMUM 50 characters (absolute maximum 72). Count characters before outputting.

STRICT BODY RULES (if needed for complex diffs):
1. Leave EXACTLY one blank line between title and body.
2. Format body as short bullet points starting with "- ".
3. Hard line limit: NO line in the body can exceed 72 characters.
4. DO NOT repeat or restate the title in the body.

OUTPUT FORMAT:
- Return ONLY the raw commit message text.
- Absolute prohibition: NO markdown code fences (no ```), NO preamble, NO quote marks, NO postscript.

FEW-SHOT EXAMPLES:

Example 1 (Simple):
feat(auth): add google oauth login support

Example 2 (With Scope and Body):
fix(api): prevent null pointer on empty payload

- validate request body before parsing
- return 400 bad request on missing required fields

Example 3 (No Scope):
refactor: simplify database connection pool logic'

info "Generando mensaje de commit con $(llm_describe)..."
COMMIT_MSG=$(call_llm_chat "$SYSTEM_PROMPT" "$DIFF")
COMMIT_MSG=$(printf '%s\n' "$COMMIT_MSG" | strip_code_fences)

if [ -z "$COMMIT_MSG" ]; then
    fail "$(llm_provider_name) devolvió una respuesta vacía."
    exit 1
fi

COMMIT_TITLE=$(echo "$COMMIT_MSG" | head -n1)

# 3. Si el título se pasó del límite, truncamos localmente
if [ "${#COMMIT_TITLE}" -gt "$MAX_TITLE_LEN" ]; then
    warn "Título de ${#COMMIT_TITLE} caracteres (máx $MAX_TITLE_LEN). Truncando localmente..."
    COMMIT_BODY=$(echo "$COMMIT_MSG" | tail -n +2)
    COMMIT_TITLE="${COMMIT_TITLE:0:$MAX_TITLE_LEN}"
    COMMIT_TITLE="${COMMIT_TITLE% *}"  # corta en el último espacio, no a mitad de palabra
    COMMIT_MSG="${COMMIT_TITLE}
${COMMIT_BODY}"
fi

# 4. Validar formato Conventional Commits
if ! [[ "$COMMIT_TITLE" =~ ^(feat|fix|docs|style|refactor|test|chore)(\([a-zA-Z0-9_-]+\))?:\ .+ ]]; then
    warn "El título no sigue Conventional Commits al pie de la letra. Revisalo al editar."
fi

TITLE_LEN=${#COMMIT_TITLE}
if [ "$TITLE_LEN" -gt "$MAX_TITLE_LEN" ]; then
    warn "El título sigue en $TITLE_LEN caracteres tras el truncado. Te conviene editarlo (opción 'e')."
fi

echo ""
echo "-----------------------------------------------"
echo "📝 Mensaje generado ($(llm_describe)):"
echo ""
echo "$COMMIT_MSG"
echo "-----------------------------------------------"
echo ""

# 5. Confirmar / editar / cancelar
read -r -p "¿Aplicar (a), editar (e) o cancelar (c)? " CONFIRM

TEMP_MSG_FILE=$(mktemp)
echo "$COMMIT_MSG" > "$TEMP_MSG_FILE"

case "$CONFIRM" in
    a|A)
        git commit -F "$TEMP_MSG_FILE"
        ok "Commit realizado."
        ;;
    e|E)
        ${EDITOR:-vim} "$TEMP_MSG_FILE"
        git commit -F "$TEMP_MSG_FILE"
        ok "Commit realizado con mensaje editado."
        ;;
    *)
        fail "Commit cancelado."
        rm -f "$TEMP_MSG_FILE"
        exit 1
        ;;
esac

rm -f "$TEMP_MSG_FILE"
