package org.residencia.androidllmbench

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.ExperimentalFlags
import com.google.ai.edge.litertlm.SamplerConfig
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.buffer
import java.io.File

// Called serially from the Activity's worker coroutine, never on the UI thread.
@OptIn(ExperimentalApi::class)
class LiteRTBenchmark(context: Context) : AutoCloseable {
    private val context = context.applicationContext
    private var engine: Engine? = null
    val isLoaded: Boolean get() = engine != null

    fun loadModel(): BenchmarkResult {
        val result = BenchmarkResult(operation = "model_load", promptCharacters = 0)
        var candidate: Engine? = null
        try {
            DeviceMetrics.capture(context, result, before = true)
            check(engine == null) { "O Engine já está carregado." }
            val model = File(context.filesDir, "model.litertlm")
            check(model.isFile && model.length() > 0) { "Modelo não encontrado: ${model.absolutePath}" }
            ExperimentalFlags.enableBenchmark = true
            ExperimentalFlags.enableSpeculativeDecoding = false
            candidate = Engine(EngineConfig(modelPath = model.absolutePath, backend = Backend.CPU()))
            Log.i(TAG, "MODEL_LOAD_START")
            val started = SystemClock.elapsedRealtimeNanos()
            try {
                candidate.initialize()
            } finally {
                result.modelLoadMs = (SystemClock.elapsedRealtimeNanos() - started) / 1_000_000.0
                Log.i(TAG, "MODEL_LOAD_END")
            }
            engine = candidate
            candidate = null
            result.success = true
        } catch (e: OutOfMemoryError) {
            result.error = "OutOfMemoryError durante model loading: ${e.message}"
            Log.e(TAG, "ERROR ${result.error}", e)
        } catch (e: Exception) {
            result.error = "${e.javaClass.simpleName}: ${e.message}"
            Log.e(TAG, "ERROR ${result.error}", e)
        } catch (e: LinkageError) {
            result.error = "Biblioteca nativa indisponível: ${e.message}"
            Log.e(TAG, "ERROR ${result.error}", e)
        } finally {
            try {
                if (candidate?.isInitialized() == true) candidate.close()
            } catch (e: Exception) {
                result.error = "${result.error.orEmpty()} Cleanup: ${e.message}"
                Log.e(TAG, "ERROR ${result.error}", e)
            }
            DeviceMetrics.capture(context, result, before = false)
        }
        return result
    }

    suspend fun runBaseline(): BenchmarkResult {
        val result = BenchmarkResult(operation = "baseline", promptCharacters = PROMPT.length)
        var started: Long? = null
        val output = StringBuilder()
        try {
            DeviceMetrics.capture(context, result, before = true)
            val loaded = checkNotNull(engine) { "Use LOAD MODEL antes de RUN BASELINE." }
            // Includes conversation creation, but never Engine.initialize().
            Log.i(TAG, "GENERATION_START")
            val generationStart = SystemClock.elapsedRealtimeNanos()
            started = generationStart
            loaded.createConversation(
                ConversationConfig(
                    samplerConfig = SamplerConfig(topK = 1, topP = 1.0, temperature = 0.0),
                    maxOutputToken = 128,
                )
            ).use { conversation ->
                // Fused callbackFlow buffer avoids dropped trySend chunks; output is capped at 128 tokens.
                conversation.sendMessageAsync(PROMPT).buffer(Channel.UNLIMITED).collect { message ->
                    val text = message.contents.contents.filterIsInstance<Content.Text>()
                        .joinToString("") { it.text }
                    if (text.isNotEmpty()) {
                        if (result.firstTextMs == null) {
                            result.firstTextMs = (SystemClock.elapsedRealtimeNanos() - generationStart) / 1_000_000.0
                            Log.i(TAG, "FIRST_TEXT")
                        }
                        output.append(text)
                    }
                }
                result.totalGenerationMs = (SystemClock.elapsedRealtimeNanos() - generationStart) / 1_000_000.0
                started = null // Do not include metrics lookup or conversation.close() in duration.
                Log.i(TAG, "GENERATION_END")
                try {
                    val info = conversation.getBenchmarkInfo()
                    result.inputTokens = info.lastPrefillTokenCount.takeIf { it > 0 }
                    result.outputTokens = info.lastDecodeTokenCount.takeIf { it > 0 }
                    result.prefillTokensPerSecond = info.lastPrefillTokensPerSecond.takeIf { it.isFinite() && it > 0 }
                    result.decodeTokensPerSecond = info.lastDecodeTokensPerSecond.takeIf { it.isFinite() && it > 0 }
                } catch (e: Exception) {
                    result.metricsError = "${e.javaClass.simpleName}: ${e.message}"
                    Log.e(TAG, "ERROR benchmark metrics: ${result.metricsError}", e)
                }
            }
            check(output.isNotBlank()) { "O modelo retornou texto vazio." }
            result.success = true
        } catch (e: OutOfMemoryError) {
            result.error = "OutOfMemoryError durante geração: ${e.message}"
            Log.e(TAG, "ERROR ${result.error}", e)
        } catch (e: Exception) {
            result.error = "${e.javaClass.simpleName}: ${e.message}"
            Log.e(TAG, "ERROR ${result.error}", e)
        } catch (e: LinkageError) {
            result.error = "Biblioteca nativa indisponível: ${e.message}"
            Log.e(TAG, "ERROR ${result.error}", e)
        } finally {
            started?.let {
                result.totalGenerationMs = (SystemClock.elapsedRealtimeNanos() - it) / 1_000_000.0
                Log.i(TAG, "GENERATION_END")
            }
            result.response = output.toString().ifEmpty { null }
            DeviceMetrics.capture(context, result, before = false)
        }
        return result
    }

    override fun close() {
        engine?.close()
        engine = null
    }

    companion object {
        const val TAG = "AndroidLLMBench"
        const val PROMPT = "Explique em português, em uma única frase curta, por que o céu é azul."
    }
}
