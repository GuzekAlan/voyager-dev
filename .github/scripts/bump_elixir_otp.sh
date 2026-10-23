#!/usr/bin/env bash
# Pins .tool-versions to the newest OTP and Elixir builds on builds.hex.pm within the current OTP major.
set -euo pipefail

hex=https://builds.hex.pm/builds
current_otp=$(awk '$1 == "erlang" {print $2}' .tool-versions)
current_elixir=$(awk '$1 == "elixir" {print $2}' .tool-versions)
major=${current_otp%%.*}

otp_versions=$(curl -fsS "$hex/otp/ubuntu-24.04/builds.txt" | awk '{print $1}' |
  sed -nE "s/^OTP-($major(\.[0-9]+)+)$/\1/p" | sort -V)
elixir_versions=$(curl -fsS "$hex/elixir/builds.txt" | awk '{print $1}' |
  sed -nE "s/^v([0-9]+\.[0-9]+\.[0-9]+)-otp-$major$/\1/p" | sort -V)

otp=$(tail -1 <<< "$otp_versions")
elixir=$(tail -1 <<< "$elixir_versions")-otp-$major

newer_than() {
  awk -v current="$1" 'found; $0 == current {found = 1}' | paste -sd ' ' -
}

sed -E -e "s/^erlang .*/erlang $otp/" -e "s/^elixir .*/elixir $elixir/" .tool-versions > .tool-versions.tmp
mv .tool-versions.tmp .tool-versions

{
  echo "otp=$otp"
  echo "elixir=$elixir"
  echo "otp_releases=$(newer_than "$current_otp" <<< "$otp_versions")"
  echo "elixir_releases=$(newer_than "${current_elixir%%-*}" <<< "$elixir_versions")"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
