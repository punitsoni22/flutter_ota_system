// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

import 'platform_stub.dart' if (dart.library.ffi) 'platform_native.dart';

String platformInfo() => describePlatform();
