# SFT LoRA smoke (Mac, 2026-11-07)

This study is separate from the runtime-acceleration work (`results/runtime`, `results/bfcl-mt/dac`).
It checks only two things: does each adapter `davidoneil/agent-sft-*-lora` **load**, and does it make **correct function calls** on 6 short prompts, using greedy decoding (temp 0) and max 256 tokens.

- Engine: **Python mlx-lm 0.32.2 / mlx 0.32.4** on the Mac (M1, MacBook Pro). The adapter is applied **at runtime on the 4-bit MLX base**, without fusing (QLoRA-style). This mirrors what `SFTAdapter.load` does in Swift (`MobileLLMCore/SFTAdapters.swift`) with `LoRAContainer.fromPEFT` + `QLoRALinear`.
  The **Swift path is the one that runs on the iPhone. It was not run on the Mac.** It was only built for iOS (generic) in both apps.
- PEFT → MLX conversion: `analysis/sft/smoke.py:peft_to_mlx`. It strips `base_model.model.`, applies the rename `model.language_model.`→`language_model.model.` (Qwen3.5 only), renames `lora_A/B.weight`→`lora_a/b`, transposes, scales by α/r = 2.0, and casts to the base's dtype. The load fails if any key is missing or any shape differs. `probe_equal` confirms the tensor that got loaded is the same as the one converted.
- `no_lora` = the same base and the same template, without the adapter (reference). `lora` = with the adapter.
- `valid` = the expected call was recovered with the right arguments (`analysis/sft/smoke.py:CASES`). The parser is a Python port of `MLXPhoneBackend.recoverToolCalls`, plus the Qwen3.5 `<function=…>` format that `.xmlFunction` reads natively.

## Results

| adapter | base | template | LoRA tensors | thinking | no_lora | lora | format parsed | lora failures |
|---|---|---|---|---|---|---|---|---|
| qwen35 | mlx-community/Qwen3.5-2B-4bit | training (Hermes `<tool_call>{json}`) | 192 (24 layers) | off / on | 5/6, 5/6 | **4/6, 4/6** | `tool_call_json` (`.json`) | weather, parallel: `"name": <function-get_weather>` (invalid JSON) |
| qwen35 | mlx-community/Qwen3.5-2B-4bit | base (native XML) | 192 | off / on | 6/6, 5/6 | **6/6, 6/6** | `qwen_xml_function` (`.xmlFunction`) | — |
| qwen35 | mlx-community/Qwen3.5-2B-bf16 | training | 192 | off | 6/6 | **6/6** | `tool_call_json` | — (the error above only shows up on the 4-bit base) |
| minicpm5 | openbmb/MiniCPM5-2B-MLX | training | 588 (42 layers) | off / on | 5/6, 5/6 | **5/6, 6/6** | `minicpm_xml` (text, `recoverToolCalls`) | alarm (think off): `18:45` instead of `6:45` |
| minicpm5 | openbmb/MiniCPM5-2B-MLX | base | 588 | off / on | 5/6, 5/6 | **5/6, 6/6** | `minicpm_xml` | same; both templates render the same prompt here (same prompt_tokens, same outputs) |
| xlam2 | xLAM-2-3b-fc-r 4-bit g64 (**local conversion**) | training (= base, byte for byte) | 504 (36 layers) | n/a | 6/6 | **6/6** | `bare_json` (`[{"name":…}]`, `recoverToolCalls`) | — |

Every load came back with `probe_equal: true`, no missing keys and no shape mismatches. The LoRA keys are q/k/v/o/gate/up/down. In Qwen3.5 the attention LoRAs exist only on the full-attention layers.

## Files
- `raw/*.json`: full output of `analysis/sft/smoke.py` (scripts in `analysis/sft/`), one file per run (includes the raw text of each generation).
- `smoke.jsonl`: one line per case (120 lines). `summary.json`: one line per run/phase/thinking.
- `run.log`: stdout from the run.

## Commands
```zsh
# W = workspace with venv/ (mlx-lm), models/ and hf/ (adapters at the pinned revisions in SFTAdapters.swift)
W=<workspace> analysis/sft/run.sh > results/sft-smoke/run.log 2>&1
python3 -I analysis/sft/to_jsonl.py
```
xLAM-2 4-bit base (not on the Hub; **not published**):
`mlx_lm.convert --hf-path <snapshot Salesforce/xLAM-2-3b-fc-r@be83286f6a1a82c8bd4bfb751190271f58693f30> -q --q-bits 4 --q-group-size 64 --mlx-path $W/models/xLAM-2-3b-fc-r-4bit`.

## Pending
- Publish the xLAM-2 4-bit base. The `baseID` `davidoneil/xLAM-2-3b-fc-r-MLX-4bit` in `SFTAdapter.xlam2` does not exist yet, and its revision is `main`. Until it is published, `xlam2_sft` cannot load on the iPhone.
- Default template for Qwen3.5 SFT. The code today uses `.training` + `.json` (4/6 on 4-bit). On the Mac, `.base` + `.xmlFunction` scored 6/6.
- Smoke of the Swift path (`SFTAdapter.apply`, `.noUnusedKeys`) on the device.
