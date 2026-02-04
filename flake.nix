{
  description = "elixir, erlang";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        erlang = pkgs.beam.interpreters.erlang_28;
        elixir = pkgs.beam.packages.erlang_28.elixir_1_19;
        hex = pkgs.beam.packages.erlang_28.hex;
        rebar3 = pkgs.beam.packages.erlang_28.rebar3;
        MIX_PATH = "${hex}/lib/erlang/lib/hex-${hex.version}/ebin";
        MIX_REBAR3 = "${rebar3}/bin/rebar3";
      in
      {
        devShells.default = pkgs.mkShell {
          inherit MIX_PATH MIX_REBAR3;
          MIX_HOME = ".cache/mix";
          HEX_HOME = ".cache/hex";
          ERL_AFLAGS = "-kernel shell_history enabled";

          packages = [
            elixir
            erlang
          ];
        };
      }
    );
}