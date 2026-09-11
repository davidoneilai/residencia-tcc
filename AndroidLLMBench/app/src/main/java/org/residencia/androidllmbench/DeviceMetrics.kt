package org.residencia.androidllmbench

import android.content.Context
import android.os.BatteryManager
import android.os.Debug
import android.os.PowerManager

object DeviceMetrics {
    fun capture(context: Context, result: BenchmarkResult, before: Boolean) {
        val memory = try {
            val info = Debug.MemoryInfo()
            Debug.getMemoryInfo(info)
            info.totalPss.takeIf { it > 0 }?.let { it * 1024.0 / 1_000_000 }
        } catch (_: Exception) { null }
        val battery = try {
            context.getSystemService(BatteryManager::class.java)
                ?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                ?.takeIf { it in 0..100 }?.div(100f)
        } catch (_: Exception) { null }
        val thermal = try {
            when (context.getSystemService(PowerManager::class.java)?.currentThermalStatus) {
                PowerManager.THERMAL_STATUS_NONE -> "NONE"
                PowerManager.THERMAL_STATUS_LIGHT -> "LIGHT"
                PowerManager.THERMAL_STATUS_MODERATE -> "MODERATE"
                PowerManager.THERMAL_STATUS_SEVERE -> "SEVERE"
                PowerManager.THERMAL_STATUS_CRITICAL -> "CRITICAL"
                PowerManager.THERMAL_STATUS_EMERGENCY -> "EMERGENCY"
                PowerManager.THERMAL_STATUS_SHUTDOWN -> "SHUTDOWN"
                else -> null
            }
        } catch (_: Exception) { null }
        if (before) {
            result.memoryBeforeMB = memory
            result.batteryBefore = battery
            result.thermalBefore = thermal
        } else {
            result.memoryAfterMB = memory
            result.batteryAfter = battery
            result.thermalAfter = thermal
        }
    }
}
