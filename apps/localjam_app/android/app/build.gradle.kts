import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is driven by android/key.properties, which is git-ignored.
// Copy key.properties.example to key.properties and fill it in to sign a real
// release (docs/release/ANDROID_RELEASE.md). Without it a release build FAILS,
// so nobody uploads a debug-signed artifact by accident. To build a release
// locally anyway (R8 checks, `flutter run --release` on your own device), opt
// in explicitly and the debug key is used:
//
//   LOCALJAM_ALLOW_DEBUG_SIGNING=1 flutter build apk --release
//   flutter build apk --release --android-project-arg=localjam.allowDebugSigning=true
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties =
    Properties().apply {
        if (keystorePropertiesFile.exists()) {
            keystorePropertiesFile.inputStream().use { load(it) }
        }
    }
val hasReleaseKeystore =
    keystoreProperties.getProperty("storeFile")?.let { rootProject.file(it).exists() } == true
val allowDebugSigning =
    System.getenv("LOCALJAM_ALLOW_DEBUG_SIGNING")?.let { it == "1" || it == "true" } == true ||
        (findProperty("localjam.allowDebugSigning") as String?)?.toBoolean() == true

android {
    namespace = "np.com.bibektimsina.localjam"
    // permission_handler 13 (ACCESS_LOCAL_NETWORK support) needs API 37.
    compileSdk = maxOf(flutter.compileSdkVersion, 37)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "np.com.bibektimsina.localjam"
        // Android 7.0, Flutter's own floor: the MediaStore library, the
        // foreground service and AudioTrack timestamps all work from here.
        minSdk = flutter.minSdkVersion
        // Pinned rather than inherited from the Flutter tool, so a Flutter
        // upgrade cannot silently move the app onto new platform behaviour.
        // Google Play requires API 36 for new apps and updates from
        // 2026-08-31. Moving to 37 changes local-network enforcement
        // (ACCESS_LOCAL_NETWORK gates LAN sockets). Apps targeting 36 or
        // lower must not declare or request it, so it is off for now; the
        // bump to 37 must, in the same change, declare it in
        // AndroidManifest.xml, set androidRequestsLocalNetwork in
        // lib/src/util/permissions.dart to true, and re-run DEVICE_TESTING.md
        // on an Android 17 device.
        targetSdk = 36
        // From pubspec.yaml `version: x.y.z+N`: N is the versionCode and must
        // grow with every upload to Play.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasReleaseKeystore) {
                    signingConfigs.getByName("release")
                } else {
                    // Only used with the explicit opt-in (top of this file);
                    // without it the task-graph check below stops the build.
                    // println() lands at Gradle's QUIET level, so it survives
                    // `-q` and the Flutter tool's output filtering.
                    if (allowDebugSigning) {
                        println(
                            "\n  localjam: signing the release build with the DEBUG key " +
                                "(LOCALJAM_ALLOW_DEBUG_SIGNING).\n" +
                                "      This artifact cannot be uploaded to Play.\n",
                        )
                    }
                    signingConfigs.getByName("debug")
                }

            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// A release build without a release key fails once the task graph is known,
// not at configuration time, so debug and profile builds never trip over it.
gradle.taskGraph.whenReady {
    val buildsRelease =
        allTasks.any { it.project == project && it.name.contains("Release") }
    if (buildsRelease && !hasReleaseKeystore && !allowDebugSigning) {
        throw GradleException(
            "localjam: no release signing key.\n" +
                "  android/key.properties is missing, or its storeFile does not exist.\n" +
                "  To sign for Play, see docs/release/ANDROID_RELEASE.md.\n" +
                "  For a local, non-distributable release build, set " +
                "LOCALJAM_ALLOW_DEBUG_SIGNING=1.",
        )
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
