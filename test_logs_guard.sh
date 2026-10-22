#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
python3 -m unittest discover -s tests -p 'test_fast.py' -v
./tests/integration.sh
