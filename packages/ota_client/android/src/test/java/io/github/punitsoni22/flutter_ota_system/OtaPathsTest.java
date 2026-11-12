// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

package io.github.punitsoni22.flutter_ota_system;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class OtaPathsTest {
  private static final String ID = "11111111-1111-1111-1111-111111111111";
  private static final String ROOT = "/data/user/0/app/files";

  @Test
  public void acceptsCanonicalLowercaseUuid() {
    assertTrue(OtaPaths.isValidPatchId(ID));
    assertTrue(OtaPaths.isValidPatchId("0f8fad5b-d9cb-469f-a165-70867728950e"));
  }

  @Test
  public void rejectsAnythingElseAsPatchId() {
    String[] bad = {
      null, "", ".", "..", "../..", "a/b", "/etc", "0F8FAD5B-D9CB-469F-A165-70867728950E", ID + "\n", ID + "/..",
      "11111111-1111-1111-1111-11111111111", "11111111111111111111111111111111", "x\u0000y",
    };
    for (String id : bad) assertFalse(String.valueOf(id), OtaPaths.isValidPatchId(id));
  }

  @Test
  public void acceptsOnlyKnownAbis() {
    for (String abi : new String[] {"arm64-v8a", "armeabi-v7a", "x86_64", "x86"}) {
      assertTrue(abi, OtaPaths.isValidAbi(abi));
    }
    for (String abi : new String[] {null, "", "../x", "arm64-v8a/../..", "mips"}) {
      assertFalse(String.valueOf(abi), OtaPaths.isValidAbi(abi));
    }
  }

  @Test
  public void patchLibraryMustBeInsideRootAndNamedAfterItsId() {
    String good = ROOT + "/ota/patches/" + ID + "/libapp.so";
    assertTrue(OtaPaths.isPatchLibrary(good, ROOT, ID));
    assertTrue(OtaPaths.isPatchLibrary(good, ROOT + "/", ID));

    String other = "22222222-2222-2222-2222-222222222222";
    assertFalse("another patch's file", OtaPaths.isPatchLibrary(good, ROOT, other));
    assertFalse("outside the root", OtaPaths.isPatchLibrary("/data/local/tmp/" + ID + "/libapp.so", ROOT, ID));
    assertFalse("sibling dir sharing the prefix", OtaPaths.isPatchLibrary(ROOT + "2/" + ID + "/libapp.so", ROOT, ID));
    assertFalse("not libapp.so", OtaPaths.isPatchLibrary(ROOT + "/ota/patches/" + ID + "/evil.so", ROOT, ID));
    assertFalse("invalid id", OtaPaths.isPatchLibrary(ROOT + "/../libapp.so", ROOT, ".."));
    assertFalse("null path", OtaPaths.isPatchLibrary(null, ROOT, ID));
  }
}
