#!/usr/bin/env bash
# Build an RPM from the artifacts already produced by `just build`.
# This script does NOT rebuild — it stages files from build/ into a tarball
# and runs rpmbuild against dev/rpm/jellyfin-desktop.spec.in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
OUTPUT_DIR="${1:-${PROJECT_ROOT}/dist}"

if ! command -v rpmbuild >/dev/null 2>&1; then
    echo 'error: rpmbuild not found (install rpm-build)' >&2
    exit 1
fi

if [ ! -x "${BUILD_DIR}/jellyfin-desktop" ]; then
    echo "error: ${BUILD_DIR}/jellyfin-desktop not found — run 'just build' first" >&2
    exit 1
fi

# Translate VERSION into RPM-legal Version/Release. RPM disallows '-' in
# either field. For pre-release builds (VERSION contains '-'), Release
# encodes the suffix and a short git hash so newer dev builds outrank older
# ones while still ranking below the eventual tagged release.
APP_VERSION="$(cat "${PROJECT_ROOT}/VERSION")"
RPM_VERSION="${APP_VERSION%%-*}"
if [ "${APP_VERSION}" = "${RPM_VERSION}" ]; then
    RPM_RELEASE="1"
    RPM_FULL_VERSION="${APP_VERSION}"
else
    SUFFIX="${APP_VERSION#*-}"
    GIT_HASH="$(cd "${PROJECT_ROOT}" && git describe --always --dirty 2>/dev/null || echo unknown)"
    SAFE_HASH="$(printf '%s' "${GIT_HASH}" | tr -c '[:alnum:]' '_')"
    SAFE_SUFFIX="$(printf '%s' "${SUFFIX}" | tr -c '[:alnum:]' '_')"
    RPM_RELEASE="0.${SAFE_SUFFIX}.${SAFE_HASH}"
    RPM_FULL_VERSION="${APP_VERSION}+${GIT_HASH}"
fi
RPM_DATE="$(LC_ALL=C date '+%a %b %d %Y')"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

TOPDIR="${WORK_DIR}/rpmbuild"
mkdir -p "${TOPDIR}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

# Stage everything the spec's %install section copies out of, in a single
# tarball whose top-level dir matches `%{name}-%{version}` so %setup -q works.
SRC_NAME="jellyfin-desktop-${RPM_VERSION}"
SRC_DIR="${WORK_DIR}/${SRC_NAME}"
mkdir -p "${SRC_DIR}/locales"

cp -p "${BUILD_DIR}/jellyfin-desktop"          "${SRC_DIR}/"
cp -p "${BUILD_DIR}/chrome-sandbox"            "${SRC_DIR}/"
cp -p "${BUILD_DIR}/libcef.so"                 "${SRC_DIR}/"
cp -p "${BUILD_DIR}/libEGL.so"                 "${SRC_DIR}/"
cp -p "${BUILD_DIR}/libGLESv2.so"              "${SRC_DIR}/"
cp -p "${BUILD_DIR}/libvk_swiftshader.so"      "${SRC_DIR}/"
cp -p "${BUILD_DIR}/libmpv.so.2"               "${SRC_DIR}/"

cp -p "${BUILD_DIR}/chrome_100_percent.pak"    "${SRC_DIR}/"
cp -p "${BUILD_DIR}/chrome_200_percent.pak"    "${SRC_DIR}/"
cp -p "${BUILD_DIR}/resources.pak"             "${SRC_DIR}/"
cp -p "${BUILD_DIR}/icudtl.dat"                "${SRC_DIR}/"
cp -p "${BUILD_DIR}/v8_context_snapshot.bin"   "${SRC_DIR}/"
cp -p "${BUILD_DIR}/vk_swiftshader_icd.json"   "${SRC_DIR}/"

cp -p "${BUILD_DIR}"/locales/*.pak             "${SRC_DIR}/locales/"

cp -p "${PROJECT_ROOT}/resources/linux/org.jellyfin.JellyfinDesktop.desktop"      "${SRC_DIR}/"
cp -p "${PROJECT_ROOT}/resources/linux/org.jellyfin.JellyfinDesktop.svg"          "${SRC_DIR}/"
cp -p "${PROJECT_ROOT}/resources/linux/org.jellyfin.JellyfinDesktop.metainfo.xml" "${SRC_DIR}/"
cp -p "${PROJECT_ROOT}/LICENSE"                "${SRC_DIR}/"

# Uncompressed tar — rpmbuild recompresses the payload anyway, so gzipping
# 1.3GB of CEF here is pure waste.
tar -C "${WORK_DIR}" -cf "${TOPDIR}/SOURCES/${SRC_NAME}.tar" "${SRC_NAME}"

# Render the spec template
SPEC="${TOPDIR}/SPECS/jellyfin-desktop.spec"
sed \
    -e "s|@RPM_VERSION@|${RPM_VERSION}|g" \
    -e "s|@RPM_RELEASE@|${RPM_RELEASE}|g" \
    -e "s|@RPM_DATE@|${RPM_DATE}|g" \
    -e "s|@RPM_FULL_VERSION@|${RPM_FULL_VERSION}|g" \
    "${SCRIPT_DIR}/jellyfin-desktop.spec.in" > "${SPEC}"

echo "Building RPM (Version=${RPM_VERSION} Release=${RPM_RELEASE})..."
# w3T0 = zstd level 3, all CPU threads. Level 19 (rpm's "max") is glacial on
# a 1.3GB payload and saves only a few percent.
rpmbuild \
    --define "_topdir ${TOPDIR}" \
    --define "_binary_payload w3T0.zstdio" \
    -bb "${SPEC}"

mkdir -p "${OUTPUT_DIR}"
find "${TOPDIR}/RPMS" -name '*.rpm' -exec cp -p {} "${OUTPUT_DIR}/" \;

echo
echo "RPMs:"
find "${OUTPUT_DIR}" -name "jellyfin-desktop-${RPM_VERSION}-${RPM_RELEASE}*.rpm" -printf '  %p\n'
