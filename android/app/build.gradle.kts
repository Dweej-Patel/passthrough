plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "dev.dpatel.passthrough"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.dpatel.passthrough.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
    }

    // iroh ships a large native library per ABI: phones only (64- and 32-bit ARM), plus the
    // x86_64 emulator in debug builds.
    buildTypes {
        debug {
            ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
        }
        release {
            ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Sign with your own key: see android/README.md.
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // buildConfig: BuildConfig.DEBUG gates the debug-only Remote shell demo (MainActivity), so R8 drops it from release.
    buildFeatures { compose = true; buildConfig = true }
    testOptions { unitTests.isReturnDefaultValues = true }
    // terminal-emulator ships Termux's process-spawning JNI library; the shell runs on the Mac, never here.
    packaging {
        jniLibs.excludes += "**/libtermux.so"
        // computer.iroh:iroh (pulled in by iroh-android) also carries desktop builds of the
        // native library as Java resources; Android loads the one under lib/<abi>/.
        resources.excludes += listOf("darwin-*/**", "linux-*/**", "win32-*/**")
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.fragment:fragment-ktx:1.8.5")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    // Remote shell terminal: Termux v0.118.3 (stable, 2025-05-22). These two modules are Apache-2.0
    // (the Termux app itself is GPLv3); brings terminal-emulator. See THIRD_PARTY_NOTICES.md.
    implementation("com.github.termux.termux-app:terminal-view:v0.118.3")
    // Remote shell from anywhere: iroh 1.1.0 (MIT OR Apache-2.0), pinned; brings JNA 5.15.0.
    // Its native libraries predate 16 KB page alignment (CI reports it); move to 1.1.1 when released.
    implementation("computer.iroh:iroh-android:1.1.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.compose.ui:ui-tooling-preview")

    testImplementation("junit:junit:4.13.2")
}
