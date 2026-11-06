{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks.actions-lock = pkgs.runCommand "actions-lock-check" { } ''
        cp -R ${../../.github} .github
        GH_ACTIONS_LOCK_REPO_ROOT="$PWD" \
          ${pkgs.lib.getExe pkgs.gh-actions-lock} --verify-local
        touch "$out"
      '';
    };
}
