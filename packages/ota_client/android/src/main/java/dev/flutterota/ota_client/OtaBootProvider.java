// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

package dev.flutterota.ota_client;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;

/**
 * Android creates content providers at process start, before Application.onCreate and before
 * any Flutter engine. That is the one moment the app's code (libapp.so) can still be chosen.
 * It provides no data.
 */
public final class OtaBootProvider extends ContentProvider {
  @Override
  public boolean onCreate() {
    if (getContext() != null) OtaBoot.prepare(getContext());
    return true;
  }

  @Override
  public Cursor query(Uri uri, String[] p, String s, String[] a, String o) {
    return null;
  }

  @Override
  public String getType(Uri uri) {
    return null;
  }

  @Override
  public Uri insert(Uri uri, ContentValues values) {
    return null;
  }

  @Override
  public int delete(Uri uri, String s, String[] a) {
    return 0;
  }

  @Override
  public int update(Uri uri, ContentValues v, String s, String[] a) {
    return 0;
  }
}
