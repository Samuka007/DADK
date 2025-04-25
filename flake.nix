{
  description = "DADK";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane.url = "github:ipetkov/crane";

    flake-utils.url = "github:numtide/flake-utils";

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, crane, flake-utils, advisory-db, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        # NB: we don't need to overlay our custom toolchain for the *entire*
        # pkgs (which would require rebuidling anything else which uses rust).
        # Instead, we just want to update the scope that crane will use by appending
        # our specific toolchain there.
        craneLib = (crane.mkLib pkgs).overrideToolchain (p: (p.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml));

        inherit (pkgs) lib;

        src = craneLib.cleanCargoSource ./.;

        # Common arguments can be set here to avoid repeating them later
        commonArgs = {
          inherit src;
          strictDeps = true;

          buildInputs = with pkgs; [
            # Add additional build inputs here
            openssl
            util-linux
            multipath-tools
            dosfstools
          ] ++ lib.optionals pkgs.stdenv.isDarwin [
            # Additional darwin specific inputs can be set here
            pkgs.libiconv
          ];

          nativeBuildInputs = with pkgs; [
            openssl
            pkg-config
          ];
          
          # Set OpenSSL environment variables
          OPENSSL_DIR = "${pkgs.openssl.dev}";
          OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
          
          # Additional environment variables can be set directly
          # MY_CUSTOM_VAR = "some value";
        };

        # Build *just* the cargo dependencies (of the entire workspace),
        # so we can reuse all of that work (e.g. via cachix) when running in CI
        # It is *highly* recommended to use something like cargo-hakari to avoid
        # cache misses when building individual top-level-crates
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        individualCrateArgs = commonArgs // {
          inherit cargoArtifacts;
          inherit (craneLib.crateNameFromCargoToml { inherit src; }) version;
          # NB: we disable tests since we'll run them all via cargo-nextest
          doCheck = false;
        };

        fileSetForCrate = crate: lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./Cargo.toml
            ./Cargo.lock
            (craneLib.fileset.commonCargoSources ./crates/test_base)
            (craneLib.fileset.commonCargoSources ./dadk)
            (craneLib.fileset.commonCargoSources ./dadk-config)
            (craneLib.fileset.commonCargoSources ./dadk-user)
            (craneLib.fileset.commonCargoSources crate)
          ];
        };

        # Build the top-level crates of the workspace as individual derivations.
        # This allows consumers to only depend on (and build) only what they need.
        # Though it is possible to build the entire workspace as a single derivation,
        # so this is left up to you on how to organize things
        #
        # Note that the cargo workspace must define `workspace.members` using wildcards,
        # otherwise, omitting a crate (like we do below) will result in errors since
        # cargo won't be able to find the sources for all members.
        dadk = craneLib.buildPackage (individualCrateArgs // {
          pname = "dadk";
          cargoExtraArgs = "-p dadk";
          src = fileSetForCrate ./dadk;
        });
      in
      {
        checks = {
          # Build the crates as part of `nix flake check` for convenience
          inherit dadk;

          # Run clippy (and deny all warnings) on the workspace source,
          # again, reusing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          my-workspace-clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          });

          my-workspace-doc = craneLib.cargoDoc (commonArgs // {
            inherit cargoArtifacts;
          });

          # Check formatting
          my-workspace-fmt = craneLib.cargoFmt {
            inherit src;
          };

          my-workspace-toml-fmt = craneLib.taploFmt {
            src = pkgs.lib.sources.sourceFilesBySuffices src [ ".toml" ];
            # taplo arguments can be further customized below as needed
            # taploExtraArgs = "--config ./taplo.toml";
          };

          # Audit dependencies
          my-workspace-audit = craneLib.cargoAudit {
            inherit src advisory-db;
          };

          # Audit licenses
          my-workspace-deny = craneLib.cargoDeny {
            inherit src;
          };

          # Run tests with cargo-nextest
          # Consider setting `doCheck = false` on other crate derivations
          # if you do not want the tests to run twice
          my-workspace-nextest = craneLib.cargoNextest (commonArgs // {
            inherit cargoArtifacts;
            partitions = 1;
            partitionType = "count";
            cargoNextestPartitionsExtraArgs = "--no-tests=pass";
          });
        };

        packages = {
          default = dadk;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = dadk;
        };

        devShells.default = craneLib.devShell {
          # Inherit inputs from checks.
          checks = self.checks.${system};

          # Additional dev-shell environment variables can be set directly
          # MY_CUSTOM_DEVELOPMENT_VAR = "something else";

          # Extra inputs can be added here; cargo and rustc are provided by default.
          packages = [];
        };
      });
}
