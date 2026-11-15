load("@rules_cc//cc:cc_library.bzl", "cc_library")

# Test host only: production hosts still require signing-time dylib injection.
cc_library(
    name = "BYPluginTestShim",
    testonly = True,
    srcs = ["Sources/BYPlugin.c"],
    hdrs = ["Sources/BYPlugin.h"],
    alwayslink = True,
    visibility = ["//submodules/TelegramCore:__pkg__"],
)
