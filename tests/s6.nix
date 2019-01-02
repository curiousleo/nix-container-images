# Run init scripts in the builder for testing purposes

{ pkgs, lib }:

let
  makeInit = c: (lib.makeImage c).init;
  makeConfig = c: (lib.makeImage c).config;

  # Run init script in background adn redirect its stdout to a file. A
  # test script can use this file to do some tests
  runS6Test = test: let
    run = pkgs.runCommand "runS6-${test.config.image.name}" { } ''
      # This is to check the environment variable propagation
      export IN_S6_INIT_TEST=1

      echo "Running ${makeInit test.config}"...
      ${makeInit test.config} s6-state > s6-log &
      S6PID=$!
      tail -f s6-log &

      for i in `seq 1 10`;
      do
        if ${pkgs.writeScript "runS6-testscript" test.testScript} s6-log
        then
          mkdir $out
          cp s6-log $out/
          echo "ok" > $out/result
          exit 0
        fi

        # If s6 is down, the test fails
        if ! ${pkgs.procps}/bin/ps -p $S6PID > /dev/null;
        then
          echo "Test fails and s6-svscan is down."
          exit 1
        fi

        sleep 1
      done

      # If the timeout is reached, the test fails
      echo "Test timeout."
      exit 1
    '';
  in
    # We add the config attribute for debugging
    run // { config = makeConfig (test.config); };

in
pkgs.lib.mapAttrs (n: v: runS6Test v) {

  # If a long run service with restart = no fails, s6-svscan
  # terminates
  stopIfLongrunNoRestartFails = {
    config = {
      image.name = "stopIfLongrunNoRestartFails";
      systemd.services.example.script = ''
        exit 1
      '';
    };
    testScript = ''
      #!${pkgs.stdenv.shell}
      grep -q "init finish" $1
    '';
  };

  # If a long run service with restart = always fails, the service is
  # restarted
  stopIfLongrunRestart = {
    config = {
      image.name = "stopIfLongrunRestart";
      systemd.services.example = {
        script = ''
          echo "restart"
          exit 1
        '';
        serviceConfig.Restart = "always";
      };
    };
    testScript = ''
      #!${pkgs.stdenv.shell} -e
      [ `grep "restart" $1 | wc -l` -ge 2 ]
    '';
  };

  # If a oneshot fails, s6-svscan terminates
  stopIfOneshotFail = {
    config = {
      image.name = "stopIfOneshotFail";
      systemd.services.example = {
        script = ''
          echo "restart"
          exit 1
        '';
        serviceConfig.Type = "oneshot";
      };
    };
    testScript = ''
      #!${pkgs.stdenv.shell}
      grep -q "init finish" $1
    '';
  };

  # Oneshot service can have dependencies
  dependentOneshot = {
    config = {
      image.name = "dependentOneshot";
      systemd.services.example-1 = {
        script = "echo example-1: MUSTNOTEXISTELSEWHERE_1";
        after = [ "example-2.service" ];
        serviceConfig.Type = "oneshot";
      };
      systemd.services.example-2 = {
        script = "echo example-2: MUSTNOTEXISTELSEWHERE_2";
        serviceConfig.Type = "oneshot";
      };
    };
    testScript = ''
      #!${pkgs.stdenv.shell}
      set -e
      grep -q MUSTNOTEXISTELSEWHERE_1 $1
      grep -q MUSTNOTEXISTELSEWHERE_2 $1
      grep MUSTNOTEXISTELSEWHERE $1 | sort --check --reverse
    '';
  };

  # OneshotPost service can have dependencies
  # example-1 is executed after example-2
  oneshotPost = {
    config = {
      image.name = "oneshotPost";

      systemd.services.example-1 = {
        script = "sleep 2; echo example-1: MUSTNOTEXISTELSEWHERE_1";
        after = [ "example-2.service" ];
        serviceConfig.Type = "oneshot";
      };
      systemd.services.example-2 = {
        script = "echo example-2: MUSTNOTEXISTELSEWHERE_2";
      };
    };
    testScript = ''
      #!${pkgs.stdenv.shell}
      set -e
      grep -q MUSTNOTEXISTELSEWHERE_1 $1
      grep -q MUSTNOTEXISTELSEWHERE_2 $1
      grep MUSTNOTEXISTELSEWHERE $1 | head -n2 | sort --check --reverse
    '';
  };

  path = {
    config = {
      image.name = "path";

      systemd.services.path = {
        script = "hello";
        path = [ pkgs.hello ];
      };
    };
    testScript = ''
      #!${pkgs.stdenv.shell} -e
      grep -q 'Hello, world!' $1
    '';
  };

  # Environment variables are propagated to the init script
  propagatedEnv = {
    config = {
      image.name = "propagatedEnv";
      systemd.services.exemple.script = "echo $IN_S6_INIT_TEST";
    };
    testScript = ''
      #!${pkgs.stdenv.shell} -e
      grep -q '^1$' $1
    '';
  };


}