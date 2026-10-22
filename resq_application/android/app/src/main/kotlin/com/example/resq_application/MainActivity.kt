package com.example.resq_application

import android.content.ComponentName
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        // Switches the launcher icon between the light and dark activity-alias
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "resq/app_icon").setMethodCallHandler { call, result ->
            if (call.method == "setDark") {
                val dark = call.arguments as? Boolean ?: false
                setAlias("LightIcon", !dark)
                setAlias("DarkIcon", dark)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun setAlias(name: String, enabled: Boolean) {
        val component = ComponentName(this, "$packageName.$name")
        val state = if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        if (packageManager.getComponentEnabledSetting(component) == state) return
        packageManager.setComponentEnabledSetting(component, state, PackageManager.DONT_KILL_APP)
    }
}
