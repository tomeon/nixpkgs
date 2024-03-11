import ./make-test-python.nix ({ lib, pkgs, ... }: {
  name = "docuum";

  meta.maintainers = [ lib.maintainers.tomeon ];

  nodes =
    let
      dockerCommon = {
        virtualisation.docker = {
          enable = true;
          daemon.settings.debug = true;
        };
      };

      docuumCommon = {
        services.docuum = {
          enable = true;
          threshold = "1M";
          keep = [
            "^b.*:kays$"
          ];
          deletionChunkSize = 2;
          logLevel = "trace";
        };

        # Do not start automatically; want to import images before docuum
        # starts.
        systemd.services.docuum.wantedBy = lib.mkForce [ ];
      };

      dockerListenPort = 2375;
    in
    {
      docker_only = lib.const {
        imports = [
          dockerCommon
        ];

        networking.firewall.allowedTCPPorts = [ dockerListenPort ];

        virtualisation.docker = {
          listenOptions = [
            "[::]:${toString dockerListenPort}"
          ];
        };
      };

      docuum_local = lib.const {
        imports = [
          dockerCommon
          docuumCommon
        ];
      };

      docuum_remote = lib.const {
        imports = [
          docuumCommon
        ];

        services.docuum.docker.host = "tcp://docker_only:${toString dockerListenPort}";
      };
    };

  testScript =
    let
      buildDummyImage = name: tag: pkgs.dockerTools.buildImage {
        inherit name tag;
        copyToRoot = [
          (pkgs.runCommand "${name}:${tag}.txt" { } ''
            mkdir -p $out/share
            yes | head -n 1048576 > $out/share/${name}:${tag}.txt || :
          '')
        ];
      };
    in
    ''
      start_all()

      def load_images(machine):
        machine.succeed("docker load -i ${buildDummyImage "foo" "fighters"}")
        machine.succeed("docker load -i ${buildDummyImage "bar" "kays"}")
        machine.succeed("docker load -i ${buildDummyImage "baz" "luhrmann"}")

      def wait_for_docuum_cleanup(machine):
        machine.wait_until_fails("docker images --format='{{.Repository}}:{{.Tag}}' | grep foo:fighters")
        machine.wait_until_fails("docker images --format='{{.Repository}}:{{.Tag}}' | grep baz:luhrmann")

        # Exempted from removal by the `--keep` filter.  Defer this check until
        # the other images have been deleted, as this way we'll know that
        # Docuum has run.
        machine.succeed("docker images --format='{{.Repository}}:{{.Tag}}' | grep bar:kays")

      def run_cleanup_scenarios(docuum_machine, docker_machine=None):
        if docker_machine is None:
          docker_machine = docuum_machine

        docker_machine.wait_for_unit("sockets.target")

        with subtest("initial docuum pass"):
          load_images(docker_machine)
          docuum_machine.systemctl("start docuum.service")
          docuum_machine.systemctl("cat docuum.service 1>&2")
          docuum_machine.systemctl("status -l docuum.service 1>&2")
          docuum_machine.wait_for_unit("docuum.service")
          wait_for_docuum_cleanup(docker_machine)

        # Docuum is now listening to Docker events and should automatically
        # clean up images.
        with subtest("docuum event watch pass"):
          load_images(docker_machine)
          wait_for_docuum_cleanup(docker_machine)

        with subtest("docuum state file written"):
          docuum_machine.wait_for_file("/var/lib/docuum/state.yml")

      run_cleanup_scenarios(docuum_local)
      run_cleanup_scenarios(docuum_remote, docker_only)
    '';
})
