# AndroidLLMBench

MVP Android independente da pesquisa **Inferência Adaptativa de LLMs em Dispositivos Mobile**. Um Gemma local, CPU, uma geração por toque, métricas e JSON. O diretório iOS `../MobileLLMBench/` não foi alterado.

## APIs conferidas

1. `Engine(EngineConfig(modelPath, backend = Backend.CPU()))` e `initialize()` fora da UI.
2. Engine mantido durante a sessão; `createConversation(ConversationConfig(...))` novo por baseline.
3. `ConversationConfig(maxOutputToken = 128)` e `SamplerConfig(topK = 1, topP = 1.0, temperature = 0.0)`.
4. `sendMessageAsync(prompt): Flow<Message>`; texto somente de `Content.Text`, acumulado como deltas.
5. `SystemClock.elapsedRealtimeNanos()` para durações; primeiro texto não vazio define `firstTextMs`.
6. `ExperimentalFlags.enableBenchmark` e `getBenchmarkInfo()` para métricas nativas disponíveis.
7. `Conversation.close()` após a geração, `Engine.close()` ao encerrar a Activity.
8. Exportação com `ACTION_CREATE_DOCUMENT` e `ContentResolver`, sem permissão ampla de armazenamento.

Fontes: [guia Kotlin/Android](https://developers.google.com/edge/litert-lm/android), [Config 0.17.0](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.17.0/kotlin/java/com/google/ai/edge/litertlm/Config.kt), [Conversation](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.17.0/kotlin/java/com/google/ai/edge/litertlm/Conversation.kt), [exemplo oficial](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.17.0/kotlin/java/com/google/ai/edge/litertlm/example/Main.kt).

## Versões fixadas

| Componente | Versão |
| --- | --- |
| Android Gradle Plugin | 9.4.0 |
| Gradle Wrapper | 9.6.0, distribuição e JAR verificados por SHA-256 |
| Kotlin / Kotlin Gradle Plugin | 2.4.20, com suporte Kotlin integrado do AGP |
| JDK | 17; ambiente consultado: Oracle 17.0.12 |
| Compile SDK / Target SDK | 37 / 37 |
| Min SDK escolhido para o MVP | 31, Android 12+ |
| SDK Build Tools | 36.0.0 |
| ABI | arm64-v8a, Android físico de 64 bits |
| LiteRT-LM | `com.google.ai.edge.litertlm:litertlm-android:0.17.0` |
| Coroutines | `org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0` |

LiteRT-LM **0.17.0** foi confirmado como release estável no [Maven Google](https://dl.google.com/dl/android/maven2/com/google/ai/edge/litertlm/litertlm-android/maven-metadata.xml) e no [release oficial](https://github.com/google-ai-edge/LiteRT-LM/releases/tag/v0.17.0). Seu POM inclui Gson 2.14.0 e Kotlin Reflect 2.4.0 transitivamente; o Gradle pode alinhar bibliotecas Kotlin com 2.4.20. Compatibilidade: [AGP 9.4](https://developer.android.com/build/releases/agp-9-4-0-release-notes), [Kotlin 2.4.20](https://kotlinlang.org/docs/whatsnew2420.html), [atualização oficial do KGP integrado](https://developer.android.com/build/releases/agp-9-0-0-release-notes#runtime-dependency-on-kotlin-gradle-plugin-upgrade). Não há Compose, DI ou AndroidX UI; a tela usa widgets da plataforma.

## Modelo escolhido

**`litert-community/Gemma3-1B-IT/gemma3-1b-it-int4.litertlm`**, variante genérica INT4, **584.417.280 bytes** no catálogo consultado. Já está no formato LiteRT-LM, é pequena para um modelo de 1B e não é um pacote NPU específico de um SoC. A documentação Android usa essa família em seus exemplos. [Arquivos oficiais](https://huggingface.co/litert-community/Gemma3-1B-IT/tree/main).

Revisão do repositório de pesos consultada: `a6306a4e292016480083b73b8dc6f3f939ae04c3`. Faça login e aceite os termos Gemma **no navegador do Windows**, depois baixe [este arquivo na revisão consultada](https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/a6306a4e292016480083b73b8dc6f3f939ae04c3/gemma3-1b-it-int4.litertlm?download=true). O repositório exige aceite para download; nenhum login ou downloader existe no app. Não use `.task`, variantes `sm*`, `mt*` ou `Google_Tensor*` neste teste. Guarde o arquivo fora do Git e de `assets`; `.gitignore` também exclui pesos.

## Primeiro teste no Windows e Android físico

1. Instale Android Studio estável compatível com AGP 9.4; no SDK Manager instale **Android SDK Platform 37**, **Build Tools 36.0.0** e **Platform Tools**. Abra esta pasta e selecione JDK 17+ no Gradle JDK. O Studio configura `local.properties`; pelo terminal, configure `ANDROID_HOME` para o mesmo SDK.
2. Ative Developer Options e USB Debugging no Android ARM64, conecte por USB e autorize este computador. Com `platform-tools` no PATH, execute `adb devices` e confira o estado `device`.
3. No PowerShell, dentro de `AndroidLLMBench`, execute ` .\gradlew.bat assembleDebug` e `adb install -r .\app\build\outputs\apk\debug\app-debug.apk`.
4. Baixe o arquivo acima no navegador para a pasta Downloads. Registre seu hash: `Get-FileHash "$env:USERPROFILE\Downloads\gemma3-1b-it-int4.litertlm" -Algorithm SHA256`.
5. Copie o modelo com o bloco ADB abaixo; confira o tamanho e hash da cópia.
6. Abra o app pelo ícone ou execute `adb shell am start -n org.residencia.androidllmbench/.MainActivity`.
7. Toque **LOAD MODEL** e aguarde **Ready**. Falhas de caminho/carregamento aparecem na tela, no Logcat e no JSON quando recuperáveis.
8. Toque **RUN BASELINE**; confira resposta local, `firstTextMs`, geração, memória, bateria e estado térmico. O prompt é o mesmo do baseline iOS: “Explique em português, em uma única frase curta, por que o céu é azul.”
9. Toque **RUN BASELINE** novamente: não há novo carregamento. Após carregar os pesos, também pode verificar uma execução com a rede desligada.
10. Toque **EXPORT JSON**, escolha um destino local para `benchmark-results.json`. Depois de um load e dois baselines, o array deve ter três registros. Exporte antes de encerrar a sessão.

Com mais de um aparelho conectado, acrescente `-s SERIAL` a **todos** os comandos ADB. Os comandos abaixo assumem um único Android, usuário principal e o APK **debug** instalado:

```powershell
adb devices
adb push "$env:USERPROFILE\Downloads\gemma3-1b-it-int4.litertlm" /data/local/tmp/model.litertlm
adb shell run-as org.residencia.androidllmbench mkdir -p files
adb shell "cat /data/local/tmp/model.litertlm | run-as org.residencia.androidllmbench sh -c 'cat > files/model.litertlm'"
adb shell run-as org.residencia.androidllmbench ls -l files/model.litertlm
adb shell run-as org.residencia.androidllmbench sha256sum files/model.litertlm
```

O pipe/redirecionamento ocorre **inteiramente no shell Android**, preservando os bytes também quando o host usa Windows PowerShell 5.1. `run-as` muda para o diretório privado do pacote antes de executar o comando. [Implementação oficial do run-as](https://android.googlesource.com/platform/system/core/+/refs/heads/main/run-as/run-as.cpp). O resultado é exatamente `context.filesDir/model.litertlm`. A forma direta `adb shell run-as org.residencia.androidllmbench cp /data/local/tmp/model.litertlm files/model.litertlm` também tem sintaxe válida, mas pode falhar por política de acesso ao arquivo temporário; o pipe lê como `shell` e grava como o app. Não desative SELinux. Sem aparelho conectado, a execução destes comandos ainda não foi testada.

## Métricas e limites

- **LOAD MODEL é um registro `operation = model_load`**: mede `initialize()`, incluindo eventuais caches nativos, entre snapshots do processo. Se initialize falhar, `modelLoadMs` mede o tempo até a falha e `success=false`; se o arquivo nem existir, esse campo é `null`. `totalGenerationMs=0` significa que nenhuma geração foi iniciada nesse registro; `response=null`.
- Cada `operation = baseline` reutiliza o Engine e tem **`modelLoadMs=null`**. A UI mantém o tempo do load bem-sucedido da sessão acima do último registro. Cada conversa é descartada ao final; não há histórico entre baselines.
- `totalGenerationMs`: da criação da conversa até o fim do Flow, excluindo initialize, consulta de métricas, encerramento normal da conversa e exportação. Em falha após o início, mede até a captura do erro. `firstTextMs` usa o mesmo início.
- **firstTextMs é latência observada pela aplicação até o primeiro chunk textual recebido; não necessariamente é TTFT interno do runtime.** Nenhuma duração usa relógio de calendário.
- Tokens e taxas vêm diretamente de [BenchmarkInfo](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.17.0/kotlin/java/com/google/ai/edge/litertlm/Benchmark.kt): último prefill e último decode, numa conversa com uma única geração. Essa API é marcada experimental na versão fixada; a instrumentação oficial fica habilitada em todas as execuções deste MVP. Se não houver valores positivos/finitos, ou a consulta lançar exceção, exportamos `null`; `metricsError` explica a consulta malsucedida. Isso não transforma uma geração concluída em falha.
- CPU usa a contagem padrão de threads do runtime (`Backend.CPU()`); o limite oficial é 128 tokens de saída. Não estimamos tokens por caracteres/chunks e não retokenizamos. Speculative decoding está explicitamente desabilitado.
- Memória: `Debug.getMemoryInfo(...).totalPss`, PSS aproximado do próprio processo, com páginas compartilhadas contabilizadas proporcionalmente, convertido de KiB para **MB decimais**. Inclui heap e memória nativa reportados pelo Android; não é pico, RSS nem memória física total do telefone. [API MemoryInfo](https://developer.android.com/reference/android/os/Debug.MemoryInfo).
- Bateria: `BatteryManager.BATTERY_PROPERTY_CAPACITY / 100f`, fração de 0 a 1; valores inválidos ficam `null`. Thermal vem de `PowerManager.currentThermalStatus` (suportado desde API 29; nosso min SDK é 31). O firmware pode reportar `NONE` sem detalhar sensores.
- Erros de arquivo, initialize, JNI, geração, vínculo nativo e `OutOfMemoryError` são registrados quando o processo consegue continuar. **OOM nativo fatal/abort e encerramento pelo Android não podem ser convertidos garantidamente em JSON**; preserve Logcat. Não há recuperação artificial por GC ou troca automática de backend.
- Tag Logcat: `AndroidLLMBench`; eventos `MODEL_LOAD_START`, `MODEL_LOAD_END`, `GENERATION_START`, `FIRST_TEXT`, `GENERATION_END`, `ERROR`. Para observar: `adb logcat -s AndroidLLMBench:I`. O runtime pode emitir seus próprios logs.
- Resultados pertencem à sessão da Activity, somente em memória; rotação de tela é tratada sem recriá-la. Ao fechar a Activity, o app aguarda a operação nativa atual terminar antes de fechar o Engine. Não há serviço em background. Se o Android matar o processo, os resultados não exportados se perdem.
- `model` identifica o arquivo **esperado**, não uma identificação automática dos bytes. Preserve hash, revisão e nome original do download junto do JSON. O app não pede acesso à internet nem a arquivos pessoais; o diálogo de exportação grava somente no destino escolhido.

## Coleta científica em Release

Use Android físico, Release sem debugger/profiler conectado, feche apps desnecessários e prefira não carregar o telefone; se estiver conectado, registre isso. Preserve bateria e thermal iniciais, fabricante/modelo, versão/build do Android (já incluídos no JSON), versão do runtime, hash/revisão do modelo e versões resolvidas das dependências.

Para este projeto de pesquisa, **Release é não depurável e assinado com a mesma chave debug local**. Isso permite atualizar o APK com `-r` preservando os pesos privados, sem tornar o build Release depurável. Não é uma configuração para distribuição pública. Após provisionar pelo APK debug:

```powershell
.\gradlew.bat assembleRelease
adb install -r .\app\build\outputs\apk\release\app-release.apk
```

Use o mesmo computador/chave. **Não desinstale o app nem limpe seus dados** entre os builds: isso remove o modelo. `run-as` não funciona no Release não depurável; para trocar os pesos, reinstale o APK debug com `-r`, copie novamente e reinstale Release com `-r`. Exporte os resultados antes dessas trocas. Abra pelo ícone para medir, sem Android Studio profiler. LiteRT-LM suporta GPU/NPU, mas este MVP usa exclusivamente CPU. Performance do Windows ou emulador nunca é dado científico; não tente carregar o Gemma de 1B no emulador. O APK atual é ARM64.

## Validação nesta máquina

Gradle Wrapper oficial 9.6.0 baixado e verificado. `gradlew.bat assembleDebug` foi tentado no Windows com Java 17 e acesso aos repositórios: **BUILD FAILED — SDK location not found**. Android SDK/ADB não foram encontrados/configurados nos locais usuais nem nas variáveis de ambiente. Isso impede a compilação Kotlin/Android e geração do APK; não afirmamos que o app compilou. Instale/configure o SDK e repita o passo 3. Nenhum benchmark foi executado no Windows, no emulador ou em telefone.

Revisão estática: quatro fontes Kotlin, contratos conferidos na versão 0.17.0, JSON com `null` explícito, operações de load/generation separadas, Engine retido e fechamentos previstos. Ainda faltam build completo, instalação física, initialize, geração, medidas, verificação do reuso e exportação no aparelho.

## Próximos experimentos

1. CPU vs GPU
2. Repetições controladas
3. Context-length sweep
4. FunctionGemma + tool calling
5. Endurance / thermal throttling
6. LiteRT-LM vs llama.cpp
