plugins {
    id("com.android.application")
}

android {
    namespace = "dev.cursoe"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.cursoe"
        minSdk = 26
        targetSdk = 37
        versionCode = 2
        versionName = "1.0.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Pemakaian pribadi: ditandatangani dengan kunci debug, sehingga build dev (debug) dan
            // prod (release) bisa saling menimpa tanpa uninstall — pairing & izin tetap tersimpan.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// Sengaja tanpa dependency: hanya framework Android + Kotlin stdlib.
