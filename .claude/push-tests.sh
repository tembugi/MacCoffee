#!/bin/bash
# The quickest run that proves a push (house rules): the app builds and its logic tests pass.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null
Tests/run.sh
