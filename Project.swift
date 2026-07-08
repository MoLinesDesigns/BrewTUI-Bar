import ProjectDescription
import Foundation

// Single source of truth: the marketing version comes from ./package.json.
// Override at build time with `MARKETING_VERSION=x.y.z tuist generate` if
// you ever need to detach it.
//
// Tuist evaluates this manifest from a temp directory, so `#filePath` is not
// reliable — instead resolve relative to the current working directory, which
// Tuist sets to the manifest's containing folder.
private func readMarketingVersion() -> String {
    let cwd = FileManager.default.currentDirectoryPath
    let url = URL(fileURLWithPath: cwd)
        .appendingPathComponent("package.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = json["version"] as? String,
          !version.isEmpty
    else {
        // Fail loud at generate-time rather than silently shipping a wrong version.
        fatalError("Project.swift: could not read \"version\" from package.json at \(url.path)")
    }
    return version
}

private let marketingVersion = readMarketingVersion()

let project = Project(
    name: "BrewTUI-Bar",
    options: .options(
        defaultKnownRegions: ["en", "es"],
        developmentRegion: "en"
    ),
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
            "MARKETING_VERSION": .string("$(MARKETING_VERSION:default=\(marketingVersion))"),
            "CURRENT_PROJECT_VERSION": "1",
            "DEAD_CODE_STRIPPING": "YES",
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            "STRING_CATALOG_GENERATE_SYMBOLS": "NO",
            "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
            "SWIFT_STRICT_CONCURRENCY": "complete",
        ],
        configurations: [
            .debug(name: "Debug"),
            .release(name: "Release"),
        ]
    ),
    targets: [
        .target(
            name: "BrewTUI-Bar",
            destinations: .macOS,
            product: .app,
            bundleId: "com.molinesdesigns.brewtuibar",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true,
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "NSMainStoryboardFile": "",
                "CFBundleDisplayName": "BrewTUI-Bar",
                "CFBundleDevelopmentRegion": "en",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSHumanReadableCopyright": "MoLines Designs",
            ]),
            // ARQ-005: excluir DesignExploration/ del binario notariado.
            // BrewTUIBarDesignVariants.swift es codigo de exploracion
            // de diseno que no debe entrar al producto firmado.
            sources: SourceFilesList(globs: [
                .glob("BrewTUI-Bar/Sources/**", excluding: ["BrewTUI-Bar/Sources/DesignExploration/**"]),
            ]),
            resources: ["BrewTUI-Bar/Resources/**"],
            settings: .settings(
                base: [
                    // Xcode sanitises hyphens out of PRODUCT_NAME when derived from the
                    // target name, which would emit BrewTUI-Bar.app. The cask + installer
                    // scripts look for the hyphenated bundle, so force the brand name
                    // explicitly while keeping PRODUCT_MODULE_NAME identifier-safe.
                    "PRODUCT_NAME": "BrewTUI-Bar",
                    "EXECUTABLE_NAME": "BrewTUI-Bar",
                    "PRODUCT_MODULE_NAME": "BrewTUI_Bar",
                    "DEVELOPMENT_TEAM": "GD6M44DYPQ",
                    "CODE_SIGN_STYLE": "Manual",
                    "CODE_SIGN_IDENTITY": "Developer ID Application",
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
                    "OTHER_CODE_SIGN_FLAGS": "--timestamp",
                ],
                configurations: [
                    // Debug: relax signing so Xcode Preview JIT injection works.
                    // Hardened Runtime + Developer ID blocks the preview executor on Debug builds.
                    .debug(name: "Debug", settings: [
                        "CODE_SIGN_STYLE": "Automatic",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "ENABLE_HARDENED_RUNTIME": "NO",
                        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES",
                        "OTHER_CODE_SIGN_FLAGS": "",
                    ]),
                ]
            )
        ),
        .target(
            name: "BrewTUI-BarTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.molinesdesigns.brewtui-bar.tests",
            deploymentTargets: .macOS("14.0"),
            sources: ["BrewTUI-BarTests/Sources/**"],
            dependencies: [.target(name: "BrewTUI-Bar")],
            // Tuist derives TEST_HOST from the sanitised host name (BrewTUI_Bar),
            // but the host target overrides EXECUTABLE_NAME to keep the hyphens.
            // Override here to point at the actual binary path.
            settings: .settings(
                base: [
                    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/BrewTUI-Bar.app/Contents/MacOS/BrewTUI-Bar",
                    "BUNDLE_LOADER": "$(TEST_HOST)",
                ]
            )
        ),
    ]
)
