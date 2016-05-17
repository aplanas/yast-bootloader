require "yast"
require "yast2/execute"

Yast.import "Arch"

module Bootloader
  # Wraps grub install script for easier usage.
  class GrubInstall
    def initialize(efi: false)
      @efi = efi
    end

    def execute(devices: nil, secure_boot: false, trusted_boot: false)
      raise "cannot have secure boot without efi" if secure_boot && !@efi
      raise "cannot have trusted boot with efi" if trusted_boot && @efi

      cmd = []
      if secure_boot
        cmd << "/usr/sbin/shim-install" << "--config-file=/boot/grub2/grub.cfg"
      else
        cmd << "/usr/sbin/grub2-install" << "--target=#{target}"
        # Do skip-fs-probe to avoid error when embedding stage1
        # to extended partition
        cmd << "--force" << "--skip-fs-probe"
        cmd << "--directory=/usr/lib/trustedgrub2/#{target}" if trusted_boot
      end

      # EFI has 2 boot paths. The default is that there is a target file listed
      # in the boot list. The boot list is stored in NVRAM and exposed as
      # efivars.
      #
      # If no entry in the boot list was bootable (or a removable media is in
      # the boot list), EFI falls back to removable media booting which loads
      # a default file from /efi/boot/boot.efi.
      #
      # On U-Boot EFI capable systems we do not have NVRAM because we would
      # have to store that on the same flash that Linux may be running on,
      # creating device ownership conflicts. So on those systems we instead have
      # to rely on the removable boot case.
      #
      # The easiest heuristic is that on "normal" EFI systems with working
      # NVRAM, there is at least one efi variable visible. On systems without
      # working NVRAM, we either see no efivars at all (booted via non-EFI entry
      # point) or there is no efi variable exposed. Install grub in the
      # removable location there.
      if @efi && Dir.glob("/sys/firmware/efi/efivars/*").empty?
        cmd << "--no-nvram" << "--removable"
      end

      if devices && !devices.empty?
        devices.each do |dev|
          Yast::Execute.on_target(cmd + [dev])
        end
      else
        # s390 and efi can install grub2 without device, otherwise user
        # intentionally do not want grub2 installed by yast2
        Yast::Execute.on_target(cmd) if Yast::Arch.s390 || @efi
      end
    end

  private

    def target
      @target ||= case Yast::Arch.architecture
                  when "i386"
                    if @efi
                      "i386-efi"
                    else
                      "i386-pc"
                    end
                  when "x86_64"
                    if @efi
                      "x86_64-efi"
                    else
                      "i386-pc"
                    end
                  when "ppc", "ppc64"
                    raise "EFI on ppc not supported" if @efi
                    "powerpc-ieee1275"
                  when "s390_32", "s390_64"
                    raise "EFI on s390 not supported" if @efi
                    "s390x-emu"
                  when "aarch64"
                    raise "Only EFI supported on aarch64" unless @efi
                    "arm64-efi"
                  else
                    raise "unsupported architecture '#{Yast::Arch.architecture}'"
                  end
    end
  end
end
