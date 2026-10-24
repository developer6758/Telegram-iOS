load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library", "swift_test")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "TimeCapsuleCore",
    module_name = "TimeCapsuleCore",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors", "-enable-testing"],
    visibility = ["//visibility:public"],
)

# Pure Foundation/CryptoKit host tests. Requires macOS; Linux is not an iOS build.
swift_test(
    name = "TimeCapsuleCoreHostTests",
    srcs = glob(["Tests/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [":TimeCapsuleCore"],
)

swift_library(
    name = "TimeCapsuleCoreTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    deps = [":TimeCapsuleCore"],
)

# Matches the existing TextFormat runner. Change only to a runtime actually installed
# on the testing Mac; this target has not been executed in the Linux implementation host.
ios_test_runner(
    name = "TimeCapsuleCoreTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "TimeCapsuleCoreTests",
    minimum_os_version = "15.0",
    runner = ":TimeCapsuleCoreTestRunner",
    deps = [":TimeCapsuleCoreTestsLib"],
    visibility = ["//visibility:public"],
)
