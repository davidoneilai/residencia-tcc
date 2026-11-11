#!/bin/zsh
# Mac smoke dos LoRA de SFT (Python mlx-lm; o caminho Swift é o que roda no iPhone).
# Uso: W=<dir com venv/, models/, hf/, hfhome/> analysis/sft/run.sh   (saída em results/sft-smoke/raw/)
set -e
W=${W:?"defina W = workspace com venv/, models/, hf/ e hfhome/"}
S=$(cd "$(dirname "$0")" && pwd)
H=$(cd "$S/../.." && pwd)/results/sft-smoke
mkdir -p $H/raw
PY="$W/venv/bin/python -I $S/smoke.py"
Q4=$W/hfhome/hub/models--mlx-community--Qwen3.5-2B-4bit/snapshots/674aaa7240b91e8012fcad5d791b7dfe5ba90207
QP=--prefix=model.language_model.=language_model.model.
$=PY --name qwen35_sft_training --base $Q4 --adapter $W/hf/qwen35-2b $QP --thinking both --out $H/raw/qwen35_training.json
$=PY --name qwen35_sft_basetemplate --base $Q4 --adapter $W/hf/qwen35-2b $QP --thinking both \
  --template $W/hf/base-qwen35/chat_template.jinja --out $H/raw/qwen35_base.json
$=PY --name qwen35_sft_bf16_training --base $W/models/mlx-community--Qwen3.5-2B-bf16 --adapter $W/hf/qwen35-2b $QP \
  --thinking false --out $H/raw/qwen35_bf16_training.json
$=PY --name minicpm5_sft_training --base $W/models/openbmb--MiniCPM5-2B-MLX --adapter $W/hf/minicpm5-2b \
  --thinking both --out $H/raw/minicpm5_training.json
$=PY --name minicpm5_sft_basetemplate --base $W/models/openbmb--MiniCPM5-2B-MLX --adapter $W/hf/minicpm5-2b \
  --thinking both --template $W/hf/base-minicpm5/chat_template.jinja --out $H/raw/minicpm5_base.json
# xLAM-2: template do adaptador == template da base (byte a byte); base 4 bits convertida localmente:
#   mlx_lm.convert --hf-path $W/models/Salesforce--xLAM-2-3b-fc-r (snapshot de Salesforce/xLAM-2-3b-fc-r) -q --q-bits 4 --q-group-size 64 --mlx-path $W/models/xLAM-2-3b-fc-r-4bit
$=PY --name xlam2_sft_training --base $W/models/xLAM-2-3b-fc-r-4bit --adapter $W/hf/xlam2-3b \
  --thinking none --out $H/raw/xlam2_training.json
