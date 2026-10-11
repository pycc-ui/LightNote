import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// release 签名
//
// 这里原本是模板留下的 TODO：release 也用 **debug 签名**。那样打出来的 APK
// 不能上架，也不能覆盖安装升级 —— 一旦装过 debug 签名的包，以后换正式签名
// 必须先卸载（用户数据会丢）。
//
// 现在从 `android/key.properties` 读（该文件**不进版本库**，见 .gitignore）：
//
//     storePassword=…
//     keyPassword=…
//     keyAlias=lightnote
//     storeFile=../lightnote.jks
//
// 密钥自己生成（密码不要写进代码）：
//
//     keytool -genkey -v -keystore android\lightnote.jks -keyalg RSA `
//       -keysize 2048 -validity 10000 -alias lightnote
//
// ⚠️ 这个 .jks 与两个密码**丢了就再也无法更新已发布的 App**，必须离线备份。
//
// 没有 key.properties 时回退到 debug 签名，好让开发机上 `flutter run --release`
// 仍然能跑；但这样打出来的包不能发布。
// ---------------------------------------------------------------------------
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.lightnote.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lightnote.app"
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

    signingConfigs {
        // 只有存在 key.properties 时才定义 release 签名 —— 否则 Gradle 会因为
        // 读不到 keystore 而在**配置阶段**就失败，连 debug 包都打不出来。
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // 开发机上没有密钥时的退路。**发布前必须先配好 key.properties**，
                // 否则打出来的包用的是 debug 签名，装不上正式版、也上不了架。
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
