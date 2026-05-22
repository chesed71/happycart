import 'package:flutter_dotenv/flutter_dotenv.dart';

typedef EnvFileLoader = Future<void> Function(String fileName);

class EnvLoadException implements Exception {
  final String message;
  EnvLoadException(this.message);

  @override
  String toString() => 'EnvLoadException: $message';
}

class Env {
  static const _supportedFlavors = {'development', 'staging', 'production'};

  static String? _flavor;

  static String get flavor {
    final f = _flavor;
    if (f == null) {
      throw EnvLoadException('Env.load() has not been called yet.');
    }
    return f;
  }

  static String get supabaseUrl => _required('SUPABASE_URL');

  static String get supabaseAnonKey => _required('SUPABASE_ANON_KEY');

  static String _required(String key) {
    if (!dotenv.isInitialized) {
      throw EnvLoadException(
        'Env.load() has not been called yet — cannot read "$key".',
      );
    }
    final value = dotenv.maybeGet(key);
    if (value == null || value.isEmpty) {
      throw EnvLoadException(
        '$key is missing or empty in .env.${_flavor ?? '<unknown>'}. '
        'Check the .env file content and pubspec.yaml asset registration.',
      );
    }
    return value;
  }

  static Future<void> load({
    String? flavorOverride,
    EnvFileLoader? loader,
  }) async {
    final resolved =
        flavorOverride ?? const String.fromEnvironment('FLAVOR');

    if (resolved.isEmpty) {
      throw EnvLoadException(
        'FLAVOR is not set. Pass --dart-define=FLAVOR=development|staging|production '
        '(or flavorOverride in tests).',
      );
    }
    if (!_supportedFlavors.contains(resolved)) {
      throw EnvLoadException(
        'Unsupported flavor "$resolved". '
        'Expected one of: ${_supportedFlavors.join(', ')}.',
      );
    }

    final fileName = '.env.$resolved';
    final effectiveLoader = loader ?? (name) => dotenv.load(fileName: name);

    try {
      await effectiveLoader(fileName);
    } catch (e) {
      throw EnvLoadException(
        'Failed to load $fileName: $e. '
        'Ensure the file exists and is declared under flutter > assets in pubspec.yaml.',
      );
    }

    for (final key in const ['SUPABASE_URL', 'SUPABASE_ANON_KEY']) {
      final value = dotenv.maybeGet(key);
      if (value == null || value.isEmpty) {
        throw EnvLoadException(
          '$key is missing or empty in $fileName for flavor="$resolved". '
          'Check the .env file content and pubspec.yaml asset registration.',
        );
      }
    }

    _flavor = resolved;
  }

  static void reset() {
    _flavor = null;
    if (dotenv.isInitialized) {
      dotenv.clean();
    }
  }
}
