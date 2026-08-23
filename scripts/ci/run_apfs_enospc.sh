#!/usr/bin/env bash
# Exercise the capture-transaction ENOSPC leaf on one disposable fixed-size
# APFS image. The evidence is intentionally limited to seed integrity, a real
# competing allocation failure, the pressure capture result, and fresh reopen.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: run_apfs_enospc.sh <log-dir> <runner-temp>" >&2
  exit 2
fi

log_dir="$1"
runner_temp="$2"
probe=".build/release/HistoryRestartProbe"
image_size_mib=256
competitor_size_mib=512
temp_root=""
mountpoint=""
filler=""
pressure_pid=""
pressure_input_open=0
pressure_output_open=0
attached=0

mkdir -p "$log_dir"
if [[ ! -d "$runner_temp" ]]; then
  echo "Runner temporary directory does not exist: $runner_temp" >&2
  exit 2
fi
runner_temp="$(cd "$runner_temp" && pwd -P)"
temp_root="$(mktemp -d "$runner_temp/clipy-apfs-enospc.XXXXXX")"
mountpoint="$temp_root/volume"
image="$temp_root/clipy-enospc.dmg"
store="$mountpoint/history.store"
filler="$mountpoint/competitor.fill"
mkdir "$mountpoint"

# Bash 3.2 has no timed wait. A one-shot Perl alarm bounds a wait without
# shell sleep/poll loops; the marker distinguishes a timeout from child status.
bounded_wait() {
  local child_pid="$1"
  local timeout_seconds="$2"
  local label="$3"
  local timeout_marker="$temp_root/$label.timeout"
  local watchdog_pid=""
  local child_status=0

  rm -f -- "$timeout_marker"
  perl -e '
    my ($pid, $seconds, $marker) = @ARGV;
    $SIG{ALRM} = sub {
      if (open(my $handle, ">", $marker)) {
        print {$handle} "timeout\n";
        close($handle);
      }
      kill("TERM", $pid);
      select(undef, undef, undef, 2);
      kill("KILL", $pid);
      exit(0);
    };
    alarm($seconds);
    select(undef, undef, undef, $seconds + 60);
  ' "$child_pid" "$timeout_seconds" "$timeout_marker" &
  watchdog_pid=$!

  if wait "$child_pid"; then
    child_status=0
  else
    child_status=$?
  fi
  kill -TERM "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if [[ -e "$timeout_marker" ]]; then
    echo "Timed out waiting for $label" >&2
    return 124
  fi
  return "$child_status"
}

detach_volume() {
  local detach_pid=""

  if [[ "$attached" -ne 1 ]]; then
    return 0
  fi

  hdiutil detach "$mountpoint" \
    >"$log_dir/detach.log" 2>&1 &
  detach_pid=$!
  if bounded_wait "$detach_pid" 20 "detach"; then
    attached=0
    return 0
  fi

  hdiutil detach -force "$mountpoint" \
    >"$log_dir/detach-force.log" 2>&1 &
  detach_pid=$!
  if bounded_wait "$detach_pid" 20 "detach-force"; then
    attached=0
    return 0
  fi

  echo "Unable to detach disposable APFS image within the cleanup bound" >&2
  return 1
}

cleanup() {
  local original_status=$?

  set +e
  if [[ "$pressure_input_open" -eq 1 ]]; then
    exec 8>&-
    pressure_input_open=0
  fi
  if [[ "$pressure_output_open" -eq 1 ]]; then
    exec 7>&-
    pressure_output_open=0
  fi
  if [[ -n "$pressure_pid" ]] && kill -0 "$pressure_pid" 2>/dev/null; then
    kill -TERM "$pressure_pid" 2>/dev/null
    bounded_wait "$pressure_pid" 10 "pressure-cleanup" >/dev/null 2>&1
  fi
  if [[ -n "$filler" ]]; then
    rm -f -- "$filler"
  fi
  detach_volume
  if [[ -n "$temp_root" ]]; then
    case "$temp_root" in
      "$runner_temp"/clipy-apfs-enospc.*)
        rm -rf -- "$temp_root"
        ;;
      *)
        echo "Refusing to delete unexpected temporary root: $temp_root" >&2
        ;;
    esac
  fi
  return "$original_status"
}
trap cleanup EXIT

require_literal_file() {
  local path="$1"
  local expected="$2"

  if ! cmp -s "$path" <(printf '%s\n' "$expected"); then
    echo "Probe output at $path did not match $expected" >&2
    exit 1
  fi
}

swift build -c release --product HistoryRestartProbe \
  2>&1 | tee "$log_dir/release-build.log"
python3 scripts/diagnostic_scan.py \
  --profile strict "$log_dir/release-build.log"
if [[ ! -x "$probe" ]]; then
  echo "Release probe was not produced at $probe" >&2
  exit 1
fi

hdiutil create \
  -size "${image_size_mib}m" \
  -fs APFS \
  -volname CLIPY_ENOSPC \
  -type UDIF \
  -format UDRW \
  "$image" >"$log_dir/image-create.log" 2>&1
hdiutil attach \
  -nobrowse \
  -owners on \
  -mountpoint "$mountpoint" \
  "$image" >"$log_dir/image-attach.log" 2>&1
attached=1

diskutil info -plist "$mountpoint" > "$log_dir/volume-info.plist"
filesystem_type="$(plutil -extract FilesystemType raw -o - \
  "$log_dir/volume-info.plist")"
if [[ "$filesystem_type" != "apfs" ]]; then
  echo "Disposable image mounted with unexpected filesystem: $filesystem_type" >&2
  exit 1
fi

if ! "$probe" seed "$store" \
  >"$log_dir/seed.stdout.log" 2>"$log_dir/seed.stderr.log"; then
  echo "Seed child failed" >&2
  exit 1
fi
require_literal_file "$log_dir/seed.stdout.log" "SEED_OK"

pressure_input_fifo="$temp_root/pressure.stdin"
pressure_output_fifo="$temp_root/pressure.stdout"
mkfifo "$pressure_input_fifo" "$pressure_output_fifo"

# RDWR opens keep FIFO setup nonblocking for the host. The child closes the
# inherited host descriptors and opens only its redirected stdin/stdout ends.
exec 7<>"$pressure_output_fifo"
pressure_output_open=1
exec 8<>"$pressure_input_fifo"
pressure_input_open=1
"$probe" pressureCapture "$store" \
  <"$pressure_input_fifo" >"$pressure_output_fifo" \
  2>"$log_dir/pressure.stderr.log" 7>&- 8>&- &
pressure_pid=$!

ready_line=""
if ! IFS= read -r -t 30 ready_line <&7; then
  echo "Pressure child did not publish bounded readiness" >&2
  exit 1
fi
printf '%s\n' "$ready_line" > "$log_dir/pressure-ready.stdout.log"
require_literal_file \
  "$log_dir/pressure-ready.stdout.log" "APFS_PRESSURE_READY"

# The requested write exceeds the entire image capacity. Require dd both to
# fail and to report ENOSPC under a fixed C locale. Its expected failure text
# remains private to this runtime log and is never fed to diagnostic_scan.py.
set +e
LC_ALL=C dd if=/dev/zero of="$filler" \
  bs=1048576 count="$competitor_size_mib" \
  > /dev/null 2>"$log_dir/competitor-dd.stderr.log"
dd_status=$?
set -e
if [[ "$dd_status" -eq 0 ]]; then
  echo "Competitor allocation unexpectedly fit inside the bounded image" >&2
  exit 1
fi
if ! grep -Fq "No space left on device" \
  "$log_dir/competitor-dd.stderr.log"; then
  echo "Competitor allocation failed without an ENOSPC report" >&2
  exit 1
fi

printf 'GO\n' >&8
exec 8>&-
pressure_input_open=0

result_line=""
if ! IFS= read -r -t 30 result_line <&7; then
  echo "Pressure child did not publish a bounded capture result" >&2
  exit 1
fi
printf '%s\n' "$result_line" > "$log_dir/pressure-result.stdout.log"
require_literal_file \
  "$log_dir/pressure-result.stdout.log" "PRESSURECAPTURE_OK"

if bounded_wait "$pressure_pid" 15 "pressure-exit"; then
  pressure_status=0
else
  pressure_status=$?
fi
pressure_pid=""
if [[ "$pressure_status" -ne 0 ]]; then
  echo "Pressure child exited unsuccessfully: $pressure_status" >&2
  exit 1
fi

extra_line=""
if IFS= read -r -t 1 extra_line <&7 || [[ -n "$extra_line" ]]; then
  echo "Pressure child emitted output beyond the frozen two-line grammar" >&2
  exit 1
fi
exec 7>&-
pressure_output_open=0

rm -f -- "$filler"
filler=""

if ! "$probe" verifySeed "$store" \
  >"$log_dir/verify.stdout.log" 2>"$log_dir/verify.stderr.log"; then
  echo "Fresh verification child failed after freeing capacity" >&2
  exit 1
fi
require_literal_file "$log_dir/verify.stdout.log" "VERIFYSEED_OK"

detach_volume

{
  printf 'artifact=%s\n' "HistoryRestartProbe Release product"
  printf 'filesystem=%s\n' "APFS"
  printf 'image_capacity_mib=%s\n' "$image_size_mib"
  printf 'competitor_request_mib=%s\n' "$competitor_size_mib"
  printf 'competitor_result=%s\n' "ENOSPC"
  printf 'seed=%s\n' "complete"
  printf 'pressure_capture=%s\n' "transaction rejected with seed preserved"
  printf 'fresh_verify=%s\n' "seed state readable"
  printf '%s\n' \
    "evidence_ceiling=Card 6B exact capture transaction physical ENOSPC leaf only"
} | tee "$log_dir/apfs-enospc-summary.log"

echo "APFS ENOSPC evidence: capture transaction leaf and fresh seed verification passed"
