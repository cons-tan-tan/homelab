{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      docsSvg = pkgs.writeShellApplication {
        name = "docs-svg";
        runtimeInputs = [ pkgs.typst ];
        text = ''
          export TYPST_FONT_PATHS=${pkgs.noto-fonts-cjk-sans}/share/fonts/opentype
          if [[ ! -d docs ]]; then
            printf 'Run this app from the repository root (docs/ must exist).\n' >&2
            exit 1
          fi

          shopt -s globstar nullglob
          for typst_source in docs/**/*.typ; do
            [[ -f "$typst_source" ]] || continue
            svg_path="''${typst_source%.typ}.svg"
            typst compile --root docs --ignore-system-fonts "$typst_source" "$svg_path"
            printf 'Generated %s\n' "$svg_path"
          done
        '';
      };
    in
    {
      apps.docs-svg = {
        type = "app";
        program = pkgs.lib.getExe docsSvg;
        meta.description = "Generate SVGs beside all Typst sources under docs/";
      };

      checks.docs-svg = pkgs.runCommand "docs-svg-check" { } ''
        cp -R ${../../docs} docs
        chmod -R u+w docs
        ${pkgs.lib.getExe docsSvg}
        touch "$out"
      '';
    };
}
