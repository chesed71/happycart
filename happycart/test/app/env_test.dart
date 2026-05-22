import 'package:happycart/app/env.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(Env.reset);
  tearDown(Env.reset);

  EnvFileLoader stringLoader(Map<String, String> envByFile) {
    return (fileName) async {
      final contents = envByFile[fileName];
      if (contents == null) {
        throw StateError('Unexpected file requested: $fileName');
      }
      dotenv.loadFromString(envString: contents);
    };
  }

  group('Env.load flavor selection', () {
    test('development flavor loads .env.development', () async {
      String? requestedFile;
      await Env.load(
        flavorOverride: 'development',
        loader: (fileName) async {
          requestedFile = fileName;
          dotenv.loadFromString(
            envString:
                'SUPABASE_URL=https://dev.example\nSUPABASE_ANON_KEY=devkey',
          );
        },
      );

      expect(requestedFile, '.env.development');
      expect(Env.flavor, 'development');
      expect(Env.supabaseUrl, 'https://dev.example');
      expect(Env.supabaseAnonKey, 'devkey');
    });

    test('staging flavor loads .env.staging', () async {
      String? requestedFile;
      await Env.load(
        flavorOverride: 'staging',
        loader: (fileName) async {
          requestedFile = fileName;
          dotenv.loadFromString(
            envString:
                'SUPABASE_URL=https://staging.example\nSUPABASE_ANON_KEY=stagingkey',
          );
        },
      );

      expect(requestedFile, '.env.staging');
      expect(Env.flavor, 'staging');
      expect(Env.supabaseUrl, 'https://staging.example');
    });

    test('production flavor loads .env.production', () async {
      String? requestedFile;
      await Env.load(
        flavorOverride: 'production',
        loader: (fileName) async {
          requestedFile = fileName;
          dotenv.loadFromString(
            envString:
                'SUPABASE_URL=https://prod.example\nSUPABASE_ANON_KEY=prodkey',
          );
        },
      );

      expect(requestedFile, '.env.production');
      expect(Env.flavor, 'production');
    });

    test('unsupported flavor throws EnvLoadException', () async {
      expect(
        () => Env.load(flavorOverride: 'bogus', loader: (_) async {}),
        throwsA(isA<EnvLoadException>()),
      );
    });

    test('empty flavor throws EnvLoadException', () async {
      expect(
        () => Env.load(flavorOverride: '', loader: (_) async {}),
        throwsA(isA<EnvLoadException>()),
      );
    });
  });

  group('Env.load failure cases', () {
    test('missing env file (loader throws) is wrapped in EnvLoadException',
        () async {
      expect(
        () => Env.load(
          flavorOverride: 'development',
          loader: (fileName) async {
            throw FileNotFoundError(fileName);
          },
        ),
        throwsA(isA<EnvLoadException>()),
      );
    });

    test('empty SUPABASE_URL throws EnvLoadException', () async {
      expect(
        () => Env.load(
          flavorOverride: 'development',
          loader: stringLoader({
            '.env.development': 'SUPABASE_URL=\nSUPABASE_ANON_KEY=somekey',
          }),
        ),
        throwsA(isA<EnvLoadException>()),
      );
    });

    test('empty SUPABASE_ANON_KEY throws EnvLoadException', () async {
      expect(
        () => Env.load(
          flavorOverride: 'development',
          loader: stringLoader({
            '.env.development':
                'SUPABASE_URL=https://dev.example\nSUPABASE_ANON_KEY=',
          }),
        ),
        throwsA(isA<EnvLoadException>()),
      );
    });

    test('missing SUPABASE_URL key throws EnvLoadException', () async {
      expect(
        () => Env.load(
          flavorOverride: 'development',
          loader: stringLoader({
            '.env.development': 'SUPABASE_ANON_KEY=somekey',
          }),
        ),
        throwsA(isA<EnvLoadException>()),
      );
    });

    test('flavor is not committed when load fails on empty SUPABASE_URL',
        () async {
      try {
        await Env.load(
          flavorOverride: 'staging',
          loader: stringLoader({
            '.env.staging': 'SUPABASE_URL=\nSUPABASE_ANON_KEY=somekey',
          }),
        );
        fail('expected EnvLoadException');
      } on EnvLoadException {
        // expected
      }
      expect(() => Env.flavor, throwsA(isA<EnvLoadException>()));
    });
  });

  group('Env getters before load', () {
    test('accessing supabaseUrl before load throws', () {
      expect(() => Env.supabaseUrl, throwsA(isA<EnvLoadException>()));
    });

    test('accessing flavor before load throws', () {
      expect(() => Env.flavor, throwsA(isA<EnvLoadException>()));
    });
  });
}
