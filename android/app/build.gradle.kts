plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.duohuo.nuist_sta_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    val signingKeyPath = System.getenv("SIGNING_KEY_PATH")
    val signingStorePassword = System.getenv("KEYSTORE_PASSWORD")
    val signingKeyAlias = System.getenv("KEY_ALIAS")
    val signingKeyPassword = System.getenv("KEY_PASSWORD")
    val configuredApplicationIdSuffix = System.getenv("APP_ID_SUFFIX") ?: ".debug"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.duohuo.nuist_sta_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        debug {
            applicationIdSuffix = configuredApplicationIdSuffix
        }

        release {
            applicationIdSuffix = configuredApplicationIdSuffix
            signingConfig = if (listOf(
                    signingKeyPath,
                    signingStorePassword,
                    signingKeyAlias,
                    signingKeyPassword,
                ).all { !it.isNullOrBlank() }
            ) {
                signingConfigs.create("release") {
                    storeFile = file(signingKeyPath!!)
                    storePassword = signingStorePassword
                    keyAlias = signingKeyAlias
                    keyPassword = signingKeyPassword
                }
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
