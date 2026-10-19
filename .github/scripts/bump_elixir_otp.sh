#!/usr/bin/env bash
# Pins .tool-versions to the newest OTP release that builds.hex.pm has an Elixir build for.
set -euo pipefail

builds=$(curl -fsS https://builds.hex.pm/builds/elixir/builds.txt |
  awk '{print $1}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-otp-[0-9]+$')
otp_majors=$(sed -E 's/.*-otp-//' <<< "$builds" | sort -un | paste -sd '|' -)

otp=$(gh api 'repos/erlang/otp/releases?per_page=100' --jq '.[].tag_name' |
  sed -nE 's/^OTP-([0-9]+(\.[0-9]+)+)$/\1/p' |
  grep -E "^($otp_majors)\." | sort -V | tail -1)
elixir=$(grep -E -- "-otp-${otp%%.*}$" <<< "$builds" | sed 's/^v//' | sort -V | tail -1)

if [[ -z $otp || -z $elixir ]]; then
  echo "Could not resolve versions (otp='$otp', elixir='$elixir')" >&2
  exit 1
fi

sed -E -e "s/^erlang .*/erlang $otp/" -e "s/^elixir .*/elixir $elixir/" .tool-versions > .tool-versions.tmp
mv .tool-versions.tmp .tool-versions

echo "otp=$otp" >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "elixir=$elixir" >> "${GITHUB_OUTPUT:-/dev/stdout}"
