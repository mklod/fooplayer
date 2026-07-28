import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fooplayer_app/model/app_config.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('app_config'));
  tearDown(() async => tmp.delete(recursive: true));

  File cfgFile() => File('${tmp.path}/config.json');

  group('readConfigFile', () {
    test('missing file returns an empty map', () {
      expect(readConfigFile(cfgFile()), isEmpty);
    });

    test('valid config round-trips as-is', () {
      final f = cfgFile()
        ..writeAsStringSync(
          jsonEncode({
            'libraryRoots': ['L:\\music'],
          }),
        );
      expect(readConfigFile(f), {
        'libraryRoots': ['L:\\music'],
      });
    });

    test(
      'corrupt (invalid JSON) config is backed up to .bad and an empty map is returned',
      () {
        final f = cfgFile()..writeAsStringSync('{not valid json');
        final result = readConfigFile(f);
        expect(result, isEmpty);
        final backup = File('${f.path}.bad');
        expect(backup.existsSync(), isTrue);
        expect(backup.readAsStringSync(), '{not valid json');
        // The original bad file is left in place too -- only a copy is made.
        expect(f.existsSync(), isTrue);
      },
    );

    test(
      'valid JSON that is not an object is treated as corrupt (backed up, empty map)',
      () {
        final f = cfgFile()
          ..writeAsStringSync(jsonEncode(['not', 'an', 'object']));
        final result = readConfigFile(f);
        expect(result, isEmpty);
        expect(File('${f.path}.bad').existsSync(), isTrue);
      },
    );
  });

  group('migrateConfig', () {
    const defaultRoot = r'L:\music (original structure)';

    test('first run / empty config defaults to a single default root', () {
      final config = migrateConfig({}, defaultRoot: defaultRoot);
      expect(config.libraryRoots, [defaultRoot]);
      expect(config.raw['libraryRoots'], [defaultRoot]);
      expect(config.raw.containsKey('libraryRoot'), isFalse);
    });

    test(
      'migrates the old singular libraryRoot key to a one-element libraryRoots list',
      () {
        final config = migrateConfig({
          'libraryRoot': r'D:\music',
          'ui': {'sidebarWidth': 240},
        }, defaultRoot: defaultRoot);
        expect(config.libraryRoots, [r'D:\music']);
        expect(config.raw['libraryRoots'], [r'D:\music']);
        expect(
          config.raw.containsKey('libraryRoot'),
          isFalse,
          reason: 'the old v1 key must not survive migration',
        );
        // Unrelated keys (e.g. Task 3's "ui" prefs) are preserved untouched.
        expect(config.raw['ui'], {'sidebarWidth': 240});
      },
    );

    test('an already-v2 config with libraryRoots passes through unchanged', () {
      final config = migrateConfig({
        'libraryRoots': [r'D:\music', r'E:\more music'],
        'ui': {'filterHeight': 200},
      }, defaultRoot: defaultRoot);
      expect(config.libraryRoots, [r'D:\music', r'E:\more music']);
      expect(config.raw['ui'], {'filterHeight': 200});
    });

    test(
      'an empty libraryRoots list is treated like no roots configured and defaults',
      () {
        final config = migrateConfig({
          'libraryRoots': [],
        }, defaultRoot: defaultRoot);
        expect(config.libraryRoots, [defaultRoot]);
      },
    );

    test('does not mutate the map passed in', () {
      final input = {'libraryRoot': r'D:\music'};
      migrateConfig(input, defaultRoot: defaultRoot);
      expect(input, {'libraryRoot': r'D:\music'});
    });

    test('toJson layers libraryRoots over every preserved key', () {
      final config = migrateConfig({
        'libraryRoot': r'D:\music',
        'ui': {'sidebarWidth': 240},
      }, defaultRoot: defaultRoot);
      expect(config.toJson(), {
        'ui': {'sidebarWidth': 240},
        'libraryRoots': [r'D:\music'],
      });
    });
  });

  group('writeConfigFile', () {
    test('round-trips through readConfigFile and leaves no .tmp residue', () {
      final f = cfgFile();
      writeConfigFile(f, {
        'libraryRoots': [r'L:\music'],
        'ui': {'x': 1},
      });

      expect(f.existsSync(), isTrue);
      expect(readConfigFile(f), {
        'libraryRoots': [r'L:\music'],
        'ui': {'x': 1},
      });
      expect(File('${f.path}.tmp').existsSync(), isFalse);
    });

    test('creates the parent directory if it does not exist yet', () {
      final nested = File('${tmp.path}/nested/dir/config.json');
      expect(nested.parent.existsSync(), isFalse);

      writeConfigFile(nested, {'libraryRoots': <String>[]});

      expect(nested.existsSync(), isTrue);
    });

    test('a second write replaces the first, with no .tmp residue left '
        'behind either time', () {
      final f = cfgFile();
      writeConfigFile(f, {
        'libraryRoots': [r'L:\music'],
      });
      writeConfigFile(f, {
        'libraryRoots': [r'D:\more music'],
      });

      expect(readConfigFile(f), {
        'libraryRoots': [r'D:\more music'],
      });
      expect(File('${f.path}.tmp').existsSync(), isFalse);
    });
  });

  group('needsMigrationWrite', () {
    test('true when there is no libraryRoots key yet', () {
      expect(needsMigrationWrite({}), isTrue);
      expect(needsMigrationWrite({'libraryRoot': r'D:\music'}), isTrue);
    });

    test(
      'true when the old libraryRoot key is still present alongside libraryRoots',
      () {
        expect(
          needsMigrationWrite({
            'libraryRoots': [r'D:\music'],
            'libraryRoot': r'D:\music',
          }),
          isTrue,
        );
      },
    );

    test('false for an already-migrated v2 config', () {
      expect(
        needsMigrationWrite({
          'libraryRoots': [r'D:\music'],
        }),
        isFalse,
      );
    });
  });
}
