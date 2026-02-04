{
  description = "elixir, erlang";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      pkgs = import nixpkgs { system = "aarch64-darwin"; }; 
      erlang = pkgs.beam.interpreters.erlang_28;
      elixir = pkgs.beam.packages.erlang_28.elixir_1_19;
      hex = pkgs.beam.packages.erlang.hex;
      MIX_PATH = "${hex}/archives/hex-${hex.version}/hex-${hex.version}/ebin";
      rebar3 = pkgs.beam.packages.erlang.rebar3;
      MIX_REBAR3 = "${rebar3}/bin/rebar3"; 
    in   
    {
      devShell.aarch64-darwin = pkgs.mkShell {
        inherit MIX_PATH MIX_REBAR3;
        MIX_HOME = ".cache/mix";
        HEX_HOME = ".cache/hex";
        ERL_AFLAGS = "-kernel shell_history enabled";
         
        packages = [
          elixir
          erlang
        ];
      };

      devShell.devShell.x86_64-linux = pkgs.mkShell {
        MIX_HOME = ".cache/mix";
        HEX_HOME = ".cache/hex";
        ERL_AFLAGS = "-kernel shell_history enabled";
         
        packages = [
          elixir
          erlang
        ];
      };
    
    };
}
