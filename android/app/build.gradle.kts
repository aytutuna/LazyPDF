plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "com.lazypdf.lazypdf"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.lazypdf.lazypdf"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "1.0.0"
        ndk {
            abiFilters += setOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    testImplementation(libs.junit)
}
