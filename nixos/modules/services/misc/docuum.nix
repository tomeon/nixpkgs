{ config
, lib
, options
, pkgs
, ...
}:
let
  inherit (lib)
    any
    concatMap
    escapeShellArgs
    filter
    hasPrefix
    head
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    optional
    optionals
    optionalAttrs
    removePrefix
    toList
    types;

  cfg = config.services.docuum;
in
{
  meta.maintainers = [ lib.maintainers.tomeon ];

  options.services.docuum = {
    enable = mkEnableOption "least-recently-used (LRU) Docker image eviction service";

    package = mkPackageOption pkgs "docuum" { };

    deletionChunkSize = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 10;
      description = ''
        Number of images to delete concurrently. Specify `null` to use
        {command}`docuum`'s default (which is `1` as of this writing).
      '';
    };

    keep = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
      ];
      description = ''
        List of regular expressions matched against `repository:tag`.  Matching
        images will not be deleted.
      '';
    };

    threshold = mkOption {
      type = types.nullOr (types.coercedTo types.ints.positive (n: "${toString n} GB") types.nonEmptyStr);
      default = null;
      example = "32GiB";
      description = ''
        Maximum amount of space to be used for storing Docker images.

        This flag accepts multiple representations
        (see <https://docs.rs/byte-unit/4.0.12/byte_unit/struct.Byte.html#examples-2>),
        like `10 GB`, `10 GiB`, or `10GB`. On Linux, percentage-based
        thresholds like `50%` are also supported.

        Specify `null` to use {command}`docuum`'s default (which is `10 GB` as
        of this writing).
      '';
    };

    logLevel = mkOption {
      type = types.nullOr (types.enum [ "trace" "debug" "info" "warning" "error" ]);
      default = null;
      example = "warning";
      description = ''
        Log verbosity. Specify `null` to use {command}`docuum`'s default
        (`debug` as of this writing).
      '';
    };

    docker =
      let
        sock = config.systemd.sockets.docker or { };
      in
      {
        package = mkOption {
          inherit (options.virtualisation.docker.package) type;
          default = config.virtualisation.docker.package;
          defaultText = "config.virtualisation.docker.package";
          description = ''
            Docker package that Docuum should use for communicating with the
            Docker daemon.
          '';
        };

        host = mkOption {
          type = types.nullOr types.str;
          default =
            let
              # Use `unix://` as the default; Docker will handle expanding it:
              # https://github.com/docker/cli/blob/4e9abfecf569b33ea51da61b6fd3bb7addeb27fb/opts/hosts.go#L71-L109
              listenStream = toList (sock.socketConfig.ListenStream or [ ]);
              unix = map (s: "unix://${s}") (filter (hasPrefix "/") listenStream);
              tcp = map (s: "tcp://${s}") (filter (s: !(any (p: hasPrefix p s) [ "/" "@" "vsock:" ])) listenStream);
            in
            head (unix ++ tcp ++ [ null ]);
          defaultText = "unix:///run/docker.sock";
          example = "tcp://host.example.com:2375";
          description = ''
            The value to use as {env}`DOCKER_SOCK` in the environment of the
            Docuum service; that is, the endpoint of the Docker daemon whose
            images Docuum should monitor and clean up.

            If the `docker.socket` unit is defined in your configuration
            ({option}`systemd.sockets.docker`), then the {option}`host` setting
            defaults to the first of the `ListenStream` directives
            ({manpage}`systemd.socket(5)`) in `docker.socket` that refers to a
            UNIX socket, or, if no `ListenStream` definitions are UNIX sockets,
            to the first IPv4 or IPv6 socket.

            If the `docker.socket` unit is **not** defined in your
            configuration, or has no UNIX, IPv4, or IPv6 `ListenStream`
            definitions, then {env}`DOCKER_HOST` will be omitted from the
            environment of the Docuum service.
          '';
        };

        group = mkOption {
          type = types.nonEmptyStr;
          default = (sock.socketConfig.SocketGroup or "docker");
          defaultText = ''"docker"'';
          description = ''
            The group that owns the Docker socket.

            Defaults to the value of the `SocketGroup` directive
            ({manpage}`systemd.socket(5)`) specified in the `docker.socket`
            unit, if that unit is defined and provides a `SocketGroup`
            definition; otherwise, defaults to `"docker"`.
          '';
        };
      };
  };

  config = mkIf cfg.enable {
    systemd.services.docuum = { name, ... }:
      let
        unixPrefix = "unix://";
        usingDockerUnixSocket = hasPrefix unixPrefix cfg.docker.host;
      in
      {
        environment = {
          # Docuum uses `data_local_dir` for storing cache data, and, on Linux,
          # `data_local_dir` resolves to `XDG_DATA_HOME` if the latter is set.
          # https://docs.rs/dirs/latest/dirs/fn.data_local_dir.html
          # With this `XDG_DATA_HOME`, Docuum data will live in
          # `/var/lib/docuum`, which is the service `StateDirectory` configured
          # below.
          XDG_DATA_HOME = "/var/lib";
        } // optionalAttrs (cfg.logLevel != null) {
          LOG_LEVEL = cfg.logLevel;
        } // optionalAttrs (cfg.docker.host != null) {
          DOCKER_HOST = cfg.docker.host;
        };

        path = [ cfg.docker.package ];

        serviceConfig = {
          DynamicUser = true;

          SupplementaryGroups = optional usingDockerUnixSocket cfg.docker.group;

          ExecStart = escapeShellArgs ([
            "${cfg.package}/bin/docuum"
          ] ++ (optionals (cfg.deletionChunkSize != null) [
            "--deletion-chunk-size"
            (toString cfg.deletionChunkSize)
          ]) ++ (concatMap
            (pattern:
              [ "--keep" pattern ]
            )
            cfg.keep) ++ (optionals (cfg.threshold != null) [
            "--threshold"
            cfg.threshold
          ]));

          RuntimeDirectory = [ name ];
          RuntimeDirectoryMode = "0700";
          StateDirectory = [ name ];
          StateDirectoryMode = "0700";

          RootDirectory = "%t/${name}";

          # `/var/run/docker.sock` is the default in case `DOCKER_HOST` is set to
          # `unix://`: https://github.com/docker/cli/blob/4e9abfecf569b33ea51da61b6fd3bb7addeb27fb/opts/hosts.go#L71-L109.
          BindPaths =
            let
              unixPrefix = "unix://";
              path = removePrefix unixPrefix cfg.docker.host;
              path' = if path == "" then "/var/run/docker.sock" else path;
            in
            (optional usingDockerUnixSocket path') ++ [ "%S/${name}" ];

          BindReadOnlyPaths = [
            builtins.storeDir
            "/etc" # for NSS, etc.
          ];

          AmbientCapabilities = [ "" ];
          CapabilityBoundingSet = [ "" ];
          DevicePolicy = "closed";
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateIPC = true;
          PrivateNetwork = false;
          PrivateTmp = true;
          ProcSubset = "pid";
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectProc = "invisible";
          ProtectSystem = "strict";
          RemoveIPC = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@chown"
            "~@clock"
            "~@cpu-emulation"
            "~@debug"
            "~@keyring"
            "~@memlock"
            "~@module"
            "~@mount"
            "~@obsolete"
            "~@pkey"
            "~@privileged"
            "~@reboot"
            "~@sandbox"
            "~@setuid"
            "~@swap"
            "~@timer"
          ];
        };

        wantedBy = [ "multi-user.target" ];
      };
  };
}
