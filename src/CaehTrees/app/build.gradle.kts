import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.google.services)
}

// Release signing: same keystore as Android-init-NDEF / android-NDEF POS (sibling project).
val androidInitNdefDir = rootProject.file("../Android-init-NDEF")
val keystorePropertiesFile = androidInitNdefDir.resolve("keystore.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.beamio.app"
    compileSdk {
        version = release(36) {
            minorApiLevel = 1
        }
    }

    defaultConfig {
        applicationId = "com.beamio.app"
        minSdk = 24
        targetSdk = 36
        versionCode = 11
        versionName = "1.0.9"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                val storeRel = keystoreProperties.getProperty("storeFile")
                storeFile = androidInitNdefDir.resolve(storeRel)
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // R8：缩小体积 + 生成 mapping；AGP 8.5+ 会将 mapping 打入 AAB，Play 可自动去混淆崩溃栈
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

/** Same as run-debug.sh — bypasses stale IDE applicationId (com.beamio.caehtrees). */
tasks.register<Exec>("launchDebug") {
    group = "application"
    description = "Install debug APK and start com.beamio.app.MainActivity"
    dependsOn("installDebug")
    commandLine(
        "adb",
        "shell",
        "am",
        "start",
        "-n",
        "com.beamio.app/com.beamio.app.MainActivity",
    )
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity)
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.webkit:webkit:1.12.1")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    // Offline chat → FCM badge (replace app/google-services.json with Firebase Console export)
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}