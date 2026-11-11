#!/bin/zsh
# Progresso de run_slice.sh: analysis/bfcl_mt/status.sh [dev|test]
cd "${0:A:h}/../.."
SLICE=${1:-dev}
LOG=results/bfcl-mt/run-$SLICE.log
N=$(.bfcl-venv/bin/python -c "import json;print(len(json.load(open('results/bfcl-mt/slice.json'))['$SLICE']))")
TOTAL=$(( N * 11 ))   # 3 condições × 3 SLMs + 2 no LFM2.5
[[ -f $LOG ]] || { print "ainda não começou ($LOG não existe)"; exit 0; }
DONE=$(.bfcl-venv/bin/python -c "
import json,glob
ids=set(json.load(open('results/bfcl-mt/slice.json'))['$SLICE'])
print(sum(1 for p in glob.glob('results/bfcl-mt/result/*-prefix/multi_turn/*_result.json') for l in open(p)
          if l.strip() and (r:=json.loads(l))['id'] in ids and 'latency' in r))")
if (( DONE >= TOTAL )); then
  print "TERMINOU: $DONE/$TOTAL válidas ($(command grep '^== done' $LOG | tail -1))"
elif pgrep -f "run_slice.sh $SLICE" >/dev/null; then
  print "RODANDO: $DONE/$TOTAL válidas; agora: $(command grep -E '^[0-9:]{8} ' $LOG | tail -1)"
else
  print "PARADO: $DONE/$TOTAL válidas; relance com analysis/bfcl_mt/run_slice.sh $SLICE (retoma)"
fi
WAITS=$(command grep -c 'WAIT iPhone' $LOG)
(( WAITS )) && print "esperas pelo iPhone: $WAITS (última: $(command grep 'WAIT iPhone' $LOG | tail -1 | cut -c1-8))"
FAILS=$(command grep -c '^FAILED' $LOG)
(( FAILS )) && print "falhas: $FAILS" && command grep '^FAILED' $LOG | tail -3
IDLE=$(( $(date +%s) - $(stat -f %m results/bfcl-mt/result/*/multi_turn/*.json(om[1]) $LOG(om[1]) | sort -n | tail -1) ))
print "última atividade há $(( IDLE / 60 )) min$( (( IDLE > 900 )) && print ' — parado demais: confira se o app está aberto no iPhone')"
