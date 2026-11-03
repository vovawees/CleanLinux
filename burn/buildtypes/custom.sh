# shellcheck shell=bash
# Everything is done by the recipe's do_* functions; only do_install is mandatory.

bt_install() { die "$name: build_type=custom needs a do_install() function"; }
