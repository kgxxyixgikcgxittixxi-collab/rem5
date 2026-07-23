#!/bin/bash
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/start_nro.sh" "$@"
