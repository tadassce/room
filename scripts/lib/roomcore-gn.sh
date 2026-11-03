# Sourced by roomcore-apply.sh. args.gn alone is not a completed generation:
# an interrupted/failed first run can leave it behind without build.ninja.
roomcore_ensure_gn() {
  local args_file="$1" out="$2"
  mkdir -p "$out"
  if [[ ! -f "$out/build.ninja" ]] || ! cmp -s "$args_file" "$out/args.gn"; then
    cp "$args_file" "$out/args.gn"
    gn gen "$out"
  fi
}
