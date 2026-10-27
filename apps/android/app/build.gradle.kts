plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.hilt)
    alias(libs.plugins.ksp)
    alias(libs.plugins.detekt)
    alias(libs.plugins.ktlint)
    kotlin("plugin.serialization") version "2.1.0"
}

android {
    namespace = "com.monadial.ash"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.monadial.ash"
        minSdk = 26
        targetSdk = 35
        versionCode = System.getenv("VERSION_CODE")?.toIntOrNull() ?: 1
        versionName = System.getenv("VERSION_NAME") ?: "1.0.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        buildConfigField("String", "DEFAULT_RELAY_URL", "\"https://eu.relay.ashprotocol.app\"")
    }

    signingConfigs {
        create("release") {
            // These can be set via environment variables or gradle.properties
            // For CI, use -P flags or environment variables
            val keystoreFile = System.getenv("KEYSTORE_FILE")
            if (keystoreFile != null && file(keystoreFile).exists()) {
                storeFile = file(keystoreFile)
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS")
                keyPassword = System.getenv("KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Use release signing config if available
            val releaseConfig = signingConfigs.findByName("release")
            if (releaseConfig?.storeFile != null) {
                signingConfig = releaseConfig
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    testOptions {
        unitTests.all {
            it.useJUnitPlatform()
            // Host build of the Rust bindings, for tests that run the real protocol
            it.systemProperty("jna.library.path", rootProject.file("../../bindings/target/release").absolutePath)
        }
        unitTests.isReturnDefaultValues = true
    }

    lint {
        warningsAsErrors = false
        abortOnError = false
        checkDependencies = true
        checkReleaseBuilds = true
        xmlReport = true
        htmlReport = true
        lintConfig = file("lint.xml")
        disable +=
            setOf(
                "ObsoleteLintCustomCheck",
                "GradleDependency",
                "OldTargetApi",
                "AndroidGradlePluginVersion",
                "Aligned16KB",
                "MissingApplicationIcon"
            )
        enable +=
            setOf(
                "Interoperability",
                "UnusedResources"
            )
    }
}

// Detekt configuration
detekt {
    buildUponDefaultConfig = true
    allRules = false
    config.setFrom(files("$rootDir/config/detekt/detekt.yml"))
    parallel = true
    autoCorrect = true
}

tasks.withType<io.gitlab.arturbosch.detekt.Detekt>().configureEach {
    jvmTarget = "17"
    exclude("**/uniffi/**")
    exclude("**/ash.kt")
}

tasks.withType<io.gitlab.arturbosch.detekt.DetektCreateBaselineTask>().configureEach {
    jvmTarget = "17"
}

// ktlint configuration
ktlint {
    android = true
    ignoreFailures = true
    reporters {
        reporter(org.jlleitschuh.gradle.ktlint.reporter.ReporterType.PLAIN)
        reporter(org.jlleitschuh.gradle.ktlint.reporter.ReporterType.HTML)
    }
    filter {
        exclude("**/generated/**")
        exclude("**/uniffi/**")
        exclude("**/ash.kt")
        include("**/kotlin/**")
    }
}

dependencies {
    // Core Android
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)

    // Compose
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.androidx.navigation.compose)
    debugImplementation(libs.androidx.ui.tooling)

    // Hilt DI
    implementation(libs.hilt.android)
    ksp(libs.hilt.android.compiler)
    implementation(libs.hilt.navigation.compose)

    // JNA for UniFFI bindings
    implementation(libs.jna) { artifact { type = "aar" } }

    // Ktor HTTP client
    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.okhttp)
    implementation(libs.ktor.client.content.negotiation)
    implementation(libs.ktor.serialization.kotlinx.json)

    // DataStore for preferences
    implementation(libs.datastore.preferences)

    // ML Kit for QR scanning
    implementation(libs.mlkit.barcode)

    // CameraX
    implementation(libs.camerax.core)
    implementation(libs.camerax.camera2)
    implementation(libs.camerax.lifecycle)
    implementation(libs.camerax.view)

    // ZXing for QR generation
    implementation(libs.zxing.core)

    // Biometric authentication
    implementation(libs.biometric)

    // Encrypted SharedPreferences
    implementation(libs.security.crypto)

    // Coroutines
    implementation(libs.coroutines.core)
    implementation(libs.coroutines.android)

    // Accompanist
    implementation(libs.accompanist.permissions)

    // Play Services Location
    implementation(libs.play.services.location)

    // Testing
    testImplementation(libs.junit.jupiter.api)
    testImplementation(libs.jna)
    testRuntimeOnly(libs.junit.jupiter.engine)
    testImplementation(libs.junit.jupiter.params)
    testImplementation(libs.mockk)
    testImplementation(libs.turbine)
    testImplementation(libs.truth)
    testImplementation(libs.coroutines.test)
    testImplementation(libs.arch.core.testing)

    // Android Instrumentation Tests
    androidTestImplementation(libs.mockk.android)
}
