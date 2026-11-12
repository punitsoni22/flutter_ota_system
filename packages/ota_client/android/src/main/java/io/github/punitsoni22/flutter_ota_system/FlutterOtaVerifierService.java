// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

package io.github.punitsoni22.flutter_ota_system;

import android.app.Service;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.os.RemoteException;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.Map;

import io.flutter.FlutterInjector;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.embedding.engine.loader.FlutterLoader;
import io.flutter.plugin.common.MethodChannel;

/**
 * Runs in the separate {@code :flutter_ota_verify} process (declared in this plugin's
 * AndroidManifest, not exported, same UID as the app; NOT an isolated process, because Flutter
 * cannot start there in release builds — Phase 3C).
 *
 * <p>It starts its own FlutterEngine on the app's AOT snapshot, without plugins, and runs {@code
 * flutterOtaVerifierMain} from this SDK, which loads ONE candidate module (received as bytes read
 * from a read-only file descriptor). A malformed module that aborts the Dart VM kills only this
 * process. After reporting, the process exits: modules cannot be unloaded.
 *
 * <p>Messages: MSG_VERIFY (app → service: fd, loaderHandle), MSG_JOB_TAKEN (service → app: the
 * Dart side took the module; a death before it is UNAVAILABLE, after it CRASHED), MSG_RESULT
 * (service → app: status, detail, verifier_ms).
 */
public final class FlutterOtaVerifierService extends Service {
  static final int MSG_VERIFY = 1;
  static final int MSG_RESULT = 2;
  static final int MSG_JOB_TAKEN = 3;
  static final String PROCESS_SUFFIX = ":flutter_ota_verify";

  /** Same limit as the container ({@code maxContainerBytes}). */
  private static final int MAX_MODULE_BYTES = 8 * 1024 * 1024;

  static final String ENTRYPOINT_LIBRARY = "package:flutter_ota_system/src/bytecode/verifier_main.dart";
  static final String ENTRYPOINT_FUNCTION = "flutterOtaVerifierMain";

  private final Handler main = new Handler(Looper.getMainLooper());
  private FlutterEngine engine;
  private boolean started = false;
  private boolean jobHandedOut = false;
  private boolean reported = false;

  private final Messenger messenger =
      new Messenger(
          new Handler(
              Looper.getMainLooper(),
              msg -> {
                if (msg.what == MSG_VERIFY && !started) {
                  started = true;
                  start(msg.getData(), msg.replyTo);
                }
                return true;
              }));

  @Override
  public IBinder onBind(Intent intent) {
    return messenger.getBinder();
  }

  private void start(Bundle data, Messenger replyTo) {
    final byte[] module;
    ParcelFileDescriptor fd = data.getParcelable("fd");
    try {
      module = readAll(fd);
    } catch (Exception e) {
      report(replyTo, "UNAVAILABLE", "could not read the module: " + e.getClass().getSimpleName(), 0);
      return;
    }
    if (module == null) {
      report(replyTo, "REJECTED", "module larger than " + MAX_MODULE_BYTES + " bytes", 0);
      return;
    }
    final long loaderHandle = data.getLong("loaderHandle");
    byte[] raw = new byte[16];
    new SecureRandom().nextBytes(raw);
    StringBuilder sb = new StringBuilder();
    for (byte b : raw) sb.append(String.format("%02x", b));
    final String nonce = sb.toString();

    try {
      FlutterLoader loader = FlutterInjector.instance().flutterLoader();
      loader.startInitialization(getApplicationContext());
      loader.ensureInitializationComplete(getApplicationContext(), null);
      // No plugins: the verifier must not touch app services.
      FlutterEngine e = new FlutterEngine(getApplicationContext(), null, false);
      engine = e;
      new MethodChannel(e.getDartExecutor().getBinaryMessenger(), "flutter_ota/verifier")
          .setMethodCallHandler(
              (call, res) -> {
                switch (call.method) {
                  case "job":
                    if (jobHandedOut) {
                      // One-shot, so module code cannot fetch the nonce afterwards.
                      res.error("taken", "the job was already taken", null);
                      return;
                    }
                    jobHandedOut = true;
                    send(replyTo, Message.obtain(null, MSG_JOB_TAKEN));
                    Map<String, Object> job = new HashMap<>();
                    job.put("bytes", module);
                    job.put("loaderHandle", loaderHandle == 0 ? null : loaderHandle);
                    job.put("nonce", nonce);
                    res.success(job);
                    break;
                  case "result":
                    Map<?, ?> m = (Map<?, ?>) call.arguments;
                    if (m == null || !nonce.equals(m.get("nonce"))) {
                      res.error("bad_nonce", "result without the job nonce", null);
                      return;
                    }
                    res.success(null);
                    Object ms = m.get("verifier_ms");
                    report(
                        replyTo,
                        m.get("status") instanceof String ? (String) m.get("status") : "CRASHED",
                        m.get("detail") == null ? "" : m.get("detail").toString(),
                        ms instanceof Number ? ((Number) ms).doubleValue() : 0);
                    break;
                  default:
                    res.notImplemented();
                }
              });
      e.getDartExecutor()
          .executeDartEntrypoint(
              new DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRYPOINT_LIBRARY, ENTRYPOINT_FUNCTION));
    } catch (Exception e) {
      report(replyTo, "UNAVAILABLE", "verifier engine did not start: " + e.getClass().getSimpleName(), 0);
    }
  }

  /** Reads the whole module, or returns null if it is larger than the limit. */
  private static byte[] readAll(ParcelFileDescriptor fd) throws Exception {
    if (fd == null) throw new IllegalArgumentException("no file descriptor");
    // Closing the stream also closes the descriptor.
    try (InputStream in = new ParcelFileDescriptor.AutoCloseInputStream(fd)) {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      byte[] buf = new byte[1 << 16];
      int n;
      while ((n = in.read(buf)) > 0) {
        if (out.size() + n > MAX_MODULE_BYTES) return null;
        out.write(buf, 0, n);
      }
      return out.toByteArray();
    }
  }

  private void report(Messenger replyTo, String status, String detail, double verifierMs) {
    if (reported) return;
    reported = true;
    Message out = Message.obtain(null, MSG_RESULT);
    Bundle b = new Bundle();
    b.putString("status", status);
    b.putString("detail", detail);
    b.putDouble("verifier_ms", verifierMs);
    out.setData(b);
    send(replyTo, out);
    // A loaded module cannot be unloaded: end this process so every check starts clean.
    main.postDelayed(() -> Process.killProcess(Process.myPid()), 300);
  }

  private static void send(Messenger to, Message m) {
    try {
      if (to != null) to.send(m);
    } catch (RemoteException ignored) {
      // The app is gone; nothing to report to.
    }
  }
}
