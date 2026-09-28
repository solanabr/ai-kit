#!/usr/bin/env bash
# Run every verification script. T22_SO=<path> loads a different token-2022 ELF into LiteSVM.
cd "$(dirname "$0")"
for f in b1-create-mint-plan b1b-group-member b2-pausable b3-permissioned-burn b4-scaled-ui b5-combos b6-transfer-hook a-zk-proof-program; do
  echo "== $f"; node "$f.mjs"
done
