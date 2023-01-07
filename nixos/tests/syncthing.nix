import ./make-test-python.nix ({ lib, pkgs, ... }: {
  name = "syncthing";
  meta.maintainers = with pkgs.lib.maintainers; [ chkno ];

  nodes = rec {
    a = {
      environment.systemPackages = with pkgs; [ curl libxml2 syncthing ];
      services.syncthing = {
        enable = true;
        openDefaultPorts = true;
        extraOptions.gui = {
          user = "me";
          password._secret = pkgs.writeText "syncthing-gui-password" "hunter2";
        };
      };
    };
    b = a;
  };

  testScript = ''
    import json
    import shlex
    from urllib.parse import urlparse

    confdir = "/var/lib/syncthing/.config/syncthing"
    baseurl = urlparse("http://127.0.0.1:8384")

    def apiKey(host):
        return host.succeed(
            "xmllint --xpath 'string(configuration/gui/apikey)' %s/config.xml" % confdir
        ).strip()

    def makeReq(host, path, *args, **kwargs):
        APIKey = kwargs.get('APIKey', apiKey(host))

        cmd = [
          "curl",
          "-Ssf",
          "-H", ("X-API-Key: %s" % APIKey),
          baseurl._replace(path=path).geturl(),
        ] + list(args)

        return host.succeed(shlex.join(cmd))

    def reqConf(host, *args, **kwargs):
        return makeReq(host, "/rest/config", *args, **kwargs)

    def getConf(host, *args, **kwargs):
        oldConf = reqConf(host, *args, **kwargs)
        return json.loads(oldConf)

    def putConf(host, conf, *args, **kwargs):
        newConf = json.dumps(conf)
        return reqConf(host, "-X", "PUT", "-d", newConf, *args, **kwargs)

    def addPeer(host, name, deviceID):
        APIKey = apiKey(host)

        conf = getConf(host, APIKey=APIKey)

        conf["devices"].append({"deviceID": deviceID, "id": name})
        conf["folders"].append(
            {
                "devices": [{"deviceID": deviceID}],
                "id": "foo",
                "path": "/var/lib/syncthing/foo",
                "rescanIntervalS": 1,
            }
        )

        return putConf(host, conf, APIKey=APIKey)

    def checkConf(host):
      guiConf = makeReq(host, "/rest/config/gui")
      conf = json.loads(guiConf)

      for field in ["user", "password"]:
          with host.nested("GUI configuration must contain '%s'" % field):
              if field not in conf:
                  raise Exception("'%s' missing from GUI configuration" % field)

      with host.nested("GUI user must be 'me'"):
          if conf["user"] != "me":
              raise Exception("wrong GUI user; expected 'me', got '%s'" % conf["user"])

      with host.nested("GUI password should be encrypted"):
          if not conf["password"].startswith("$"):
              raise Exception("expected GUI password to be encrypted; got '%s'" % conf["password"])


    start_all()
    a.wait_for_unit("syncthing.service")
    b.wait_for_unit("syncthing.service")
    a.wait_for_open_port(22000)
    b.wait_for_open_port(22000)

    # Block until `syncthing-init` completes; otherwise, Syncthing may not yet
    # have updated to reflect the settings from `devices`, `folders`, and/or
    # `extraConfig`.
    a.wait_for_unit("syncthing-init.service", substate="exited")
    b.wait_for_unit("syncthing-init.service", substate="exited")

    aDeviceID = a.succeed("syncthing -home=%s -device-id" % confdir).strip()
    bDeviceID = b.succeed("syncthing -home=%s -device-id" % confdir).strip()
    addPeer(a, "b", bDeviceID)
    addPeer(b, "a", aDeviceID)

    checkConf(a)
    checkConf(b)

    a.wait_for_file("/var/lib/syncthing/foo")
    b.wait_for_file("/var/lib/syncthing/foo")
    a.succeed("echo a2b > /var/lib/syncthing/foo/a2b")
    b.succeed("echo b2a > /var/lib/syncthing/foo/b2a")
    a.wait_for_file("/var/lib/syncthing/foo/b2a")
    b.wait_for_file("/var/lib/syncthing/foo/a2b")
  '';
})
