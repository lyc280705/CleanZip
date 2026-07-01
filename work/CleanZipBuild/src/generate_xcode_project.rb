#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "xcodeproj"

root = File.expand_path("..", __dir__)
project_path = File.join(root, "CleanZip.xcodeproj")

FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path, false, 60)

main_group = project.main_group
main_group.set_source_tree("<group>")

src_group = main_group.new_group("src", "src")
resources_group = src_group.new_group("Resources", "src/Resources")
icon_group = main_group.new_group("Icon", nil)

main_ref = src_group.new_file("main.swift")
service_ref = src_group.new_file("service.swift")
app_info_ref = src_group.new_file("CleanZip-Info.plist")
service_info_ref = src_group.new_file("CleanZipService-Info.plist")
resources_group.new_file("7zz")
resources_group.new_file("7-Zip-License.txt")
resources_group.new_file("7-Zip-readme.txt")
resources_group.new_file("AppIcon.icns")
resources_group.new_file("CleanZipIcon.icns")

asset_catalog_ref = main_group.new_file("Assets.xcassets")
asset_catalog_ref.last_known_file_type = "folder.assetcatalog"

icon_ref = icon_group.new_file("AppIcon.icon")
icon_ref.last_known_file_type = "folder.iconcomposer.icon"

def configure_target(target, info_plist, bundle_id, executable_name, product_name, wrapper_extension)
  target.build_configurations.each do |config|
    config.build_settings["ARCHS"] = "arm64 x86_64"
    config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
    config.build_settings["CLANG_ENABLE_MODULES"] = "YES"
    config.build_settings["CODE_SIGN_IDENTITY"] = "-"
    config.build_settings["CODE_SIGN_STYLE"] = "Manual"
    config.build_settings["COMBINE_HIDPI_IMAGES"] = "YES"
    config.build_settings["DEVELOPMENT_TEAM"] = ""
    config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
    config.build_settings["INFOPLIST_FILE"] = info_plist
    config.build_settings["LD_RUNPATH_SEARCH_PATHS"] = "$(inherited) @executable_path/../Frameworks"
    config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
    config.build_settings["ONLY_ACTIVE_ARCH"] = "NO"
    config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id
    config.build_settings["PRODUCT_NAME"] = product_name
    config.build_settings["SDKROOT"] = "macosx"
    config.build_settings["SWIFT_VERSION"] = "5.0"
    config.build_settings["WRAPPER_EXTENSION"] = wrapper_extension

    if config.name == "Release"
      config.build_settings["COPY_PHASE_STRIP"] = "YES"
      config.build_settings["SWIFT_COMPILATION_MODE"] = "wholemodule"
      config.build_settings["SWIFT_OPTIMIZATION_LEVEL"] = "-O"
    else
      config.build_settings["COPY_PHASE_STRIP"] = "NO"
      config.build_settings["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone"
    end
  end

  target.product_name = product_name
  target.product_reference.path = "#{product_name}.#{wrapper_extension}"
  target.product_reference.name = "#{product_name}.#{wrapper_extension}"
  target.product_reference.explicit_file_type = "wrapper.application"
  target.product_reference.include_in_index = "0"

  phase = target.new_shell_script_build_phase("Copy CleanZip Resources")
  phase.shell_script = <<~'SH'
    set -euo pipefail

    resources_source="$SRCROOT/src/Resources"
    resources_destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"

    if [[ -d "$resources_source" ]]; then
      rsync -a "$resources_source/" "$resources_destination/"
    fi

    if [[ -d "$SRCROOT/AppIcon.icon" ]]; then
      rm -rf "$resources_destination/AppIcon.icon"
      ditto "$SRCROOT/AppIcon.icon" "$resources_destination/AppIcon.icon"
    fi

    if [[ -x "$resources_destination/7zz" ]]; then
      chmod +x "$resources_destination/7zz"
    fi
  SH

  target
end

app_target = project.new_target(:application, "CleanZip", :osx, "14.0")
app_target.source_build_phase.add_file_reference(main_ref)
app_target.resources_build_phase.add_file_reference(asset_catalog_ref)
app_target.resources_build_phase.add_file_reference(icon_ref)
configure_target(
  app_target,
  "src/CleanZip-Info.plist",
  "local.codex.cleanzip",
  "CleanZip",
  "CleanZip",
  "app"
)

service_target = project.new_target(:application, "CleanZipService", :osx, "14.0")
service_target.source_build_phase.add_file_reference(service_ref)
service_target.resources_build_phase.add_file_reference(asset_catalog_ref)
service_target.resources_build_phase.add_file_reference(icon_ref)
configure_target(
  service_target,
  "src/CleanZipService-Info.plist",
  "local.codex.cleanzip.service",
  "CleanZipService",
  "CleanZipService",
  "service"
)

project.build_configurations.each do |config|
  config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
  config.build_settings["SDKROOT"] = "macosx"
end

project.save
