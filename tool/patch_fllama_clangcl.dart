// Makes fllama's native build use Visual Studio's ClangCL toolset when the
// target is Windows on ARM64.
//
// Why: fllama bundles llama.cpp, and llama.cpp stops its CMake configure on
// Windows ARM64 when the compiler is MSVC ("MSVC is not supported for ARM,
// use clang"). The Flutter build then fails with "Building native assets
// failed" / "Custom build for 'flutter_windows.dll.rule' failed".
//
// fllama's build hook calls CMakeBuilder.create without a toolset, and Dart
// build hooks do not see custom environment variables, so the fix has to be
// in the hook itself. This script adds one argument to that call:
//
//   toolset: <Windows ARM64 target> ? 'ClangCL' : null,
//
// Every other target (macOS, Linux, Windows x64) is unchanged. The patch is
// idempotent and is applied to the fllama checkout in the pub cache, so run
// it after `flutter pub get`:
//
//   dart run tool/patch_fllama_clangcl.dart
//
// It needs Visual Studio's "C++ Clang Compiler for Windows" and "MSBuild
// support for LLVM (clang-cl) toolset" components.
//
// Remove this once fllama selects clang for Windows ARM64 itself.

import 'dart:convert';
import 'dart:io';

const String _marker = 'spwrite: ClangCL for Windows ARM64';
const String _anchor = "CMakeBuilder.create(\n          name: 'fllama',";
const String _insert = "\n          // $_marker (tool/patch_fllama_clangcl.dart)\n"
    '          toolset: input.config.code.targetOS == OS.windows &&\n'
    '                  input.config.code.targetArchitecture == Architecture.arm64\n'
    "              ? 'ClangCL'\n"
    '              : null,';

void main() {
  final File config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) {
    _fail('Run `flutter pub get` first (.dart_tool/package_config.json is missing).');
  }
  final Map<String, dynamic> json =
      jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  final List<dynamic> packages = json['packages'] as List<dynamic>;
  final Map<String, dynamic>? fllama = packages
      .cast<Map<String, dynamic>>()
      .where((Map<String, dynamic> p) => p['name'] == 'fllama')
      .firstOrNull;
  if (fllama == null) _fail('fllama is not a dependency of this project.');

  final Uri root = config.absolute.uri.resolve(fllama['rootUri'] as String);
  final File hook = File.fromUri(root.resolve('hook/build.dart'));
  if (!hook.existsSync()) _fail('fllama build hook not found at ${hook.path}');

  final String source = hook.readAsStringSync().replaceAll('\r\n', '\n');
  if (source.contains(_marker)) {
    stdout.writeln('fllama hook already patched: ${hook.path}');
    return;
  }
  if (!source.contains(_anchor)) {
    _fail('fllama changed: could not find the CMakeBuilder.create call in '
        '${hook.path}. Check whether this patch is still needed.');
  }
  hook.writeAsStringSync(source.replaceFirst(_anchor, '$_anchor$_insert'));
  stdout.writeln('Patched fllama hook to use ClangCL on Windows ARM64: ${hook.path}');
}

Never _fail(String message) {
  stderr.writeln('[patch_fllama_clangcl] $message');
  exit(1);
}
