#!/usr/bin/env bats

@test "uninstall.sh passes shellcheck" {
  run shellcheck -x uninstall.sh
  [ "$status" -eq 0 ]
}

@test "uninstall.sh DRY_RUN=1 lists removals" {
  run bash -c 'DRY_RUN=1 ./uninstall.sh'
  [ "$status" -eq 0 ]
  [[ "$output" == *"sl-monitor"* ]]
  [[ "$output" == *"uart-logger@.service"* ]]
  [[ "$output" == *"99-pi-monitor.rules"* ]]
}
