// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

package io.github.punitsoni22.flutter_ota_system;

import java.io.File;
import java.util.regex.Pattern;

/**
 * Input checks for values that become file paths (SEC-01). Plain Java with no Android classes,
 * so JVM unit tests can cover it.
 */
final class OtaPaths {
  /** Canonical lowercase UUID, as the server generates. Must match {@code patch_id.dart}. */
  private static final Pattern PATCH_ID =
      Pattern.compile("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");

  private static final String[] ABIS = {"arm64-v8a", "armeabi-v7a", "x86_64", "x86"};

  private OtaPaths() {}

  static boolean isValidPatchId(String id) {
    return id != null && PATCH_ID.matcher(id).matches();
  }

  static boolean isValidAbi(String abi) {
    if (abi == null) return false;
    for (String known : ABIS) {
      if (known.equals(abi)) return true;
    }
    return false;
  }

  /**
   * True if {@code canonicalPath} is {@code .../<patchId>/libapp.so} strictly inside
   * {@code canonicalRoot}. Both paths must already be canonical (symlinks and ".." resolved).
   */
  static boolean isPatchLibrary(String canonicalPath, String canonicalRoot, String patchId) {
    if (canonicalPath == null || canonicalRoot == null || !isValidPatchId(patchId)) return false;
    String root = canonicalRoot.endsWith(File.separator) ? canonicalRoot : canonicalRoot + File.separator;
    return canonicalPath.startsWith(root)
        && canonicalPath.endsWith(File.separator + patchId + File.separator + "libapp.so");
  }
}
