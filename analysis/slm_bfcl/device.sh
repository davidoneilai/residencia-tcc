#!/bin/zsh
# Ciclo on-device do estudo SLM × BFCL AST.
#   device.sh install
#   device.sh run '<auto-run json>'     # envia Documents/auto-run.json e relança o app
#   device.sh pull <destino.json>       # copia a session.json atual
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer
DEV=${IPHONE_UDID:?"defina IPHONE_UDID (xcrun devicectl list devices)"}
BUNDLE=davidoneil.MobileLLMBench
DC=(xcrun devicectl)

case "$1" in
install)
  APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/MobileLLMBench-*/Build/Products/Debug-iphoneos/MobileLLMBench.app | head -1)
  $DC device install app --device $DEV "$APP" --timeout 180 ;;
run)
  TMP=$(mktemp -d); print -r -- "$2" > $TMP/auto-run.json
  $DC device copy to --device $DEV --domain-type appDataContainer --domain-identifier $BUNDLE \
    --source $TMP/auto-run.json --destination Documents/auto-run.json
  $DC device process launch --device $DEV --terminate-existing $BUNDLE ;;
pull)
  $DC device copy from --device $DEV --domain-type appDataContainer --domain-identifier $BUNDLE \
    --source "Library/Application Support/MobileLLMBench/session.json" --destination "$2" ;;
esac
