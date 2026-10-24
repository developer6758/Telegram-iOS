load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "TimeCapsuleAuthorizationUI",
    module_name = "TimeCapsuleAuthorizationUI",
    srcs = glob(["Sources/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = ["//submodules/TimeCapsuleCore"],
    visibility = ["//visibility:public"],
)
