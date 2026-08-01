#
# Copyright (C) 2021 The LineageOS Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

ifneq ($(filter kvim1s kvim1s_car kvim1s_tab,$(TARGET_DEVICE)),)

LOCAL_PATH := device/khadas/kvim1s
FACTORY_PATH := device/khadas/kvim1s/factory

RADIO_FILES := $(wildcard $(FACTORY_PATH)/bootfiles/*)
$(foreach f, $(notdir $(RADIO_FILES)), \
    $(call add-radio-file,factory/bootfiles/$(f)))

## odm_ext / oem
# Both are slot-suffixed in gpt.bin and both are required first_stage_mount
# entries in fstab.amlogic, but neither is a standard AOSP image, so they were
# absent from AB_OTA_PARTITIONS and *_b stayed blank. The first OTA - which
# switches to slot B - therefore made first-stage init panic and bootloop.
#
# An OTA can only write a partition that has an image in the target-files zip,
# so both are staged as radio images: that puts them in RADIO/, and
# BOARD_PACK_RADIOIMAGES mirrors them into IMAGES/, which is where
# brillo_update_payload resolves them
# (system/update_engine/scripts/brillo_update_payload:474).
#
# odm_ext stays a prebuilt - it holds real Amlogic content (etc/tvconfig, PQ
# tables, logo_files) that this tree has no sources for. oem is built below.
KHADAS_ODM_EXT_IMAGE := $(PRODUCT_OUT)/odm_ext.img
KHADAS_OEM_IMAGE := $(PRODUCT_OUT)/oem.img

# odm_ext_a.PARTITION is an Android sparse image; update_engine writes raw bytes.
$(KHADAS_ODM_EXT_IMAGE): $(FACTORY_PATH)/odm_ext_a.PARTITION $(SIMG2IMG)
	@echo "Target odm_ext image: $@"
	$(hide) mkdir -p $(dir $@)
	$(hide) $(SIMG2IMG) $< $@

# oem is built from source rather than shipped as a blob. Nothing on this tree
# reads /oem - PRODUCT_OEM_PROPERTIES is set nowhere, and init no longer imports
# /oem/oem.prop - so the image is an empty ext4, which beats factory/oem_a.
# PARTITION: a 2022 eng blob whose only file sets stock Khadas identity props
# (ro.product.brand=Khadas, ro.product.model=VIM1S) that would fight LineageOS's
# if anything ever did import them.
#
# This duplicates build/make/core/tasks/oem_image.mk because that task is gated
# on 'oem_image' being an explicit make goal, so it never runs in a normal build.
#
# BUILD_IMAGE honours extfs_sparse_flag=-s, so this is an *Android sparse*
# image, unlike the raw factory/oem_a.PARTITION it replaces. The OTA path copes
# (brillo_update_payload:486 sniffs the 0x3aff26ed magic and runs simg2img), but
# factory/image_upgrade.cfg had to change to file_type="sparse" - writing the
# 45 KB sparse container raw left /oem unmountable and panicked first-stage init.
INTERNAL_OEMIMAGE_FILES := \
    $(filter $(TARGET_OUT_OEM)/%,$(ALL_DEFAULT_INSTALLED_MODULES))
oemimage_intermediates := $(call intermediates-dir-for,PACKAGING,oem)

$(KHADAS_OEM_IMAGE): $(INTERNAL_USERIMAGES_DEPS) $(INTERNAL_OEMIMAGE_FILES)
	$(call pretty,"Target oem fs image: $@")
	@mkdir -p $(TARGET_OUT_OEM)
	@mkdir -p $(oemimage_intermediates) && rm -rf $(oemimage_intermediates)/oem_image_info.txt
	$(call generate-image-prop-dictionary, $(oemimage_intermediates)/oem_image_info.txt,oem,skip_fsck=true)
	PATH=$(INTERNAL_USERIMAGES_BINARY_PATHS):$$PATH \
	    $(BUILD_IMAGE) \
	        $(TARGET_OUT_OEM) $(oemimage_intermediates)/oem_image_info.txt $@ $(TARGET_OUT)
	$(call assert-max-image-size,$@,$(BOARD_OEMIMAGE_PARTITION_SIZE))

INSTALLED_RADIOIMAGE_TARGET += $(KHADAS_ODM_EXT_IMAGE) $(KHADAS_OEM_IMAGE)
BOARD_PACK_RADIOIMAGES += odm_ext.img oem.img

PRODUCT_INSTALL_OUT := $(PRODUCT_OUT)/aml_install
PRODUCT_UPGRADE_OUT := $(PRODUCT_OUT)/aml_upgrade
INSTALL_PACKAGE_CONFIG_FILE := $(PRODUCT_INSTALL_OUT)/image_install.cfg
UPGRADE_PACKAGE_CONFIG_FILE := $(PRODUCT_UPGRADE_OUT)/image_upgrade.cfg
# Built from hardware/amlogic/tools/imagepacker (PRODUCT_HOST_PACKAGES in
# device.mk) rather than the proprietary $(FACTORY_PATH)/aml_image_v2_packer
# prebuilt. Packing needs -r2: the prebuilt emits v2 images, and the burner
# expects the v2 item info layout, while -r would give a v1 image.
AML_IMAGE_TOOL := $(HOST_OUT_EXECUTABLES)/aml_image_packer$(HOST_EXECUTABLE_SUFFIX)
INSTALLED_AML_INSTALL_PACKAGE_TARGET := $(PRODUCT_OUT)/aml_install_package.img
INSTALLED_AML_UPGRADE_PACKAGE_TARGET := $(PRODUCT_OUT)/aml_upgrade_package.img

define aml-copy-install-file
	$(hide) $(ACP) $(1) $(PRODUCT_INSTALL_OUT)/$(strip $(if $(2), $(2), $(notdir $(1))))
endef

define aml-copy-upgrade-file
	$(hide) $(ACP) $(1) $(PRODUCT_UPGRADE_OUT)/$(strip $(if $(2), $(2), $(notdir $(1))))
endef


## misc
# Both packages write every partition to slot A, so both have to reset the A/B
# metadata as well - misc is what U-Boot reads to pick a slot (get_valid_slot in
# cmd/amlogic/cmd_bootctl_vab.c derives active_slot/boot_part/slot-suffixes from
# it on every boot, so nothing else needs fixing up). Without this a board that
# an OTA has moved to slot B keeps booting _b after a factory flash, against
# images that were all written to _a, and bootloops.
#
# The stock bootfiles/misc.img was 512 bytes, so it could not even reach the
# bootloader_control at offset 2048; image_upgrade.cfg did not flash misc at all.
# Both images are now 64 KiB, generated once by factory/gen_misc.py, and zero
# everything but the control block - a factory flash has just replaced super, so
# a leftover snapshot-merge state would describe partitions that no longer exist.
#
#   misc.img          slot A active, command="boot-recovery". The install
#                     package writes super_empty.img, so it has to land in
#                     recovery to get the logical partitions flashed.
#   misc_upgrade.img  slot A active, no command - the upgrade package writes a
#                     real super.img and should boot straight into Android.
UPGRADE_IMAGES := \
    boot.img \
    dtb.img \
    dtbo.img \
    init_boot.img \
    logo.img \
    misc_upgrade.img \
    oem.img \
    super_empty.img \
    super.img \
    vbmeta_system.img \
    vbmeta.img \
    vendor_boot.img

INSTALL_IMAGES := \
    boot.img \
    dtb.img \
    dtbo.img \
    logo.img \
    init_boot.img \
    misc.img \
    super_empty.img \
    super.img \
    vbmeta_system.img \
    vbmeta.img \
    vendor_boot.img


$(INSTALLED_AML_INSTALL_PACKAGE_TARGET): $(addprefix $(PRODUCT_OUT)/,$(INSTALL_IMAGES)) $(ACP) $(AML_IMAGE_TOOL)
	$(hide) mkdir -p $(PRODUCT_INSTALL_OUT)
ifeq ($(WITH_CONSOLE_BL),true)
	$(hide) $(call aml-copy-install-file, $(FACTORY_PATH)/bootfiles/bootloader-console.img, bootloader.img)
else
	$(hide) $(call aml-copy-install-file, $(FACTORY_PATH)/bootfiles/bootloader.img, bootloader.img)
endif
	$(hide) $(call aml-copy-install-file, $(FACTORY_PATH)/bootfiles/u-boot.bin.sd.bin.signed)
	$(hide) $(call aml-copy-install-file, $(FACTORY_PATH)/bootfiles/u-boot.bin.usb.signed)
	$(hide) $(call aml-copy-install-file, $(FACTORY_PATH)/gpt.bin)
	$(hide) $(call aml-copy-install-file, $(PRODUCT_OUT)/logo.img)
	$(hide) $(call aml-copy-install-file, $(FACTORY_PATH)/aml_sdc_burn.ini)
	$(hide) $(call aml-copy-install-file, $(FACTORY_PATH)/usb_flow.aml)
	$(hide) $(call aml-copy-install-file, $(FACTORY_PATH)/image_install.cfg, image.cfg)
	$(hide) $(call aml-copy-install-file, $(FACTORY_PATH)/platform.conf)
	$(hide) $(call aml-copy-install-file, $(PRODUCT_OUT)/boot.img)
	$(hide) $(call aml-copy-install-file, $(PRODUCT_OUT)/dtb.img)
	$(hide) $(call aml-copy-install-file, $(PRODUCT_OUT)/dtbo.img)
	$(hide) $(call aml-copy-install-file, $(PRODUCT_OUT)/init_boot.img)
	$(hide) $(call aml-copy-install-file, $(PRODUCT_OUT)/super_empty.img, super.img)
	$(hide) $(call aml-copy-install-file, $(PRODUCT_OUT)/vbmeta.img)
	$(hide) $(call aml-copy-install-file, $(PRODUCT_OUT)/vbmeta_system.img)
	$(hide) $(call aml-copy-install-file, $(PRODUCT_OUT)/vendor_boot.img)
	$(hide) $(call aml-copy-install-file, $(PRODUCT_OUT)/misc.img)
	$(hide) $(AML_IMAGE_TOOL) -r2 $(PRODUCT_INSTALL_OUT)/image.cfg $(PRODUCT_INSTALL_OUT)/ $@
	$(hide) rm -rf $(PRODUCT_INSTALL_OUT)
	$(hide) echo " $@ created"

.PHONY: aml_install
aml_install: $(INSTALLED_AML_INSTALL_PACKAGE_TARGET)

BUILT_TARGET_FILES_ZIPROOT := $(call intermediates-dir-for,PACKAGING,target_files)/$(TARGET_PRODUCT)-target_files
$(BUILT_TARGET_FILES_ZIPROOT).zip: $(BUILT_TARGET_FILES_ZIPROOT)/IMAGES/aml_install_package.img

$(BUILT_TARGET_FILES_ZIPROOT)/IMAGES/aml_install_package.img: $(BUILT_TARGET_FILES_ZIPROOT).zip.list $(PRODUCT_OUT)/aml_install_package.img
	@mkdir -p $(dir $@)
	@cp $(PRODUCT_OUT)/aml_install_package.img $@
	@echo $@ >> $(BUILT_TARGET_FILES_ZIPROOT).zip.list

INSTALLED_RADIOIMAGE_TARGET += $(INSTALLED_AML_INSTALL_PACKAGE_TARGET)

$(INSTALLED_AML_UPGRADE_PACKAGE_TARGET): $(addprefix $(PRODUCT_OUT)/,$(UPGRADE_IMAGES)) $(ACP) $(AML_IMAGE_TOOL)
	$(hide) mkdir -p $(PRODUCT_UPGRADE_OUT)
ifeq ($(WITH_CONSOLE_BL),true)
	$(hide) $(call aml-copy-upgrade-file, $(FACTORY_PATH)/bootfiles/bootloader-console.img, bootloader.img)
else
	$(hide) $(call aml-copy-upgrade-file, $(FACTORY_PATH)/bootfiles/bootloader.img, bootloader.img)
endif
	$(hide) $(call aml-copy-upgrade-file, $(PRODUCT_OUT)/logo.img)
	$(hide) $(call aml-copy-upgrade-file, $(FACTORY_PATH)/bootfiles/u-boot.bin.sd.bin.signed)
	$(hide) $(call aml-copy-upgrade-file, $(FACTORY_PATH)/bootfiles/u-boot.bin.usb.signed)
	$(hide) $(call aml-copy-upgrade-file, $(FACTORY_PATH)/usb_flow.aml)
	$(hide) $(call aml-copy-upgrade-file, $(FACTORY_PATH)/aml_sdc_burn.ini)
	$(hide) $(call aml-copy-upgrade-file, $(FACTORY_PATH)/gpt.bin)
	$(hide) $(call aml-copy-upgrade-file, $(FACTORY_PATH)/image_upgrade.cfg, image.cfg)
	$(hide) $(call aml-copy-upgrade-file, $(FACTORY_PATH)/platform.conf)
	$(hide) $(call aml-copy-upgrade-file, $(FACTORY_PATH)/odm_ext_a.PARTITION)
	$(hide) $(call aml-copy-upgrade-file, $(KHADAS_OEM_IMAGE))
	$(hide) $(call aml-copy-upgrade-file, $(PRODUCT_OUT)/logo.img)
	$(hide) $(call aml-copy-upgrade-file, $(PRODUCT_OUT)/boot.img)
	$(hide) $(call aml-copy-upgrade-file, $(PRODUCT_OUT)/dtb.img)
	$(hide) $(call aml-copy-upgrade-file, $(PRODUCT_OUT)/init_boot.img)
	$(hide) $(call aml-copy-upgrade-file, $(PRODUCT_OUT)/dtbo.img)
	$(hide) $(call aml-copy-upgrade-file, $(PRODUCT_OUT)/super.img)
	$(hide) $(call aml-copy-upgrade-file, $(PRODUCT_OUT)/vbmeta.img)
	$(hide) $(call aml-copy-upgrade-file, $(PRODUCT_OUT)/vbmeta_system.img)
	$(hide) $(call aml-copy-upgrade-file, $(PRODUCT_OUT)/vendor_boot.img)
	$(hide) $(call aml-copy-upgrade-file, $(PRODUCT_OUT)/misc_upgrade.img, misc.img)
	$(hide) $(AML_IMAGE_TOOL) -r2 $(PRODUCT_UPGRADE_OUT)/image.cfg $(PRODUCT_UPGRADE_OUT)/ $@
	$(hide) rm -rf $(PRODUCT_UPGRADE_OUT)
	$(hide) echo " $@ created"

.PHONY: aml_upgrade
aml_upgrade: $(INSTALLED_AML_UPGRADE_PACKAGE_TARGET)

$(BUILT_TARGET_FILES_DIR): $(INSTALLED_RADIOIMAGE_TARGET)

endif
