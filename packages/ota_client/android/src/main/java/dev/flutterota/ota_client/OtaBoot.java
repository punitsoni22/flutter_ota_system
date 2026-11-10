// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

package dev.flutterota.ota_client;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;

import io.flutter.FlutterInjector;
import io.flutter.embedding.engine.loader.FlutterLoader;

/**
 * Chooses which compiled Dart code (libapp.so) this process runs. Called once, at process start.
 *
 * <p>Dart (ota_client) downloads, verifies and rebuilds a patch, then writes {@code boot.json}:
 * the patch to try next ("next") and the last one that booted fine ("good"). This class reads it
 * before any Flutter engine exists and points the FlutterLoader at the chosen file, the same way
 * Shorebird's engine swaps the app library on Android. Stock Flutter allows that for a .so inside
 * the app's own files dir.
 *
 * <p>Boot protection lives here, not in Dart, because a broken patch may never reach Dart code:
 * when a new patch is used by a visible app, {@code native.json} records an "attempt". Dart
 * confirms success by making that patch "good". An attempt still unconfirmed on the next start
 * means the patch failed: it is skipped for good and the last good code runs instead.
 */
final class OtaBoot {
  private static final String TAG = "OtaBoot";
  static final String DIR = "ota_aot";
  private static final int MAX_FAILED = 50;

  private static boolean prepared;
  private static boolean enabled;
  private static String loadedPatchId;
  private static String pendingAttempt;
  private static final List<String> newlyFailed = new ArrayList<>();
  private static String error;
  private static String installStamp = "";

  private OtaBoot() {}

  static File bootDir(Context context) {
    return new File(context.getFilesDir(), DIR);
  }

  static synchronized void prepare(Context context) {
    if (prepared) return;
    prepared = true;
    try {
      ApplicationInfo info = context.getApplicationInfo();
      // Debug builds run Dart in JIT mode from a kernel file; there is no libapp.so to swap.
      enabled = (info.flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0;
      installStamp = installStamp(context);
      if (!enabled) return;

      File dir = bootDir(context);
      JSONObject boot = readJson(new File(dir, "boot.json"));
      JSONObject nat = readJson(new File(dir, "native.json"));
      if (nat == null) nat = new JSONObject();
      JSONArray failed = nat.optJSONArray("failed");
      if (failed == null) failed = new JSONArray();
      String attempt = nat.has("attempt") ? nat.optString("attempt") : null;
      nat.remove("attempt");

      // boot.json from another install (store update, reinstall): its patches were built for a
      // different base, so run the store code. Dart resets its own state the same way.
      if (boot == null || !installStamp.equals(boot.optString("install_stamp"))) {
        writeJson(new File(dir, "native.json"), nat);
        return;
      }
      JSONObject next = boot.optJSONObject("next");
      JSONObject good = boot.optJSONObject("good");
      String goodId = good == null ? null : good.optString("id");

      if (attempt != null && !attempt.equals(goodId)) {
        Log.w(TAG, "Patch " + attempt + " did not confirm its last start: skipping it");
        markFailed(failed, attempt);
      }

      JSONObject chosen = null;
      for (JSONObject candidate : new JSONObject[] {next, good}) {
        if (candidate == null) continue;
        String id = candidate.optString("id");
        if (contains(failed, id)) continue;
        if (isValid(context, candidate, nat)) {
          chosen = candidate;
          break;
        }
        Log.w(TAG, "Patch " + id + " failed verification: skipping it");
        markFailed(failed, id);
      }

      while (failed.length() > MAX_FAILED) failed.remove(0);
      nat.put("failed", failed);
      writeJson(new File(dir, "native.json"), nat);

      if (chosen == null) return;
      String id = chosen.getString("id");
      if (!id.equals(goodId)) pendingAttempt = id;
      String path = new File(chosen.getString("file")).getCanonicalPath();
      FlutterLoader loader = FlutterInjector.instance().flutterLoader();
      Context app = context.getApplicationContext();
      loader.startInitialization(app);
      loader.ensureInitializationComplete(app, new String[] {"--aot-shared-library-name=" + path});
      loadedPatchId = id;
      Log.i(TAG, "Running patch " + id);
      if (pendingAttempt != null && app instanceof Application) watchFirstActivity((Application) app);
    } catch (Throwable t) {
      // Never break the app: anything unexpected means the store code runs.
      error = t.toString();
      loadedPatchId = null;
      pendingAttempt = null;
      Log.e(TAG, "OTA boot failed, running the store code", t);
    }
  }

  /** What Dart needs at boot: what runs now, and the patches that failed at this start. */
  static synchronized JSONObject report(Context context) throws JSONException {
    JSONObject out = new JSONObject();
    out.put("enabled", enabled);
    out.put("boot_dir", bootDir(context).getAbsolutePath());
    out.put("install_stamp", installStamp);
    out.put("abi", runningAbi(context));
    out.put("loaded_patch_id", loadedPatchId == null ? JSONObject.NULL : loadedPatchId);
    out.put("failed_patch_ids", new JSONArray(newlyFailed));
    out.put("error", error == null ? JSONObject.NULL : error);
    return out;
  }

  /**
   * Only a start that shows UI counts as an attempt. A process woken for a push or background job
   * never runs the app's main(), so it could never confirm, and must not count as a failure.
   */
  private static void watchFirstActivity(Application app) {
    app.registerActivityLifecycleCallbacks(
        new Application.ActivityLifecycleCallbacks() {
          @Override
          public void onActivityCreated(Activity activity, Bundle state) {
            app.unregisterActivityLifecycleCallbacks(this);
            recordAttempt(app);
          }

          @Override public void onActivityStarted(Activity activity) {}
          @Override public void onActivityResumed(Activity activity) {}
          @Override public void onActivityPaused(Activity activity) {}
          @Override public void onActivityStopped(Activity activity) {}
          @Override public void onActivitySaveInstanceState(Activity a, Bundle b) {}
          @Override public void onActivityDestroyed(Activity activity) {}
        });
  }

  private static synchronized void recordAttempt(Context context) {
    if (pendingAttempt == null) return;
    try {
      File file = new File(bootDir(context), "native.json");
      JSONObject nat = readJson(file);
      if (nat == null) nat = new JSONObject();
      nat.put("attempt", pendingAttempt);
      writeJson(file, nat);
    } catch (Exception e) {
      Log.e(TAG, "Could not record the boot attempt", e);
    }
    pendingAttempt = null;
  }

  private static void markFailed(JSONArray failed, String id) {
    if (!contains(failed, id)) failed.put(id);
    if (!newlyFailed.contains(id)) newlyFailed.add(id);
  }

  /** Inside the app's files dir, the size Dart wrote, and the hash Dart verified. */
  private static boolean isValid(Context context, JSONObject patch, JSONObject nat) {
    try {
      File file = new File(patch.getString("file"));
      String path = file.getCanonicalPath();
      String root = context.getFilesDir().getCanonicalPath() + File.separator;
      if (!path.startsWith(root) || !path.endsWith(".so") || !file.isFile()) return false;
      if (file.length() != patch.getLong("size")) return false;
      // Hashing ~20 MB costs a little startup time, so do it once per file, not every start.
      String stamp = patch.getString("id") + ":" + file.length() + ":" + file.lastModified();
      JSONObject verified = nat.optJSONObject("verified");
      if (verified != null && stamp.equals(verified.optString(patch.getString("id")))) return true;
      if (!sha256(file).equals(patch.getString("sha256"))) return false;
      // Remember next and good both, so a fallback start doesn't hash again.
      JSONObject now = new JSONObject();
      if (verified != null && verified.length() < 4) now = verified;
      now.put(patch.getString("id"), stamp);
      nat.put("verified", now);
      return true;
    } catch (Exception e) {
      return false;
    }
  }

  /** Changes with every store update or reinstall, even of the same version. */
  static String installStamp(Context context) throws Exception {
    PackageInfo p = context.getPackageManager().getPackageInfo(context.getPackageName(), 0);
    long code = Build.VERSION.SDK_INT >= 28 ? p.getLongVersionCode() : p.versionCode;
    return p.versionName + "+" + code + "@" + p.lastUpdateTime;
  }

  /** The ABI this process loads native code for: arm64-v8a, armeabi-v7a, x86_64 or x86. */
  static String runningAbi(Context context) {
    String dir = new File(context.getApplicationInfo().nativeLibraryDir).getName();
    switch (dir) {
      case "arm64": return "arm64-v8a";
      case "arm": return "armeabi-v7a";
      case "x86_64": return "x86_64";
      case "x86": return "x86";
      default: return Build.SUPPORTED_ABIS.length > 0 ? Build.SUPPORTED_ABIS[0] : dir;
    }
  }

  static String sha256(File file) throws Exception {
    MessageDigest digest = MessageDigest.getInstance("SHA-256");
    try (InputStream in = new FileInputStream(file)) {
      byte[] buf = new byte[1 << 16];
      int n;
      while ((n = in.read(buf)) > 0) digest.update(buf, 0, n);
    }
    StringBuilder hex = new StringBuilder();
    for (byte b : digest.digest()) hex.append(String.format("%02x", b));
    return hex.toString();
  }

  private static boolean contains(JSONArray array, String value) {
    for (int i = 0; i < array.length(); i++) {
      if (value.equals(array.optString(i))) return true;
    }
    return false;
  }

  private static JSONObject readJson(File file) {
    if (!file.isFile()) return null;
    try (InputStream in = new FileInputStream(file)) {
      byte[] bytes = new byte[(int) file.length()];
      int off = 0;
      while (off < bytes.length) {
        int n = in.read(bytes, off, bytes.length - off);
        if (n < 0) break;
        off += n;
      }
      return new JSONObject(new String(bytes, 0, off, StandardCharsets.UTF_8));
    } catch (Exception e) {
      return null;
    }
  }

  /** Write tmp, then rename: a crash leaves the old or the new file, never half of one. */
  private static void writeJson(File file, JSONObject json) throws IOException {
    File dir = file.getParentFile();
    if (dir != null && !dir.isDirectory() && !dir.mkdirs()) throw new IOException("mkdir " + dir);
    File tmp = new File(file.getPath() + ".tmp");
    try (FileOutputStream out = new FileOutputStream(tmp)) {
      out.write(json.toString().getBytes(StandardCharsets.UTF_8));
      out.getFD().sync();
    }
    if (!tmp.renameTo(file)) throw new IOException("rename " + tmp);
  }
}
