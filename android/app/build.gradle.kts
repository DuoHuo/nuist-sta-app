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

        ndk {
            // 清空 Flutter Gradle Plugin 默认注入的三个架构
            abiFilters.clear()
            // 仅保留 arm64-v8a，剥离 armeabi-v7a 和 x86_64 库
            abiFilters.add("arm64-v8a")
        }
    }

    // 强行排除非 arm64-v8a 的所有 .so 库
    packaging {
        jniLibs {
            excludes += listOf(
                "lib/armeabi-v7a/**",
                "lib/x86/**",
                "lib/x86_64/**",
                "**/armeabi-v7a/**",
                "**/x86/**",
                "**/x86_64/**"
            )
        }
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

// ===== 校内服务地址：与 Dart 侧共用 lib/core/config/campus_config.dart =====
// 该文件里是 hex 编码；Android 资源 XML 不能执行 Dart，所以这里把 hex 解出来
// 生成 network_security_config.xml（生成物在 build/ 里，不入库）。
val campusConfigFile = rootProject.file("../lib/core/config/campus_config.dart")
val campusMapBaseUrl: String = run {
    if (!campusConfigFile.isFile) return@run ""
    val hex = Regex("_mapBaseUrlHex\\s*=\\s*'([0-9a-fA-F]+)'")
        .find(campusConfigFile.readText())
        ?.groupValues
        ?.get(1)
        .orEmpty()
    hex.chunked(2).map { it.toInt(16).toChar() }.joinToString("")
}
val campusMapHost: String = Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://([^/:]+)")
    .find(campusMapBaseUrl)
    ?.groupValues
    ?.get(1)
    .orEmpty()

abstract class GenerateNetworkSecurityConfig : DefaultTask() {
    @get:Input
    abstract val mapHost: Property<String>

    @get:Input
    abstract val debugConfig: Property<Boolean>

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun generate() {
        val host = mapHost.get()
        val debug = debugConfig.get()
        val mapDomain = when {
            host.isEmpty() -> ""
            debug -> "        <domain>$host</domain>"
            else -> "        <domain includeSubdomains=\"false\">$host</domain>"
        }
        val text = if (debug) {
            """
            <?xml version="1.0" encoding="utf-8"?>
            <!-- 由 build.gradle.kts 生成，不要手改。仅 debug 源集：信任用户安装的
                 CA 证书，让 mitmproxy / Charles 能解开 App（含 WebView）的流量。 -->
            <network-security-config>
                <base-config>
                    <trust-anchors>
                        <certificates src="system" />
                        <certificates src="user" />
                    </trust-anchors>
                </base-config>
                <domain-config cleartextTrafficPermitted="true">
            $mapDomain
                    <domain>duohuo.org.cn</domain>
                    <domain>127.0.0.1</domain>
                    <domain>localhost</domain>
                    <domain>10.0.2.2</domain>
                </domain-config>
            </network-security-config>
            """.trimIndent()
        } else {
            """
            <?xml version="1.0" encoding="utf-8"?>
            <!-- 由 build.gradle.kts 生成，不要手改。includeSubdomains 必须显式声明
                 （lint 的 NetworkSecurityConfig 检查会因缺失而判为致命错误）。 -->
            <network-security-config>
                <base-config cleartextTrafficPermitted="false">
                    <trust-anchors>
                        <certificates src="system" />
                    </trust-anchors>
                </base-config>
                <domain-config cleartextTrafficPermitted="true">
            $mapDomain
                    <domain includeSubdomains="false">duohuo.org.cn</domain>
                </domain-config>
            </network-security-config>
            """.trimIndent()
        }
        val dir = outputDirectory.get().asFile.resolve("xml")
        dir.mkdirs()
        dir.resolve("network_security_config.xml").writeText(text)
    }
}

androidComponents.onVariants { variant ->
    val debug = variant.buildType == "debug"
    val task = tasks.register<GenerateNetworkSecurityConfig>(
        "generate${variant.name.replaceFirstChar { it.uppercase() }}NetworkSecurityConfig",
    ) {
        inputs.file(campusConfigFile)
        mapHost.set(campusMapHost)
        debugConfig.set(debug)
        outputDirectory.set(layout.buildDirectory.dir("generated/nsc/${variant.name}"))
    }
    variant.sources.res?.addGeneratedSourceDirectory(
        task,
        GenerateNetworkSecurityConfig::outputDirectory,
    )
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
