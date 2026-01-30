import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:yaml/yaml.dart';

enum Bump { major, minor, patch, none }

class SemVer {
  final int major;
  final int minor;
  final int patch;
  final int build;

  const SemVer(this.major, this.minor, this.patch, this.build);

  SemVer bump(Bump b, {bool bumpBuild = true}) {
    final nextBuild = bumpBuild ? build + 1 : build;
    return switch (b) {
      Bump.major => SemVer(major + 1, 0, 0, nextBuild),
      Bump.minor => SemVer(major, minor + 1, 0, nextBuild),
      Bump.patch => SemVer(major, minor, patch + 1, nextBuild),
      Bump.none => SemVer(major, minor, patch, nextBuild),
    };
  }

  String get versionName => '$major.$minor.$patch';
  String get flutterVersion => '$versionName+$build';

  /// Parses a version string. Accepts:
  /// - Flutter style: "X.Y.Z+build" (e.g. "1.0.0+1")
  /// - Dart style: "X.Y.Z" (e.g. "1.0.0", build is 0)
  static SemVer parseVersion(String v) {
    final s = v.trim();
    if (s.contains('+')) {
      return parseFlutterVersion(s);
    }
    final ver = s.split('.');
    if (ver.length != 3) {
      throw FormatException('Expected X.Y.Z or X.Y.Z+N, got: $v');
    }
    return SemVer(int.parse(ver[0]), int.parse(ver[1]), int.parse(ver[2]), 0);
  }

  static SemVer parseFlutterVersion(String v) {
    final parts = v.trim().split('+');
    if (parts.length != 2) throw FormatException('Expected X.Y.Z+N, got: $v');
    final ver = parts[0].split('.');
    if (ver.length != 3) {
      throw FormatException('Expected X.Y.Z, got: ${parts[0]}');
    }
    return SemVer(
      int.parse(ver[0]),
      int.parse(ver[1]),
      int.parse(ver[2]),
      int.parse(parts[1]),
    );
  }
}

/// Config from changeset.yaml or pubspec "changeset:" key.
class ChangesetConfig {
  final String changelogPath;
  final String changesetsPath;
  final Map<String, String> packages;

  const ChangesetConfig({
    this.changelogPath = 'CHANGELOG.md',
    this.changesetsPath = '.changesets',
    this.packages = const {},
  });
}

/// Root directory + config (or default when no config found).
class ResolvedConfig {
  final Directory root;
  final ChangesetConfig config;

  const ResolvedConfig({required this.root, required this.config});

  String get rootPath => root.path;
}

/// Resolves root and config: walk up from [cwd] looking for changeset.yaml
/// or pubspec with workspace/melos and optional "changeset:" key.
Future<ResolvedConfig> resolveConfig({Directory? cwd}) async {
  final start = cwd ?? Directory.current;
  Directory dir = start;

  while (true) {
    final changesetYaml = File(
      '${dir.path}${Platform.pathSeparator}changeset.yaml',
    );
    if (await changesetYaml.exists()) {
      final config = await _loadChangesetYaml(changesetYaml);
      return ResolvedConfig(root: dir, config: config);
    }

    final pubspec = File('${dir.path}${Platform.pathSeparator}pubspec.yaml');
    if (await pubspec.exists()) {
      final content = await pubspec.readAsString();
      final hasWorkspace =
          RegExp(r'^\s*workspace:\s*$', multiLine: true).hasMatch(content) ||
          (content.contains('workspace:') &&
              RegExp(r'^\s*-\s*[\w./]+', multiLine: true).hasMatch(content));
      final hasMelos =
          RegExp(r'^\s*melos:\s*$', multiLine: true).hasMatch(content) ||
          content.contains('melos:');
      if (hasWorkspace || hasMelos) {
        final config = _loadChangesetFromPubspec(content);
        return ResolvedConfig(root: dir, config: config);
      }
    }

    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }

  return ResolvedConfig(root: start, config: const ChangesetConfig());
}

Future<ChangesetConfig> _loadChangesetYaml(File file) async {
  final content = await file.readAsString();
  final doc = loadYaml(content);
  if (doc == null || doc is! YamlMap) {
    return const ChangesetConfig();
  }
  return _parseConfigMap(doc);
}

ChangesetConfig _loadChangesetFromPubspec(String pubspecContent) {
  final doc = loadYaml(pubspecContent);
  if (doc == null || doc is! YamlMap) {
    return const ChangesetConfig();
  }
  final changeset = doc['changeset'];
  if (changeset == null || changeset is! YamlMap) {
    return const ChangesetConfig();
  }
  return _parseConfigMap(changeset);
}

ChangesetConfig _parseConfigMap(YamlMap map) {
  String changelogPath = 'CHANGELOG.md';
  String changesetsPath = '.changesets';
  final packages = <String, String>{};

  if (map['changelogPath'] != null && map['changelogPath'] is String) {
    changelogPath = map['changelogPath'] as String;
  }
  if (map['changesetsPath'] != null && map['changesetsPath'] is String) {
    changesetsPath = map['changesetsPath'] as String;
  }
  if (map['packages'] != null && map['packages'] is YamlMap) {
    final p = map['packages'] as YamlMap;
    for (final e in p.entries) {
      if (e.key != null && e.value != null) {
        packages[e.key.toString()] = e.value.toString();
      }
    }
  }

  return ChangesetConfig(
    changelogPath: changelogPath,
    changesetsPath: changesetsPath,
    packages: Map.unmodifiable(packages),
  );
}

class Changeset {
  final Bump type;
  final String? scope;
  final String? package;
  final String summary;
  final String filename;

  Changeset({
    required this.type,
    required this.summary,
    required this.filename,
    this.scope,
    this.package,
  });
}

Future<void> main(List<String> args) async {
  if (args.contains('--__complete-workspaces')) {
    try {
      final resolved = await resolveConfig();
      final names = resolved.config.packages.keys.toList()..sort();
      for (final n in names) {
        print(n);
      }
    } catch (_) {
      // No config or error: output nothing
    }
    return;
  }

  final runner =
      CommandRunner<void>(
          'changeset',
          'A lightweight CLI to manage changesets for Dart/Flutter projects.',
        )
        ..addCommand(AddCommand())
        ..addCommand(ReleaseCommand())
        ..addCommand(CompletionCommand());

  try {
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  }
}

class AddCommand extends Command<void> {
  @override
  String get name => 'add';

  @override
  String get description =>
      'Create a new changeset (requires --type and --summary).';

  AddCommand() {
    argParser
      ..addOption(
        'type',
        abbr: 't',
        mandatory: true,
        allowed: ['major', 'minor', 'patch'],
        help: 'Bump type: major, minor, or patch',
      )
      ..addOption(
        'summary',
        abbr: 's',
        mandatory: true,
        help: 'Short description of the change',
      )
      ..addOption('scope', help: 'Optional scope/module for changelog grouping')
      ..addOption(
        'workspace',
        abbr: 'W',
        help: 'Workspace/package name (monorepo: changeset for this package)',
      );
  }

  @override
  Future<void> run() async {
    String typeStr;
    String summary;
    try {
      typeStr = argResults!['type'] as String;
      summary = argResults!['summary'] as String;
    } on ArgumentError {
      throw UsageException(
        'add requires --type and --summary.',
        argParser.usage,
      );
    }
    final scope = argResults!['scope'] as String?;
    final workspaceName = (argResults!['workspace'] as String?)?.trim();
    if (workspaceName != null && workspaceName.isEmpty) {
      throw UsageException(
        '--workspace must be a non-empty package name.',
        argParser.usage,
      );
    }

    final type = switch (typeStr.toLowerCase()) {
      'major' => Bump.major,
      'minor' => Bump.minor,
      'patch' => Bump.patch,
      _ => throw UsageException(
        'Invalid --type "$typeStr" (use major|minor|patch)',
        argParser.usage,
      ),
    };

    Directory dir;
    String? packageLine;
    if (workspaceName != null) {
      final resolved = await resolveConfig();
      if (!resolved.config.packages.containsKey(workspaceName)) {
        stderr.writeln(
          'ERROR: Unknown workspace "$workspaceName". '
          'Define it in changeset.yaml or pubspec "changeset.packages".',
        );
        exitCode = 2;
        return;
      }
      final changesetsPath = resolved.config.changesetsPath;
      final fullPath =
          '${resolved.rootPath}${Platform.pathSeparator}$changesetsPath';
      dir = Directory(fullPath);
      packageLine = 'package: $workspaceName';
    } else {
      dir = Directory('.changesets');
      packageLine = null;
    }

    await dir.create(recursive: true);

    final now = DateTime.now();
    final datePart =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    final slug = _slugify(summary);
    final baseName = '$datePart-$slug';
    final filename = await _uniqueFilename(dir, '$baseName.md');

    final scopeVal = scope?.trim().isEmpty ?? true ? null : scope?.trim();
    final content = StringBuffer()
      ..writeln('type: ${type.name}')
      ..writeln('scope: ${scopeVal ?? ''}'.trimRight());
    if (packageLine != null) {
      content.writeln(packageLine);
    }
    content
      ..writeln('summary: ${summary.trim()}')
      ..writeln();

    var text = content.toString();
    if (scopeVal == null) {
      text = text.replaceFirst(RegExp(r'^\s*scope:.*\n', multiLine: true), '');
    }

    final file = File('${dir.path}${Platform.pathSeparator}$filename');
    await file.writeAsString(text);

    print('Created changeset: ${file.path}');
  }
}

class ReleaseCommand extends Command<void> {
  @override
  String get name => 'release';

  @override
  String get description =>
      'Apply pending changesets: bump version, update CHANGELOG, archive.';

  ReleaseCommand() {
    argParser
      ..addFlag('dry-run', help: 'Show release plan without modifying files')
      ..addOption(
        'workspace',
        abbr: 'W',
        help: 'Workspace/package name (monorepo: release only this package)',
      );
  }

  @override
  Future<void> run() async {
    final dryRun = argResults!['dry-run'] as bool;
    final workspaceName = (argResults!['workspace'] as String?)?.trim();
    if (workspaceName != null && workspaceName.isEmpty) {
      stderr.writeln('ERROR: --workspace must be a non-empty package name.');
      exitCode = 2;
      return;
    }

    final sep = Platform.pathSeparator;
    Directory changesetDir;
    File pubspecFile;
    File changelogFile;
    String archiveSubdir;

    if (workspaceName != null) {
      final resolved = await resolveConfig();
      if (!resolved.config.packages.containsKey(workspaceName)) {
        stderr.writeln(
          'ERROR: Unknown workspace "$workspaceName". '
          'Define it in changeset.yaml or pubspec "changeset.packages".',
        );
        exitCode = 2;
        return;
      }
      final pkgPath = resolved.config.packages[workspaceName]!;
      final rootPath = resolved.rootPath;
      changesetDir = Directory(
        '$rootPath$sep${resolved.config.changesetsPath}',
      );
      pubspecFile = File('$rootPath$sep$pkgPath${sep}pubspec.yaml');
      changelogFile = File('$rootPath$sep${resolved.config.changelogPath}');
      archiveSubdir = 'archived$sep$workspaceName$sep';
    } else {
      changesetDir = Directory('.changesets');
      pubspecFile = File('pubspec.yaml');
      changelogFile = File('CHANGELOG.md');
      archiveSubdir = 'archived$sep';
    }

    if (!await pubspecFile.exists()) {
      stderr.writeln('ERROR: pubspec.yaml not found at ${pubspecFile.path}');
      exitCode = 2;
      return;
    }
    if (!await changesetDir.exists()) {
      stderr.writeln('ERROR: .changesets folder not found.');
      exitCode = 2;
      return;
    }

    var allChangesets = await _readChangesets(changesetDir);
    if (workspaceName != null) {
      allChangesets = allChangesets
          .where((c) => c.package == workspaceName)
          .toList();
    } else {
      allChangesets = allChangesets.where((c) => c.package == null).toList();
    }

    if (allChangesets.isEmpty) {
      print(
        'No changesets found for ${workspaceName ?? "this project"}. Nothing to release.',
      );
      return;
    }

    final pubspecText = await pubspecFile.readAsString();
    final (current, hasBuildNumber) = _readPubspecVersion(pubspecText);
    final bump = _decideBump(allChangesets);
    final next = current.bump(bump, bumpBuild: hasBuildNumber);

    final currentVersionStr = hasBuildNumber
        ? current.flutterVersion
        : current.versionName;
    final nextVersionStr = hasBuildNumber
        ? next.flutterVersion
        : next.versionName;

    final grouped = _groupByScope(allChangesets);
    final releaseNotes = workspaceName != null
        ? _buildReleaseNotes(
            versionName: next.versionName,
            grouped: grouped,
            packageName: workspaceName,
          )
        : _buildReleaseNotes(versionName: next.versionName, grouped: grouped);

    print('--- Release Plan ---');
    if (workspaceName != null) print('Workspace: $workspaceName');
    print('Current: $currentVersionStr');
    print('Bump:    ${bump.name}');
    print('Next:    $nextVersionStr');
    print('Changesets: ${allChangesets.length}');
    print('');
    print('Changelog entry preview:\n$releaseNotes');

    if (dryRun) {
      print('\n[dry-run] No files were modified.');
      return;
    }

    final updatedPubspec = _replacePubspecVersion(pubspecText, nextVersionStr);
    await pubspecFile.writeAsString(updatedPubspec);
    print('\nUpdated ${pubspecFile.path} to version: $nextVersionStr');

    final existingChangelog = await changelogFile.exists()
        ? await changelogFile.readAsString()
        : '# Changelog\n\n';
    final updatedChangelog = _prependChangelog(existingChangelog, releaseNotes);
    await changelogFile.writeAsString(updatedChangelog);
    print('Updated ${changelogFile.path}');

    final archiveDir = Directory(
      '${changesetDir.path}$sep$archiveSubdir${next.versionName}',
    );
    await archiveDir.create(recursive: true);

    for (final cs in allChangesets) {
      final from = File('${changesetDir.path}$sep${cs.filename}');
      final to = File('${archiveDir.path}$sep${cs.filename}');
      if (await from.exists()) await from.rename(to.path);
    }
    print('Archived changesets to: ${archiveDir.path}');
    print('\nDone.');
    print('Next steps (manual):');
    final relPath = workspaceName != null ? '$workspaceName/' : '';
    print(
      '- git add ${pubspecFile.path} ${changelogFile.path} ${archiveDir.path}',
    );
    print('- git commit -m "chore(release): ${relPath}v${next.versionName}"');
    print('- git tag ${relPath}v${next.versionName}');
    print('- git push --follow-tags');
  }
}

class CompletionCommand extends Command<void> {
  @override
  String get name => 'completion';

  @override
  String get description =>
      'Print shell completion script (bash, zsh, fish, powershell). Install: eval "\$(changeset completion <shell>)".';

  CompletionCommand() {
    argParser.addOption(
      'shell',
      abbr: 's',
      allowed: ['bash', 'zsh', 'fish', 'powershell'],
      help: 'Shell to generate completion for',
    );
  }

  @override
  Future<void> run() async {
    final shell = argResults!['shell'] as String? ?? _detectShell();
    switch (shell) {
      case 'bash':
        print(_bashCompletionScript());
        break;
      case 'zsh':
        print(_zshCompletionScript());
        break;
      case 'fish':
        print(_fishCompletionScript());
        break;
      case 'powershell':
        print(_powershellCompletionScript());
        break;
      default:
        stderr.writeln(
          'Unknown shell "$shell". Use --shell bash|zsh|fish|powershell.',
        );
        exitCode = 2;
    }
  }

  String _detectShell() {
    if (Platform.isWindows) {
      final ps = Platform.environment['PSModulePath'];
      if (ps != null && ps.isNotEmpty) return 'powershell';
      final shell = Platform.environment['SHELL'] ?? '';
      if (shell.contains('bash')) return 'bash';
      if (shell.contains('zsh')) return 'zsh';
      if (shell.contains('fish')) return 'fish';
      return 'powershell';
    }
    final env = Platform.environment['SHELL'] ?? '';
    if (env.contains('bash')) return 'bash';
    if (env.contains('zsh')) return 'zsh';
    if (env.contains('fish')) return 'fish';
    return 'bash';
  }

  String _bashCompletionScript() {
    const cmd = 'changeset';
    return '''
# Bash completion for changeset
_changeset_complete() {
  local cur prev words cword
  _init_completion -s || return
  prev="\${words[cword-1]}"

  if [[ \$cword -eq 1 ]]; then
    COMPREPLY=(\$(compgen -W "add release completion" -- "\$cur"))
    return
  fi

  local subcmd="\${words[1]}"
  if [[ "\$prev" == "-W" || "\$prev" == "--workspace" ]]; then
    COMPREPLY=(\$(compgen -W "\$($cmd --__complete-workspaces 2>/dev/null)" -- "\$cur"))
    return
  fi

  if [[ "\$subcmd" == "add" ]]; then
    if [[ "\$prev" == "--type" || "\$prev" == "-t" ]]; then
      COMPREPLY=(\$(compgen -W "major minor patch" -- "\$cur"))
      return
    fi
    COMPREPLY=(\$(compgen -W "--type -t --summary -s --scope --workspace -W" -- "\$cur"))
    return
  fi

  if [[ "\$subcmd" == "release" ]]; then
    COMPREPLY=(\$(compgen -W "--dry-run --workspace -W" -- "\$cur"))
    return
  fi

  if [[ "\$subcmd" == "completion" ]]; then
    COMPREPLY=(\$(compgen -W "--shell -s bash zsh fish powershell" -- "\$cur"))
    return
  fi
}
complete -F _changeset_complete $cmd
''';
  }

  String _zshCompletionScript() {
    const cmd = 'changeset';
    return '''
# Zsh completion for changeset
_changeset() {
  local cur context state state_descr line
  _arguments -C \\
    "1:command:((add\\:Create\\ a\\ changeset release\\:Apply\\ changesets completion\\:Shell\\ completion))" \\
    "*::arg:->args"

  case "\$line[1]" in
    add)
      _arguments \\
        "--type[Bump type]:type:(major minor patch)" \\
        "-t[Bump type]:type:(major minor patch)" \\
        "--summary[Description]:summary:" \\
        "-s[Description]:summary:" \\
        "--scope[Scope]:scope:" \\
        "--workspace[Workspace name]:workspace:(\$($cmd --__complete-workspaces 2>/dev/null))" \\
        "-W[Workspace name]:workspace:(\$($cmd --__complete-workspaces 2>/dev/null))"
      ;;
    release)
      _arguments \\
        "--dry-run[Preview only]" \\
        "--workspace[Workspace name]:workspace:(\$($cmd --__complete-workspaces 2>/dev/null))" \\
        "-W[Workspace name]:workspace:(\$($cmd --__complete-workspaces 2>/dev/null))"
      ;;
    completion)
      _arguments "--shell[Shell]:shell:(bash zsh fish powershell)" "-s[Shell]:shell:(bash zsh fish powershell)"
      ;;
  esac
}
compdef _changeset $cmd
''';
  }

  String _fishCompletionScript() {
    const cmd = 'changeset';
    return '''
# Fish completion for changeset
function __changeset_workspaces
  $cmd --__complete-workspaces 2>/dev/null
end

function __changeset_complete
  set -l tokens (commandline -opc)
  set -l curr (commandline -t)
  set -l n (count \$tokens)

  if test \$n -eq 1
    echo add\\nrelease\\ncompletion
    return
  end

  set -l subcmd \$tokens[2]
  if test \$n -ge 3
    and string match -q -- "\$tokens[-1]" "-W" "--workspace"
    __changeset_workspaces
    return
  end

  if string match -q -- "\$subcmd" add
    if string match -q -- "\$tokens[-1]" "--type" "-t"
      echo major\\nminor\\npatch
      return
    end
    echo --type\\n-t\\n--summary\\n-s\\n--scope\\n--workspace\\n-W
    return
  end

  if string match -q -- "\$subcmd" release
    echo --dry-run\\n--workspace\\n-W
    return
  end

  if string match -q -- "\$subcmd" completion
    echo --shell\\n-s\\nbash\\nzsh\\nfish\\npowershell
    return
  end
end

complete -c $cmd -f -a "(__changeset_complete)"
''';
  }

  String _powershellCompletionScript() {
    const cmd = 'changeset';
    return '''
# PowerShell completion for changeset (Windows / Starship)
# Install: Add to your PowerShell profile: changeset completion powershell | Out-String | Invoke-Expression
# Or: . (changeset completion powershell)

Register-ArgumentCompleter -Native -CommandName $cmd -ScriptBlock {
  param(\$wordToComplete, \$commandAst, \$cursorPosition)
  \$line = \$commandAst.ToString()
  \$tokens = (\$line -split '\\s+').Where{ \$_.Length -gt 0 }
  \$n = \$tokens.Count
  \$prev = if (\$n -ge 2) { \$tokens[-2] } else { \$null }
  \$subcmd = if (\$n -ge 2) { \$tokens[1] } else { \$null }

  \$out = @()
  if (\$n -le 1) {
    \$out = @('add', 'release', 'completion')
  } elseif (\$prev -eq '-W' -or \$prev -eq '--workspace') {
    try {
      \$out = & $cmd --__complete-workspaces 2>\$null
      if (\$out -eq \$null) { \$out = @() }
      if (\$out -is [string]) { \$out = @(\$out) }
    } catch { \$out = @() }
  } elseif (\$subcmd -eq 'add') {
    if (\$prev -eq '--type' -or \$prev -eq '-t') {
      \$out = @('major', 'minor', 'patch')
    } else {
      \$out = @('--type', '-t', '--summary', '-s', '--scope', '--workspace', '-W')
    }
  } elseif (\$subcmd -eq 'release') {
    \$out = @('--dry-run', '--workspace', '-W')
  } elseif (\$subcmd -eq 'completion') {
    \$out = @('--shell', '-s', 'bash', 'zsh', 'fish', 'powershell')
  }

  \$out | Where-Object { \$_ -like "\$wordToComplete*" } | ForEach-Object {
    [System.Management.Automation.CompletionResult]::new(\$_, \$_, 'ParameterValue', \$_)
  }
}
''';
  }
}

Future<String> _uniqueFilename(Directory dir, String desired) async {
  final base = desired.replaceAll('.md', '');
  var name = desired;
  var i = 1;
  final sep = Platform.pathSeparator;
  while (await File('${dir.path}$sep$name').exists()) {
    name = '$base-$i.md';
    i++;
  }
  return name;
}

String _slugify(String input) {
  final s = input
      .toLowerCase()
      .trim()
      .replaceAll(RegExp(r'[^\w\s-]'), '')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'-+'), '-');
  return s.isEmpty ? 'change' : s;
}

Future<List<Changeset>> _readChangesets(Directory dir) async {
  final files = await dir
      .list(recursive: false)
      .where((e) => e is File)
      .cast<File>()
      .where((f) => f.path.endsWith('.md'))
      .toList();

  final out = <Changeset>[];
  for (final f in files) {
    if (_basename(f.path).startsWith('.')) continue;
    final content = await f.readAsString();
    out.add(_parseChangeset(content, _basename(f.path)));
  }
  return out;
}

Changeset _parseChangeset(String content, String filename) {
  String? typeStr;
  String? scope;
  String? package;
  String? summary;

  for (final rawLine in const LineSplitter().convert(content)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) continue;

    if (line.toLowerCase().startsWith('type:')) {
      typeStr = line.substring('type:'.length).trim().toLowerCase();
    } else if (line.toLowerCase().startsWith('scope:')) {
      scope = line.substring('scope:'.length).trim();
      if (scope.isEmpty) scope = null;
    } else if (line.toLowerCase().startsWith('package:')) {
      package = line.substring('package:'.length).trim();
      if (package.isEmpty) package = null;
    } else if (line.toLowerCase().startsWith('summary:')) {
      summary = line.substring('summary:'.length).trim();
    }
  }

  if (typeStr == null || summary == null || summary.isEmpty) {
    throw FormatException(
      'Invalid changeset $filename. Need: type:, summary:.',
    );
  }

  final type = switch (typeStr) {
    'major' => Bump.major,
    'minor' => Bump.minor,
    'patch' => Bump.patch,
    _ => throw FormatException('Invalid type "$typeStr" in $filename'),
  };

  return Changeset(
    type: type,
    scope: scope,
    package: package,
    summary: summary,
    filename: filename,
  );
}

Bump _decideBump(List<Changeset> list) {
  if (list.any((c) => c.type == Bump.major)) return Bump.major;
  if (list.any((c) => c.type == Bump.minor)) return Bump.minor;
  return Bump.patch;
}

/// Returns (version, hasBuildNumber)
/// [hasBuildNumber] is true when pubspec, uses Flutter format (X.Y.Z+build)
/// else for Dart format (X.Y.Z)
(SemVer, bool) _readPubspecVersion(String pubspecText) {
  final flutterRe = RegExp(
    r'^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)\s*$',
    multiLine: true,
  );
  final flutterM = flutterRe.firstMatch(pubspecText);
  if (flutterM != null) {
    return (SemVer.parseFlutterVersion(flutterM.group(1)!), true);
  }

  final dartRe = RegExp(
    r'^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$',
    multiLine: true,
  );
  final dartM = dartRe.firstMatch(pubspecText);
  if (dartM != null) {
    return (SemVer.parseVersion(dartM.group(1)!), false);
  }
  throw FormatException(
    'Could not find "version: X.Y.Z" or "version: X.Y.Z+N" in pubspec.yaml',
  );
}

String _replacePubspecVersion(String pubspecText, String newVersion) {
  final re = RegExp(
    r'^(\s*version:\s*)([0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9]+)?)(\s*)$',
    multiLine: true,
  );
  final updated = pubspecText.replaceFirstMapped(re, (m) {
    return '${m.group(1)}$newVersion${m.group(3)}';
  });
  if (updated == pubspecText) {
    throw StateError('Failed to update pubspec.yaml version line.');
  }
  return updated;
}

Map<String, List<Changeset>> _groupByScope(List<Changeset> list) {
  final map = <String, List<Changeset>>{};
  for (final cs in list) {
    final key = (cs.scope == null || cs.scope!.trim().isEmpty)
        ? 'general'
        : cs.scope!.trim();
    map.putIfAbsent(key, () => []).add(cs);
  }
  final keys = map.keys.toList()..sort();
  final out = <String, List<Changeset>>{};
  for (final k in keys) {
    final items = map[k]!..sort((a, b) => a.summary.compareTo(b.summary));
    out[k] = items;
  }
  return out;
}

String _buildReleaseNotes({
  required String versionName,
  required Map<String, List<Changeset>> grouped,
  String? packageName,
}) {
  final b = StringBuffer();
  if (packageName != null) {
    b.writeln('## $packageName $versionName');
  } else {
    b.writeln('## $versionName');
  }
  b.writeln();

  for (final entry in grouped.entries) {
    final title = entry.key == 'general' ? 'General' : entry.key;
    b.writeln('### $title');
    for (final cs in entry.value) {
      b.writeln('- ${cs.summary}');
    }
    b.writeln();
  }

  return b.toString().trimRight();
}

String _prependChangelog(String existing, String releaseNotes) {
  final headerRe = RegExp(r'^\s*#\s*Changelog\s*$', multiLine: true);
  if (!headerRe.hasMatch(existing)) {
    existing = '# Changelog\n\n$existing';
  }

  final lines = const LineSplitter().convert(existing);
  final out = StringBuffer();

  var inserted = false;
  for (final line in lines) {
    out.writeln(line);
    if (!inserted && line.trim().toLowerCase() == '# changelog') {
      out.writeln();
      out.writeln(releaseNotes);
      out.writeln();
      inserted = true;
    }
  }
  return out.toString();
}

String _basename(String path) {
  final sep = Platform.pathSeparator;
  final idx = path.lastIndexOf(sep);
  return idx >= 0 ? path.substring(idx + 1) : path;
}
