// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

package io.github.punitsoni22.flutter_ota_system;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.os.RemoteException;
import android.os.SystemClock;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Channel "flutter_ota/runtime" of the bytecode runtime (Phase 4):
 *
 * <ul>
 *   <li>{@code startupInfo}: files dir and app version ({@code versionName+versionCode});
 *   <li>{@code lastExit}: ApplicationExitInfo of the previous MAIN process (API 30+);
 *   <li>{@code libappSha256}: SHA-256 of the installed store libapp.so, computed here (never taken
 *       from input), cached by APK paths + lastUpdateTime;
 *   <li>{@code verifyInProcess}: loads a candidate module in the separate {@code :flutter_ota_verify}
 *       process (same UID; Flutter cannot start in an Android isolated process in release builds).
 *       Result status: OK, REJECTED, CRASHED, TIMEOUT or UNAVAILABLE.
 * </ul>
 */
final class OtaRuntimeChannel implements MethodChannel.MethodCallHandler {
  static final String NAME = "flutter_ota/runtime";
  private static final String PREFS = "flutter_ota_runtime";

  private final Context context;
  private final MethodChannel channel;
  private final ExecutorService io = Executors.newSingleThreadExecutor();
  private final Handler main = new Handler(Looper.getMainLooper());
  private boolean verifying = false;

  OtaRuntimeChannel(Context context, BinaryMessenger messenger) {
    this.context = context;
    this.channel = new MethodChannel(messenger, NAME);
    channel.setMethodCallHandler(this);
  }

  void dispose() {
    channel.setMethodCallHandler(null);
    io.shutdown();
  }

  @Override
  public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    switch (call.method) {
      case "startupInfo":
        try {
          Map<String, Object> m = new HashMap<>();
          m.put("filesDir", context.getFilesDir().getAbsolutePath());
          m.put("appVersion", appVersion());
          result.success(m);
        } catch (Exception e) {
          result.error("startup_info_failed", e.toString(), null);
        }
        break;
      case "lastExit":
        result.success(lastExit(true, 0));
        break;
      case "libappSha256":
        io.execute(
            () -> {
              try {
                String hex = libappSha256();
                main.post(() -> result.success(hex));
              } catch (Exception e) {
                main.post(() -> result.error("libapp_hash_failed", e.toString(), null));
              }
            });
        break;
      case "verifyInProcess":
        String path = call.argument("path");
        Number timeout = call.argument("timeoutMs");
        Number handle = call.argument("loaderHandle");
        verifyInProcess(path, timeout == null ? 30000 : timeout.longValue(), handle == null ? 0 : handle.longValue(), result);
        break;
      default:
        result.notImplemented();
    }
  }

  private String appVersion() throws Exception {
    PackageInfo p = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
    long code = Build.VERSION.SDK_INT >= 28 ? p.getLongVersionCode() : p.versionCode;
    return p.versionName + "+" + code;
  }

  /** Newest exit record of the main process (or of the verifier process), or null. */
  private Map<String, Object> lastExit(boolean mainProcess, long since) {
    if (Build.VERSION.SDK_INT < 30) return null;
    try {
      ActivityManager am = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
      String pkg = context.getPackageName();
      for (ApplicationExitInfo e : am.getHistoricalProcessExitReasons(pkg, 0, 10)) {
        if (e.getTimestamp() < since) continue;
        String name = e.getProcessName();
        boolean match = mainProcess ? pkg.equals(name) : name != null && name.endsWith(FlutterOtaVerifierService.PROCESS_SUFFIX);
        if (!match) continue;
        Map<String, Object> m = new HashMap<>();
        m.put("reason", e.getReason());
        m.put("status", e.getStatus());
        m.put("description", e.getDescription() == null ? "" : e.getDescription());
        m.put("pid", e.getPid());
        m.put("timestamp", e.getTimestamp());
        return m;
      }
    } catch (Exception ignored) {
      // No record: the Dart side treats the exit as unknown.
    }
    return null;
  }

  // ---- libapp.so -------------------------------------------------------------------------------

  private String libappSha256() throws Exception {
    ApplicationInfo info = context.getApplicationInfo();
    PackageInfo p = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
    List<String> apks = new ArrayList<>();
    apks.add(info.sourceDir);
    if (info.splitSourceDirs != null) for (String s : info.splitSourceDirs) apks.add(s);
    String abi = OtaBoot.runningAbi(context);
    StringBuilder key = new StringBuilder("libapp:").append(abi);
    for (String apk : apks) key.append('|').append(apk);
    String cacheKey = key.append('|').append(p.lastUpdateTime).toString();
    SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    String cached = prefs.getString(cacheKey, null);
    if (cached != null && cached.matches("^[0-9a-f]{64}$")) return cached;

    String hex = null;
    File extracted = new File(info.nativeLibraryDir, "libapp.so");
    if (extracted.isFile()) {
      try (InputStream in = new FileInputStream(extracted)) {
        hex = sha256(in);
      }
    } else {
      String entryName = "lib/" + abi + "/libapp.so";
      for (String apk : apks) {
        try (ZipFile zip = new ZipFile(apk)) {
          ZipEntry entry = zip.getEntry(entryName);
          if (entry == null) continue;
          try (InputStream in = zip.getInputStream(entry)) {
            hex = sha256(in);
          }
          break;
        }
      }
    }
    if (hex == null) throw new IllegalStateException("libapp.so not found in the installed app");
    // Old entries (earlier installs) are dropped; only the current key stays.
    prefs.edit().clear().putString(cacheKey, hex).apply();
    return hex;
  }

  private static String sha256(InputStream in) throws Exception {
    MessageDigest md = MessageDigest.getInstance("SHA-256");
    byte[] buf = new byte[1 << 16];
    int n;
    while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
    StringBuilder sb = new StringBuilder();
    for (byte b : md.digest()) sb.append(String.format("%02x", b));
    return sb.toString();
  }

  // ---- separate verifier process ---------------------------------------------------------------

  private void verifyInProcess(String path, long timeoutMs, long loaderHandle, MethodChannel.Result result) {
    final long start = SystemClock.elapsedRealtime();
    final long startWall = System.currentTimeMillis();
    final File file;
    try {
      // Only the SDK's own candidate file may be handed over (defence in depth).
      File root = new File(context.getFilesDir(), "flutter_ota/verify").getCanonicalFile();
      file = path == null ? null : new File(path).getCanonicalFile();
      if (file == null || !root.equals(file.getParentFile()) || !file.isFile()) {
        result.success(outcome("UNAVAILABLE", "candidate file is not in the verify directory", start));
        return;
      }
    } catch (Exception e) {
      result.success(outcome("UNAVAILABLE", "candidate file: " + e, start));
      return;
    }
    if (verifying) {
      result.success(outcome("UNAVAILABLE", "another verification is running", start));
      return;
    }
    verifying = true;

    final boolean[] done = {false};
    final boolean[] jobTaken = {false};
    final ServiceConnection[] conn = {null};
    final ParcelFileDescriptor[] fd = {null};

    final MapCallback finish =
        (map) -> {
          if (done[0]) return;
          done[0] = true;
          verifying = false;
          try {
            if (conn[0] != null) context.unbindService(conn[0]);
          } catch (Exception ignored) {
          }
          try {
            if (fd[0] != null) fd[0].close();
          } catch (Exception ignored) {
          }
          map.put("ms", (double) (SystemClock.elapsedRealtime() - start));
          result.success(map);
        };
    final TextCallback died =
        (why) ->
            main.postDelayed(
                () -> {
                  // Give the system a moment to record the verifier's exit reason.
                  Object exit = lastExit(false, startWall - 1000);
                  if (!jobTaken[0]) {
                    // Died before it took the module: an environment failure, not the module.
                    finish.call(outcome("UNAVAILABLE", "verifier died before taking the module; exit=" + exit, start));
                  } else {
                    finish.call(outcome("CRASHED", why + "; exit=" + exit, start));
                  }
                },
                600);

    final Handler replies =
        new Handler(
            Looper.getMainLooper(),
            msg -> {
              if (msg.what == FlutterOtaVerifierService.MSG_JOB_TAKEN) {
                jobTaken[0] = true;
              } else if (msg.what == FlutterOtaVerifierService.MSG_RESULT) {
                Bundle b = msg.getData();
                Map<String, Object> m = outcome(b.getString("status"), b.getString("detail"), start);
                m.put("verifier_ms", b.getDouble("verifier_ms"));
                finish.call(m);
              }
              return true;
            });

    conn[0] =
        new ServiceConnection() {
          @Override
          public void onServiceConnected(ComponentName name, IBinder binder) {
            try {
              binder.linkToDeath(() -> died.call("verifier process died"), 0);
              Message m = Message.obtain(null, FlutterOtaVerifierService.MSG_VERIFY);
              Bundle data = new Bundle();
              // Only a READ-ONLY descriptor crosses into the verifier process.
              fd[0] = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
              data.putParcelable("fd", fd[0]);
              data.putLong("loaderHandle", loaderHandle);
              m.setData(data);
              m.replyTo = new Messenger(replies);
              new Messenger(binder).send(m);
            } catch (Exception e) {
              died.call("verifier unreachable: " + e.getClass().getSimpleName());
            }
          }

          @Override
          public void onServiceDisconnected(ComponentName name) {
            died.call("verifier disconnected");
          }
        };
    boolean bound;
    try {
      bound = context.bindService(new Intent(context, FlutterOtaVerifierService.class), conn[0], Context.BIND_AUTO_CREATE);
    } catch (Exception e) {
      bound = false;
    }
    if (!bound) {
      conn[0] = null;
      finish.call(outcome("UNAVAILABLE", "could not bind the verifier service", start));
      return;
    }
    main.postDelayed(
        () -> {
          if (!done[0]) {
            killVerifier();
            finish.call(outcome("TIMEOUT", "no result within " + timeoutMs + " ms; verifier killed", start));
          }
        },
        timeoutMs);
  }

  // java.util.function needs API 24; the plugin supports API 21.
  private interface MapCallback {
    void call(Map<String, Object> map);
  }

  private interface TextCallback {
    void call(String text);
  }

  private static Map<String, Object> outcome(String status, String detail, long start) {
    Map<String, Object> m = new HashMap<>();
    m.put("status", status == null ? "CRASHED" : status);
    m.put("detail", detail == null ? "" : detail);
    return m;
  }

  private void killVerifier() {
    ActivityManager am = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
    List<ActivityManager.RunningAppProcessInfo> procs = am == null ? null : am.getRunningAppProcesses();
    if (procs == null) return;
    String name = context.getPackageName() + FlutterOtaVerifierService.PROCESS_SUFFIX;
    for (ActivityManager.RunningAppProcessInfo p : procs) {
      if (name.equals(p.processName)) Process.killProcess(p.pid);
    }
  }
}
