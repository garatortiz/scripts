# scripts

[![ShellCheck](https://github.com/garatortiz/scripts/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/garatortiz/scripts/actions/workflows/shellcheck.yml)
[![Licencia MIT](https://img.shields.io/github/license/garatortiz/scripts)](LICENSE)
[![Release](https://img.shields.io/github/v/release/garatortiz/scripts)](https://github.com/garatortiz/scripts/releases/latest)

Tres scripts de bash para el trabajo de todos los días.

- `git-ai-commit.sh` lee lo que ya pusiste en stage y propone el mensaje de commit. No commitea hasta que lo confirmás.
- `git-ai-pr.sh` propone el título y la descripción de la pull request, pushea la rama y la abre en GitHub o Forgejo.
- `update_repomix.sh` junta el código de cada proyecto en un archivo de texto y lo sube a Google Drive. Usa la rama `main` del remoto, no la rama en la que estés trabajando.

## Scripts

| Script | Qué hace |
|--------|----------|
| `git-ai-commit.sh` | Arma un mensaje [Conventional Commits](https://www.conventionalcommits.org/) a partir del stage y lo commitea si lo confirmás. |
| `git-ai-pr.sh` | Arma título y cuerpo de una PR contra la rama base, pushea la rama y abre la PR en GitHub (`gh`) o Forgejo. |
| `update_repomix.sh` | Empaqueta el código de `main` en un archivo de texto por proyecto y lo sube a Drive. |

`lib/llm-common.sh` lo usan los dos scripts de git. No se ejecuta solo.

Alias opcionales:

```bash
alias gac="$HOME/projects/scripts/git-ai-commit.sh"
alias gapr="$HOME/projects/scripts/git-ai-pr.sh"
```

## Requisitos

- `bash`, `git`, `curl`, `jq`
- Un proveedor de LLM (ver abajo)
- `gh`, solo si `git-ai-pr.sh` habla con GitHub
- `node` / `npx` y `rclone`, solo para `update_repomix.sh`

## LLM

`GIT_AI_PROVIDER` elige el modelo. El default es Ollama en `http://localhost:11434`.

| Variable | Uso |
|----------|-----|
| `GIT_AI_PROVIDER` | `ollama` (default), `gemini` o `groq` |
| `OLLAMA_HOST`, `OLLAMA_MODEL` | Ollama. Default del modelo: `qwen2.5-coder:14b` |
| `GEMINI_API_KEY`, `GEMINI_MODEL` | Gemini. Default: `gemini-2.5-flash` |
| `GROQ_API_KEY`, `GROQ_MODEL` | Groq. Default: `openai/gpt-oss-120b` |
| `GIT_AI_BASE_BRANCH` | Rama base de `git-ai-pr.sh` si no pasás una. Default: `main` |
| `FORGEJO_URL`, `FORGEJO_TOKEN` | Obligatorias si el remote no es GitHub |
| `FORGEJO_CA_CERT` | CA propia, si Forgejo no usa una CA pública |

Las claves van en el entorno (por ejemplo `.zshrc`). No van en este repo.

```bash
export GIT_AI_PROVIDER=ollama
# o: export GIT_AI_PROVIDER=gemini && export GEMINI_API_KEY=...
```

### Commits

Desde un repo, con cambios ya en stage:

```bash
./git-ai-commit.sh
```

Ignora lockfiles y `dist/`. Antes de llamar al modelo rechaza paths que parecen secretos (`.env`, `*.pem`, `id_rsa`, `credentials`).

### Pull requests

```bash
./git-ai-pr.sh                  # base: main
./git-ai-pr.sh develop          # otra base
./git-ai-pr.sh main 'src/*'     # limitar el diff
```

Muestra un preview y pregunta si aplicar, editar el cuerpo o cancelar. Recién después pushea y crea la PR.

## Reportes Repomix

`update_repomix.sh` no lee el checkout en el que estés parado. Hace `git fetch origin main` y empaqueta un worktree temporal de esa rama. Si el fetch falla, ese repo se salta.

Las rutas viven en `config.sh`, que no se versiona:

```bash
cp config.sh.example config.sh
```

Completá los directorios de cada repo, `OUTPUT_DIR` y `DRIVE_FOLDER` (`gdrive:...`, un remote de rclone). Sin `config.sh` el script sale antes de borrar reportes o sincronizar.

## Qué no entra al repo

`.gitignore` deja afuera `config.sh` y `*.log`. Tampoco subas tokens, claves de API ni la config de rclone.
