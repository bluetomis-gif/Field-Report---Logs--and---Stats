plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace   = "com.bluetomis.fieldreport"
    compileSdk  = 34

    defaultConfig {
        applicationId  = "com.bluetomis.fieldreport.agent"
        minSdk         = 23
        targetSdk      = 34
        versionCode    = 1
        versionName    = "1.0"
        multiDexEnabled = true

        // DJI API key embedded at build time
        manifestPlaceholders["DJI_API_KEY"] = "9976bf432acd10ad066badba0104f7b"

        ndk { abiFilters += listOf("arm64-v8a") }
    }

    buildTypes {
        release {
            isMinifyEnabled  = false
            isShrinkResources = false
        }
        debug {
            isDebuggable = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    aaptOptions {
        noCompress += listOf("tflite")
    }

    packaging {
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/*.kotlin_module"
            )
        }
        jniLibs { keepDebugSymbols += "**/*.so" }
    }
}

dependencies {
    // DJI Mobile SDK v5
    implementation("com.dji:dji-sdk-v5-aircraft:5.9.0")
    compileOnly("com.dji:dji-sdk-v5-aircraft-provided:5.9.0")

    // MQTT (Paho v3 — pure Java, no Android service needed)
    implementation("org.eclipse.paho:org.eclipse.paho.client.mqttv3:1.2.5")

    // Kotlin coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // Android
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.multidex:multidex:2.0.1")
}
