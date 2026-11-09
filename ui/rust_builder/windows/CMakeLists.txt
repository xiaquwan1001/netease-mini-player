# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "rust_lib_minincm")
project(${PROJECT_NAME} LANGUAGES CXX)

include("../cargokit/cmake/cargokit.cmake")
# manifest_dir: 以 rust_builder/windows 为基准 -> rust_builder -> ui -> 仓库根 -> core/crates/ncm-ffi
#   (frb 模板默认是 ../../../../../../../ 因为它的 rust crate 在别的层级; 本仓库拷贝时没改, 导致构建工具找不到 Cargo.toml)
# lib_name: **cargo 包名** ncm_ffi, 不是插件名 rust_lib_minincm —— Dart 侧 frb_generated.dart 里 stem: 'ncm_ffi'
#   决定了产物必须是 ncm_ffi.dll, 否则运行时加载失败。
apply_cargokit(${PROJECT_NAME} ../../../core/crates/ncm-ffi ncm_ffi "")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(rust_lib_minincm_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
