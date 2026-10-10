# Resolves the WPE WebKit SDK for flutter_inappwebview_linux.
#
# FLUTTER_INAPPWEBVIEW_WPE_SDK (CMake cache variable or environment
# variable) selects the SDK:
#   (unset)     Download the pinned SDK in wpe_sdk/prebuilt.json, check its
#               SHA-256, and bundle it with the app. This is the default.
#   <directory> Use an extracted SDK at this directory, and bundle it.
#   system      Use system packages through pkg-config. Bundle nothing.
#               The app then needs the same packages at run time.
#
# FLUTTER_INAPPWEBVIEW_WPE_SDK_TARGET selects the SDK target, for example
# ubuntu-24.04-x64. Default: <os-release ID>-<VERSION_ID>-<arch> of the
# build machine. An SDK runs on its own base system and on newer versions of
# it.
#
# Output: WPE_SDK_DIR (empty in system mode). PKG_CONFIG_PATH finds the SDK.

set(_wpe_sdk_choice "${FLUTTER_INAPPWEBVIEW_WPE_SDK}")
if(NOT _wpe_sdk_choice AND DEFINED ENV{FLUTTER_INAPPWEBVIEW_WPE_SDK})
  set(_wpe_sdk_choice "$ENV{FLUTTER_INAPPWEBVIEW_WPE_SDK}")
endif()

# pkg_check_modules and check_cxx_source_compiles cache their results. Drop
# them when the SDK changes.
macro(_wpe_sdk_reset_checks dir)
  if(NOT "${dir}" STREQUAL "${_FLUTTER_INAPPWEBVIEW_WPE_SDK_LAST}")
    foreach(_module WPE_WEBKIT WPE_PLATFORM WPE_PLATFORM_HEADLESS WPE_FDO LIBWPE)
      unset(__pkg_config_checked_${_module} CACHE)
    endforeach()
    unset(WEBKIT_HAS_WPE_PLATFORM_API CACHE)
    set(_FLUTTER_INAPPWEBVIEW_WPE_SDK_LAST "${dir}" CACHE INTERNAL "")
  endif()
endmacro()

set(WPE_SDK_DIR "")
if(_wpe_sdk_choice STREQUAL "system")
  message(STATUS "flutter_inappwebview_linux: WPE SDK: system packages")
  _wpe_sdk_reset_checks("system")
  return()
elseif(_wpe_sdk_choice)
  get_filename_component(WPE_SDK_DIR "${_wpe_sdk_choice}" ABSOLUTE)
  if(NOT EXISTS "${WPE_SDK_DIR}/lib/pkgconfig/wpe-webkit-2.0.pc")
    message(FATAL_ERROR "FLUTTER_INAPPWEBVIEW_WPE_SDK=${WPE_SDK_DIR} is not a WPE SDK: lib/pkgconfig/wpe-webkit-2.0.pc is missing.")
  endif()
  message(STATUS "flutter_inappwebview_linux: WPE SDK: ${WPE_SDK_DIR} (local)")
else()
  if(CMAKE_VERSION VERSION_LESS "3.19")
    message(FATAL_ERROR "The pinned WPE SDK needs CMake 3.19 or later. Set FLUTTER_INAPPWEBVIEW_WPE_SDK=system to use system packages.")
  endif()

  set(_wpe_target "${FLUTTER_INAPPWEBVIEW_WPE_SDK_TARGET}")
  if(NOT _wpe_target AND DEFINED ENV{FLUTTER_INAPPWEBVIEW_WPE_SDK_TARGET})
    set(_wpe_target "$ENV{FLUTTER_INAPPWEBVIEW_WPE_SDK_TARGET}")
  endif()
  if(NOT _wpe_target)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
      set(_wpe_arch x64)
    elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|ARM64)$")
      set(_wpe_arch arm64)
    else()
      message(FATAL_ERROR "No WPE SDK for processor ${CMAKE_SYSTEM_PROCESSOR}.")
    endif()
    file(STRINGS /etc/os-release _wpe_os_release REGEX "^(ID|VERSION_ID)=")
    foreach(_line IN LISTS _wpe_os_release)
      if(_line MATCHES "^ID=\"?([^\"]*)\"?$")
        set(_wpe_os_id "${CMAKE_MATCH_1}")
      elseif(_line MATCHES "^VERSION_ID=\"?([^\"]*)\"?$")
        set(_wpe_os_version "${CMAKE_MATCH_1}")
      endif()
    endforeach()
    set(_wpe_target "${_wpe_os_id}-${_wpe_os_version}-${_wpe_arch}")
  endif()

  set(_wpe_manifest_file "${CMAKE_CURRENT_LIST_DIR}/../wpe_sdk/prebuilt.json")
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${_wpe_manifest_file}")
  file(READ "${_wpe_manifest_file}" _wpe_manifest)
  string(JSON _wpe_targets GET "${_wpe_manifest}" targets)
  string(JSON _wpe_url ERROR_VARIABLE _wpe_missing GET "${_wpe_targets}" "${_wpe_target}" url)
  if(_wpe_missing)
    string(JSON _wpe_count LENGTH "${_wpe_targets}")
    set(_wpe_names "")
    if(_wpe_count GREATER 0)
      math(EXPR _wpe_last "${_wpe_count} - 1")
      foreach(_i RANGE ${_wpe_last})
        string(JSON _wpe_name MEMBER "${_wpe_targets}" ${_i})
        list(APPEND _wpe_names "${_wpe_name}")
      endforeach()
      list(JOIN _wpe_names ", " _wpe_names)
    else()
      set(_wpe_names "none; no SDK release is pinned yet")
    endif()
    message(FATAL_ERROR
      "No pinned WPE SDK for target ${_wpe_target}. Available: ${_wpe_names}.\n"
      "Set FLUTTER_INAPPWEBVIEW_WPE_SDK_TARGET to a compatible target, "
      "FLUTTER_INAPPWEBVIEW_WPE_SDK to a local SDK, or "
      "FLUTTER_INAPPWEBVIEW_WPE_SDK=system.")
  endif()
  string(JSON _wpe_sha256 GET "${_wpe_targets}" "${_wpe_target}" sha256)

  # Content-addressed cache: one directory per archive SHA-256.
  if(DEFINED ENV{XDG_CACHE_HOME} AND NOT "$ENV{XDG_CACHE_HOME}" STREQUAL "")
    set(_wpe_cache "$ENV{XDG_CACHE_HOME}/flutter_inappwebview/wpe-sdk")
  else()
    set(_wpe_cache "$ENV{HOME}/.cache/flutter_inappwebview/wpe-sdk")
  endif()
  set(_wpe_root "${_wpe_cache}/${_wpe_sha256}")
  set(WPE_SDK_DIR "${_wpe_root}/wpe-sdk")
  if(NOT EXISTS "${_wpe_root}/complete")
    set(_wpe_archive "${_wpe_cache}/${_wpe_sha256}.tar.zst")
    message(STATUS "flutter_inappwebview_linux: downloading WPE SDK ${_wpe_target} from ${_wpe_url}")
    file(DOWNLOAD "${_wpe_url}" "${_wpe_archive}"
      EXPECTED_HASH SHA256=${_wpe_sha256}
      TLS_VERIFY ON
      STATUS _wpe_status)
    list(GET _wpe_status 0 _wpe_code)
    if(NOT _wpe_code EQUAL 0)
      file(REMOVE "${_wpe_archive}")
      message(FATAL_ERROR "WPE SDK download failed: ${_wpe_status}")
    endif()
    set(_wpe_partial "${_wpe_root}.partial")
    file(REMOVE_RECURSE "${_wpe_partial}" "${_wpe_root}")
    file(ARCHIVE_EXTRACT INPUT "${_wpe_archive}" DESTINATION "${_wpe_partial}")
    file(REMOVE "${_wpe_archive}")
    file(RENAME "${_wpe_partial}" "${_wpe_root}")
    file(TOUCH "${_wpe_root}/complete")
  endif()
  message(STATUS "flutter_inappwebview_linux: WPE SDK: ${_wpe_target} ${_wpe_sha256}")
endif()

_wpe_sdk_reset_checks("${WPE_SDK_DIR}")
set(ENV{PKG_CONFIG_PATH} "${WPE_SDK_DIR}/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")
