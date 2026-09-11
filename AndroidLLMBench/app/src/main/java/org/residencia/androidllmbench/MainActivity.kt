package org.residencia.androidllmbench

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.WindowInsets
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray

@Suppress("DEPRECATION") // Platform document export keeps this MVP free of AndroidX UI dependencies.
class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var activeJob: Job? = null
    private lateinit var benchmark: LiteRTBenchmark
    private val results = mutableListOf<BenchmarkResult>()
    private lateinit var status: TextView
    private lateinit var output: TextView
    private lateinit var load: Button
    private lateinit var run: Button
    private lateinit var export: Button
    private var busy = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        benchmark = LiteRTBenchmark(applicationContext)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val padding = (12 * resources.displayMetrics.density).toInt()
        layout.setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            view.setPadding(padding + bars.left, padding + bars.top, padding + bars.right, padding + bars.bottom)
            insets
        }
        layout.addView(TextView(this).apply { text = "Mobile LLM Bench - Android"; textSize = 22f })
        status = TextView(this).also { layout.addView(it) }
        load = Button(this).apply { text = "LOAD MODEL"; setOnClickListener { execute(loadModel = true) } }
        run = Button(this).apply { text = "RUN BASELINE"; setOnClickListener { execute(loadModel = false) } }
        export = Button(this).apply {
            text = "EXPORT JSON"
            setOnClickListener {
                try {
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/json"
                        putExtra(Intent.EXTRA_TITLE, "benchmark-results.json")
                    }, EXPORT_REQUEST)
                } catch (e: Exception) {
                    status.text = "Error: ${e.message}"
                    Log.e(LiteRTBenchmark.TAG, "ERROR export: ${e.message}", e)
                }
            }
        }
        layout.addView(load)
        layout.addView(run)
        layout.addView(export)
        output = TextView(this).apply { setTextIsSelectable(true); text = "Modelo esperado: $filesDir/model.litertlm" }
        layout.addView(ScrollView(this).apply { addView(output) }, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(layout)
        updateButtons("Model not loaded")
    }

    private fun execute(loadModel: Boolean) {
        if (busy) return
        busy = true
        updateButtons(if (loadModel) "Loading" else "Running")
        activeJob = scope.launch {
            try {
                val result = withContext(Dispatchers.IO) {
                    if (loadModel) benchmark.loadModel() else benchmark.runBaseline()
                }
                results.add(result)
                if (!isDestroyed) {
                    val loadMs = results.lastOrNull { it.operation == "model_load" && it.success }?.modelLoadMs
                    output.text = "Load time (sessão): ${loadMs ?: "null"} ms\n${result.toJson().toString(2)}"
                    status.text = if (result.success) "Ready" else "Error: ${result.error}"
                }
            } catch (e: OutOfMemoryError) {
                // Best effort only: native abort / Android process kill cannot be recovered here.
                Log.e(LiteRTBenchmark.TAG, "ERROR OutOfMemoryError", e)
                results.add(BenchmarkResult(
                    operation = if (loadModel) "model_load" else "baseline",
                    promptCharacters = if (loadModel) 0 else LiteRTBenchmark.PROMPT.length,
                    error = "OutOfMemoryError: ${e.message}",
                ))
                if (!isDestroyed) status.text = "Error: OutOfMemoryError; veja Logcat"
            } catch (e: Exception) {
                Log.e(LiteRTBenchmark.TAG, "ERROR ${e.message}", e)
                results.add(BenchmarkResult(
                    operation = if (loadModel) "model_load" else "baseline",
                    promptCharacters = if (loadModel) 0 else LiteRTBenchmark.PROMPT.length,
                    error = "${e.javaClass.simpleName}: ${e.message}",
                ))
                if (!isDestroyed) status.text = "Error: ${e.message}"
            } finally {
                busy = false
                if (!isDestroyed) updateButtons(status.text.toString())
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != EXPORT_REQUEST || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        busy = true
        updateButtons(status.text.toString())
        activeJob = scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    val json = JSONArray().apply { results.forEach { put(it.toJson()) } }.toString(2)
                    checkNotNull(contentResolver.openOutputStream(uri, "wt")) { "Não foi possível abrir o destino." }
                        .bufferedWriter(Charsets.UTF_8).use { it.write(json) }
                }
                if (!isDestroyed) output.append("\nJSON exportado: ${results.size} registros.")
            } catch (e: OutOfMemoryError) {
                Log.e(LiteRTBenchmark.TAG, "ERROR OutOfMemoryError na exportação", e)
                if (!isDestroyed) status.text = "Error: OutOfMemoryError na exportação"
            } catch (e: Exception) {
                Log.e(LiteRTBenchmark.TAG, "ERROR export: ${e.message}", e)
                if (!isDestroyed) status.text = "Error: export ${e.message}"
            } finally {
                busy = false
                if (!isDestroyed) updateButtons(status.text.toString())
            }
        }
    }

    private fun updateButtons(state: String) {
        status.text = state
        load.isEnabled = !busy && !benchmark.isLoaded
        run.isEnabled = !busy && benchmark.isLoaded
        export.isEnabled = !busy && results.isNotEmpty()
    }

    override fun onDestroy() {
        super.onDestroy()
        // Finish the bounded native operation before closing its Engine; do not race native callbacks.
        scope.launch {
            try {
                activeJob?.join()
                withContext(Dispatchers.IO) { benchmark.close() }
            } catch (e: OutOfMemoryError) {
                Log.e(LiteRTBenchmark.TAG, "ERROR OutOfMemoryError no cleanup", e)
            } catch (e: Exception) {
                Log.e(LiteRTBenchmark.TAG, "ERROR cleanup: ${e.message}", e)
            } finally { scope.cancel() }
        }
    }

    companion object {
        private const val EXPORT_REQUEST = 1
    }
}
