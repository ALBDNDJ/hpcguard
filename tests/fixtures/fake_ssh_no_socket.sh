#!/usr/bin/env bash
set -u

case " ${*} " in
    *" -G "*)
        printf 'hostname cluster.example.edu\ncontrolpath /tmp/hpcguard-test-control-socket-does-not-exist\n'
        exit 0
        ;;
    *)
        # The test must never reach a network/control command when the socket
        # does not exist.
        exit 99
        ;;
esac
