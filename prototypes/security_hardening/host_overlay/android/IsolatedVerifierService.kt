// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0
package io.github.punitsoni22.compat_host

import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.RemoteException
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.net.InetSocketAddress
import java.net.Socket

// Phase 3C: the candidate module is verified in an ANDROID ISOLATED PROCESS
// (android:isolatedProcess="true", process ":otaverify_iso"). Android runs it under a separate,
// temporary UID with no permissions of the app, so it cannot open the app's private files.
// The main process opens the candidate READ-ONLY and passes only the file descriptor.
//
// Before loading, the service records isolation probes (UID, Process.isIsolated, attempts to read
// and write the app's private patch store, to read the app's external directory, and to create a
// network socket). The probes are evidence for docs/architecture/verification-process-isolation.md;
// they do not by themselves prove a sandbox.
//
// If Flutter cannot start in an isolated process the service reports UNAVAILABLE (never OK), and
// the app falls back to the non-isolated ":otaverify" process (logged).
class IsolatedVerifierService : Service() {
    private var engine: FlutterEngine? = null
    private val main = Handler(Looper.getMainLooper())
    private val messenger = Messenger(Handler(Looper.getMainLooper()) { msg ->
        if (msg.what == VerifierService.MSG_VERIFY && engine == null) {
            msg.data.classLoader = ParcelFileDescriptor::class.java.classLoader
            @Suppress("DEPRECATION")
            val fd = msg.data.getParcelable<ParcelFileDescriptor>("fd")
            start(fd, msg.data.getString("pkg") ?: "", msg.replyTo)
        }
        true
    })

    override fun onBind(intent: Intent): IBinder = messenger.binder

    private fun reply(to: Messenger, status: String, detail: String, ms: Double, probes: Map<String, String>) {
        val out = Message.obtain(null, VerifierService.MSG_RESULT)
        out.data = Bundle().apply {
            putString("status", status)
            putString("detail", detail)
            putDouble("ms", ms)
            putString("probes", probes.entries.joinToString(";") { "${it.key}=${it.value}" })
        }
        try { to.send(out) } catch (_: RemoteException) {}
    }

    private fun attempt(block: () -> String): String = try { block() } catch (e: Throwable) { "DENIED(${e.javaClass.simpleName})" }

    private fun probes(pkg: String): Map<String, String> {
        val store = "/data/user/0/$pkg/files/ota"
        return linkedMapOf(
            "uid" to Process.myUid().toString(),
            "app_uid" to applicationInfo.uid.toString(),
            "is_isolated" to (if (Build.VERSION.SDK_INT >= 28) Process.isIsolated().toString() else "n/a"),
            "read_private_store" to attempt { (File(store).list()?.size?.let { "ALLOWED($it entries)" }) ?: "DENIED(list=null)" },
            "read_private_state" to attempt { "ALLOWED(${File("$store/state.json").readBytes().size} bytes)" },
            "write_private_store" to attempt {
                val f = File("$store/iso_probe.tmp"); f.writeText("x"); f.delete(); "ALLOWED"
            },
            "read_external_inbox" to attempt {
                (File("/storage/emulated/0/Android/data/$pkg/files/inbox").list()?.size?.let { "ALLOWED($it entries)" }) ?: "DENIED(list=null)"
            },
            // Local only (no traffic leaves the device): socket creation itself needs INTERNET.
            "network_socket" to attempt { Socket().use { it.connect(InetSocketAddress("127.0.0.1", 9), 500) }; "ALLOWED(connected)" }
                .let { if (it.contains("ConnectException")) "ALLOWED(socket created; port closed)" else it },
        )
    }

    private fun start(fd: ParcelFileDescriptor?, pkg: String, replyTo: Messenger) {
        val t0 = System.nanoTime()
        val p = probes(pkg)
        if (fd == null) {
            reply(replyTo, "UNAVAILABLE", "no file descriptor received", 0.0, p)
            return
        }
        val bytes = try {
            FileInputStream(fd.fileDescriptor).use { it.readBytes() }.also { fd.close() }
        } catch (e: Exception) {
            reply(replyTo, "UNAVAILABLE", "cannot read the descriptor: $e", 0.0, p)
            return
        }
        val e: FlutterEngine
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            // Tested 2026-11-12 (Android 13 phone): an isolated process is denied the GPU device and
            // SurfaceFlinger, and the engine's raster thread then crashes during start-up. The
            // software-rendering flag below is IGNORED in release builds, so it does not help; the
            // crash happens before the module is taken and the app falls back (UNAVAILABLE).
            loader.ensureInitializationComplete(applicationContext, arrayOf("--enable-software-rendering"))
            e = FlutterEngine(applicationContext, null, false)
            engine = e
            MethodChannel(e.dartExecutor.binaryMessenger, "ota/verifier").setMethodCallHandler { call, res ->
                when (call.method) {
                    "job" -> {
                        // Tell the app the module is now handed over: from here on, a crash of
                        // this process is attributed to the module (before it: UNAVAILABLE).
                        try { replyTo.send(Message.obtain(null, VerifierService.MSG_JOB_TAKEN)) } catch (_: RemoteException) {}
                        res.success(bytes)
                    }
                    "result" -> {
                        res.success(null)
                        val m = call.arguments as Map<*, *>
                        reply(replyTo, m["status"] as String? ?: "REJECTED", m["detail"]?.toString() ?: "",
                            (m["ms"] as Number).toDouble(), p + mapOf("dart" to (m["probes"]?.toString() ?: "")))
                        main.postDelayed({ Process.killProcess(Process.myPid()) }, 300)
                    }
                    else -> res.notImplemented()
                }
            }
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "package:compat_host/verifier_main.dart", "verifierMain"),
            )
        } catch (x: Throwable) {
            reply(replyTo, "UNAVAILABLE", "Flutter could not start in the isolated process: $x", (System.nanoTime() - t0) / 1e6, p)
            main.postDelayed({ Process.killProcess(Process.myPid()) }, 300)
        }
    }
}
