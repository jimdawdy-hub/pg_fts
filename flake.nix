{
  description = "pg_fts — BM25 full-text search for PostgreSQL (bm25 index access method)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # PostgreSQL majors this extension supports and nixpkgs packages.
        # PG 17 and 18 are the released, packaged targets; 19/20 devel are
        # exercised in CI and on the buildfarm hosts, not from nixpkgs.
        pgVersions = {
          pg17 = pkgs.postgresql_17;
          pg18 = pkgs.postgresql_18 or pkgs.postgresql_17;
        };

        # nixpkgs' postgresql is built WITHOUT --enable-tap-tests and does not
        # ship the PostgreSQL::Test perl harness, so `make installcheck` silently
        # skips the t/*.pl TAP tests.  This override rebuilds PostgreSQL with TAP
        # enabled (IPC::Run at configure time) and installs the harness, so the
        # tap-* checks below actually run t/*.pl.  (--enable-tap-tests is a
        # configure flag, so this is a full PG rebuild; it is only pulled in by
        # the tap-* checks, not the normal build/installcheck.)
        pgTapFor = pg:
          pg.overrideAttrs (o: {
            configureFlags = (o.configureFlags or [ ]) ++ [ "--enable-tap-tests" ];
            nativeBuildInputs = (o.nativeBuildInputs or [ ])
              ++ [ pkgs.perl pkgs.perlPackages.IPCRun ];
            postInstall = (o.postInstall or "") + ''
              for d in "$NIX_BUILD_TOP"/*/src/test/perl; do
                if [ -d "$d/PostgreSQL" ]; then
                  mkdir -p "$out/lib/perl5"
                  cp -r "$d/PostgreSQL" "$out/lib/perl5/"
                fi
              done
            '';
          });

        # Build pg_fts against a given postgresql package via its bundled PGXS.
        # In nixpkgs the pg_config binary lives in the `.pg_config` output.
        buildFor = postgresql:
          pkgs.stdenv.mkDerivation {
            pname = "pg_fts";
            version = "1.8.3";
            src = ./.;

            nativeBuildInputs = [ postgresql.pg_config pkgs.clang ];
            buildInputs = [ postgresql ];

            # PGXS honours PG_CONFIG; point it at this postgresql.  nixpkgs builds
            # PostgreSQL with clang, so PGXS defaults CC=clang — provide it.
            makeFlags = [ "PG_CONFIG=${postgresql.pg_config}/bin/pg_config" ];

            # Install into $out so nixpkgs' postgresql .withPackages can pick it up.
            # PGXS emits pg_fts.so (Linux) or pg_fts.dylib (macOS); glob covers both.
            installPhase = ''
              runHook preInstall
              install -D -m 755 -t $out/lib pg_fts.so 2>/dev/null || \
                install -D -m 755 -t $out/lib pg_fts.dylib
              install -D -m 644 -t $out/share/postgresql/extension pg_fts.control
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.8.3.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.2.0--0.2.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.2.1--0.2.2.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.2.2--0.2.3.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.2.3--0.2.4.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.2.4--0.3.0.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.3.0--0.3.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.3.1--0.3.2.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.3.2--0.3.3.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.3.3--0.3.4.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.3.4--0.3.5.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.3.5--0.3.6.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--0.3.6--1.0.0.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.0.0--1.0.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.0.1--1.0.2.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.0.2--1.0.3.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.0.3--1.0.4.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.0.4--1.0.5.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.0.5--1.0.6.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.0.6--1.0.7.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.0.7--1.0.8.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.0.8--1.1.0.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.1.0--1.1.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.1.1--1.1.2.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.1.2--1.1.3.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.1.3--1.1.4.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.1.4--1.1.5.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.1.5--1.1.6.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.1.6--1.1.7.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.1.7--1.2.0.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.2.0--1.2.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.2.1--1.2.2.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.2.2--1.3.0.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.3.0--1.3.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.3.1--1.3.2.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.3.2--1.4.0.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.4.0--1.4.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.4.1--1.5.0.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.5.0--1.5.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.5.1--1.5.2.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.5.2--1.5.3.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.5.3--1.5.4.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.5.4--1.5.5.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.5.5--1.5.6.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.5.6--1.5.7.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.5.7--1.5.8.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.5.8--1.5.9.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.5.9--1.5.10.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.5.10--1.6.0.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.6.0--1.6.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.6.1--1.7.0.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.7.0--1.7.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.7.1--1.7.2.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.7.2--1.8.0.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.8.0--1.8.1.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.8.1--1.8.2.sql
              install -D -m 644 -t $out/share/postgresql/extension pg_fts--1.8.2--1.8.3.sql
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Full-text search with BM25/BM25F ranking and a dedicated bm25 index AM";
              homepage = "https://codeberg.org/gregburd/pg_fts";
              license = licenses.postgresql;
              platforms = postgresql.meta.platforms;
            };
          };

        packages = builtins.mapAttrs (_: pg: buildFor pg) pgVersions;

        # A postgresql with pg_fts installed, for running the extension's own
        # regression/isolation/TAP suite the way `make installcheck` expects.
        pgWith = pg: pg.withPackages (_: [ (buildFor pg) ]);

        # `make installcheck` needs a running server + the test harness perl
        # module IPC::Run (for TAP) and the isolation tester (bundled with PG).
        checkFor = pg:
          pkgs.stdenv.mkDerivation {
            name = "pg_fts-installcheck-${pg.version}";
            src = ./.;
            nativeBuildInputs = [ (pgWith pg) pg.pg_config pkgs.perl pkgs.perlPackages.IPCRun pkgs.python3 ];
            dontInstall = true;
            buildPhase = ''
              export PGDATA=$TMPDIR/pgdata
              export PGHOST=$TMPDIR
              export PGPORT=5432
              initdb -U postgres --no-locale --encoding=UTF8 >/dev/null
              pg_ctl -D "$PGDATA" -o "-k $TMPDIR -c listen_addresses=localhost" -w start
              # REGRESS + ISOLATION run via PGXS installcheck against the running server.
              make installcheck \
                PG_CONFIG=${pg.pg_config}/bin/pg_config \
                PGHOST=$TMPDIR PGUSER=postgres PGPORT=$PGPORT \
                || { cat regression.diffs 2>/dev/null; cat output_iso/regression.diffs 2>/dev/null; exit 1; }
              PGUSER=postgres python3 test/query_binary.py --local
              pg_ctl -D "$PGDATA" -w stop
              touch $out
            '';
          };

        # TAP check: runs the t/*.pl tests (crash recovery, replication,
        # corruption, encodings), which the plain checkFor SKIPS because stock
        # nixpkgs postgresql lacks --enable-tap-tests + the perl harness.  Uses
        # the pgTapFor override (TAP enabled, harness installed) with pg_fts
        # installed, and points PERL5LIB at the harness so PostgreSQL::Test
        # resolves.  Each t/*.pl inits + tears down its own cluster.
        tapCheckFor = pg:
          let
            pgt = pgTapFor pg;
            pgFts = buildFor pgt;
            # One prefix (symlinks, no rebuild) that has pgt's server binaries +
            # perl harness AND pg_fts's extension files.  initdb/postgres run
            # from their real store paths (rpaths intact -- unlike a cp of the
            # prefix, which breaks them).  A wrapped pg_config reports THIS prefix
            # so PostgreSQL::Test inits clusters that can CREATE EXTENSION pg_fts.
            pgtJoin = pkgs.symlinkJoin {
              name = "pg_fts-tap-prefix-${pg.version}";
              paths = [ pgFts pgt ];
            };
            pgConfigWrapped = pkgs.writeShellScriptBin "pg_config" ''
              exec ${pgt.pg_config}/bin/pg_config "$@" | sed "s#${pgt}#${pgtJoin}#g"
            '';
          in pkgs.stdenv.mkDerivation {
            name = "pg_fts-tap-${pg.version}";
            src = ./.;
            nativeBuildInputs =
              [ pgtJoin pgConfigWrapped pkgs.perl pkgs.perlPackages.IPCRun ];
            dontInstall = true;
            buildPhase = ''
              # pgConfigWrapped (reporting the joined prefix) must win over the
              # join's own symlinked pg_config, so it goes first on PATH.
              export PATH=${pgConfigWrapped}/bin:${pgtJoin}/bin:$PATH
              export PERL5LIB=${pgt}/lib/perl5''${PERL5LIB:+:$PERL5LIB}
              # Run the t/*.pl TAP tests via prove against the TAP-enabled server.
              # PROVE_TESTS selects the pg_fts-behavior tests that run cleanly in
              # the nix build sandbox (corruption, multi-encoding).  The crash-
              # recovery (t/001) and replication (t/002) tests use an older
              # PostgreSQL::Test idiom that the nixpkgs-shipped harness rejects
              # under the sandbox; they are gated in CI (real PG, matching
              # harness), not here.  This is what makes `nix flake check`
              # actually exercise TAP instead of silently skipping it.
              make installcheck REGRESS= ISOLATION= \
                PROVE_TESTS='t/003_corruption.pl t/004_encodings.pl t/005_concurrency.pl t/006_concurrent_extend.pl t/007_segment_cap.pl t/008_vacuum_reclaim.pl t/010_vacuum_delete_heavy.pl' \
                PG_CONFIG=${pgConfigWrapped}/bin/pg_config \
                || { echo '--- TAP logs ---'; cat tmp_check/log/*.log tmp_check/log/regress_log_* 2>/dev/null; exit 1; }
              touch $out
            '';
          };
      in
      {
        packages = packages // {
          default = packages.pg17;
        };

        # `nix flake check` builds every PG target and runs its installcheck.
        checks = packages // {
          installcheck-pg17 = checkFor pgVersions.pg17;
          installcheck-pg18 = checkFor pgVersions.pg18;
          # TAP checks run t/*.pl (which the plain installcheck SKIPS: stock
          # nixpkgs PG is built without --enable-tap-tests and ships no perl
          # harness).  Each rebuilds PostgreSQL with --enable-tap-tests (a
          # one-time ~20-min compile per major, then cached), installs the perl
          # harness, and runs the pg_fts-behavior TAP tests (corruption,
          # multi-encoding) against it.  The crash-recovery/replication tests
          # (t/001/t/002) run in CI where the harness version matches; they use
          # an idiom the nixpkgs-shipped harness rejects under the build sandbox.
          tap-pg17 = tapCheckFor pgVersions.pg17;
          tap-pg18 = tapCheckFor pgVersions.pg18;
        };

        devShells.default = pkgs.mkShell {
          name = "pg_fts-dev";
          # PG 17 by default; `PG_CONFIG=$(pg18-config) make` to switch.
          packages = [
            pgVersions.pg17
            pgVersions.pg17.pg_config
            pkgs.gcc
            pkgs.gnumake
            pkgs.perl
            pkgs.perlPackages.IPCRun # TAP tests (t/*.pl)
            pkgs.libxml2 # xmllint, for doc validation (nix run .#docs)
            pkgs.clang-tools # clang-format / clangd for editing the C
          ];
          shellHook = ''
            echo "pg_fts dev shell — PostgreSQL ${pgVersions.pg17.version} on PATH"
            echo "  make PG_CONFIG=\$(command -v pg_config)      # build"
            echo "  nix flake check                              # build+test all PG majors"
            echo "  nix run .#docs                               # validate doc/pg_fts.sgml"
          '';
        };

        # Validate the SGML docbook fragment.  doc/pg_fts.sgml is a DocBook
        # <sect1> fragment (as PostgreSQL's own supplied-module docs are), not a
        # standalone XML document, so it uses SGML entities like &mdash; and has
        # no DTD — xmllint --recover checks tag well-formedness and ignores the
        # undefined-entity noise.  The full PG docbook->HTML stack is ~half a GB.
        # Note: well-formedness only; wire the full docbook stack if we ever
        # ship rendered HTML from the flake.
        apps.docs = {
          type = "app";
          program = "${pkgs.writeShellScript "pg_fts-docs" ''
            set -e
            echo "Validating doc/pg_fts.sgml (tag well-formedness)..."
            ${pkgs.libxml2}/bin/xmllint --noout --recover doc/pg_fts.sgml 2>/dev/null \
              && echo "OK: doc/pg_fts.sgml tags are well-formed."
          ''}";
        };

        # Render doc/pg_fts.sgml (a DocBook <sect1> fragment) to standalone HTML
        # under doc/html/ via doc/build-html.sh (wraps the fragment in a minimal
        # <article> shell and runs the docbook-xsl-ns HTML stylesheet).
        # `nix run .#docs-html` -> doc/html/pg_fts.html + index.html.
        apps.docs-html = {
          type = "app";
          program = "${pkgs.writeShellScript "pg_fts-docs-html" ''
            set -e
            export XSLTPROC=${pkgs.libxslt}/bin/xsltproc
            export DOCBOOK_XSL=${pkgs.docbook-xsl-ns}/xml/xsl/docbook/html/docbook.xsl
            exec ${pkgs.bash}/bin/bash doc/build-html.sh
          ''}";
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
