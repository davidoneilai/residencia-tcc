Inferência local com vLLM. Duas modelos, quatro estratégias, benchmarks oficiais.

```bash
python run.py --model qwen3_1.7b --strategy direct --benchmark bfcl
python run.py --model gemma4_e2b --strategy plan_act --benchmark tau2
python analyze.py results/
```

O servidor sobe sozinho (`scripts/serve_*.sh`). O benchmark fala com o proxy em `127.0.0.1:8001`. O vLLM fica em `8000`.

No cluster:

```bash
sauron submit -c sauron/job.yaml sauron/run-bfcl.sauron
```

`HF_HOME=/cache/huggingface` é o cache que o nó já monta. Não monte outra pasta por cima. Token e chave do simulador de usuário ficam em `residencia-tcc/.env`.
