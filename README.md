# Mobile LLM Bench

Teste no iPhone das duas estratégias de `mobile-adaptive-inference`: **direto** e **plano e ação**. O modelo é o `SystemLanguageModel` da Apple. Cada botão pede uma ação real do sistema.

Não é o BFCL inteiro. Não há MLX nem pacote SwiftPM: o app usa só o SDK.

## Ações

| Botão | Tool | API da Apple | O que acontece |
| --- | --- | --- | --- |
| Ligar | `ligar` | `tel:` | Abre o Telefone e disca |
| FaceTime | `ligarFaceTime` | `facetime-audio:` | Abre o FaceTime áudio |
| E-mail | `enviarEmail` | `mailto:` | Abre o Mail com a mensagem preenchida |
| Mensagem | `enviarMensagem` | `sms:` | Abre o Mensagens com o texto preenchido |
| Calendário | `criarEvento` | EventKit | Grava um evento |
| Lembrete | `criarLembrete` | EventKit | Grava um lembrete |
| Mapas | `abrirRota` | `https://maps.apple.com` | Abre uma rota de carro |
| Safari | `abrirSafari` | `https` | Abre a página no Safari |

Os números `+15550100`, `+15550101` e `+15550102` são da faixa fictícia 555. A tool recusa qualquer outro número, para o teste não discar alguém real. O e-mail é `test@example.com`. Mail e Mensagens abrem o rascunho; o envio continua na mão de quem testa. Calendário e Lembretes gravam de verdade, com o título que o modelo passar.

**Direto** manda o pedido já com as tools. **Plano e ação** gera um plano curto sem tools e só então gera de novo com as tools, como em `strategies.py`.

## Build no Xcode

1. Crie **iOS App → MobileLLMBench → SwiftUI / Swift**, sem armazenamento e sem testes.
2. **iOS Deployment Target = 26.0**, **Swift Language Version = Swift 6**, **Default Actor Isolation = Nonisolated**.
3. Não adicione pacote. Coloque no target os sete arquivos de `MobileLLMBench/`: `MobileLLMBenchApp.swift`, `ContentView.swift`, `BenchmarkRunner.swift`, `BenchmarkModels.swift`, `DeviceMetrics.swift`, `AppleFoundationBackend.swift`, `SystemTools.swift`. Um `@main` só.
4. No target, em Info, adicione:
   - `NSCalendarsFullAccessUsageDescription` = `O teste grava um evento para verificar a ferramenta de calendário.`
   - `NSRemindersFullAccessUsageDescription` = `O teste grava um lembrete para verificar a ferramenta de lembretes.`
5. Configure o **Signing Team**, conecte o iPhone, ative o Developer Mode se o sistema pedir e selecione o aparelho.
6. Ative o Apple Intelligence e espere o modelo do sistema ficar disponível.
7. Rode pelo Xcode. Escolha a estratégia e toque em uma ação. Quando voltar ao app, o log mostra o trace. **Export JSON** junta as execuções da sessão.

`totalMs` inclui o plano, quando existe, e a ida até o app do sistema. `toolExecutionMs` é só o tempo dentro da tool. Tokens ficam `null` no iOS 26; no iOS 27 vêm de `session.usage` da geração com tools.

O MVP Android continua em [AndroidLLMBench](AndroidLLMBench/README.md).
