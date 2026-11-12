// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0
package io.github.punitsoni22.compat_host

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.os.RemoteException
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

// Runs in the separate ":otaverify" process (see AndroidManifest). Starts its own FlutterEngine
// on the app's AOT snapshot and runs package:compat_host/verifier_main.dart verifierMain(), which
// loads ONE candidate module. A malformed module that aborts the Dart VM kills only this process.
// After reporting, the process exits: modules cannot be unloaded, so each check starts clean.
class VerifierService : Service() {
    companion object {
        const val MSG_VERIFY = 1
        const val MSG_RESULT = 2
        const val MSG_JOB_TAKEN = 3
    }

    private var engine: FlutterEngine? = null
    private val main = Handler(Looper.getMainLooper())
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { msg ->
        if (msg.what == MSG_VERIFY && engine == null) start(msg.data.getString("path")!!, msg.replyTo)
        true
    })

    override fun onBind(intent: Intent): IBinder = messenger.binder

    private fun start(path: String, replyTo: Messenger) {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)
        // No plugins in the verifier: it must not touch app services.
        val e = FlutterEngine(applicationContext, null, false)
        engine = e
        MethodChannel(e.dartExecutor.binaryMessenger, "ota/verifier").setMethodCallHandler { call, res ->
            when (call.method) {
                "job" -> res.success(path)
                "result" -> {
                    res.success(null)
                    val m = call.arguments as Map<*, *>
                    val out = Message.obtain(null, MSG_RESULT)
                    out.data = Bundle().apply {
                        putString("status", m["status"] as String?)
                        putString("detail", m["detail"]?.toString())
                        putDouble("ms", (m["ms"] as Number).toDouble())
                        putString("probes", "uid=${Process.myUid()};dart=${m["probes"] ?: ""}")
                    }
                    try { replyTo.send(out) } catch (_: RemoteException) {}
                    main.postDelayed({ Process.killProcess(Process.myPid()) }, 300)
                }
                else -> res.notImplemented()
            }
        }
        e.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "package:compat_host/verifier_main.dart", "verifierMain"),
        )
    }
}
