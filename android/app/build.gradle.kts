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
    val teamDebugSigningConfig = signingConfigs.create("teamDebug") {
        storeFile = file("debug-team.keystore")
        storePassword = "android"
        keyAlias = "androiddebugkey"
        keyPassword = "android"
    }

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
            signingConfig = teamDebugSigningConfig
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

// Rust 核心随 APK 从源码构建，不提交预编译的 .so，也不需要额外 Flutter 插件。
val vpnRustRoot = rootProject.file("../native/vpn")
val vpnRustTarget = rootProject.layout.buildDirectory.dir("rust-vpn")
val vpnJniLibs = layout.buildDirectory.dir("generated/vpnJniLibs")

abstract class BuildVpnRust : Exec() {
    @get:OutputDirectory
    abstract val jniOutputDirectory: DirectoryProperty
}

val buildVpnRust by tasks.registering(BuildVpnRust::class) {
    jniOutputDirectory.set(vpnJniLibs)
    workingDir(vpnRustRoot)
    inputs.property("targetPlatform", providers.gradleProperty("target-platform").orElse("android-arm64"))
    inputs.property("ndkVersion", android.ndkVersion)
    inputs.files(fileTree(vpnRustRoot) {
        include("src/**/*.rs", "Cargo.toml", "Cargo.lock", "rust-toolchain.toml")
    })
    doFirst {
        val platforms = providers.gradleProperty("target-platform").orNull
        require(platforms == null || platforms.split(",").all { it == "android-arm64" }) {
            "校园 VPN 当前随项目仅支持 Android arm64，请传入 --target-platform android-arm64"
        }
        val sdk = androidComponents.sdkComponents.sdkDirectory.get().asFile
        val windows = System.getProperty("os.name").lowercase().contains("windows")
        val hostTag = when {
            windows -> "windows-x86_64"
            System.getProperty("os.name").lowercase().contains("mac") -> "darwin-x86_64"
            else -> "linux-x86_64"
        }
        val bin = sdk.resolve("ndk/${android.ndkVersion}/toolchains/llvm/prebuilt/$hostTag/bin")
        val linker = bin.resolve("aarch64-linux-android21-clang${if (windows) ".cmd" else ""}")
        require(linker.isFile) { "未找到 Android NDK 编译器：$linker" }
        environment("CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER", linker.absolutePath)
        environment("CC_aarch64_linux_android", linker.absolutePath)
        environment("AR_aarch64_linux_android", bin.resolve("llvm-ar${if (windows) ".exe" else ""}").absolutePath)
        val cargo = providers.environmentVariable("VPN_CARGO").orNull ?: "cargo"
        commandLine(cargo, "build", "--release", "--locked", "--target", "aarch64-linux-android",
            "--target-dir", vpnRustTarget.get().asFile.absolutePath)
    }
    doLast {
        copy {
            from(vpnRustTarget.get().file("aarch64-linux-android/release/libnuist_vpn.so"))
            into(vpnJniLibs.get().dir("arm64-v8a"))
        }
    }
}

androidComponents.onVariants { variant ->
    variant.sources.jniLibs?.addGeneratedSourceDirectory(buildVpnRust) { it.jniOutputDirectory }
}

tasks.named("preBuild").configure { dependsOn(buildVpnRust) }
