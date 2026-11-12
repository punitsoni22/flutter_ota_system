// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0
package io.github.punitsoni22.compat_host

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
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
import android.os.SystemClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile

// Phase 3 prototype host channel "ota/host":
//   lastExit          ApplicationExitInfo of the previous main process (API 30+)
//   libappSha256      SHA-256 of the installed libapp.so (computed here, never taken from input)
//   verifyIsolated    load a candidate module in a separate process: Phase 3C default is the
//                     Android isolated process ":otaverify_iso" (read-only FD, separate UID);
//                     isolated=false uses the Phase 3 ":otaverify" process (same UID)
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ota/host").setMethodCallHandler { call, result ->
            when (call.method) {
                "lastExit" -> result.success(lastExit(mainProcess = true))
                "libappSha256" -> Thread {
                    val v = try { libappSha256() } catch (e: Exception) { "error:${e.javaClass.simpleName}" }
                    main.post { result.success(v) }
                }.start()
                "verifyIsolated" -> verifyIsolated(
                    call.argument<String>("path")!!,
                    (call.argument<Int>("timeoutMs") ?: 20000).toLong(),
                    call.argument<Boolean>("isolated") ?: true,
                    result,
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun lastExit(mainProcess: Boolean, since: Long = 0): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < 30) return null
        val am = getSystemService(ActivityManager::class.java)
        val e = am.getHistoricalProcessExitReasons(packageName, 0, 10).firstOrNull {
            it.timestamp >= since && (if (mainProcess) it.processName == packageName else it.processName.contains(":otaverify"))
        } ?: return null
        return mapOf("reason" to e.reason, "status" to e.status, "description" to (e.description ?: ""), "process" to e.processName,
            "pid" to e.pid, "timestamp" to e.timestamp)
    }

    private fun libappSha256(): String {
        val info = packageManager.getPackageInfo(packageName, 0)
        val prefs = getSharedPreferences("ota_host", Context.MODE_PRIVATE)
        val cacheKey = "${info.applicationInfo!!.sourceDir}|${info.lastUpdateTime}"
        prefs.getString("libapp:$cacheKey", null)?.let { return it }
        val md = MessageDigest.getInstance("SHA-256")
        val extracted = File(info.applicationInfo!!.nativeLibraryDir, "libapp.so")
        val input = if (extracted.isFile) extracted.inputStream() else {
            val zip = ZipFile(info.applicationInfo!!.sourceDir)
            zip.getInputStream(zip.getEntry("lib/arm64-v8a/libapp.so") ?: error("libapp.so not in APK"))
        }
        input.use { s ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = s.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        val hex = md.digest().joinToString("") { "%02x".format(it) }
        prefs.edit().putString("libapp:$cacheKey", hex).apply()
        return hex
    }

    private fun verifyIsolated(path: String, timeoutMs: Long, isolated: Boolean, result: MethodChannel.Result) {
        val start = SystemClock.elapsedRealtime()
        val startWall = System.currentTimeMillis()
        var done = false
        var jobTaken = !isolated // the Phase 3 service has no separate hand-over message
        lateinit var conn: ServiceConnection
        fun finish(map: Map<String, Any?>) {
            if (done) return
            done = true
            try { unbindService(conn) } catch (_: Exception) {}
            result.success(map + mapOf("ms" to (SystemClock.elapsedRealtime() - start)))
        }
        fun crashed(why: String) {
            main.postDelayed({
                // Give the system a moment to record the verifier's exit reason.
                val exit = lastExit(false, startWall - 1000)
                if (!jobTaken) {
                    // Died before it received the module: an environment failure, not the module.
                    finish(mapOf("status" to "UNAVAILABLE", "detail" to "isolated verifier died before taking the module; exit=$exit"))
                } else {
                    finish(mapOf("status" to "CRASHED", "detail" to "$why; exit=$exit"))
                }
            }, 600)
        }
        val replies = Handler(Looper.getMainLooper()) { msg ->
            if (msg.what == VerifierService.MSG_JOB_TAKEN) {
                jobTaken = true
            } else {
                val b = msg.data
                finish(mapOf("status" to b.getString("status"), "detail" to b.getString("detail"), "verifier_ms" to b.getDouble("ms"),
                    "probes" to (b.getString("probes") ?: ""), "process" to (if (isolated) "otaverify_iso" else "otaverify")))
            }
            true
        }
        conn = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                try {
                    binder.linkToDeath({ crashed("verifier process died") }, 0)
                    val m = Message.obtain(null, VerifierService.MSG_VERIFY)
                    m.data = Bundle().apply {
                        if (isolated) {
                            // Only a READ-ONLY descriptor crosses into the isolated process.
                            putParcelable("fd", ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY))
                            putString("pkg", packageName)
                        } else {
                            putString("path", path)
                        }
                    }
                    m.replyTo = Messenger(replies)
                    Messenger(binder).send(m)
                } catch (e: RemoteException) {
                    crashed("verifier unreachable: ${e.javaClass.simpleName}")
                }
            }

            override fun onServiceDisconnected(name: ComponentName) {
                crashed("verifier disconnected")
            }
        }
        val cls = if (isolated) IsolatedVerifierService::class.java else VerifierService::class.java
        if (!bindService(Intent(this, cls), conn, Context.BIND_AUTO_CREATE)) {
            finish(mapOf("status" to "CRASHED", "detail" to "could not bind the verifier service"))
            return
        }
        main.postDelayed({
            if (!done) {
                // An isolated process has another UID and cannot be killed from here; unbinding
                // (in finish) makes the system destroy it.
                killVerifier()
                finish(mapOf("status" to "TIMEOUT", "detail" to "no result within $timeoutMs ms; verifier killed"))
            }
        }, timeoutMs)
    }

    private fun killVerifier() {
        val am = getSystemService(ActivityManager::class.java)
        am.runningAppProcesses?.filter { it.processName == "$packageName:otaverify" }?.forEach { Process.killProcess(it.pid) }
    }
}
