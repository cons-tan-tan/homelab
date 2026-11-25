{
  config,
  lib,
  pkgs,
  ...
}:
let
  cpuFreq = "/sys/devices/system/cpu/cpufreq";
  gpu = "/sys/bus/pci/drivers/amdgpu/0000:05:00.0";
  governor = "powersave";
  eppPreferences = [
    "balance_power"
    "power"
    "balance_performance"
    "default"
    "performance"
  ];
  fixedSettings = {
    "${cpuFreq}/boost" = "0";
    "${gpu}/power_dpm_force_performance_level" = "auto";
    "${gpu}/power_dpm_state" = "balanced";
  };
  rules = fixedSettings // {
    "${cpuFreq}/policy*/scaling_governor" = governor;
  };
  ruleName = "pve-power-profile";

  powerProfile = pkgs.writeShellApplication {
    name = "pve-power-profile";
    runtimeInputs = [ pkgs.coreutils ];
    runtimeEnv = {
      inherit
        cpuFreq
        governor
        eppPreferences
        fixedSettings
        ;
      ruleFile = "${ruleName}.conf";
    };
    text = builtins.readFile ./pve01-power-profile.sh;
  };
in
{
  # Drivers may still be loading during global tmpfiles setup. The service
  # reapplies these rules and verifies every attribute before guests start.
  systemd.tmpfiles.settings.${ruleName} = lib.mapAttrs (_: value: { "w-".argument = value; }) rules;

  environment.etc."systemd/system/pve-power-profile.service" = {
    source = "${config.systemd.units."pve-power-profile.service".unit}/pve-power-profile.service";
    replaceExisting = true;
  };

  systemd.services.pve-power-profile = {
    description = "Apply Proxmox host power profile";
    wantedBy = [ "multi-user.target" ];
    after = [
      "systemd-modules-load.service"
      "local-fs.target"
    ];
    before = [ "pve-guests.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe powerProfile;
      RemainAfterExit = true;
    };
  };
}
