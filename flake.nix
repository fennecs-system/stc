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
            pkgs.postgresql_18
          ];

          shellHook = ''
            export PGDATA="$PWD/.postgres/data"
            export PGHOST="localhost"
            export PGPORT="5432"

            if [ ! -d "$PGDATA" ]; then
              initdb "$PGDATA" \
                --no-locale \
                --encoding=UTF8 \
                --auth=trust \
                --username=postgres \
                > /dev/null
              echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"
              echo "unix_socket_directories = '$PWD/.postgres'" >> "$PGDATA/postgresql.conf"
            fi

            if ! pg_ctl -D "$PGDATA" status > /dev/null 2>&1; then
              pg_ctl -D "$PGDATA" -l "$PGDATA/postgres.log" -s start
            fi
          '';
        };
      }
    );
}