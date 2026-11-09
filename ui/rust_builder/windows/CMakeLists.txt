# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "rust_lib_minincm")
project(${PROJECT_NAME} LANGUAGES CXX)

include("../cargokit/cmake/cargokit.cmake")
# manifest_dir 必须是**相对**路径(cargokit 自己拼 ${CMAKE_CURRENT_SOURCE_DIR}/${manifest_dir}),
# 而 Windows 上 Flutter 用 .plugin_symlinks 引用本插件, CMAKE_CURRENT_SOURCE_DIR 指向
#   ui/windows/flutter/ephemeral/.plugin_symlinks/rust_lib_minincm/windows
# 这个"假"路径比真实路径深 4 级 —— 直接写死 ../../../ 会在 Windows 上拼成 ephemeral/core/... 而失败。
# 做法: 两个候选里挑真实存在的那个, 再用 file(RELATIVE_PATH) 折算回相对路径。
set(_ncm_m3 "${CMAKE_CURRENT_SOURCE_DIR}/../../../core/crates/ncm-ffi")
set(_ncm_m7 "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../../core/crates/ncm-ffi")
if(EXISTS "${_ncm_m3}/Cargo.toml")
  set(_ncm_manifest_abs "${_ncm_m3}")
else()
  set(_ncm_manifest_abs "${_ncm_m7}")
endif()
if(NOT EXISTS "${_ncm_manifest_abs}/Cargo.toml")
  message(FATAL_ERROR "找不到 core/crates/ncm-ffi/Cargo.toml (试过: ${_ncm_m3} 与 ${_ncm_m7})")
endif()
file(RELATIVE_PATH _ncm_manifest_rel "${CMAKE_CURRENT_SOURCE_DIR}" "${_ncm_manifest_abs}")
message(STATUS "rust manifest dir: ${_ncm_manifest_abs} (rel ${_ncm_manifest_rel})")
#   (frb 模板默认是 ../../../../../../../ 因为它的 rust crate 在别的层级; 本仓库拷贝时没改, 导致构建工具找不到 Cargo.toml)
# lib_name: **cargo 包名** ncm_ffi, 不是插件名 rust_lib_minincm —— Dart 侧 frb_generated.dart 里 stem: 'ncm_ffi'
#   决定了产物必须是 ncm_ffi.dll, 否则运行时加载失败。
apply_cargokit(${PROJECT_NAME} "${_ncm_manifest_rel}" ncm_ffi "")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(rust_lib_minincm_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
