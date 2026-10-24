load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "ChatMessageTimeCapsuleBubbleContentNode",
    module_name = "ChatMessageTimeCapsuleBubbleContentNode",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/TimeCapsuleCore",
        "//submodules/TimeCapsuleAuthorizationUI",
        "//submodules/TelegramUI/Components/Chat/ChatMessageBubbleContentNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
    ],
    visibility = ["//visibility:public"],
)

swift_library(
    name = "TimeCapsuleBubbleTestsLib",
    testonly = True,
    srcs = glob(["Tests/**/*.swift"]),
    deps = [
        ":ChatMessageTimeCapsuleBubbleContentNode",
        "//submodules/TimeCapsuleCore",
    ],
)

ios_test_runner(
    name = "TimeCapsuleBubbleTestRunner",
    device_type = "iPhone 17",
    os_version = "26.5",
)

ios_unit_test(
    name = "TimeCapsuleBubbleTests",
    minimum_os_version = "15.0",
    runner = ":TimeCapsuleBubbleTestRunner",
    deps = [":TimeCapsuleBubbleTestsLib"],
    visibility = ["//visibility:public"],
)
