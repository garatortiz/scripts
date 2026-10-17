# Cómo colaborar

El repo es chico: scripts de bash y una lib compartida. Un cambio entra si resuelve un caso real y no mete secretos ni rutas de una máquina.

## Antes de abrir la PR

1. Creá una rama desde `main`.
2. Corré [ShellCheck](https://www.shellcheck.net/) sobre lo que tocaste:

   ```bash
   shellcheck git-ai-commit.sh git-ai-pr.sh lib/llm-common.sh update_repomix.sh
   ```

3. Probá el script con tu propio entorno. No hace falta pegar la salida si incluye tokens, diffs privados o rutas locales.
4. No agregues `config.sh`, `*.log`, `.env` ni claves. Si un script necesita configuración, documentá la variable en `config.sh.example` o en el README.

## Mensaje de commit

[Conventional Commits](https://www.conventionalcommits.org/), en imperativo y en inglés, por ejemplo `fix: skip repomix report when origin/main is missing`.

## Pull request

Contá qué cambió y cómo lo probaste. Si el cambio altera variables de entorno o el formato de `config.sh`, actualizá el README y `config.sh.example` en el mismo PR.
