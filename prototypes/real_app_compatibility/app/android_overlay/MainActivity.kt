// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0
package io.github.punitsoni22.compat_host

import android.app.ActivityManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Prototype only: reports how the previous process ended (ApplicationExitInfo, API 30+), so the
// crash guard can tell crashes from a user force-stop.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "compat/exit_info").setMethodCallHandler { call, result ->
            if (call.method != "lastExit") {
                result.notImplemented()
            } else if (Build.VERSION.SDK_INT < 30) {
                result.success(null)
            } else {
                val am = getSystemService(ActivityManager::class.java)
                val e = am.getHistoricalProcessExitReasons(packageName, 0, 1).firstOrNull()
                result.success(
                    e?.let {
                        mapOf("reason" to it.reason, "status" to it.status, "description" to (it.description ?: ""), "pid" to it.pid)
                    },
                )
            }
        }
    }
}
