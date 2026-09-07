#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
docker tag marlow-depot/depot-api:latest marlow-depot/depot-api:1.0
echo "tagged marlow-depot/depot-api:1.0"
