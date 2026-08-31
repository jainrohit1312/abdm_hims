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
subprojects {
    project.evaluationDependsOn(":app")
}

// Some plugins (e.g. audioplayers_android, package_info_plus, share_plus)
// hard-code an old compileSdk (33) in their own build scripts. Their
// transitive androidx dependencies now require compileSdk 35/36, which makes
// :plugin:checkReleaseAarMetadata fail. Force every Android subproject to
// compile against SDK 36 (backward compatible).
subprojects {
    fun forceCompileSdk(target: Project) {
        val androidExt = target.extensions.findByName("android")
        if (androidExt is com.android.build.gradle.BaseExtension) {
            androidExt.compileSdkVersion(36)
        }
    }
    if (state.executed) {
        forceCompileSdk(this)
    } else {
        afterEvaluate { forceCompileSdk(this) }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
