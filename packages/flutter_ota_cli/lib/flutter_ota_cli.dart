// Copyright 2026 The Punit Authors
// SPDX-License-Identifier: Apache-2.0

/// Developer CLI for Flutter OTA System (`flutter_ota`), and the toolchain API later milestones
/// use: `ToolchainManager(ctx).resolve(lock)` returns the verified toolchain paths and build
/// environment, or throws `ToolchainUnavailableException` (there is never a fallback to a stock
/// or global Flutter SDK).
library;

export 'src/cli/runner.dart' show runCli;
export 'src/config/user_config.dart' show UserConfig, ConfigSource, ConfigValue, configKeys, configEnv;
export 'src/context.dart';
export 'src/errors.dart';
export 'src/project/lockfile.dart';
export 'src/project/project.dart';
export 'src/toolchain/cache.dart';
export 'src/toolchain/disk_space.dart' show DiskSpaceProbe, dfFreeBytes;
export 'src/toolchain/index.dart';
export 'src/toolchain/manager.dart';
export 'src/toolchain/records.dart' show computeToolchainId, genSnapshotSdkPath, toolSnapshots, mirrorFilesFor;
export 'src/version.dart';
