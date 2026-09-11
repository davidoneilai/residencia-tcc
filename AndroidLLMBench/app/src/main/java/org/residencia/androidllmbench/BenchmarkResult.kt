package org.residencia.androidllmbench

import android.os.Build
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

data class BenchmarkResult(
    val operation: String,
    val promptCharacters: Int,
    val id: String = UUID.randomUUID().toString(),
    val timestamp: String = Instant.now().toString(),
    val deviceManufacturer: String = Build.MANUFACTURER,
    val deviceModel: String = Build.MODEL,
    val androidVersion: String = Build.VERSION.RELEASE,
    val androidBuild: String = Build.FINGERPRINT,
    val sdkVersion: Int = Build.VERSION.SDK_INT,
    val runtime: String = "LiteRT-LM",
    val runtimeVersion: String = BuildConfig.LITERT_LM_VERSION,
    val model: String = "litert-community/Gemma3-1B-IT/gemma3-1b-it-int4.litertlm",
    val backend: String = "CPU",
    var inputTokens: Int? = null,
    var outputTokens: Int? = null,
    var modelLoadMs: Double? = null,
    var firstTextMs: Double? = null,
    var totalGenerationMs: Double = 0.0,
    var prefillTokensPerSecond: Double? = null,
    var decodeTokensPerSecond: Double? = null,
    var memoryBeforeMB: Double? = null,
    var memoryAfterMB: Double? = null,
    var thermalBefore: String? = null,
    var thermalAfter: String? = null,
    var batteryBefore: Float? = null,
    var batteryAfter: Float? = null,
    var success: Boolean = false,
    var error: String? = null,
    var metricsError: String? = null,
    var response: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("operation", operation)
        put("promptCharacters", promptCharacters)
        put("id", id)
        put("timestamp", timestamp)
        put("deviceManufacturer", deviceManufacturer)
        put("deviceModel", deviceModel)
        put("androidVersion", androidVersion)
        put("androidBuild", androidBuild)
        put("sdkVersion", sdkVersion)
        put("runtime", runtime)
        put("runtimeVersion", runtimeVersion)
        put("model", model)
        put("backend", backend)
        put("inputTokens", inputTokens ?: JSONObject.NULL)
        put("outputTokens", outputTokens ?: JSONObject.NULL)
        put("modelLoadMs", modelLoadMs ?: JSONObject.NULL)
        put("firstTextMs", firstTextMs ?: JSONObject.NULL)
        put("totalGenerationMs", totalGenerationMs)
        put("prefillTokensPerSecond", prefillTokensPerSecond ?: JSONObject.NULL)
        put("decodeTokensPerSecond", decodeTokensPerSecond ?: JSONObject.NULL)
        put("memoryBeforeMB", memoryBeforeMB ?: JSONObject.NULL)
        put("memoryAfterMB", memoryAfterMB ?: JSONObject.NULL)
        put("thermalBefore", thermalBefore ?: JSONObject.NULL)
        put("thermalAfter", thermalAfter ?: JSONObject.NULL)
        put("batteryBefore", batteryBefore ?: JSONObject.NULL)
        put("batteryAfter", batteryAfter ?: JSONObject.NULL)
        put("success", success)
        put("error", error ?: JSONObject.NULL)
        put("metricsError", metricsError ?: JSONObject.NULL)
        put("response", response ?: JSONObject.NULL)
    }
}
