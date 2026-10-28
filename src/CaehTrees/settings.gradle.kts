pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // chat-sdk-android (same role as the SwiftPM `chat-sdk-ios` package on iOS).
        maven {
            url = uri("https://raw.githubusercontent.com/CoNET-project/chat-sdk-android/main/maven")
            content { includeGroup("network.conet") }
        }
    }
}

rootProject.name = "CaehTrees"
include(":app")
