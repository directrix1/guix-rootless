#!/usr/bin/env bash
set -e
exec "$HOME/.local/bin/guix-env.sh" --gui "$@"
