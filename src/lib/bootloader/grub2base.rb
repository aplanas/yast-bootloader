# frozen_string_literal: true

require "yast"
require "yast2/execute"
require "yast2/target_file" # adds ability to work with cfa in inst-sys
require "bootloader/bootloader_base"
require "bootloader/exceptions"
require "bootloader/sections"
require "bootloader/grub2pwd"
require "bootloader/udev_mapping"
require "bootloader/serial_console"
require "bootloader/language"
require "cfa/grub2/default"
require "cfa/grub2/grub_cfg"
require "cfa/matcher"
require "cfa/placer"

Yast.import "Arch"
Yast.import "BootArch"
Yast.import "BootStorage"
Yast.import "HTML"
Yast.import "Initrd"
Yast.import "Kernel"
Yast.import "Mode"
Yast.import "Pkg"
Yast.import "Product"
Yast.import "ProductFeatures"
Yast.import "Stage"

module Bootloader
  # Common base for GRUB2 specialized classes
  # rubocop:disable Metrics/ClassLength
  class Grub2Base < BootloaderBase
    include Yast::Logger
    include Yast::I18n

    # @!attribute password
    #    @return [::Bootloader::GRUB2Pwd] stored password configuration object
    attr_reader :password

    attr_reader :sections
    # @!attribute grub_default
    #    @return [CFA::Grub2::Default] grub2 configuration object
    attr_reader :grub_default

    attr_accessor :pmbr_action

    # @return [Boolean]
    attr_accessor :trusted_boot

    attr_accessor :secure_boot

    # @!attribute console
    #   @return [::Bootloader::SerialConsole] serial console or nil if none
    attr_reader :console

    def initialize
      super

      textdomain "bootloader"
      @password = ::Bootloader::GRUB2Pwd.new
      @grub_default = ::CFA::Grub2::Default.new
      @sections = ::Bootloader::Sections.new
      @pmbr_action = :nothing
      @explicit_cpu_mitigations = false
    end

    # general functions

    # set pmbr flags on boot disks
    # TODO: move it to own place
    def pmbr_setup(*devices)
      return if @pmbr_action == :nothing

      action_parted = case @pmbr_action
      when :add    then "on"
      when :remove then "off"
      else raise "invalid action #{action}"
      end

      devices.each do |dev|
        Yast::Execute.locally("/usr/sbin/parted", "-s", dev, "disk_set", "pmbr_boot", action_parted)
      end
    end

    def cpu_mitigations
      CpuMitigations.from_kernel_params(grub_default.kernel_params)
    end

    def explicit_cpu_mitigations
      @explicit_cpu_mitigations ? cpu_mitigations : nil
    end

    def cpu_mitigations=(value)
      log.info "setting mitigations to #{value}"
      @explicit_cpu_mitigations = true
      value.modify_kernel_params(grub_default.kernel_params)
    end

    def read
      super

      begin
        grub_default.load
      rescue Errno::ENOENT
        raise BrokenConfiguration, _("File /etc/default/grub missing on system")
      end

      grub_cfg = CFA::Grub2::GrubCfg.new
      begin
        grub_cfg.load
      rescue Errno::ENOENT
        # there may not need to be grub.cfg generated (bnc#976534),(bsc#1124064)
        log.info "/boot/grub2/grub.cfg is missing. Defaulting to empty one."
      end
      @sections = ::Bootloader::Sections.new(grub_cfg)
      log.info "grub sections: #{@sections.all}"

      self.trusted_boot = Systeminfo.trusted_boot_active?
      self.secure_boot = Systeminfo.secure_boot_active?
    end

    def write
      super

      log.info "writing /etc/default/grub #{grub_default.inspect}"
      grub_default.save
      @sections.write
      @password.write
      Yast::Execute.on_target("/usr/sbin/grub2-mkconfig", "-o", "/boot/grub2/grub.cfg",
        env: systemwide_locale)
    end

    def propose
      super

      propose_os_probing
      propose_terminal
      propose_timeout
      propose_encrypted

      if grub_default.kernel_params.empty?
        kernel_line = Yast::BootArch.DefaultKernelParams(propose_resume)
        grub_default.kernel_params.replace(kernel_line)
      end
      grub_default.gfxmode ||= "auto"
      grub_default.recovery_entry.disable unless grub_default.recovery_entry.defined?
      grub_default.distributor ||= ""
      grub_default.default = "saved"
      # always propose true as grub2 itself detect if btrfs used
      grub_default.generic_set("SUSE_BTRFS_SNAPSHOT_BOOTING", "true")

      propose_serial
      propose_xen_hypervisor

      self.trusted_boot = false
      self.secure_boot = Systeminfo.secure_boot_active?
    end

    def merge(other)
      super

      merge_grub_default(other)
      merge_password(other)
      merge_pmbr_action(other)
      merge_sections(other)

      self.trusted_boot = other.trusted_boot unless other.trusted_boot.nil?
      self.secure_boot = other.secure_boot unless other.secure_boot.nil?
    end

    def enable_serial_console(console_arg_string)
      @console = SerialConsole.load_from_console_args(console_arg_string)
      raise ::Bootloader::InvalidSerialConsoleArguments unless @console

      grub_default.serial_console = console.console_args

      placer = CFA::ReplacePlacer.new(serial_console_matcher)
      kernel_params = grub_default.kernel_params
      kernel_params.add_parameter("console", console.kernel_args, placer)
    end

    def disable_serial_console
      @console = nil
      grub_default.kernel_params.remove_parameter(serial_console_matcher)
      grub_default.serial_console = ""
    end

    def serial_console?
      !console.nil?
    end

  private

    def systemwide_locale
      begin
        language = ::Bootloader::Language.new
        language.load
      rescue Errno::ENOENT
        log.info "/etc/sysconfig/language does not exist. Using current locale"
        return {}
      end

      lang = language.rc_lang || "C"

      log.info "System language is #{lang}"

      { "LC_MESSAGES" => nil, "LC_ALL" => nil, "LANGUAGE" => nil, "LANG" => lang }
    end

    def merge_pmbr_action(other)
      log.info "merging pmbr action. own #{@pmbr_action}, other #{other.pmbr_action}"
      @pmbr_action = other.pmbr_action if other.pmbr_action
    end

    def merge_sections(other)
      return if !other.sections.default || other.sections.default.empty?

      sections.default = other.sections.default
    end

    def merge_password(other)
      @password = other.password
    end

    KERNEL_FLAVORS_METHODS = [:kernel_params, :xen_hypervisor_params, :xen_kernel_params].freeze

    def merge_grub_default(other)
      default = grub_default
      other_default = other.grub_default

      log.info "before merge default #{default.inspect}"
      log.info "before merge other #{other_default.inspect}"

      KERNEL_FLAVORS_METHODS.each do |method|
        merge_kernel_params(method, other_default)
      end

      merge_attributes(default, other_default)

      # explicitly set mitigations means overwrite of our
      if other.explicit_cpu_mitigations
        log.info "merging cpu_mitigations"
        self.cpu_mitigations = other.cpu_mitigations
      end
      log.info "mitigations after merge #{cpu_mitigations}"

      log.info "after merge default #{default.inspect}"
    end

    def merge_kernel_params(method, other_default)
      other_params = other_default.public_send(method)
      default_params = grub_default.public_send(method)
      return if other_params.empty?

      default_serialize = default_params.serialize
      # handle specially noresume as it should lead to remove all other resume
      default_serialize.gsub!(/resume=\S+/, "") if other_params.parameter("noresume")
      # prevent double cpu_mitigations params
      default_serialize.gsub!(/mitigations=\S+/, "") if other_params.parameter("mitigations")

      new_kernel_params = default_serialize + " " + other_params.serialize
      # deduplicate identicatel parameter. Keep always the last one ( so reverse is needed ).
      new_params = new_kernel_params.split.reverse.uniq.reverse.join(" ")

      default_params.replace(new_params)
    end

    def merge_attributes(default, other)
      # string attributes
      [:serial_console, :timeout, :hidden_timeout, :distributor,
       :gfxmode, :theme, :default].each do |attr|
        val = other.public_send(attr)
        default.public_send((attr.to_s + "=").to_sym, val) if val
      end

      # array attributes with multiple values allowed
      [:terminal].each do |attr|
        val = other.public_send(attr)
        default.public_send((attr.to_s + "=").to_sym, val) if val
      end

      # specific attributes that are not part of cfa
      ["SUSE_BTRFS_SNAPSHOT_BOOTING", "GRUB_GFXPAYLOAD_LINUX", "GRUB_USE_LINUXEFI"].each do |attr|
        val = other.generic_get(attr)
        grub_default.generic_set(attr, val) if val
      end

      # boolean attributes, instance of {CFA::Boolean}
      [:os_prober, :cryptodisk].each do |attr|
        val = other.public_send(attr)
        default.public_send(attr).value = val.enabled? if val.defined?
      end
    end

    def serial_console_matcher
      CFA::Matcher.new(key: "console", value_matcher: /tty(S|AMA)/)
    end

    def propose_os_probing
      os_prober = grub_default.os_prober
      return if os_prober.defined?

      # s390 do not have os_prober, see bnc#868909#c2
      # ppc have slow os_prober, see boo#931653
      disable_os_prober = (Yast::Arch.s390 || Yast::Arch.ppc) ||
        Yast::ProductFeatures.GetBooleanFeature("globals", "disable_os_prober")
      if disable_os_prober
        os_prober.disable
      else
        os_prober.enable
      end
    end

    def propose_terminal
      begin
        return if grub_default.terminal
      rescue RuntimeError => e
        log.info "Proposing terminal again due to #{e}"
      end

      # for ppc: Boards with graphics are rare and those are PowerNV, where
      # modules are not used, see bsc#911682
      grub_default.terminal = (Yast::Arch.s390 || Yast::Arch.ppc) ? [:console] : [:gfxterm]
      grub_default.generic_set("GRUB_GFXPAYLOAD_LINUX", "text") if Yast::Arch.ppc
    end

    def propose_timeout
      return if grub_default.timeout

      grub_default.timeout = "8"
    end

    def propose_serial
      @console = SerialConsole.load_from_kernel_args(grub_default.kernel_params)
      return unless @console

      grub_default.serial_console = console.console_args
      propose_xen_serial
    end

    def propose_xen_serial
      return unless serial_console?

      grub_default.xen_kernel_params.replace(console.xen_kernel_args)
      grub_default.xen_hypervisor_params.replace(console.xen_hypervisor_args)
    end

    def propose_xen_hypervisor
      return if serial_console?
      return if Dir["/dev/fb*"].empty?

      matcher = CFA::Matcher.new(key: "vga")
      placer = CFA::ReplacePlacer.new(matcher)
      grub_default.xen_hypervisor_params.add_parameter("vga", "gfx-1024x768x16", placer)
    end

    def propose_resume
      swap_parts = Yast::BootStorage.available_swap_partitions
      largest_swap_part = (swap_parts.max_by { |_part, size| size } || [""]).first

      resume = Yast::BootArch.ResumeAvailable ? largest_swap_part : ""
      # try to use label or udev id for device name... FATE #302219
      resume = UdevMapping.to_mountby_device(resume) if resume != "" && !resume.nil?

      resume
    end

    def propose_encrypted
      grub_default.cryptodisk.value = !!Yast::BootStorage.encrypted_boot?
    end

    def secure_boot_summary
      _("Secure Boot:") + " " + (secure_boot ? _("enabled") : _("disabled")) + " " +
        if secure_boot
          "<a href=\"disable_secure_boot\">(" + _("disable") + ")</a>"
        else
          "<a href=\"enable_secure_boot\">(" + _("enable") + ")</a>"
        end
    end

    def trusted_boot_summary
      _("Trusted Boot:") + " " + (trusted_boot ? _("enabled") : _("disabled")) + " " +
        if trusted_boot
          "<a href=\"disable_trusted_boot\">(" + _("disable") + ")</a>"
        else
          "<a href=\"enable_trusted_boot\">(" + _("enable") + ")</a>"
        end
    end
  end
  # rubocop:enable Metrics/ClassLength
end
