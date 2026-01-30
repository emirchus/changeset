import 'dart:io';

import 'package:test/test.dart';

import '../bin/changeset.dart';

void main() {
  group('SemVer', () {
    test('constructor & getters: versionName - flutterVersion', () {
      const v = SemVer(1, 2, 3, 4);
      expect(v.versionName, '1.2.3');
      expect(v.flutterVersion, '1.2.3+4');
    });

    group('parseVersion', () {
      test('Dart style: 1.2.3 (build 0)', () {
        final v = SemVer.parseVersion('1.2.3');
        expect(v.major, 1);
        expect(v.minor, 2);
        expect(v.patch, 3);
        expect(v.build, 0);
      });

      test('Dart style: 0.0.1 (espaces)', () {
        final v = SemVer.parseVersion('  0.0.1  ');
        expect(v.versionName, '0.0.1');
        expect(v.build, 0);
      });

      test('Flutter style: 1.2.3+4', () {
        final v = SemVer.parseVersion('1.2.3+4');
        expect(v.major, 1);
        expect(v.minor, 2);
        expect(v.patch, 3);
        expect(v.build, 4);
      });
    });

    group('parseFlutterVersion', () {
      test('valid: 1.2.3+4', () {
        final v = SemVer.parseFlutterVersion('1.2.3+4');
        expect(v.major, 1);
        expect(v.minor, 2);
        expect(v.patch, 3);
        expect(v.build, 4);
      });

      test('valid: 0.0.1+0 (spaces)', () {
        final v = SemVer.parseFlutterVersion('  0.0.1+0  ');
        expect(v.major, 0);
        expect(v.minor, 0);
        expect(v.patch, 1);
        expect(v.build, 0);
      });

      test('invalid: without +N (1.2.3)', () {
        expect(
          () => SemVer.parseFlutterVersion('1.2.3'),
          throwsFormatException,
        );
      });

      test('invalid: only two segments (1.2)', () {
        expect(() => SemVer.parseFlutterVersion('1.2'), throwsFormatException);
      });

      test('invalid: build not numeric (1.2.3+abc)', () {
        expect(
          () => SemVer.parseFlutterVersion('1.2.3+abc'),
          throwsFormatException,
        );
      });

      test('invalid: empty string', () {
        expect(() => SemVer.parseFlutterVersion(''), throwsFormatException);
      });
    });

    group('bump', () {
      test('Bump.major increments major and resets minor/patch, build+1', () {
        const current = SemVer(1, 0, 0, 1);
        final next = current.bump(Bump.major);
        expect(next.versionName, '2.0.0');
        expect(next.build, 2);
      });

      test('Bump.minor increments minor and resets patch, build+1', () {
        const current = SemVer(1, 0, 0, 1);
        final next = current.bump(Bump.minor);
        expect(next.versionName, '1.1.0');
        expect(next.build, 2);
      });

      test('Bump.patch increments patch, build+1', () {
        const current = SemVer(1, 0, 0, 1);
        final next = current.bump(Bump.patch);
        expect(next.versionName, '1.0.1');
        expect(next.build, 2);
      });

      test('Bump.none keeps X.Y.Z, build+1 by default', () {
        const current = SemVer(1, 2, 3, 1);
        final next = current.bump(Bump.none);
        expect(next.versionName, '1.2.3');
        expect(next.build, 2);
      });

      test('bumpBuild: false keeps build the same', () {
        const current = SemVer(1, 0, 0, 5);
        final next = current.bump(Bump.patch, bumpBuild: false);
        expect(next.versionName, '1.0.1');
        expect(next.build, 5);
      });
    });
  });

  group('Changeset', () {
    test('constructor with scope', () {
      final cs = Changeset(
        type: Bump.minor,
        summary: 'x',
        filename: 'a.md',
        scope: 's',
      );
      expect(cs.type, Bump.minor);
      expect(cs.scope, 's');
      expect(cs.summary, 'x');
      expect(cs.filename, 'a.md');
    });

    test('constructor without scope', () {
      final cs = Changeset(type: Bump.patch, summary: 'foo', filename: 'b.md');
      expect(cs.type, Bump.patch);
      expect(cs.scope, isNull);
      expect(cs.summary, 'foo');
      expect(cs.filename, 'b.md');
    });
  });

  group('CLI', () {
    late String projectRoot;

    setUpAll(() {
      projectRoot = Directory.current.path;
    });

    test('--help shows Usage and exits with 0', () async {
      final result = await Process.run(
        'dart',
        ['run', 'lib/src/changeset_script.dart', '--help'],
        runInShell: false,
        workingDirectory: projectRoot,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('Usage'));
    });

    test('-h shows help', () async {
      final result = await Process.run(
        'dart',
        ['run', 'lib/src/changeset_script.dart', '-h'],
        runInShell: false,
        workingDirectory: projectRoot,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('Usage'));
    });

    test('unknown command exits with 64 and message in stderr', () async {
      final result = await Process.run(
        'dart',
        ['run', 'lib/src/changeset_script.dart', 'unknown'],
        runInShell: false,
        workingDirectory: projectRoot,
      );
      expect(result.exitCode, 64);
      expect(result.stderr, contains('Could not find a command'));
    });

    test('add without --type and --summary exits with 64', () async {
      final result = await Process.run(
        'dart',
        ['run', 'lib/src/changeset_script.dart', 'add'],
        runInShell: false,
        workingDirectory: projectRoot,
      );
      expect(result.exitCode, 64);
      expect(result.stderr, contains('add requires --type and --summary'));
    });

    test('add with --type but without --summary exits with 64', () async {
      final result = await Process.run(
        'dart',
        ['run', 'lib/src/changeset_script.dart', 'add', '--type', 'minor'],
        runInShell: false,
        workingDirectory: projectRoot,
      );
      expect(result.exitCode, 64);
      expect(result.stderr, contains('add requires --type and --summary'));
    });
  });
}
