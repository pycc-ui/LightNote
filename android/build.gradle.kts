allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// 把**插件模块**的 compileSdk 抬到和应用同一档。
//
// ## 为什么必须动别人的模块
//
// `onnxruntime`（FFI 那套，自带各 ABI 的 `libonnxruntime.so`）的 android 模块里
// 写死了 `compileSdkVersion 33`，而 Flutter 给插件模块默认挂上的 androidx 依赖
// （`androidx.fragment:1.7.1`、`androidx.window:1.2.0`）要求编译目标 ≥ 34 ——
// 于是 `:onnxruntime:checkReleaseAarMetadata` 直接失败，**整个 APK 打不出来**
//（报错是 "15 issues were found when checking AAR metadata"）。
//
// 应用自身是 36（`flutter.compileSdkVersion`），所以抬到 36 只是"跟上应用"，
// 没有引入新的目标版本。
//
// ## 为什么用反射而不是强类型
//
// 强类型要在这里再引一遍 AGP 的 classpath（`com.android.build.gradle.BaseExtension`），
// 那份版本和 Flutter 自带的对不上时会炸出更难查的错。反射只调一个方法，
// 失败也只是"没改成"，`runCatching` 吞掉即可（真有问题下一个任务的报错更清楚）。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        runCatching {
            androidExt.javaClass
                .getMethod("compileSdkVersion", java.lang.Integer.TYPE)
                .invoke(androidExt, 36)
        }.onFailure {
            logger.lifecycle(
                "⚠️ 没能把 ${project.name} 的 compileSdk 抬到 36：${it.message}"
            )
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

subprojects {
    project.evaluationDependsOn(":app")
}
