load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

config_setting(
    name = "local_pro_features",
    define_values = {"local_pro_features": "true"},
    visibility = ["//visibility:public"],
)

swift_library(
    name = "SGSimpleSettings",
    module_name = "SGSimpleSettings",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ] + select({
        ":local_pro_features": ["-D", "SG_LOCAL_PRO_FEATURES"],
        "//conditions:default": [],
    }),
    deps = [
        "//Swiftgram/SGAppGroupIdentifier:SGAppGroupIdentifier",
        "//Swiftgram/SGLogging:SGLogging",
    ],
    visibility = [
        "//visibility:public",
    ],
)
