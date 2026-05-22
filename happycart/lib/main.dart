import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/env.dart';
import 'firebase_options.dart';

Future<void> main() async {
  // Crashlytics 가 Dart zone 의 비동기 에러까지 잡으려면 runApp 호출도 같은 zone
  // 안에서 일어나야 한다. runZonedGuarded 로 전체를 감싼다.
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await Env.load();
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );

      // Flutter framework 에서 발생한 동기 에러를 Crashlytics 로.
      FlutterError.onError =
          FirebaseCrashlytics.instance.recordFlutterFatalError;
      // Flutter framework 바깥(플랫폼 / native 호출 등) 의 에러도 Crashlytics 로.
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };
      // debug 빌드에서는 Crashlytics 수집을 비활성 (테스터 단계만 데이터 의미 있음).
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(!kDebugMode);

      await Supabase.initialize(
        url: Env.supabaseUrl,
        anonKey: Env.supabaseAnonKey,
      );

      runApp(const ProviderScope(child: HappyCartApp()));
    },
    (error, stack) {
      // zone 바깥에서 잡힌 에러도 Crashlytics 로.
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    },
  );
}
