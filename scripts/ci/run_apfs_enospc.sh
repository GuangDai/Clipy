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
current_phase="bootstrap"
last_command_status=0

mkdir -p "$log_dir"
if [[ ! -d "$runner_temp" ]]; then
  echo "Runner temporary directory is unavailable" >&2
  exit 2
fi
runner_temp="$(cd "$runner_temp" && pwd -P)"
temp_root="$(mktemp -d "$runner_temp/clipy-apfs-enospc.XXXXXX")"
mountpoint="$temp_root/volume"
image="$temp_root/clipy-enospc.dmg"
store="$mountpoint/history.store"
filler="$mountpoint/competitor.fill"
mkdir "$mountpoint"

phase_log="$log_dir/phase-events.log"
command_status_log="$log_dir/command-status.log"
runtime_facts_log="$log_dir/runtime-facts.log"
: > "$phase_log"
: > "$command_status_log"
: > "$runtime_facts_log"

# Durable, content-free breadcrumb vocabulary. These files are safe to upload:
# they contain only owned phase labels, exit statuses, numeric capacity facts,
# and closed result classifications. Raw tool output stays in temp_root and is
# deleted with the disposable image because it can contain host paths.
record_event() {
  printf 'phase=%s event=%s\n' "$current_phase" "$1" >> "$phase_log"
}

begin_phase() {
  current_phase="$1"
  record_event "start"
}

record_command_status() {
  printf 'phase=%s command=%s status=%s\n' \
    "$current_phase" "$1" "$2" >> "$command_status_log"
}

classify_failure() {
  local command_label="$1"
  local raw_log="$2"
  local classification="unclassified"

  if grep -Fq -- "-format requires -srcfolder or -srcdevice" "$raw_log"; then
    classification="blank-image-format-option-rejected"
  elif grep -Fq -- "No space left on device" "$raw_log"; then
    classification="insufficient-disk-space"
  elif grep -Fq -- "Resource busy" "$raw_log"; then
    classification="resource-busy"
  elif grep -Fq -- "Permission denied" "$raw_log"; then
    classification="permission-denied"
  fi
  printf 'phase=%s command=%s failure=%s\n' \
    "$current_phase" "$command_label" "$classification" \
    >> "$runtime_facts_log"
}

run_quiet_command() {
  local command_label="$1"
  local raw_log="$2"
  shift 2

  set +e
  "$@" > "$raw_log" 2>&1
  last_command_status=$?
  set -e
  record_command_status "$command_label" "$last_command_status"
  if [[ "$last_command_status" -ne 0 ]]; then
    classify_failure "$command_label" "$raw_log"
    return "$last_command_status"
  fi
  return 0
}

collect_probe_diagnostics() {
  local raw_log="$1"
  local safe_log="$2"

  if [[ -f "$raw_log" ]]; then
    grep '^CLIPY_PROBE ' "$raw_log" > "$safe_log" || : > "$safe_log"
  fi
}

record_volume_facts() {
  local checkpoint="$1"
  local capacity_kib=""
  local available_kib=""
  local df_values=""
  local df_status=0

  set +e
  df_values="$(LC_ALL=C df -kP "$mountpoint" \
    2> "$temp_root/df-$checkpoint.raw.log" \
    | awk 'NR == 2 { print $2, $4 }')"
  df_status=$?
  set -e
  record_command_status "volume-facts-$checkpoint" "$df_status"
  read -r capacity_kib available_kib <<EOF
$df_values
EOF
  if [[ "$df_status" -ne 0 \
    || -z "$capacity_kib" \
    || -z "$available_kib" ]]; then
    printf 'volume.%s=facts-unavailable\n' "$checkpoint" \
      >> "$runtime_facts_log"
    return 1
  fi
  printf 'volume.%s.capacity_bytes=%s\n' \
    "$checkpoint" "$((capacity_kib * 1024))" >> "$runtime_facts_log"
  printf 'volume.%s.available_bytes=%s\n' \
    "$checkpoint" "$((available_kib * 1024))" >> "$runtime_facts_log"
}

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
    printf 'phase=%s wait=%s result=timeout\n' \
      "$current_phase" "$label" >> "$runtime_facts_log"
    return 124
  fi
  printf 'phase=%s wait=%s status=%s\n' \
    "$current_phase" "$label" "$child_status" >> "$command_status_log"
  return "$child_status"
}

detach_volume() {
  local detach_pid=""

  if [[ "$attached" -ne 1 ]]; then
    return 0
  fi

  hdiutil detach "$mountpoint" \
    >"$temp_root/detach.raw.log" 2>&1 &
  detach_pid=$!
  if bounded_wait "$detach_pid" 20 "detach"; then
    attached=0
    record_event "detach-complete"
    return 0
  fi

  hdiutil detach -force "$mountpoint" \
    >"$temp_root/detach-force.raw.log" 2>&1 &
  detach_pid=$!
  if bounded_wait "$detach_pid" 20 "detach-force"; then
    attached=0
    record_event "force-detach-complete"
    return 0
  fi

  record_event "detach-failed"
  return 1
}

cleanup() {
  local original_status=$?

  set +e
  current_phase="cleanup"
  printf 'phase=cleanup event=start incoming_status=%s\n' \
    "$original_status" >> "$phase_log"
  if [[ "$pressure_input_open" -eq 1 ]]; then
    exec 8>&-
    pressure_input_open=0
    record_event "pressure-input-closed"
  fi
  if [[ "$pressure_output_open" -eq 1 ]]; then
    exec 7>&-
    pressure_output_open=0
    record_event "pressure-output-closed"
  fi
  if [[ -n "$pressure_pid" ]] && kill -0 "$pressure_pid" 2>/dev/null; then
    kill -TERM "$pressure_pid" 2>/dev/null
    bounded_wait "$pressure_pid" 10 "pressure-cleanup" >/dev/null 2>&1
    record_event "pressure-child-reaped"
  fi
  collect_probe_diagnostics \
    "$temp_root/seed.stderr.raw.log" "$log_dir/seed-diagnostics.log"
  collect_probe_diagnostics \
    "$temp_root/pressure.stderr.raw.log" "$log_dir/pressure-diagnostics.log"
  collect_probe_diagnostics \
    "$temp_root/verify.stderr.raw.log" "$log_dir/verify-diagnostics.log"
  if [[ -n "$filler" && -e "$filler" ]]; then
    rm -f -- "$filler"
    record_event "competitor-removed"
  fi
  detach_volume
  if [[ -n "$temp_root" ]]; then
    case "$temp_root" in
      "$runner_temp"/clipy-apfs-enospc.*)
        rm -rf -- "$temp_root"
        record_event "temporary-root-removed"
        ;;
      *)
        record_event "temporary-root-prefix-rejected"
        ;;
    esac
  fi
  printf 'phase=cleanup event=complete outgoing_status=%s\n' \
    "$original_status" >> "$phase_log"
  return "$original_status"
}
trap cleanup EXIT

require_literal_file() {
  local path="$1"
  local expected="$2"
  local label="$3"

  if ! cmp -s "$path" <(printf '%s\n' "$expected"); then
    printf 'phase=%s assertion=%s result=unexpected-output\n' \
      "$current_phase" "$label" >> "$runtime_facts_log"
    exit 1
  fi
  printf 'phase=%s assertion=%s result=matched\n' \
    "$current_phase" "$label" >> "$runtime_facts_log"
}

begin_phase "build-probe"
set +e
swift build -c release --product HistoryRestartProbe \
  > "$temp_root/release-build.raw.log" 2>&1
build_status=$?
set -e
record_command_status "swift-build" "$build_status"
if [[ "$build_status" -ne 0 ]]; then
  printf 'probe.build=failed\n' >> "$runtime_facts_log"
  record_event "build-failed"
  exit 1
fi
set +e
python3 scripts/diagnostic_scan.py \
  --profile strict "$temp_root/release-build.raw.log" \
  > "$temp_root/diagnostic-scan.raw.log" 2>&1
diagnostic_scan_status=$?
set -e
record_command_status "diagnostic-scan" "$diagnostic_scan_status"
if [[ "$diagnostic_scan_status" -ne 0 ]]; then
  printf 'probe.compiler_diagnostics=rejected\n' >> "$runtime_facts_log"
  record_event "diagnostic-scan-failed"
  exit 1
fi
printf 'probe.build=complete\nprobe.compiler_diagnostics=clean\n' \
  >> "$runtime_facts_log"
if [[ ! -x "$probe" ]]; then
  record_event "release-probe-missing"
  exit 1
fi
record_event "complete"

begin_phase "create-image"
# On macOS 26 a blank image selects its read/write UDIF encoding from
# `-type UDIF`; `-format UDRW` is a source-conversion option and is rejected
# unless `-srcfolder` or `-srcdevice` is also supplied. The imageinfo assertion
# below independently proves the resulting image is fixed UDRW, not sparse.
if ! run_quiet_command "hdiutil-create" "$temp_root/image-create.raw.log" \
  hdiutil create \
  -size "${image_size_mib}m" \
  -fs APFS \
  -volname CLIPY_ENOSPC \
  -type UDIF \
  "$image"; then
  record_event "failed"
  exit 1
fi

set +e
hdiutil imageinfo -plist "$image" \
  > "$temp_root/image-info.plist" 2> "$temp_root/image-info.raw.log"
image_info_status=$?
set -e
record_command_status "hdiutil-imageinfo" "$image_info_status"
if [[ "$image_info_status" -ne 0 ]]; then
  classify_failure "hdiutil-imageinfo" "$temp_root/image-info.raw.log"
  record_event "imageinfo-failed"
  exit 1
fi
set +e
image_format="$(plutil -extract Format raw -o - \
  "$temp_root/image-info.plist" 2> "$temp_root/image-format.raw.log")"
image_format_status=$?
set -e
record_command_status "read-image-format" "$image_format_status"
if [[ "$image_format_status" -ne 0 || "$image_format" != "UDRW" ]]; then
  printf 'image.format=%s\n' "unexpected" >> "$runtime_facts_log"
  record_event "fixed-read-write-format-not-proven"
  exit 1
fi
printf 'image.format=UDRW\nimage.sparse=false\n' >> "$runtime_facts_log"
record_event "complete"

begin_phase "attach-image"
if ! run_quiet_command "hdiutil-attach" "$temp_root/image-attach.raw.log" \
  hdiutil attach \
  -nobrowse \
  -owners on \
  -mountpoint "$mountpoint" \
  "$image"; then
  record_event "failed"
  exit 1
fi
attached=1

set +e
diskutil info -plist "$mountpoint" \
  > "$temp_root/volume-info.plist" 2> "$temp_root/volume-info.raw.log"
volume_info_status=$?
set -e
record_command_status "diskutil-info" "$volume_info_status"
if [[ "$volume_info_status" -ne 0 ]]; then
  classify_failure "diskutil-info" "$temp_root/volume-info.raw.log"
  record_event "volume-info-failed"
  exit 1
fi
set +e
filesystem_type="$(plutil -extract FilesystemType raw -o - \
  "$temp_root/volume-info.plist" 2> "$temp_root/filesystem-type.raw.log")"
filesystem_type_status=$?
set -e
record_command_status "read-filesystem-type" "$filesystem_type_status"
if [[ "$filesystem_type_status" -ne 0 || "$filesystem_type" != "apfs" ]]; then
  printf 'volume.filesystem=%s\n' "unexpected" >> "$runtime_facts_log"
  record_event "apfs-not-proven"
  exit 1
fi
set +e
read_only_volume="$(plutil -extract ReadOnlyVolume raw -o - \
  "$temp_root/volume-info.plist" 2> "$temp_root/read-only-volume.raw.log")"
read_only_volume_status=$?
set -e
record_command_status "read-read-only-volume" "$read_only_volume_status"
if [[ "$read_only_volume_status" -ne 0 || "$read_only_volume" != "false" ]]; then
  printf 'volume.read_only=%s\n' "unexpected" >> "$runtime_facts_log"
  record_event "writable-volume-not-proven"
  exit 1
fi
printf 'volume.filesystem=apfs\nvolume.read_only=false\n' \
  >> "$runtime_facts_log"

if ! run_quiet_command "writable-preflight" "$temp_root/preflight.raw.log" \
  dd if=/dev/zero of="$mountpoint/writable.preflight" bs=1048576 count=1; then
  record_event "writable-preflight-failed"
  exit 1
fi
rm -f -- "$mountpoint/writable.preflight"
record_volume_facts "attached"
record_event "complete"

begin_phase "seed-store"
set +e
CLIPY_APFS_PROBE_DIAGNOSTICS=1 "$probe" seed "$store" \
  > "$log_dir/seed.stdout.log" 2> "$temp_root/seed.stderr.raw.log"
seed_status=$?
set -e
record_command_status "seed-child" "$seed_status"
collect_probe_diagnostics \
  "$temp_root/seed.stderr.raw.log" "$log_dir/seed-diagnostics.log"
if [[ "$seed_status" -ne 0 ]]; then
  record_event "child-failed"
  exit 1
fi
require_literal_file "$log_dir/seed.stdout.log" "SEED_OK" "seed-token"
record_volume_facts "seeded"
record_event "complete"

pressure_input_fifo="$temp_root/pressure.stdin"
pressure_output_fifo="$temp_root/pressure.stdout"
mkfifo "$pressure_input_fifo" "$pressure_output_fifo"

# RDWR opens keep FIFO setup nonblocking for the host. The child closes the
# inherited host descriptors and opens only its redirected stdin/stdout ends.
exec 7<>"$pressure_output_fifo"
pressure_output_open=1
exec 8<>"$pressure_input_fifo"
pressure_input_open=1
begin_phase "start-pressure-child"
CLIPY_APFS_PROBE_DIAGNOSTICS=1 "$probe" pressureCapture "$store" \
  <"$pressure_input_fifo" >"$pressure_output_fifo" \
  2>"$temp_root/pressure.stderr.raw.log" 7>&- 8>&- &
pressure_pid=$!
record_event "child-started"

ready_line=""
if ! IFS= read -r -t 30 ready_line <&7; then
  record_event "readiness-timeout-or-eof"
  exit 1
fi
printf '%s\n' "$ready_line" > "$log_dir/pressure-ready.stdout.log"
require_literal_file \
  "$log_dir/pressure-ready.stdout.log" "APFS_PRESSURE_READY" \
  "pressure-ready-token"
record_event "ready"

# The requested write exceeds the entire image capacity. Require dd both to
# fail and to report ENOSPC under a fixed C locale. Its expected failure text
# stays in the disposable temp root because BSD dd prefixes it with a path.
begin_phase "fill-volume"
record_volume_facts "before-competitor"
set +e
LC_ALL=C dd if=/dev/zero of="$filler" \
  bs=1048576 count="$competitor_size_mib" \
  > /dev/null 2>"$temp_root/competitor-dd.stderr.raw.log"
dd_status=$?
set -e
record_command_status "competitor-dd" "$dd_status"
if [[ "$dd_status" -eq 0 ]]; then
  printf 'competitor.result=unexpected-success\n' >> "$runtime_facts_log"
  record_event "unexpected-success"
  exit 1
fi
if ! grep -Fq "No space left on device" \
  "$temp_root/competitor-dd.stderr.raw.log"; then
  classify_failure "competitor-dd" \
    "$temp_root/competitor-dd.stderr.raw.log"
  printf 'competitor.result=non-enospc-failure\n' >> "$runtime_facts_log"
  record_event "non-enospc-failure"
  exit 1
fi
printf 'competitor.request_bytes=%s\ncompetitor.result=enospc\n' \
  "$((competitor_size_mib * 1048576))" >> "$runtime_facts_log"
record_volume_facts "under-pressure"
record_event "complete"

begin_phase "capture-under-pressure"
printf 'GO\n' >&8
exec 8>&-
pressure_input_open=0
record_event "go-sent"

result_line=""
if ! IFS= read -r -t 30 result_line <&7; then
  collect_probe_diagnostics \
    "$temp_root/pressure.stderr.raw.log" \
    "$log_dir/pressure-diagnostics.log"
  record_event "result-timeout-or-eof"
  exit 1
fi
printf '%s\n' "$result_line" > "$log_dir/pressure-result.stdout.log"
require_literal_file \
  "$log_dir/pressure-result.stdout.log" "PRESSURECAPTURE_OK" \
  "pressure-result-token"

if bounded_wait "$pressure_pid" 15 "pressure-exit"; then
  pressure_status=0
else
  pressure_status=$?
fi
pressure_pid=""
record_command_status "pressure-child" "$pressure_status"
collect_probe_diagnostics \
  "$temp_root/pressure.stderr.raw.log" "$log_dir/pressure-diagnostics.log"
if [[ "$pressure_status" -ne 0 ]]; then
  record_event "child-failed"
  exit 1
fi

extra_line=""
if IFS= read -r -t 1 extra_line <&7 || [[ -n "$extra_line" ]]; then
  record_event "unexpected-extra-output"
  exit 1
fi
exec 7>&-
pressure_output_open=0
record_volume_facts "after-rejected-capture"
record_event "complete"

begin_phase "release-pressure"
rm -f -- "$filler"
filler=""
record_volume_facts "after-competitor-removal"
record_event "complete"

begin_phase "fresh-process-verify"
set +e
CLIPY_APFS_PROBE_DIAGNOSTICS=1 "$probe" verifySeed "$store" \
  > "$log_dir/verify.stdout.log" 2> "$temp_root/verify.stderr.raw.log"
verify_status=$?
set -e
record_command_status "verify-child" "$verify_status"
collect_probe_diagnostics \
  "$temp_root/verify.stderr.raw.log" "$log_dir/verify-diagnostics.log"
if [[ "$verify_status" -ne 0 ]]; then
  record_event "child-failed"
  exit 1
fi
require_literal_file \
  "$log_dir/verify.stdout.log" "VERIFYSEED_OK" "verify-token"
record_event "complete"

begin_phase "detach-image"
detach_volume
record_event "complete"

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

current_phase="complete"
record_event "evidence-passed"
echo "APFS ENOSPC evidence: capture transaction leaf and fresh seed verification passed"
