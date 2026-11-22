// swift-tools-version: 6.0
import PackageDescription

// 依頼では swiftpm-1.5.1 指定だが、そのブランチは存在しない(2026-11 時点)。
// 最も近い swiftpm-1.5.0 を使う。変える場合はここだけ直す。
let executorchBranch = "swiftpm-1.5.0"

// バックエンドとカーネルは静的初期化子で登録されるため -all_load が必要。
let allLoad: [LinkerSetting] = [.unsafeFlags(["-all_load"])]

let package = Package(
    name: "MorphCore",
    platforms: [
        .iOS(.v18),   // Synchronization.Atomic
        .macOS(.v15),
    ],
    products: [
        .library(name: "MorphCore", targets: ["MorphCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pytorch/executorch.git", branch: executorchBranch),
    ],
    targets: [
        .target(
            name: "MorphCore",
            dependencies: [
                .product(name: "executorch", package: "executorch"),
                .product(name: "backend_xnnpack", package: "executorch"),
                .product(name: "kernels_optimized", package: "executorch"),
            ],
            linkerSettings: allLoad
        ),
        .testTarget(
            name: "MorphCoreTests",
            dependencies: ["MorphCore"],
            linkerSettings: allLoad
        ),
    ],
    swiftLanguageModes: [.v5]
)
