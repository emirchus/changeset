import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

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

class Changeset {
  final Bump type;
  final String? scope;
  final String summary;
  final String filename;

  Changeset({
    required this.type,
    required this.summary,
    required this.filename,
    this.scope,
  });
}

Future<void> main(List<String> args) async {
  final runner = CommandRunner<void>(
    'changeset',
    'A lightweight CLI to manage changesets for Dart/Flutter projects.',
  )
    ..addCommand(AddCommand())
    ..addCommand(ReleaseCommand());

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
      ..addOption(
        'scope',
        help: 'Optional scope/module for changelog grouping',
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

    final type = switch (typeStr.toLowerCase()) {
      'major' => Bump.major,
      'minor' => Bump.minor,
      'patch' => Bump.patch,
      _ => throw UsageException(
        'Invalid --type "$typeStr" (use major|minor|patch)',
        argParser.usage,
      ),
    };

    final dir = Directory('.changesets');
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
      ..writeln('scope: ${scopeVal ?? ''}'.trimRight())
      ..writeln('summary: ${summary.trim()}')
      ..writeln();

    final text = content.toString();
    final finalText = scopeVal == null
        ? text.replaceFirst(RegExp(r'^\s*scope:.*\n', multiLine: true), '')
        : text;

    final file = File('${dir.path}/${filename}');
    await file.writeAsString(finalText);

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
    argParser.addFlag(
      'dry-run',
      help: 'Show release plan without modifying files',
    );
  }

  @override
  Future<void> run() async {
    final dryRun = argResults!['dry-run'] as bool;

    final changesetDir = Directory('.changesets');
    final pubspecFile = File('pubspec.yaml');
    final changelogFile = File('CHANGELOG.md');

    if (!await pubspecFile.exists()) {
      stderr.writeln('ERROR: pubspec.yaml not found.');
      exitCode = 2;
      return;
    }
    if (!await changesetDir.exists()) {
      stderr.writeln('ERROR: .changesets folder not found.');
      exitCode = 2;
      return;
    }

    final changesets = await _readChangesets(changesetDir);
    if (changesets.isEmpty) {
      print('No changesets found. Nothing to release.');
      return;
    }

    final pubspecText = await pubspecFile.readAsString();
    final (current, hasBuildNumber) = _readPubspecVersion(pubspecText);
    final bump = _decideBump(changesets);
    final next = current.bump(bump, bumpBuild: hasBuildNumber);

    final currentVersionStr = hasBuildNumber
        ? current.flutterVersion
        : current.versionName;
    final nextVersionStr = hasBuildNumber
        ? next.flutterVersion
        : next.versionName;

    final now = DateTime.now();
    final dateStr =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    final grouped = _groupByScope(changesets);

    final releaseNotes = _buildReleaseNotes(
      versionName: next.versionName,
      date: dateStr,
      grouped: grouped,
    );

    print('--- Release Plan ---');
    print('Current: $currentVersionStr');
    print('Bump:    ${bump.name}');
    print('Next:    $nextVersionStr');
    print('Changesets: ${changesets.length}');
    print('');
    print('Changelog entry preview:\n$releaseNotes');

    if (dryRun) {
      print('\n[dry-run] No files were modified.');
      return;
    }

    final updatedPubspec = _replacePubspecVersion(pubspecText, nextVersionStr);
    await pubspecFile.writeAsString(updatedPubspec);
    print('\nUpdated pubspec.yaml to version: $nextVersionStr');

    final existingChangelog = await changelogFile.exists()
        ? await changelogFile.readAsString()
        : '# Changelog\n\n';
    final updatedChangelog = _prependChangelog(existingChangelog, releaseNotes);
    await changelogFile.writeAsString(updatedChangelog);
    print('Updated CHANGELOG.md');

    final archiveDir = Directory('.changesets/archived/${next.versionName}');
    await archiveDir.create(recursive: true);

    for (final cs in changesets) {
      final from = File('${changesetDir.path}/${cs.filename}');
      final to = File('${archiveDir.path}/${cs.filename}');
      if (await from.exists()) await from.rename(to.path);
    }
    print('Archived changesets to: ${archiveDir.path}');
    print('\nDone.');
    print('Next steps (manual):');
    print(
      '- git add pubspec.yaml CHANGELOG.md .changesets/archived/${next.versionName}',
    );
    print('- git commit -m "chore(release): v${next.versionName}"');
    print('- git tag v${next.versionName}');
    print('- git push --follow-tags');
  }
}

Future<String> _uniqueFilename(Directory dir, String desired) async {
  final base = desired.replaceAll('.md', '');
  var name = desired;
  var i = 1;
  while (await File('${dir.path}/$name').exists()) {
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
  required String date,
  required Map<String, List<Changeset>> grouped,
}) {
  final b = StringBuffer();
  b.writeln('## $versionName - $date');
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
