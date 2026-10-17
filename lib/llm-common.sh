#!/bin/bash
# lib/llm-common.sh
# Funciones compartidas por git-ai-commit.sh y git-ai-pr.sh.
# Agnóstico al proveedor: Ollama, Gemini, Groq vía GIT_AI_PROVIDER.
#
# Se importa con: source "$(dirname "$0")/lib/llm-common.sh"
#
# Env vars (.zshrc):
#   GIT_AI_PROVIDER   ollama | gemini | groq   (default: ollama)
#   OLLAMA_HOST       URL base de Ollama (default: http://localhost:11434)
#   OLLAMA_MODEL      modelo Ollama (default: qwen2.5-coder:14b)
#   OLLAMA_TIMEOUT    timeout curl en segundos (default: 600)
#   GEMINI_API_KEY    API key de Google AI Studio
#   GEMINI_MODEL      modelo Gemini (default: gemini-2.5-flash)
#   GEMINI_TIMEOUT    timeout curl en segundos (default: 120)
#   GROQ_API_KEY      API key de Groq Console
#   GROQ_MODEL        modelo Groq (default: openai/gpt-oss-120b)
#   GROQ_TIMEOUT      timeout curl en segundos (default: 120)
#   OLLAMA_API_BASE   alias legacy (Aider); fallback si OLLAMA_HOST no está seteado

# --- Config por defecto (sobreescribible por env vars) ---
GIT_AI_PROVIDER="${GIT_AI_PROVIDER:-ollama}"
OLLAMA_HOST="${OLLAMA_HOST:-${OLLAMA_API_BASE:-http://localhost:11434}}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:14b}"
OLLAMA_TIMEOUT="${OLLAMA_TIMEOUT:-600}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-flash}"
GEMINI_TIMEOUT="${GEMINI_TIMEOUT:-120}"
GROQ_MODEL="${GROQ_MODEL:-openai/gpt-oss-120b}"
GROQ_TIMEOUT="${GROQ_TIMEOUT:-120}"

# --- Colores para output ---
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_RESET='\033[0m'

info()  { echo -e "${C_BLUE}ℹ️  $1${C_RESET}"; }
ok()    { echo -e "${C_GREEN}✅ $1${C_RESET}"; }
warn()  { echo -e "${C_YELLOW}⚠️  $1${C_RESET}"; }
fail()  { echo -e "${C_RED}❌ $1${C_RESET}"; }

# --- Identidad del proveedor activo (para mensajes al usuario) ---
llm_provider_name() {
    case "$GIT_AI_PROVIDER" in
        ollama) echo "Ollama" ;;
        gemini) echo "Gemini" ;;
        groq)   echo "Groq" ;;
        *)      echo "$GIT_AI_PROVIDER" ;;
    esac
}

llm_model_name() {
    case "$GIT_AI_PROVIDER" in
        ollama) echo "$OLLAMA_MODEL" ;;
        gemini) echo "$GEMINI_MODEL" ;;
        groq)   echo "$GROQ_MODEL" ;;
        *)      echo "?" ;;
    esac
}

# Ej: "Ollama · qwen2.5-coder:14b" / "Gemini · gemini-2.5-flash" / "Groq · openai/gpt-oss-120b"
llm_describe() {
    echo "$(llm_provider_name) · $(llm_model_name)"
}

# --- Chequeo de dependencias ---
check_dependencies() {
    local missing=()
    for cmd in curl jq git; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        fail "Faltan dependencias: ${missing[*]}"
        echo "   Instalá con: sudo apt install ${missing[*]} (o brew install ${missing[*]})"
        exit 1
    fi
}

# --- Valida que el proveedor configurado esté listo para usarse ---
check_llm_ready() {
    case "$GIT_AI_PROVIDER" in
        ollama)
            if ! curl -sS --connect-timeout 5 --max-time 10 \
                "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
                fail "No se pudo conectar a Ollama en ${OLLAMA_HOST}."
                echo "   Revisá OLLAMA_HOST / que el servicio esté arriba."
                echo "   O cambiá de proveedor: export GIT_AI_PROVIDER=gemini"
                exit 1
            fi
            ;;
        gemini)
            if [ -z "${GEMINI_API_KEY:-}" ]; then
                fail "No se encontró GEMINI_API_KEY en las variables de entorno."
                echo "   Generá tu API key en Google AI Studio y agregá a tu .zshrc:"
                echo "   export GEMINI_API_KEY=\"tu_api_key\""
                echo "   O cambiá de proveedor: export GIT_AI_PROVIDER=ollama"
                exit 1
            fi
            ;;
        groq)
            if [ -z "${GROQ_API_KEY:-}" ]; then
                fail "No se encontró GROQ_API_KEY en las variables de entorno."
                echo "   Generá tu API key en https://console.groq.com y agregá a tu .zshrc:"
                echo "   export GROQ_API_KEY=\"tu_api_key\""
                echo "   O cambiá de proveedor: export GIT_AI_PROVIDER=ollama"
                exit 1
            fi
            ;;
        *)
            fail "Proveedor LLM desconocido: GIT_AI_PROVIDER='${GIT_AI_PROVIDER}'"
            echo "   Valores soportados: ollama | gemini | groq"
            exit 1
            ;;
    esac

    info "LLM: $(llm_describe)"
}

# --- Chequeo de archivos sensibles antes de mandar el diff al LLM ---
# Uso: check_sensitive_files ""                 -> archivos en stage (gac)
#      check_sensitive_files "$file_list"       -> lista explícita (gapr)
check_sensitive_files() {
    local file_list="${1:-}"
    if [ -z "$file_list" ]; then
        file_list=$(git diff --cached --name-only)
    fi

    local sensitive
    sensitive=$(echo "$file_list" | grep -E '\.env($|\.)|secrets|\.pem$|id_rsa|\.key$|credentials' || true)
    if [ -n "$sensitive" ]; then
        warn "Hay archivos con nombres sensibles en los cambios:"
        while IFS= read -r line; do
            echo "     $line"
        done <<< "$sensitive"
        read -r -p "¿Seguir de todos modos y mandar el diff a $(llm_describe)? (y/n): " CONFIRM_SENSITIVE
        if [ "$CONFIRM_SENSITIVE" != "y" ]; then
            fail "Cancelado por seguridad."
            exit 1
        fi
    fi
}

# --- Backend: Ollama (API /api/chat) ---
_call_ollama_chat() {
    local system_prompt="$1"
    local user_content="$2"

    local sys_file usr_file payload_file
    sys_file=$(mktemp)
    usr_file=$(mktemp)
    payload_file=$(mktemp)

    printf '%s' "$system_prompt" > "$sys_file"
    printf '%s' "$user_content" > "$usr_file"

    jq -n \
        --arg model "$OLLAMA_MODEL" \
        --rawfile sys "$sys_file" \
        --rawfile usr "$usr_file" \
        '{
            model: $model,
            stream: false,
            options: { temperature: 0.2 },
            messages: [
                { role: "system", content: $sys },
                { role: "user", content: $usr }
            ]
        }' > "$payload_file"

    local response curl_exit=0
    response=$(curl -sS --connect-timeout 10 --max-time "$OLLAMA_TIMEOUT" -X POST \
        -H "Content-Type: application/json" \
        --data-binary "@${payload_file}" \
        "${OLLAMA_HOST}/api/chat") || curl_exit=$?

    rm -f "$sys_file" "$usr_file" "$payload_file"

    if [ "$curl_exit" -ne 0 ]; then
        fail "curl falló al contactar Ollama en ${OLLAMA_HOST} (código $curl_exit)."
        exit 1
    fi

    local api_error
    api_error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
    if [ -n "$api_error" ]; then
        fail "Error de Ollama: $api_error"
        exit 1
    fi

    local output_text
    output_text=$(echo "$response" | jq -r '.message.content // empty' 2>/dev/null)

    if [ -z "$output_text" ]; then
        fail "Ollama devolvió una respuesta vacía."
        exit 1
    fi

    echo "$output_text"
}

# --- Backend: Gemini (generateContent) ---
_call_gemini_chat() {
    local system_prompt="$1"
    local user_content="$2"

    if [ -z "${GEMINI_API_KEY:-}" ]; then
        fail "GEMINI_API_KEY no está definida."
        exit 1
    fi

    local sys_file usr_file payload_file
    sys_file=$(mktemp)
    usr_file=$(mktemp)
    payload_file=$(mktemp)

    printf '%s' "$system_prompt" > "$sys_file"
    printf '%s' "$user_content" > "$usr_file"

    jq -n \
        --rawfile sys "$sys_file" \
        --rawfile usr "$usr_file" \
        '{
            system_instruction: { parts: [{ text: $sys }] },
            contents: [{ parts: [{ text: $usr }] }],
            generationConfig: { temperature: 0.2 }
        }' > "$payload_file"

    local response curl_exit=0
    response=$(curl -sS --connect-timeout 10 --max-time "$GEMINI_TIMEOUT" -X POST \
        -H "Content-Type: application/json" \
        --data-binary "@${payload_file}" \
        "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}") || curl_exit=$?

    rm -f "$sys_file" "$usr_file" "$payload_file"

    if [ "$curl_exit" -ne 0 ]; then
        fail "curl falló al contactar la API de Gemini (código $curl_exit)."
        exit 1
    fi

    local api_error
    api_error=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$api_error" ]; then
        fail "Error de la API de Gemini: $api_error"
        exit 1
    fi

    local output_text
    output_text=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)

    if [ -z "$output_text" ]; then
        fail "Gemini devolvió una respuesta vacía."
        exit 1
    fi

    echo "$output_text"
}

# --- Backend: Groq (OpenAI-compatible /chat/completions) ---
_call_groq_chat() {
    local system_prompt="$1"
    local user_content="$2"

    if [ -z "${GROQ_API_KEY:-}" ]; then
        fail "GROQ_API_KEY no está definida."
        exit 1
    fi

    local sys_file usr_file payload_file
    sys_file=$(mktemp)
    usr_file=$(mktemp)
    payload_file=$(mktemp)

    printf '%s' "$system_prompt" > "$sys_file"
    printf '%s' "$user_content" > "$usr_file"

    jq -n \
        --arg model "$GROQ_MODEL" \
        --rawfile sys "$sys_file" \
        --rawfile usr "$usr_file" \
        '{
            model: $model,
            temperature: 0.2,
            messages: [
                { role: "system", content: $sys },
                { role: "user", content: $usr }
            ]
        }' > "$payload_file"

    local response curl_exit=0
    response=$(curl -sS --connect-timeout 10 --max-time "$GROQ_TIMEOUT" -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${GROQ_API_KEY}" \
        --data-binary "@${payload_file}" \
        "https://api.groq.com/openai/v1/chat/completions") || curl_exit=$?

    rm -f "$sys_file" "$usr_file" "$payload_file"

    if [ "$curl_exit" -ne 0 ]; then
        fail "curl falló al contactar la API de Groq (código $curl_exit)."
        exit 1
    fi

    local api_error
    api_error=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [ -n "$api_error" ]; then
        fail "Error de la API de Groq: $api_error"
        exit 1
    fi

    local output_text
    output_text=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    if [ -z "$output_text" ]; then
        fail "Groq devolvió una respuesta vacía."
        exit 1
    fi

    echo "$output_text"
}

# --- Entrypoint agnóstico: call_llm_chat "system_prompt" "user_content" ---
call_llm_chat() {
    local system_prompt="$1"
    local user_content="$2"

    case "$GIT_AI_PROVIDER" in
        ollama) _call_ollama_chat "$system_prompt" "$user_content" ;;
        gemini) _call_gemini_chat "$system_prompt" "$user_content" ;;
        groq)   _call_groq_chat "$system_prompt" "$user_content" ;;
        *)
            fail "Proveedor LLM desconocido: GIT_AI_PROVIDER='${GIT_AI_PROVIDER}'"
            exit 1
            ;;
    esac
}

# --- Limpia fences de markdown (```json ... ```) que el modelo a veces agrega ---
strip_code_fences() {
    sed -e '/^```[a-zA-Z]*$/d' -e '/^```$/d'
}

# --- Detecta si el remote es GitHub o Forgejo/Gitea, para elegir gh vs API directa ---
detect_remote_type() {
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$remote_url" == *"github.com"* ]]; then
        echo "github"
    else
        echo "forgejo"
    fi
}

# --- Parsea owner/repo desde la URL del remote 'origin' ---
parse_git_remote() {
    local url
    url=$(git remote get-url origin 2>/dev/null || echo "")

    if [[ "$url" =~ ^ssh://[^/]+/([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
        REPO_OWNER="${BASH_REMATCH[1]}"
        REPO_NAME="${BASH_REMATCH[2]}"
    elif [[ "$url" =~ ^[^@]+@[^:]+:([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
        REPO_OWNER="${BASH_REMATCH[1]}"
        REPO_NAME="${BASH_REMATCH[2]}"
    elif [[ "$url" =~ ^https?://[^/]+/([^/]+)/([^/.]+)(\.git)?/?$ ]]; then
        REPO_OWNER="${BASH_REMATCH[1]}"
        REPO_NAME="${BASH_REMATCH[2]}"
    else
        fail "No se pudo parsear owner/repo desde el remote: $url"
        exit 1
    fi
}

# --- Crea la PR directo contra la API de Forgejo ---
create_forgejo_pr() {
    local title="$1"
    local body="$2"
    local base="$3"
    local head="$4"

    if [ -z "${FORGEJO_URL:-}" ] || [ -z "${FORGEJO_TOKEN:-}" ]; then
        fail "Faltan las variables de entorno FORGEJO_URL y/o FORGEJO_TOKEN."
        echo "   Generá un token en tu Forgejo: Settings > Applications > Generate New Token"
        echo "   Después agregá en tu .zshrc:"
        echo "      export FORGEJO_URL=\"https://git.example.com\""
        echo "      export FORGEJO_TOKEN=\"tu_token_aca\""
        exit 1
    fi

    parse_git_remote

    local payload
    payload=$(jq -n \
        --arg title "$title" \
        --arg body "$body" \
        --arg base "$base" \
        --arg head "$head" \
        '{title: $title, body: $body, base: $base, head: $head}')

    local curl_tls_opts=()
    if [ -n "${FORGEJO_CA_CERT:-}" ]; then
        curl_tls_opts=(--cacert "$FORGEJO_CA_CERT")
    fi

    local response http_code response_body curl_exit=0
    response=$(curl -sS --connect-timeout 10 --max-time 30 "${curl_tls_opts[@]}" -w "\n%{http_code}" -X POST \
        "${FORGEJO_URL}/api/v1/repos/${REPO_OWNER}/${REPO_NAME}/pulls" \
        -H "Authorization: token ${FORGEJO_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload") || curl_exit=$?

    if [ "$curl_exit" -ne 0 ]; then
        fail "curl falló al conectar con Forgejo (código de salida $curl_exit)."
        exit 1
    fi

    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        local pr_url
        pr_url=$(echo "$response_body" | jq -r '.html_url // empty')
        ok "PR creada: $pr_url"
    else
        fail "Error creando la PR (HTTP $http_code):"
        echo "$response_body" | jq . 2>/dev/null || echo "$response_body"
        exit 1
    fi
}
