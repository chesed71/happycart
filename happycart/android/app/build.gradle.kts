import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing 설정 — key.properties 는 .gitignore 에 들어가며 로컬·CI 환경에서만
// 존재한다. 파일이 없으면 release 빌드는 debug 키로 fallback (CI 미설정 환경 보호).
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(FileInputStream(keystorePropertiesFile))
    }
}

android {
    namespace = "com.rimonhouse.happycart"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.rimonhouse.happycart"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }

    flavorDimensions += "environment"

    // 모든 flavor 가 동일한 applicationId (com.rimonhouse.happycart) 를 사용한다.
    // Firebase 에 등록된 단일 패키지와 일치시키기 위함이며, 환경 분리는 .env.* 파일과
    // Supabase 프로젝트 분리로 이미 보장된다. 같은 디바이스에 dev/prod 동시 설치가
    // 필요해지면 Firebase 에 별도 Android 앱(.dev, .staging) 을 등록한 뒤
    // applicationIdSuffix 를 다시 살리는 방식으로 전환한다.
    productFlavors {
        create("development") {
            dimension = "environment"
            versionNameSuffix = "-dev"
        }
        create("staging") {
            dimension = "environment"
            versionNameSuffix = "-staging"
        }
        create("production") {
            dimension = "environment"
        }
    }
}

flutter {
    source = "../.."
}
