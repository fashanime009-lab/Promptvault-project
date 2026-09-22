#!/usr/bin/env bash
# Deploys the generated ../site directory to Vercel using a token (no git needed).
# Usage: VERCEL_TOKEN=xxxx ./deploy.sh
set -euo pipefail

if [ -z "${VERCEL_TOKEN:-}" ]; then
  echo "Error: set VERCEL_TOKEN (create one at https://vercel.com/account/tokens)"
  exit 1
fi

cd "$(dirname "$0")/../site"
npx --yes vercel deploy --prod --token "$VERCEL_TOKEN" --yes
