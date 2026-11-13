group = "dev.bimsina.localjam_audio"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.3.3")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// The `android {}` accessor is typed with AGP's deprecated
// com.android.build.gradle.LibraryExtension when the embedding app builds
// with `android.newDsl=false` (Flutter's template; LocalJam's apps set it to
// true); configuring the new DSL interface directly works under both.
extensions.configure<com.android.build.api.dsl.LibraryExtension> {
    namespace = "dev.bimsina.localjam_audio"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.directories.add("src/main/kotlin")
        }
        getByName("test") {
            java.directories.add("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            // android.util.Log is a stub in JVM unit tests; the gate logs on
            // its failure paths, and a "not mocked" throw there would hide the
            // very behaviour under test.
            isReturnDefaultValues = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // The JUnit 5 flavour of kotlin.test, named explicitly: with AGP's
    // built-in Kotlin nothing infers it from useJUnitPlatform() the way the
    // Kotlin Gradle Plugin did.
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit5")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
