#!/usr/bin/env python3
"""Generate WayLink.xcodeproj/project.pbxproj deterministically from sources.

Usage: python3 tools/gen_xcodeproj.py
Produces a valid Xcode 14+ project (objectVersion 56) with automatic signing.
Every object UUID is derived from an md5 of its path, so regeneration is
stable and diffable.
"""

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, "WayLink")
PROJ_DIR = os.path.join(ROOT, "WayLink.xcodeproj")

BUNDLE_ID = "com.d3m0n.waylink"
DEPLOYMENT_TARGET = "16.0"
SWIFT_VERSION = "5.0"


def uid(name: str) -> str:
    """Stable 24-hex-char object ID from a logical name."""
    return hashlib.md5(f"waylink::{name}".encode()).hexdigest()[:24].upper()


def collect_sources():
    out = []
    for dirpath, dirnames, filenames in os.walk(SRC_DIR):
        dirnames.sort()
        for f in sorted(filenames):
            if f.endswith(".swift"):
                out.append(os.path.relpath(os.path.join(dirpath, f), ROOT))
    return out


def main():
    sources = collect_sources()
    if not sources:
        sys.exit("no Swift sources found under WayLink/")

    lines = []
    w = lines.append
    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {")
    w("\t};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")

    # ---- PBXBuildFile
    w("")
    w("/* Begin PBXBuildFile section */")
    for s in sources:
        w(f"\t\t{uid('build:' + s)} /* {os.path.basename(s)} in Sources */ = "
          f"{{isa = PBXBuildFile; fileRef = {uid('file:' + s)} /* {os.path.basename(s)} */; }};")
    w("/* End PBXBuildFile section */")

    # ---- PBXFileReference
    w("")
    w("/* Begin PBXFileReference section */")
    w(f"\t\t{uid('product:WayLink.app')} /* WayLink.app */ = "
      f"{{isa = PBXFileReference; explicitFileType = wrapper.application; "
      f"includeInIndex = 0; path = WayLink.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    for s in sources:
        w(f"\t\t{uid('file:' + s)} /* {os.path.basename(s)} */ = "
          f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
          f"path = {os.path.basename(s)}; sourceTree = \"<group>\"; }};")
    w(f"\t\t{uid('file:Info.plist')} /* Info.plist */ = "
      f"{{isa = PBXFileReference; lastKnownFileType = text.plist.xml; "
      f"path = Info.plist; sourceTree = \"<group>\"; }};")
    w("/* End PBXFileReference section */")

    # ---- PBXFrameworksBuildPhase
    w("")
    w("/* Begin PBXFrameworksBuildPhase section */")
    w(f"\t\t{uid('phase:frameworks')} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")

    # ---- PBXGroup
    w("")
    w("/* Begin PBXGroup section */")
    w(f"\t\t{uid('group:main')} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{uid('group:WayLink')} /* WayLink */,")
    w(f"\t\t\t\t{uid('group:products')} /* Products */,")
    w("\t\t\t);")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    w(f"\t\t{uid('group:products')} /* Products */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{uid('product:WayLink.app')} /* WayLink.app */,")
    w("\t\t\t);")
    w("\t\t\tname = Products;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    w(f"\t\t{uid('group:WayLink')} /* WayLink */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    for s in sources:
        w(f"\t\t\t\t{uid('file:' + s)} /* {os.path.basename(s)} */,")
    w(f"\t\t\t\t{uid('file:Info.plist')} /* Info.plist */,")
    w("\t\t\t);")
    w("\t\t\tpath = WayLink;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")
    w("/* End PBXGroup section */")

    # ---- PBXNativeTarget
    w("")
    w("/* Begin PBXNativeTarget section */")
    w(f"\t\t{uid('target:WayLink')} /* WayLink */ = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {uid('conflist:target')} /* Build configuration list for PBXNativeTarget \"WayLink\" */;")
    w("\t\t\tbuildPhases = (")
    w(f"\t\t\t\t{uid('phase:sources')} /* Sources */,")
    w(f"\t\t\t\t{uid('phase:frameworks')} /* Frameworks */,")
    w(f"\t\t\t\t{uid('phase:resources')} /* Resources */,")
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t);")
    w("\t\t\tname = WayLink;")
    w("\t\t\tproductName = WayLink;")
    w(f"\t\t\tproductReference = {uid('product:WayLink.app')} /* WayLink.app */;")
    w("\t\t\tproductType = \"com.apple.product-type.application\";")
    w("\t\t};")
    w("/* End PBXNativeTarget section */")

    # ---- PBXProject
    w("")
    w("/* Begin PBXProject section */")
    w(f"\t\t{uid('project')} /* Project object */ = {{")
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tLastSwiftUpdateCheck = 1500;")
    w("\t\t\t\tLastUpgradeCheck = 1500;")
    w("\t\t\t};")
    w(f"\t\t\tbuildConfigurationList = {uid('conflist:project')} /* Build configuration list for PBXProject \"WayLink\" */;")
    w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    w("\t\t\tdevelopmentRegion = en;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t);")
    w(f"\t\t\tmainGroup = {uid('group:main')};")
    w(f"\t\t\tproductRefGroup = {uid('group:products')} /* Products */;")
    w("\t\t\tprojectDirPath = \"\";")
    w("\t\t\tprojectRoot = \"\";")
    w(f"\t\t\ttargets = (")
    w(f"\t\t\t\t{uid('target:WayLink')} /* WayLink */,")
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")

    # ---- PBXResourcesBuildPhase
    w("")
    w("/* Begin PBXResourcesBuildPhase section */")
    w(f"\t\t{uid('phase:resources')} /* Resources */ = {{")
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")

    # ---- PBXSourcesBuildPhase
    w("")
    w("/* Begin PBXSourcesBuildPhase section */")
    w(f"\t\t{uid('phase:sources')} /* Sources */ = {{")
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for s in sources:
        w(f"\t\t\t\t{uid('build:' + s)} /* {os.path.basename(s)} in Sources */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")

    # ---- XCBuildConfiguration
    common_proj = [
        "ALWAYS_SEARCH_USER_PATHS = NO",
        "CLANG_ENABLE_MODULES = YES",
        "CLANG_ENABLE_OBJC_ARC = YES",
        "ENABLE_STRICT_OBJC_MSGSEND = YES",
        "GCC_C_LANGUAGE_STANDARD = gnu17",
        "SDKROOT = iphoneos",
        "IPHONEOS_DEPLOYMENT_TARGET = " + DEPLOYMENT_TARGET,
        "SWIFT_VERSION = " + SWIFT_VERSION,
    ]
    w("")
    w("/* Begin XCBuildConfiguration section */")
    for name, extra in (("Debug", ["DEBUG_INFORMATION_FORMAT = dwarf",
                                   "ENABLE_TESTABILITY = YES",
                                   "GCC_OPTIMIZATION_LEVEL = 0",
                                   "SWIFT_OPTIMIZATION_LEVEL = \"-Onone\"",
                                   "ONLY_ACTIVE_ARCH = YES"]),
                        ("Release", ["DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\"",
                                     "SWIFT_COMPILATION_MODE = wholemodule",
                                     "VALIDATE_PRODUCT = YES"])):
        w(f"\t\t{uid('cfg:project:' + name)} /* {name} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        for kv in common_proj + extra:
            w(f"\t\t\t\t{kv};")
        w("\t\t\t};")
        w(f"\t\t\tname = {name};")
        w("\t\t};")

    for name in ("Debug", "Release"):
        w(f"\t\t{uid('cfg:target:' + name)} /* {name} */ = {{")
        w("\t\t\tisa = XCBuildConfiguration;")
        w("\t\t\tbuildSettings = {")
        for kv in [
            "CODE_SIGN_STYLE = Automatic",
            "CURRENT_PROJECT_VERSION = 1",
            "DEVELOPMENT_TEAM = \"\"",
            "GENERATE_INFOPLIST_FILE = NO",
            "INFOPLIST_FILE = WayLink/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/Frameworks\",)",
            "MARKETING_VERSION = 1.0",
            "PRODUCT_BUNDLE_IDENTIFIER = " + BUNDLE_ID,
            "PRODUCT_NAME = \"$(TARGET_NAME)\"",
            "SUPPORTS_MACCATALYST = NO",
            "SWIFT_EMIT_LOC_STRINGS = YES",
            "TARGETED_DEVICE_FAMILY = \"1,2\"",
        ]:
            w(f"\t\t\t\t{kv};")
        w("\t\t\t};")
        w(f"\t\t\tname = {name};")
        w("\t\t};")
    w("/* End XCBuildConfiguration section */")

    # ---- XCConfigurationList
    w("")
    w("/* Begin XCConfigurationList section */")
    for key, label, ids in (
        ("conflist:project", "PBXProject \"WayLink\"",
         [uid("cfg:project:Debug"), uid("cfg:project:Release")]),
        ("conflist:target", "PBXNativeTarget \"WayLink\"",
         [uid("cfg:target:Debug"), uid("cfg:target:Release")]),
    ):
        w(f"\t\t{uid(key)} /* Build configuration list for {label} */ = {{")
        w("\t\t\tisa = XCConfigurationList;")
        w("\t\t\tbuildConfigurations = (")
        w(f"\t\t\t\t{ids[0]} /* Debug */,")
        w(f"\t\t\t\t{ids[1]} /* Release */,")
        w("\t\t\t);")
        w("\t\t\tdefaultConfigurationIsVisible = 0;")
        w("\t\t\tdefaultConfigurationName = Release;")
        w("\t\t};")
    w("/* End XCConfigurationList section */")

    w("\t};")
    w(f"\trootObject = {uid('project')} /* Project object */;")
    w("}")

    os.makedirs(PROJ_DIR, exist_ok=True)
    out = os.path.join(PROJ_DIR, "project.pbxproj")
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {out} ({len(sources)} sources)")


if __name__ == "__main__":
    main()
