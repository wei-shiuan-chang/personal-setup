#!/usr/bin/env bash
set -euo pipefail

version=3.1.8
venv="${XDG_CACHE_HOME:-$HOME/.cache}/redfish-service-validator/$version"
case "${1:-}" in
    -h|--help)
        cat <<'HELP'
validate-redfish.sh --install
validate-redfish.sh --config FILE                         # full service tree
validate-redfish.sh --config FILE --payload Single URI    # one resource
validate-redfish.sh --config FILE --payload Tree URI      # resource and descendants

With no arguments, reads ./config.ini. Reports default to ./logs.
Additional DMTF validator options pass through unchanged.
HELP
        exit 0 ;;
    --install)
        python3 -m venv "$venv"
        exec "$venv/bin/python" -m pip install "redfish-service-validator==$version" ;;
esac
if [[ ! -x "$venv/bin/rf_service_validator" ]]; then
    echo 'Install the validator first with validate-redfish.sh --install' >&2
    exit 1
fi
exec "$venv/bin/rf_service_validator" "$@"
