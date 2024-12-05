load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def _mlx_impl(mctx):
    # https://storage.googleapis.com/jax-releases/libtpu_releases.html
    http_archive(
        name = "libmlx",
        url = "https://files.pythonhosted.org/packages/41/e6/4b6341151ea4593423337255bbf50dcad0ba3600c050013a1502a21b7427/mlx-0.21.0-cp313-cp313-macosx_14_0_arm64.whl",
        type = "zip",
        sha256 = "3155918a74c5cdb87839e999b069b887043166b1370946a4ef4c633b555861ae",
        build_file = "libmlx.BUILD.bazel",
    )
    return mctx.extension_metadata(
        reproducible = True,
        root_module_direct_deps = ["libmlx"],
        root_module_direct_dev_deps = [],
    )

mlx_packages = module_extension(
    implementation = _mlx_impl,
)
