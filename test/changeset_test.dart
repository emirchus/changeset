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

    test('constructor with package', () {
      final cs = Changeset(
        type: Bump.minor,
        summary: 'bar',
        filename: 'c.md',
        package: 'my_pkg',
      );
      expect(cs.package, 'my_pkg');
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
        ['run', 'bin/changeset.dart', '--help'],
        runInShell: false,
        workingDirectory: projectRoot,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('Usage'));
    });

    test('-h shows help', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/changeset.dart', '-h'],
        runInShell: false,
        workingDirectory: projectRoot,
      );
      expect(result.exitCode, 0);
      expect(result.stdout, contains('Usage'));
    });

    test('unknown command exits with 64 and message in stderr', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/changeset.dart', 'unknown'],
        runInShell: false,
        workingDirectory: projectRoot,
      );
      expect(result.exitCode, 64);
      expect(result.stderr, contains('Could not find a command'));
    });

    test('add without --type and --summary exits with 64', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/changeset.dart', 'add'],
        runInShell: false,
        workingDirectory: projectRoot,
      );
      expect(result.exitCode, 64);
      expect(result.stderr, contains('add requires --type and --summary'));
    });

    test('add with --type but without --summary exits with 64', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/changeset.dart', 'add', '--type', 'minor'],
        runInShell: false,
        workingDirectory: projectRoot,
      );
      expect(result.exitCode, 64);
      expect(result.stderr, contains('add requires --type and --summary'));
    });
  });

  group('Config and workspace', () {
    test(
      'resolveConfig finds changeset.yaml and returns root and packages',
      () async {
        final temp = await Directory.systemTemp.createTemp('changeset_test_');
        try {
          final configFile = File('${temp.path}/changeset.yaml');
          await configFile.writeAsString('''
          changelogPath: ROOT_CHANGELOG.md
          changesetsPath: .changesets
          packages:
            foo: packages/foo
            bar: packages/bar
          ''');
          final resolved = await resolveConfig(cwd: temp);
          expect(resolved.root.path, temp.path);
          expect(resolved.config.changelogPath, 'ROOT_CHANGELOG.md');
          expect(resolved.config.changesetsPath, '.changesets');
          expect(resolved.config.packages['foo'], 'packages/foo');
          expect(resolved.config.packages['bar'], 'packages/bar');
        } finally {
          await temp.delete(recursive: true);
        }
      },
    );

    test(
      'add -W creates changeset in root .changesets with package: line',
      () async {
        final temp = await Directory.systemTemp.createTemp('changeset_mono_');
        final sep = Platform.pathSeparator;
        try {
          await File('${temp.path}${sep}changeset.yaml').writeAsString('''
packages:
  foo: packages/foo
''');
          await Directory(
            '${temp.path}${sep}packages${sep}foo',
          ).create(recursive: true);
          await File(
            '${temp.path}${sep}packages${sep}foo${sep}pubspec.yaml',
          ).writeAsString('name: foo\nversion: 1.0.0\n');
          final binPath =
              '${Directory.current.path}$sep'
              'bin$sep'
              'changeset.dart';

          final result = await Process.run(
            'dart',
            [
              'run',
              binPath,
              'add',
              '-W',
              'foo',
              '--type',
              'patch',
              '--summary',
              'test change',
            ],
            runInShell: false,
            workingDirectory: temp.path,
          );
          expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');

          final changesetsDir = Directory('${temp.path}$sep.changesets');
          expect(await changesetsDir.exists(), isTrue);
          final files = await changesetsDir
              .list()
              .where((e) => e is File && e.path.endsWith('.md'))
              .toList();
          expect(files.length, 1);
          final content = await (files.first as File).readAsString();
          expect(content, contains('package: foo'));
          expect(content, contains('summary: test change'));
        } finally {
          await temp.delete(recursive: true);
        }
      },
    );

    test('release -W updates package pubspec and root changelog', () async {
      final temp = await Directory.systemTemp.createTemp('changeset_release_');
      final sep = Platform.pathSeparator;
      try {
        await File('${temp.path}${sep}changeset.yaml').writeAsString('''
        packages:
          foo: packages/foo
        ''');
        await Directory('${temp.path}$sep.changesets').create(recursive: true);
        await Directory(
          '${temp.path}${sep}packages${sep}foo',
        ).create(recursive: true);
        await File(
          '${temp.path}${sep}packages${sep}foo${sep}pubspec.yaml',
        ).writeAsString('name: foo\nversion: 1.0.0\n');
        final csFile = File(
          '${temp.path}$sep.changesets${sep}2025-01-01-test.md',
        );
        await csFile.writeAsString('''
        type: patch
        package: foo
        summary: A fix
        ''');
        final binPath =
            '${Directory.current.path}$sep'
            'bin$sep'
            'changeset.dart';

        final result = await Process.run(
          'dart',
          ['run', binPath, 'release', '-W', 'foo'],
          runInShell: false,
          workingDirectory: temp.path,
        );
        expect(result.exitCode, 0, reason: 'stderr: ${result.stderr}');

        final pubspecContent = await File(
          '${temp.path}${sep}packages${sep}foo${sep}pubspec.yaml',
        ).readAsString();
        expect(pubspecContent, contains('version: 1.0.1'));

        final changelogFile = File('${temp.path}${sep}CHANGELOG.md');
        expect(await changelogFile.exists(), isTrue);
        final changelogContent = await changelogFile.readAsString();
        expect(changelogContent, contains('foo 1.0.1'));
        expect(changelogContent, contains('A fix'));

        final archivedDir = Directory(
          '${temp.path}$sep.changesets${sep}archived${sep}foo${sep}1.0.1',
        );
        expect(await archivedDir.exists(), isTrue);
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });
}
