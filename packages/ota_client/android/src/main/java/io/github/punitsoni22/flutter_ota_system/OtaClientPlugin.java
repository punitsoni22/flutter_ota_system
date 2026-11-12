// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

package io.github.punitsoni22.flutter_ota_system;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Channel "ota_client/aot": the boot report, and a copy of the store libapp.so to patch. Also
 * registers channel "flutter_ota/runtime" of the bytecode runtime ({@link OtaRuntimeChannel}).
 */
public final class OtaClientPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private MethodChannel channel;
  private OtaRuntimeChannel runtime;
  private Context context;
  private final ExecutorService io = Executors.newSingleThreadExecutor();
  private final Handler main = new Handler(Looper.getMainLooper());

  @Override
  public void onAttachedToEngine(FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    OtaBoot.prepare(context); // no-op when the provider already ran
    channel = new MethodChannel(binding.getBinaryMessenger(), "ota_client/aot");
    channel.setMethodCallHandler(this);
    // Bytecode runtime (FlutterOta): channel "flutter_ota/runtime".
    runtime = new OtaRuntimeChannel(context, binding.getBinaryMessenger());
  }

  @Override
  public void onDetachedFromEngine(FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    if (runtime != null) runtime.dispose();
    runtime = null;
  }

  @Override
  public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    switch (call.method) {
      case "report":
        try {
          result.success(toMap(OtaBoot.report(context)));
        } catch (Exception e) {
          result.error("report_failed", e.toString(), null);
        }
        break;
      case "extractBase":
        String abi = call.argument("abi");
        // The ABI becomes part of a file name: accept only the four Android ABIs (SEC-01).
        if (!OtaPaths.isValidAbi(abi)) {
          result.error("invalid_abi", "Unsupported ABI", null);
          break;
        }
        io.execute(
            () -> {
              try {
                String path = extractBase(abi);
                main.post(() -> result.success(path));
              } catch (Exception e) {
                main.post(() -> result.error("extract_failed", e.toString(), null));
              }
            });
        break;
      default:
        result.notImplemented();
    }
  }

  /**
   * Copies the installed store libapp.so for {@code abi} into the cache dir. With modern
   * packaging the library is not extracted on install; it stays inside one of the APK splits.
   */
  private String extractBase(String abi) throws Exception {
    File out = new File(context.getCacheDir(), "ota_base_" + abi + ".so");
    File installed = new File(context.getApplicationInfo().nativeLibraryDir, "libapp.so");
    List<String> apks = new ArrayList<>();
    apks.add(context.getApplicationInfo().sourceDir);
    String[] splits = context.getApplicationInfo().splitSourceDirs;
    if (splits != null) for (String s : splits) apks.add(s);

    String entryName = "lib/" + abi + "/libapp.so";
    for (String apk : apks) {
      try (ZipFile zip = new ZipFile(apk)) {
        ZipEntry entry = zip.getEntry(entryName);
        if (entry == null) continue;
        try (InputStream in = zip.getInputStream(entry)) {
          copy(in, out);
        }
        return out.getAbsolutePath();
      }
    }
    if (installed.isFile() && abi.equals(OtaBoot.runningAbi(context))) {
      try (InputStream in = new java.io.FileInputStream(installed)) {
        copy(in, out);
      }
      return out.getAbsolutePath();
    }
    throw new IllegalStateException("No " + entryName + " in the installed app");
  }

  private static void copy(InputStream in, File target) throws Exception {
    try (OutputStream out = new FileOutputStream(target)) {
      byte[] buf = new byte[1 << 16];
      int n;
      while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
    }
  }

  private static Map<String, Object> toMap(JSONObject json) throws Exception {
    Map<String, Object> map = new HashMap<>();
    for (Iterator<String> keys = json.keys(); keys.hasNext(); ) {
      String key = keys.next();
      Object value = json.get(key);
      if (value == JSONObject.NULL) {
        value = null;
      } else if (value instanceof JSONArray) {
        JSONArray array = (JSONArray) value;
        List<Object> list = new ArrayList<>();
        for (int i = 0; i < array.length(); i++) list.add(array.get(i));
        value = list;
      }
      map.put(key, value);
    }
    return map;
  }
}
