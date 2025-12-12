{ pkgs, lib, config, inputs, ... }:

{
  # https://devenv.sh/packages/
  packages = [ pkgs.git ];

  languages.zig = {
    enable = true;
    version = "0.15.1";
  };

  env.ZLS_LOCATION = "${pkgs.zls}/bin/zls";
}
