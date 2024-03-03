// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:unified_analytics/unified_analytics.dart';

import '../artifacts.dart';
import '../base/analyze_size.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/project_migrator.dart';
import '../base/terminal.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../cache.dart';
import '../cmake.dart';
import '../cmake_project.dart';
import '../convert.dart';
import '../flutter_plugins.dart';
import '../globals.dart' as globals;
import '../migrations/cmake_custom_command_migration.dart';
import '../migrations/cmake_native_assets_migration.dart';
import 'migrations/build_architecture_migration.dart';
import 'migrations/show_window_migration.dart';
import 'migrations/version_migration.dart';
import 'visual_studio.dart';

// These characters appear to be fine: @%()-+_{}[]`~
const String _kBadCharacters = r"'#!$^&*=|,;<>?";

/// Builds the Windows project using msbuild.
Future<void> buildWindows(WindowsProject windowsProject, BuildInfo buildInfo, {
  String? target,
  VisualStudio? visualStudioOverride,
  SizeAnalyzer? sizeAnalyzer,
}) async {
  // MSBuild files generated by CMake do not properly escape some characters
  // In the directories. This check produces more meaningful error messages
  // on failure as pertains to https://github.com/flutter/flutter/issues/104802
  final String projectPath = windowsProject.parent.directory.absolute.path;
  final bool badPath = _kBadCharacters.runes
      .any((int i) => projectPath.contains(String.fromCharCode(i)));
  if (badPath) {
    throwToolExit(
      'Path $projectPath contains invalid characters in "$_kBadCharacters". '
      'Please rename your directory so as to not include any of these characters '
      'and retry.',
    );
  }

  if (!windowsProject.cmakeFile.existsSync()) {
    throwToolExit(
      'No Windows desktop project configured. See '
      'https://docs.flutter.dev/desktop#add-desktop-support-to-an-existing-flutter-app '
      'to learn about adding Windows support to a project.');
  }

  // TODO(pbo-linaro): Add support for windows-arm64 platform, https://github.com/flutter/flutter/issues/129807
  const TargetPlatform targetPlatform = TargetPlatform.windows_x64;
  final Directory buildDirectory = globals.fs.directory(globals.fs.path.join(
    projectPath,
    getWindowsBuildDirectory(targetPlatform),
  ));

  final List<ProjectMigrator> migrators = <ProjectMigrator>[
    CmakeCustomCommandMigration(windowsProject, globals.logger),
    CmakeNativeAssetsMigration(windowsProject, 'windows', globals.logger),
    VersionMigration(windowsProject, globals.logger),
    ShowWindowMigration(windowsProject, globals.logger),
    BuildArchitectureMigration(windowsProject, buildDirectory, globals.logger),
  ];

  final ProjectMigration migration = ProjectMigration(migrators);
  migration.run();

  // Ensure that necessary ephemeral files are generated and up to date.
  _writeGeneratedFlutterConfig(windowsProject, buildInfo, target);
  createPluginSymlinks(windowsProject.parent);

  final VisualStudio visualStudio = visualStudioOverride ?? VisualStudio(
    fileSystem: globals.fs,
    platform: globals.platform,
    logger: globals.logger,
    processManager: globals.processManager,
  );
  final String? cmakePath = visualStudio.cmakePath;
  final String? cmakeGenerator = visualStudio.cmakeGenerator;
  if (cmakePath == null || cmakeGenerator == null) {
    throwToolExit('Unable to find suitable Visual Studio toolchain. '
        'Please run `flutter doctor` for more details.');
  }

  final String buildModeName = buildInfo.mode.cliName;
  final Status status = globals.logger.startProgress(
    'Building Windows application...',
  );
  try {
    await _runCmakeGeneration(
      cmakePath: cmakePath,
      generator: cmakeGenerator,
      buildDir: buildDirectory,
      sourceDir: windowsProject.cmakeFile.parent,
      targetPlatform: targetPlatform,
    );
    if (visualStudio.displayVersion == '17.1.0') {
      _fixBrokenCmakeGeneration(buildDirectory);
    }
    await _runBuild(cmakePath, buildDirectory, buildModeName);
  } finally {
    status.stop();
  }

  final String? binaryName = getCmakeExecutableName(windowsProject);
  final File appFile = buildDirectory
    .childDirectory('runner')
    .childDirectory(sentenceCase(buildModeName))
    .childFile('$binaryName.exe');
  if (appFile.existsSync()) {
    final String appSize = (buildInfo.mode == BuildMode.debug)
        ? '' // Don't display the size when building a debug variant.
        : ' (${getSizeAsMB(appFile.lengthSync())})';
    globals.logger.printStatus(
      '${globals.logger.terminal.successMark}  '
      'Built ${globals.fs.path.relative(appFile.path)}$appSize.',
      color: TerminalColor.green,
    );
  }

  if (buildInfo.codeSizeDirectory != null && sizeAnalyzer != null) {
    final String arch = getNameForTargetPlatform(TargetPlatform.windows_x64);
    final File codeSizeFile = globals.fs.directory(buildInfo.codeSizeDirectory)
      .childFile('snapshot.$arch.json');
    final File precompilerTrace = globals.fs.directory(buildInfo.codeSizeDirectory)
      .childFile('trace.$arch.json');
    final Map<String, Object?> output = await sizeAnalyzer.analyzeAotSnapshot(
      aotSnapshot: codeSizeFile,
      // This analysis is only supported for release builds.
      outputDirectory: globals.fs.directory(
        globals.fs.path.join(
          buildDirectory.path,
          'runner',
          'Release'
        ),
      ),
      precompilerTrace: precompilerTrace,
      type: 'windows',
    );
    final File outputFile = globals.fsUtils.getUniqueFile(
      globals.fs
        .directory(globals.fsUtils.homeDirPath)
        .childDirectory('.flutter-devtools'), 'windows-code-size-analysis', 'json',
    )..writeAsStringSync(jsonEncode(output));
    // This message is used as a sentinel in analyze_apk_size_test.dart
    globals.printStatus(
      'A summary of your Windows bundle analysis can be found at: ${outputFile.path}',
    );

    // DevTools expects a file path relative to the .flutter-devtools/ dir.
    final String relativeAppSizePath = outputFile.path.split('.flutter-devtools/').last.trim();
    globals.printStatus(
      '\nTo analyze your app size in Dart DevTools, run the following command:\n'
      'dart devtools --appSizeBase=$relativeAppSizePath'
    );
  }
}

Future<void> _runCmakeGeneration({
  required String cmakePath,
  required String generator,
  required Directory buildDir,
  required Directory sourceDir,
  required TargetPlatform targetPlatform,
}) async {
  if (targetPlatform != TargetPlatform.windows_x64) {
    throwToolExit('Windows build supports only x64 target architecture');
  }

  final Stopwatch sw = Stopwatch()..start();

  await buildDir.create(recursive: true);
  int result;
  const String arch = 'x64';
  const String flutterTargetPlatform = 'windows-x64';
  try {
    result = await globals.processUtils.stream(
      <String>[
        cmakePath,
        '-S',
        sourceDir.path,
        '-B',
        buildDir.path,
        '-G',
        generator,
        '-A',
        arch,
        '-DFLUTTER_TARGET_PLATFORM=$flutterTargetPlatform',
      ],
      trace: true,
    );
  } on ArgumentError {
    throwToolExit("cmake not found. Run 'flutter doctor' for more information.");
  }
  if (result != 0) {
    throwToolExit('Unable to generate build files');
  }
  final Duration elapsedDuration = sw.elapsed;
  globals.flutterUsage.sendTiming('build', 'windows-cmake-generation', elapsedDuration);
  globals.analytics.send(Event.timing(
    workflow: 'build',
    variableName: 'windows-cmake-generation',
    elapsedMilliseconds: elapsedDuration.inMilliseconds,
  ));
}

Future<void> _runBuild(
  String cmakePath,
  Directory buildDir,
  String buildModeName,
  { bool install = true }
) async {
  final Stopwatch sw = Stopwatch()..start();

  // MSBuild sends all output to stdout, including build errors. This surfaces
  // known error patterns.
  final RegExp errorMatcher = RegExp(
    <String>[
      // Known error messages
      r'(:\s*(?:warning|(?:fatal )?error).*?:)',
      r'Error detected in pubspec\.yaml:',

      // Known secondary error lines for pubspec.yaml
      r'No file or variants found for asset:',
    ].join('|'),
  );

  int result;
  try {
    result = await globals.processUtils.stream(
      <String>[
        cmakePath,
        '--build',
        buildDir.path,
        '--config',
        sentenceCase(buildModeName),
        if (install)
          ...<String>['--target', 'INSTALL'],
        if (globals.logger.isVerbose)
          '--verbose',
      ],
      environment: <String, String>{
        if (globals.logger.isVerbose)
          'VERBOSE_SCRIPT_LOGGING': 'true',
      },
      trace: true,
      stdoutErrorMatcher: errorMatcher,
    );
  } on ArgumentError {
    throwToolExit("cmake not found. Run 'flutter doctor' for more information.");
  }
  if (result != 0) {
    throwToolExit('Build process failed.');
  }
  final Duration elapsedDuration = sw.elapsed;
  globals.flutterUsage.sendTiming('build', 'windows-cmake-build', elapsedDuration);
  globals.analytics.send(Event.timing(
    workflow: 'build',
    variableName: 'windows-cmake-build',
    elapsedMilliseconds: elapsedDuration.inMilliseconds,
  ));
}

/// Writes the generated CMake file with the configuration for the given build.
void _writeGeneratedFlutterConfig(
  WindowsProject windowsProject,
  BuildInfo buildInfo,
  String? target,
) {
  final Map<String, String> environment = <String, String>{
    'FLUTTER_ROOT': Cache.flutterRoot!,
    'FLUTTER_EPHEMERAL_DIR': windowsProject.ephemeralDirectory.path,
    'PROJECT_DIR': windowsProject.parent.directory.path,
    if (target != null)
      'FLUTTER_TARGET': target,
    ...buildInfo.toEnvironmentConfig(),
  };
  final LocalEngineInfo? localEngineInfo = globals.artifacts?.localEngineInfo;
  if (localEngineInfo != null) {
    final String targetOutPath = localEngineInfo.targetOutPath;
    // Get the engine source root $ENGINE/src/out/foo_bar_baz -> $ENGINE/src
    environment['FLUTTER_ENGINE'] = globals.fs.path.dirname(globals.fs.path.dirname(targetOutPath));
    environment['LOCAL_ENGINE'] = localEngineInfo.localTargetName;
    environment['LOCAL_ENGINE_HOST'] = localEngineInfo.localHostName;
  }
  writeGeneratedCmakeConfig(Cache.flutterRoot!, windowsProject, buildInfo, environment, globals.logger);
}

// Works around the Visual Studio 17.1.0 CMake bug described in
// https://github.com/flutter/flutter/issues/97086
//
// Rather than attempt to remove all the duplicate entries within the
// <CustomBuild> element, which would require a more complicated parser, this
// just fixes the incorrect duplicates to have the correct `$<CONFIG>` value,
// making the duplication harmless.
//
// TODO(stuartmorgan): Remove this workaround either once 17.1.0 is
// sufficiently old that we no longer need to support it, or when
// dropping VS 2022 support.
void _fixBrokenCmakeGeneration(Directory buildDirectory) {
  final File assembleProject = buildDirectory
    .childDirectory('flutter')
    .childFile('flutter_assemble.vcxproj');
  if (assembleProject.existsSync()) {
    // E.g.: <Command Condition="'$(Configuration)|$(Platform)'=='Debug|x64'">
    final RegExp commandRegex = RegExp(
      r'<Command Condition=.*\(Configuration\)\|\$\(Platform\).==.(Debug|Profile|Release)\|');
    // E.g.: [...]/flutter_tools/bin/tool_backend.bat windows-x64 Debug
    final RegExp assembleCallRegex = RegExp(
      r'^.*/tool_backend\.bat windows[^ ]* (Debug|Profile|Release)');
    String? lastCommandConditionConfig;
    final StringBuffer newProjectContents = StringBuffer();
    // vcxproj files contain a BOM, which readAsLinesSync drops; re-add it.
    newProjectContents.writeCharCode(unicodeBomCharacterRune);
    for (final String line in assembleProject.readAsLinesSync()) {
      final RegExpMatch? commandMatch = commandRegex.firstMatch(line);
      if (commandMatch != null) {
        lastCommandConditionConfig = commandMatch.group(1);
      } else if (lastCommandConditionConfig != null) {
        final RegExpMatch? assembleCallMatch = assembleCallRegex.firstMatch(line);
        if (assembleCallMatch != null) {
          final String callConfig = assembleCallMatch.group(1)!;
          if (callConfig != lastCommandConditionConfig) {
            // The config is the end of the line; make sure to replace that one,
            // in case config-matching strings appear anywhere else in the line
            // (e.g., the project path).
            final int badConfigIndex = line.lastIndexOf(assembleCallMatch.group(1)!);
            final String correctedLine = line.replaceFirst(
              callConfig, lastCommandConditionConfig, badConfigIndex);
            newProjectContents.writeln('$correctedLine\r');
            continue;
          }
        }
      }
      newProjectContents.writeln('$line\r');
    }
    assembleProject.writeAsStringSync(newProjectContents.toString());
  }
}
