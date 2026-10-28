# Diagnóstico AdaptiveStep — sessão DC484191

Fonte: `step-pilot-session.json` (48/48). Sem código novo, sem retreino, freeze v3 intocado.

## 1. `seq_001` e `seq_004` — onde quebrou

Pedido `seq_001`: buscar Ana e só então `ligar` no número devolvido.

| Política | Falha | Ponto exato |
|---|---|---|
| Direct | `no_tool` / `length` | r0 gasta 512 tokens em `<think>` e para sem ferramenta. |
| NoThink | `grade` | `buscarContato` devolve `Ana: +15550100`; r1 gera texto (“Ligue para o número… +15550100”) **sem** `ligar`. |
| AdaptiveStep | `grade` | Igual ao NoThink após `slow` de 64: lookup ok; r1–r3 `fast:unresolved_dependency` repetem o mesmo texto, 0 tools. |
| Budget64 | `execution` | Lookup + `ligar` **corretos** (sequence/args true), depois `enviarMensagem` sem `numero` → o runtime lança e aborta. |

Pedido `seq_004`: lembrete “Retornar Diego” (40 min) **e** FaceTime com o número da agenda (depende de `buscarContato`).

| Política | Falha | Ponto exato |
|---|---|---|
| Direct | `no_tool` / `length` | Outra vez 512 tokens de think, zero tools. |
| NoThink | `execution` | `criarLembrete` ok; `ligarFaceTime(numero: "##")` — placeholder, sem lookup. Validação: “precisa começar com +”. |
| AdaptiveStep | `execution` | Mesmo padrão: lembrete ok; `ligarFaceTime(numero: "##AGENDA##")`. O throw aborta (só r0 no trace). |
| Budget64 | `grade` | Quatro vezes o mesmo `criarLembrete`; nunca `buscarContato` nem FaceTime. |

Classificação: **não é o gold**. Direct é **modelo + teto de thinking**. NoThink/Adaptive em `seq_001` é **orquestração do modelo** (viu o número, não emitiu a segunda tool). `seq_004` é **modelo pulando a dependência** + **runtime** que rejeita placeholder e, no Adaptive, encerra o loop. Budget64 em `seq_001` mostra que a dependência era resolvível; o extra inválido é de novo modelo + aborto do runtime.

## 2. Por que AdaptiveStep não para

Direct/NoThink, em geração vazia, caem no `break` de `runControlled` (observe não pede recover). AdaptiveStep só dá `break` se `step.mode == recover`. Depois de ferramentas com `stop != length`, `noProgress` é falso (é “conclusão”). `unresolved_dependency` continua verdadeiro em `seq_001` (há telefone e não há `ligar`). Sem lookup pendente, cai em `fast:default`. Resultado: média 3,75 rodadas vs 2,0 no NoThink; ~2,4 rodadas finais vazias. Os textos de r2/r3 copiam r1.

Dá para parar **sem gold**: se a rodada teve 0 tool calls, `stopReason == stop`, e já existe alguma saída de ferramenta → `stop`. É o mesmo critério que Direct/NoThink já usam. No piloto isso **não mudaria o sucesso** de `seq_001`/`seq_004` (a tool que faltava nunca veio nessas rodadas extras). Preservaria multi/seq que ainda emitem tools (`seq_002`/`seq_003` param no primeiro vazio *depois* da segunda tool). Hipótese não vista aqui: modelo que faz uma pausa vazia e só então chama a próxima tool — essa regra cortaria isso; neste JSON não ocorreu.

`seq_004` Adaptive parou cedo por **throw**, não por essa regra. `multi_004` Adaptive falhou por tools **a mais** (WhatsApp) nas rodadas com `calls>0`; parar no vazio não evita isso.

## 3. Latência (média ms, n=12)

| Política | total | prefill | repeated prefill | decode | tools | overhead | residual |
|---|---:|---:|---:|---:|---:|---:|---:|
| Direct | 27636 | 251 | 2544 | 21770 | ~0 | 0.02 | 3071 |
| NoThink | 6262 | 285 | 1015 | 1870 | ~0 | 0.02 | 3092 |
| Budget64 | 18696 | 229 | 6313 | 8891 | ~0 | 0.03 | 3262 |
| AdaptiveStep | 13898 | 231 | 3218 | 4314 | ~0 | 0.52 | 6134 |

Tools simuladas ≈ 0. Overhead do controlador Adaptive é 0,5 ms — irrelevante.

Custo Adaptive vs NoThink (**+7,6 s**): +2,2 s repeated prefill (s1 `think()` + rodadas extras), +2,4 s decode, +3,0 s residual (parede do `think()`/passagens que não entram nos campos MLX). Prefill estático é o mesmo. Direct é caro no decode (thinking 512). Budget64 é o pior repeated prefill (s1 em todo turno).

## 4. Thinking vs NoThink neste piloto

Uma tarefa: `step_single_001` (“ligação … sem mensagem e sem FaceTime”).

- NoThink: `enviarWhatsApp` → grade (3,6 s).
- Direct (thinking 512): `ligar` certo (21,3 s).
- Adaptive `slow` 64 (heurística viu cues de mensagem/FaceTime na **negação**): `ligar` certo (16,5 s).
- Budget64: `ligar` certo na r0, depois WhatsApp/SMS extras → grade (17,6 s).

Custo do único ganho vs NoThink: **+12,9 s** (Adaptive) ou **+17,7 s** (Direct). Nenhuma outra tarefa do recorte converte falha NoThink em sucesso via thinking. O contrário existe: Direct perde `seq_003` e `multi_003` por `length`; NoThink acerta. Adaptive empatou NoThink em sequential (2/4, mesmos IDs).

## Recomendações

1. Não tratar AdaptiveStep como melhor que NoThink neste recorte: mesmo sucesso, 2,2× mais lento.
2. Se houver um ajuste mínimo depois, é **parar no primeiro vazio com `stop` e tools já observadas** — critério observável, já usado nas fixas. Não é aceleração nova; é o loop atual.
3. `seq_001`/`seq_004` não se resolvem com mais thinking no teto atual: Direct nem chega à tool. O buraco é emitir a segunda tool (ou `buscarContato`) depois do primeiro efeito. Placeholder `##` / `##AGENDA##` é falha de argumentos, não de roteamento.
4. Cues de thinking por substring (“mensagem”, “FaceTime”) na negativa são ruído (`single_001`). Não retreinar o v3 em cima disso.
