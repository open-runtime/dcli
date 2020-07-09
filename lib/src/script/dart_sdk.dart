import 'dart:cli';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:system_info/system_info.dart';

import '../../dshell.dart';
import '../util/progress.dart';
import '../util/runnable_process.dart';
import '../util/terminal.dart';

/// The [DartSdk] provides access to a number of the dart sdk tools
/// as well as details on the active sdk instance.
class DartSdk {
  static DartSdk _self;

  /// Path of Dart SDK
  String _sdkPath;

  // Path the dart executable obtained by scanning the PATH
  String _exePath;

  String _version;

  ///
  factory DartSdk() {
    _self ??= DartSdk._internal();

    return _self;
  }

  DartSdk._internal() {
    if (Settings().isVerbose) {
      // expensive operation so only peform if required.
      Settings().verbose('Dart SDK Version  $version, path: $_sdkPath');
    }
  }

  /// The path to the dart 'bin' directory.
  String get sdkPath {
    _sdkPath ??= _detect();
    return _sdkPath;
  }

  /// platform specific name of the 'dart' executable
  static String get dartExeName {
    if (Platform.isWindows) {
      return 'dart.exe';
    } else {
      return 'dart';
    }
  }

  /// platform specific name of the 'pub' executable
  static String get pubExeName {
    if (Platform.isWindows) {
      return 'pub.bat';
    } else {
      return 'pub';
    }
  }

  /// platform specific name of the 'dart2native' executable
  static String get dart2NativeExeName {
    if (Platform.isWindows) {
      return 'dart2native.bat';
    } else {
      return 'dart2native';
    }
  }

  /// The path to the dart exe.
  String get dartExePath {
    if (_exePath == null) {
      // this is an expesive operation so only do it if required.
      var path = which(dartExeName, first: true).firstLine;
      assert(path != null);
      _exePath = path;
    }
    return _exePath;
  }

  /// file path to the 'pub' command.
  String get pubPath => p.join(sdkPath, 'bin', pubExeName);

  /// file path to the 'dart2native' command.
  String get dart2NativePath => p.join(sdkPath, 'bin', dart2NativeExeName);

  /// run the 'dart2native' command.
  /// [runtimeScriptPath] is the path of the dshell script we are compiling.
  /// [outputPath] is the path to write the compiled ex to .
  /// [runtimePath] is the path to execute 'dart2native' in.
  void runDart2Native(
      String runtimeScriptPath, String outputPath, String runtimePath,
      {Progress progress}) {
    var runArgs = <String>[];
    runArgs.add(runtimeScriptPath);
    runArgs.add('--packages=${join(runtimePath, ".packages")}');
    runArgs.add(
        '--output=${join(outputPath, basenameWithoutExtension(runtimeScriptPath))}');

    var process = RunnableProcess.fromCommandArgs(
      dart2NativePath,
      runArgs,
    );

    process.start();

    process.processUntilExit(progress, nothrow: false);
  }

  /// runs 'pub get'
  void runPubGet(String workingDirectory,
      {Progress progress, bool compileExecutables}) {
    var process = RunnableProcess.fromCommandArgs(
        pubPath, ['get', '--no-precompile'],
        workingDirectory: workingDirectory);

    process.start();

    process.processUntilExit(progress, nothrow: false);
    Settings().verbose('pub get finished');
  }

  static String _detect() {
    var path = which(pubExeName).firstLine;

    if (path != null) {
      return dirname(dirname(path));
    } else {
      var executable = Platform.resolvedExecutable;

      final file = File(executable);
      if (!file.existsSync()) {
        throw dartSdkNotFound;
      }

      var parent = file.absolute.parent;
      parent = parent.parent;

      final sdkPath = parent.path;
      final dartApi = "${join(sdkPath, 'include', 'dart_api.h')}";
      if (!File(dartApi).existsSync()) {
        throw Exception('Cannot find Dart SDK!');
      }

      return sdkPath;
    }
  }

  /// returns the version of date.
  String get version {
    if (_version == null) {
      final res = waitFor<ProcessResult>(
          Process.run(dartExePath, <String>['--version']));
      if (res.exitCode != 0) {
        throw Exception('Failed!');
      }

      var resultString = res.stderr as String;

      _version =
          resultString.substring('Dart VM version: '.length).split(' ').first;
    }

    return _version;
  }

  /// Installs the latest version of DartSdk from the official google archives
  /// This is simply the process of downloading and extracting the
  /// sdk to the [defaultDartSdkPath].
  ///
  /// The user is asked to confirm the install path and can modifiy
  /// it if desired.
  ///
  /// returns the directory where the dartSdk was installed.
  String installFromArchive(String defaultDartSdkPath) {
    Settings().verbose('Architecture: ${SysInfo.kernelArchitecture}');
    var zipRelease = _fetchDartSdk();

    var installDir = _askForDartSdkInstallDir(defaultDartSdkPath);

    // Read the Zip file from disk.
    _extractDartSdk(zipRelease, installDir);
    delete(zipRelease);

    return installDir;
  }

  String _fetchDartSdk() {
    var bitness = SysInfo.kernelBitness;
    var architechture = 'x64';
    if (bitness == 32) {
      architechture = 'ia32';
    }
    var platform = Platform.operatingSystem;

    var zipRelease = FileSync.tempFile(suffix: 'release.zip');

    // the sdk's can be found here:
    /// https://dart.dev/tools/sdk/archive

    var term = Terminal();
    term.showCursor(show: false);

    fetch(
        url:
            'https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-$platform-$architechture-release.zip',
        saveToPath: zipRelease,
        onProgress: _showProgress);

    term.showCursor(show: true);
    print('');
    return zipRelease;
  }

  String _askForDartSdkInstallDir(String dartToolDir) {
    var confirmed = false;

    /// ask for and confirm the install directory.
    while (!confirmed) {
      var entered = ask(
          prompt:
              'Install dart-sdk to (Enter for default [${truepath(dartToolDir)}]): ');
      if (!entered.isEmpty) {
        dartToolDir = entered;
      }

      confirmed = confirm(prompt: 'Is $dartToolDir correct:');
    }

    if (!exists(dartToolDir)) {
      createDir(dartToolDir, recursive: true);
    }
    return dartToolDir;
  }

  void _extractDartSdk(String zipRelease, String dartToolDir) {
    // Read the Zip file from disk.
    final bytes = File(zipRelease).readAsBytesSync();

    // Decode the Zip file
    final archive = ZipDecoder().decodeBytes(bytes);

    for (final file in archive) {
      final filename = file.name;
      var path = join(dartToolDir, filename);
      if (file.isFile) {
        final data = file.content as List<int>;
        File(path)
          ..createSync(recursive: true)
          ..writeAsBytesSync(data);
      } else {
        createDir(path, recursive: true);
      }
    }
  }

  void _showProgress(FetchProgress progress) {
    // var term = Terminal();
    // term.clearLine(mode: TerminalClearMode.all);
    // term.startOfLine();
    // var percentage = Format().percentage(progress.progress, 1);
    // echo(
    //     '${EnumHelper.getName(progress.status).padRight(15)}${humanNumber(progress.downloaded)}/${humanNumber(progress.length)} $percentage');
  }
}

/// Exception throw if we can't find the dart sdk.
final Exception dartSdkNotFound = Exception('Dart SDK not found!');

/// This method is ONLY for use by the installer so that we can
/// set the path during the install when it won't be detectable
/// as its not on the system path.
void setDartSdkPath(String dartSdkPath) {
  DartSdk()._sdkPath = dartSdkPath;
}
