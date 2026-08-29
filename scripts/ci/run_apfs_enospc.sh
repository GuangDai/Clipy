#!/usr/bin/env bash
# Exercise the capture-transaction ENOSPC leaf on one disposable fixed-size
# APFS image. The evidence is intentionally limited to seed integrity, a real
# competing allocation failure, the pressure capture result, and fresh reopen.
# The added Card 6B full-disk cells repeat the same fill discipline for the
# §16 admission-refused revise leaf and for open-on-full-volume
# characterization: the two open children report one branch of a closed
# typed-or-opened disjunction, and the observed branch is a recorded fact,
# never a failure.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: run_apfs_enospc.sh <log-dir> <runner-temp>" >&2
  exit 2
fi

log_dir="$1"
runner_temp="$2"
probe="${CLIPY_APFS_PROBE_PATH:-.build/release/HistoryRestartProbe}"
image_size_mib=256
competitor_size_mib=512
temp_root=""
mountpoint=""
image=""
store=""
filler=""
pressure_pid=""
pressure_input_open=0
pressure_output_open=0
open_full_pid=""
open_seeded_full_pid=""
matched_literal=""
open_full_volume_branch=""
open_seeded_full_volume_branch=""
attached=0
current_phase="bootstrap"
last_command_status=0
diagnostic_publication_status=0

bootstrap_cleanup_on_exit() {
  local original_status=$?

  # Breadcrumbs only. The runner's bash 3.2 runs an inherited EXIT trap in
  # substitution subshells mid-body (runs 32634454727/32635233048/
  # 32635568571: a trap fire between the pressure-result read and the next
  # body statement tore down the volume while the main shell kept
  # executing), so an EXIT trap must never touch processes, mounts, or the
  # disposable root, and must never `exit`: a trap that only writes
  # bounded evidence files into $log_dir is harmless in every context that
  # can fire it, and the shell's own exit status is what the job sees.
  if [[ -d "$log_dir" ]]; then
    {
      printf 'result=failure\n'
      printf 'exit_phase=bootstrap\n'
      printf 'body_status=%s\n' "$original_status"
    } > "$log_dir/failure-summary.log"
  fi
  printf 'CLIPY_APFS_BOOTSTRAP_FAILURE body_status=%s\n' \
    "$original_status" >&2
}
trap bootstrap_cleanup_on_exit EXIT

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
failure_summary_log="$log_dir/failure-summary.log"
diagnostic_manifest_log="$log_dir/diagnostic-manifest.log"
: > "$phase_log"
: > "$command_status_log"
: > "$runtime_facts_log"
: > "$failure_summary_log"
: > "$diagnostic_manifest_log"

# Durable phase breadcrumbs use a closed vocabulary. APFS/system/build/probe stderr
# is copied without semantic redaction, but with hard line-count and line-length
# bounds, before the disposable root is removed. Probe stdout alone remains a
# closed-token channel because it is the only path that could carry payload.
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

bound_apfs_diagnostics() {
  awk '
    length($0) > 4096 { print substr($0, 1, 4096) "<LINE_TRUNCATED>"; next }
    { print }
  '
}

publish_bounded_diagnostic() {
  local label="$1"
  local raw_log="$2"
  local safe_dir="$log_dir/raw-bounded"
  local safe_log="$safe_dir/$label.log"
  local staged_log="$safe_dir/$label.staged"
  local line_count=0

  if [[ ! -f "$raw_log" ]]; then
    return 0
  fi
  if (
    set -euo pipefail
    mkdir -p "$safe_dir"
    bound_apfs_diagnostics < "$raw_log" > "$staged_log"
    line_count="$(wc -l < "$staged_log" | tr -d ' ')"
    if [[ "$line_count" -le 240 ]]; then
      mv "$staged_log" "$safe_log"
    else
      {
        sed -n '1,160p' "$staged_log"
        printf '<DIAGNOSTIC_TRUNCATED omitted_lines=%s>\n' \
          "$((line_count - 240))"
        tail -n 80 "$staged_log"
      } > "$safe_log"
      rm -f -- "$staged_log"
    fi
  ); then
    return 0
  fi
  diagnostic_publication_status=1
  rm -f -- "$staged_log"
  return 1
}

publish_plist_key_inventory() {
  local label="$1"
  local plist_path="$2"
  local raw_inventory="$temp_root/$label-key-inventory.raw.log"
  local inventory_status=0

  if [[ ! -f "$plist_path" ]]; then
    return 0
  fi
  if /usr/bin/python3 - "$plist_path" > "$raw_inventory" 2>&1 <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)

def visit(value, path):
    if isinstance(value, dict):
        for key in sorted(value):
            child = f"{path}.{key}" if path else str(key)
            print(f"key={child}")
            visit(value[key], child)
    elif isinstance(value, list):
        print(f"collection={path} count={len(value)}")

visit(root, "")
PY
  then
    inventory_status=0
  else
    inventory_status=$?
  fi
  record_command_status "$label-key-inventory" "$inventory_status"
  publish_bounded_diagnostic "$label-key-inventory" "$raw_inventory"
}

publish_plist_diagnostics() {
  local label="$1"
  local plist_path="$2"
  local printable_plist="$temp_root/$label-printable.raw.log"
  local printable_status=0

  if [[ ! -f "$plist_path" ]]; then
    return 0
  fi
  if /usr/bin/plutil -p "$plist_path" > "$printable_plist" 2>&1; then
    printable_status=0
  else
    printable_status=$?
  fi
  record_command_status "$label-printable-plist" "$printable_status"
  publish_bounded_diagnostic "$label-plist" "$printable_plist"
  publish_plist_key_inventory "$label" "$plist_path"
}

publish_known_raw_diagnostics() {
  local raw_log=""
  local raw_name=""

  diagnostic_publication_status=0

  publish_bounded_diagnostic "swift-build" \
    "$temp_root/release-build.raw.log"
  publish_bounded_diagnostic "diagnostic-scan" \
    "$temp_root/diagnostic-scan.raw.log"
  publish_bounded_diagnostic "hdiutil-create" \
    "$temp_root/image-create.raw.log"
  publish_bounded_diagnostic "hdiutil-imageinfo-stderr" \
    "$temp_root/image-info.raw.log"
  publish_plist_diagnostics "hdiutil-imageinfo" \
    "$temp_root/image-info.plist"
  publish_bounded_diagnostic "image-format-extraction" \
    "$temp_root/image-format.raw.log"
  publish_bounded_diagnostic "hdiutil-attach" \
    "$temp_root/image-attach.raw.log"
  publish_bounded_diagnostic "diskutil-info-stderr" \
    "$temp_root/volume-info.raw.log"
  publish_bounded_diagnostic "diskutil-info-text" \
    "$temp_root/volume-info-text.raw.log"
  publish_plist_diagnostics "diskutil-info" \
    "$temp_root/volume-info.plist"
  publish_bounded_diagnostic "filesystem-type-extraction" \
    "$temp_root/filesystem-type.raw.log"
  publish_bounded_diagnostic "writable-volume-extraction" \
    "$temp_root/writable-volume.raw.log"
  publish_bounded_diagnostic "writable-extraction" \
    "$temp_root/writable.raw.log"
  publish_bounded_diagnostic "writable-preflight-dd" \
    "$temp_root/preflight.raw.log"
  publish_bounded_diagnostic "competitor-dd" \
    "$temp_root/competitor-dd.stderr.raw.log"
  publish_bounded_diagnostic "seed-child-stderr" \
    "$temp_root/seed.stderr.raw.log"
  publish_bounded_diagnostic "pressure-child-stderr" \
    "$temp_root/pressure.stderr.raw.log"
  publish_bounded_diagnostic "verify-child-stderr" \
    "$temp_root/verify.stderr.raw.log"
  publish_bounded_diagnostic "open-full-child-stderr" \
    "$temp_root/open-full.stderr.raw.log"
  publish_bounded_diagnostic "open-seeded-full-child-stderr" \
    "$temp_root/open-seeded-full.stderr.raw.log"
  publish_bounded_diagnostic "revise-child-stderr" \
    "$temp_root/revise.stderr.raw.log"
  publish_bounded_diagnostic "revise-commit-child-stderr" \
    "$temp_root/revise-commit.stderr.raw.log"
  publish_bounded_diagnostic "revise-verify-child-stderr" \
    "$temp_root/revise-verify.stderr.raw.log"
  publish_bounded_diagnostic "competitor-dd-under-pressure-open" \
    "$temp_root/competitor-dd-under-pressure-open.stderr.raw.log"
  publish_bounded_diagnostic "competitor-dd-revise-under-pressure" \
    "$temp_root/competitor-dd-revise-under-pressure.stderr.raw.log"
  publish_bounded_diagnostic "hdiutil-detach" \
    "$temp_root/detach.raw.log"
  publish_bounded_diagnostic "hdiutil-force-detach" \
    "$temp_root/detach-force.raw.log"

  for raw_log in "$temp_root"/df-*.raw.log; do
    if [[ -f "$raw_log" ]]; then
      raw_name="$(basename "$raw_log" .raw.log)"
      publish_bounded_diagnostic "$raw_name" "$raw_log"
    fi
  done
  return "$diagnostic_publication_status"
}

write_diagnostic_manifest() {
  local safe_file=""
  local relative_name=""
  local byte_count=0
  local line_count=0

  (
    set -euo pipefail
    : > "$diagnostic_manifest_log"
    while IFS= read -r safe_file; do
      if [[ "$safe_file" == "$diagnostic_manifest_log" ]]; then
        continue
      fi
      relative_name="${safe_file#"$log_dir"/}"
      byte_count="$(wc -c < "$safe_file" | tr -d ' ')"
      line_count="$(wc -l < "$safe_file" | tr -d ' ')"
      printf 'file=%s bytes=%s lines=%s\n' \
        "$relative_name" "$byte_count" "$line_count" \
        >> "$diagnostic_manifest_log"
    done < <(find "$log_dir" -type f | LC_ALL=C sort)
  )
}

write_exit_summary() {
  local result="failure"

  if [[ "$4" -eq 0 ]]; then
    result="success"
  fi
  {
    printf 'result=%s\n' "$result"
    printf 'exit_phase=%s\n' "$1"
    printf 'body_status=%s\n' "$2"
    printf 'cleanup_status=%s\n' "$3"
    printf 'outgoing_status=%s\n' "$4"
  } > "$failure_summary_log"
}

finish_after_publication_failure() {
  local command_label="$1"
  local publication_status="$2"

  set +e
  current_phase="complete"
  record_command_status "$command_label" "$publication_status"
  record_event "success-evidence-publication-failed"
  write_exit_summary "complete" "$publication_status" 0 "$publication_status"
  if write_diagnostic_manifest; then
    printf 'CLIPY_APFS_MANIFEST status=0 after_publication_failure=1\n' >&2
  else
    rm -f -- "$diagnostic_manifest_log"
    printf 'CLIPY_APFS_MANIFEST status=1 after_publication_failure=1\n' >&2
  fi
  printf 'CLIPY_APFS_PUBLICATION_FAILURE command=%s status=%s\n' \
    "$command_label" "$publication_status" >&2
  exit "$publication_status"
}

emit_bounded_diagnostics() {
  local safe_file=""
  local relative_name=""

  while IFS= read -r safe_file; do
    relative_name="${safe_file#"$log_dir"/}"
    printf '== CLIPY_APFS_DIAGNOSTIC %s ==\n' "$relative_name" >&2
    sed -n '1,240p' "$safe_file" >&2
  done < <(find "$log_dir" -type f | LC_ALL=C sort)
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
    grep -E '^CLIPY_(PROBE|PERSISTENCE_ERROR) ' "$raw_log" \
      > "$safe_log" || : > "$safe_log"
  fi
}

record_volume_facts() {
  local checkpoint="$1"
  local capacity_kib=""
  local available_kib=""
  local df_output="$temp_root/df-$checkpoint.stdout.raw.log"
  local df_error="$temp_root/df-$checkpoint.stderr.raw.log"
  local df_status=0

  set +e
  LC_ALL=C df -kP "$mountpoint" > "$df_output" 2> "$df_error"
  df_status=$?
  set -e
  record_command_status "volume-facts-$checkpoint" "$df_status"
  if [[ "$df_status" -eq 0 ]]; then
    read -r capacity_kib available_kib <<EOF
$(awk 'NR == 2 { print $2, $4 }' "$df_output")
EOF
  fi
  if [[ "$df_status" -ne 0 \
    || -z "$capacity_kib" \
    || -z "$available_kib" ]]; then
    printf 'volume.%s=facts-unavailable\n' "$checkpoint" \
      >> "$runtime_facts_log"
    # A missing fact is a recorded breadcrumb, never a gate: every call
    # site runs bare under `set -e`, and run 32634454727 died mid-phase
    # only because a failed redirect made this path return nonzero.
    return 0
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

cleanup_resources() {
  local original_status="$1"
  local finalize_manifest="${2:-1}"
  local cleanup_status=0
  local outgoing_status=0
  local phase_at_exit="$current_phase"

  set +e
  current_phase="cleanup"
  printf 'phase=cleanup event=start incoming_status=%s\n' \
    "$original_status" >> "$phase_log"
  if [[ "$pressure_input_open" -eq 1 ]]; then
    if exec 8>&-; then
      record_command_status "close-pressure-input" 0
    else
      record_command_status "close-pressure-input" 1
      cleanup_status=1
    fi
    pressure_input_open=0
    record_event "pressure-input-closed"
  fi
  if [[ "$pressure_output_open" -eq 1 ]]; then
    if exec 7>&-; then
      record_command_status "close-pressure-output" 0
    else
      record_command_status "close-pressure-output" 1
      cleanup_status=1
    fi
    pressure_output_open=0
    record_event "pressure-output-closed"
  fi
  if [[ -n "$pressure_pid" ]]; then
    if kill -0 "$pressure_pid" 2>/dev/null; then
      if kill -TERM "$pressure_pid" 2>/dev/null; then
        record_command_status "terminate-pressure-child" 0
      else
        record_command_status "terminate-pressure-child" 1
        cleanup_status=1
      fi
    fi
    if bounded_wait "$pressure_pid" 10 "pressure-cleanup" >/dev/null 2>&1; then
      record_event "pressure-child-reaped"
    else
      cleanup_status=1
      record_event "pressure-child-reap-failed"
    fi
    pressure_pid=""
  fi
  # The open/open-seeded children are reaped inline right after their
  # bounded_wait; this loop only guards the unreachable window between a
  # background start and that reap (same posture as pressure_pid above).
  for early_pid in "$open_full_pid" "$open_seeded_full_pid"; do
    if [[ -n "$early_pid" ]] && kill -0 "$early_pid" 2>/dev/null; then
      if kill -TERM "$early_pid" 2>/dev/null; then
        record_command_status "terminate-early-open-child" 0
      else
        record_command_status "terminate-early-open-child" 1
        cleanup_status=1
      fi
    fi
  done
  open_full_pid=""
  open_seeded_full_pid=""
  collect_probe_diagnostics \
    "$temp_root/seed.stderr.raw.log" "$log_dir/seed-diagnostics.log"
  collect_probe_diagnostics \
    "$temp_root/pressure.stderr.raw.log" "$log_dir/pressure-diagnostics.log"
  collect_probe_diagnostics \
    "$temp_root/verify.stderr.raw.log" "$log_dir/verify-diagnostics.log"
  collect_probe_diagnostics \
    "$temp_root/open-full.stderr.raw.log" "$log_dir/open-full-diagnostics.log"
  collect_probe_diagnostics \
    "$temp_root/open-seeded-full.stderr.raw.log" \
    "$log_dir/open-seeded-full-diagnostics.log"
  collect_probe_diagnostics \
    "$temp_root/revise.stderr.raw.log" "$log_dir/revise-diagnostics.log"
  collect_probe_diagnostics \
    "$temp_root/revise-commit.stderr.raw.log" \
    "$log_dir/revise-commit-diagnostics.log"
  collect_probe_diagnostics \
    "$temp_root/revise-verify.stderr.raw.log" \
    "$log_dir/revise-verify-diagnostics.log"
  if [[ -n "$filler" && -e "$filler" ]]; then
    if rm -f -- "$filler"; then
      record_command_status "remove-competitor" 0
      record_event "competitor-removed"
    else
      record_command_status "remove-competitor" 1
      cleanup_status=1
      record_event "competitor-removal-failed"
    fi
  fi
  if ! detach_volume; then
    cleanup_status=1
  fi
  # Copy every bounded APFS-tool diagnostic only after detach has produced its own
  # output, but before deleting the disposable root that owns the raw files.
  if publish_known_raw_diagnostics; then
    record_command_status "publish-bounded-diagnostics" 0
  else
    record_command_status "publish-bounded-diagnostics" 1
    cleanup_status=1
    record_event "diagnostic-publication-failed"
  fi
  if [[ -n "$temp_root" ]]; then
    case "$temp_root" in
      "$runner_temp"/clipy-apfs-enospc.*)
        if rm -rf -- "$temp_root"; then
          record_command_status "remove-temporary-root" 0
          record_event "temporary-root-removed"
        else
          record_command_status "remove-temporary-root" 1
          cleanup_status=1
          record_event "temporary-root-removal-failed"
        fi
        ;;
      *)
        cleanup_status=1
        record_event "temporary-root-prefix-rejected"
        ;;
    esac
  fi
  if [[ "$original_status" -ne 0 ]]; then
    outgoing_status="$original_status"
  else
    outgoing_status="$cleanup_status"
  fi
  printf 'phase=cleanup event=complete outgoing_status=%s\n' \
    "$outgoing_status" >> "$phase_log"
  write_exit_summary \
    "$phase_at_exit" "$original_status" "$cleanup_status" "$outgoing_status"
  # A caller may defer the manifest only when cleanup itself is fully green;
  # every cleanup failure must leave a finalized failure artifact immediately.
  if [[ "$finalize_manifest" -eq 1 || "$outgoing_status" -ne 0 ]]; then
    if write_diagnostic_manifest; then
      # On EXIT paths the manifest is the final filesystem write, so its
      # recorded sizes cannot be made stale by a later status breadcrumb.
      printf 'CLIPY_APFS_MANIFEST status=0\n' >&2
    else
      rm -f -- "$diagnostic_manifest_log"
      record_command_status "write-diagnostic-manifest" 1
      cleanup_status=1
      record_event "diagnostic-manifest-failed"
      if [[ "$original_status" -eq 0 ]]; then
        outgoing_status=1
      fi
      write_exit_summary \
        "$phase_at_exit" "$original_status" "$cleanup_status" "$outgoing_status"
      printf 'CLIPY_APFS_MANIFEST status=1\n' >&2
    fi
  fi
  if [[ "$outgoing_status" -ne 0 ]]; then
    emit_bounded_diagnostics
  fi
  set -e
  return "$outgoing_status"
}

cleanup_on_exit() {
  local original_status=$?

  # Breadcrumbs only — never teardown. The runner's bash 3.2 runs an
  # inherited EXIT trap inside substitution subshells mid-body (observed
  # three times between the pressure-result read and the very next body
  # statement: runs 32634454727, 32635233048, 32635568571), and no
  # in-trap discriminator ($BASH_SUBSHELL is not bumped by the firing
  # form) can tell that context from a real exit. A trap that only
  # publishes bounded evidence into $log_dir and returns is harmless in
  # every context that can fire it: a mid-body fire duplicates at most
  # breadcrumb lines that the final fire rewrites, the shell's own exit
  # status still reaches the job unchanged, and process/mount/root
  # teardown stays exclusively on the explicit success path
  # (`trap - EXIT` + `cleanup_resources 0 0`). A failure path leaves the
  # disposable image attached on the ephemeral runner VM — acceptable
  # hygiene debt against the alternative of racing teardown.
  if [[ -d "$log_dir" ]]; then
    publish_known_raw_diagnostics || true
    write_exit_summary "$current_phase" "$original_status" 0 \
      "$original_status"
    if write_diagnostic_manifest; then
      printf 'CLIPY_APFS_MANIFEST status=0\n' >&2
    else
      printf 'CLIPY_APFS_MANIFEST status=1\n' >&2
    fi
  fi
}
trap cleanup_on_exit EXIT

require_literal_file() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local expected_file="$temp_root/$label.expected"

  # Compare via a staged file, never an argument-position process
  # substitution: the runner's bash 3.2 runs the inherited EXIT trap
  # inside a `<(…)` subshell (without bumping $BASH_SUBSHELL), so the
  # old `cmp -s … <(printf …)` form fired the full teardown mid-body
  # on runs 32634454727 and 32635233048 — detaching the volume and
  # deleting the disposable root while the main shell kept executing,
  # which then failed every later redirect into the removed root.
  printf '%s\n' "$expected" > "$expected_file"
  if ! cmp -s "$path" "$expected_file"; then
    printf 'phase=%s assertion=%s result=unexpected-output\n' \
      "$current_phase" "$label" >> "$runtime_facts_log"
    exit 1
  fi
  printf 'phase=%s assertion=%s result=matched\n' \
    "$current_phase" "$label" >> "$runtime_facts_log"
}

# One full-disk fill cycle for the added Card 6B cells: the same fixed-block
# dd + ENOSPC + volume-facts discipline as the inline fill-volume block, kept
# as a helper because these cells repeat the cycle. Bash 3.2 safe: staged
# files, no process substitution, no arrays. `filler` is re-assigned so each
# cycle owns the competitor path even after an earlier release cleared it.
require_competitor_enospc() {
  local checkpoint="$1"
  local dd_log="$temp_root/competitor-dd-$checkpoint.stderr.raw.log"
  local dd_status=0

  filler="$mountpoint/competitor.fill"
  record_volume_facts "before-$checkpoint"
  set +e
  LC_ALL=C dd if=/dev/zero of="$filler" \
    bs=1048576 count="$competitor_size_mib" \
    > /dev/null 2>"$dd_log"
  dd_status=$?
  set -e
  record_command_status "competitor-dd-$checkpoint" "$dd_status"
  if [[ "$dd_status" -eq 0 ]]; then
    printf 'competitor.%s.result=unexpected-success\n' "$checkpoint" \
      >> "$runtime_facts_log"
    record_event "unexpected-success"
    return 1
  fi
  if ! grep -Fq "No space left on device" "$dd_log"; then
    classify_failure "competitor-dd-$checkpoint" "$dd_log"
    printf 'competitor.%s.result=non-enospc-failure\n' "$checkpoint" \
      >> "$runtime_facts_log"
    record_event "non-enospc-failure"
    return 1
  fi
  printf 'competitor.%s.request_bytes=%s\n' \
    "$checkpoint" "$((competitor_size_mib * 1048576))" >> "$runtime_facts_log"
  printf 'competitor.%s.result=enospc\n' "$checkpoint" >> "$runtime_facts_log"
  record_volume_facts "$checkpoint"
  return 0
}

# Closed-set disjunction assertion for the full-disk open characterization
# children: stdout must be exactly one line carrying one of the enumerated
# literal tokens; the matched token is the recorded evidence. Bash 3.2 safe:
# a staged file read, `[[ ]]` equality, and a plain for-loop over the
# remaining positional parameters — no arrays, no process substitution. The
# matched literal is published through the global `matched_literal` for the
# caller's branch mapping.
require_one_of_literals() {
  local path="$1"
  local label="$2"
  local copy_path="$3"
  local observed=""
  local line_count=0
  local literal=""

  shift 3
  if ! IFS= read -r observed < "$path"; then
    printf 'phase=%s assertion=%s result=no-output\n' \
      "$current_phase" "$label" >> "$runtime_facts_log"
    exit 1
  fi
  line_count="$(wc -l < "$path" | tr -d ' ')"
  if [[ "$line_count" -ne 1 ]]; then
    printf 'phase=%s assertion=%s result=unexpected-output\n' \
      "$current_phase" "$label" >> "$runtime_facts_log"
    exit 1
  fi
  # `wc -l` counts newlines only, so a trailing line without its newline
  # would slip past the count above. The staged-file byte comparison (the
  # `require_literal_file` discipline) closes that gap: every observed
  # candidate is re-emitted with exactly one trailing newline and compared
  # against the captured output byte-for-byte.
  for literal in "$@"; do
    printf '%s\n' "$literal" > "$copy_path.staged"
    if cmp -s "$path" "$copy_path.staged"; then
      break
    fi
    rm -f "$copy_path.staged"
  done
  if [[ ! -f "$copy_path.staged" ]]; then
    printf 'phase=%s assertion=%s result=unexpected-output\n' \
      "$current_phase" "$label" >> "$runtime_facts_log"
    exit 1
  fi
  rm -f "$copy_path.staged"
  matched_literal=""
  for literal in "$@"; do
    if [[ "$observed" == "$literal" ]]; then
      matched_literal="$literal"
      break
    fi
  done
  if [[ -z "$matched_literal" ]]; then
    printf 'phase=%s assertion=%s result=unexpected-output\n' \
      "$current_phase" "$label" >> "$runtime_facts_log"
    exit 1
  fi
  printf 'phase=%s assertion=%s result=matched literal=%s\n' \
    "$current_phase" "$label" "$matched_literal" >> "$runtime_facts_log"
  printf '%s\n' "$matched_literal" > "$copy_path"
}

begin_phase "build-probe"
set +e
swift build -c release --product HistoryRestartProbe \
  -Xswiftc -D -Xswiftc CLIPY_RUNTIME_DIAGNOSTICS \
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
LC_ALL=C diskutil info "$mountpoint" \
  > "$temp_root/volume-info-text.raw.log" 2>&1
volume_info_text_status=$?
set -e
record_command_status "diskutil-info-text" "$volume_info_text_status"
if [[ "$volume_info_text_status" -ne 0 ]]; then
  printf 'volume.text_diagnostics=unavailable\n' >> "$runtime_facts_log"
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
writable_volume="$(plutil -extract WritableVolume raw -o - \
  "$temp_root/volume-info.plist" 2> "$temp_root/writable-volume.raw.log")"
writable_volume_status=$?
set -e
record_command_status "read-writable-volume" "$writable_volume_status"
writable_fact="$writable_volume"
writable_fact_status="$writable_volume_status"
writable_fact_key="WritableVolume"
if [[ "$writable_volume_status" -ne 0 ]]; then
  set +e
  writable_fact="$(plutil -extract Writable raw -o - \
    "$temp_root/volume-info.plist" 2> "$temp_root/writable.raw.log")"
  writable_fact_status=$?
  set -e
  writable_fact_key="Writable"
  record_command_status "read-writable" "$writable_fact_status"
fi
if [[ "$writable_fact_status" -eq 0 \
  && "$writable_fact" == "false" ]]; then
  printf 'volume.writable_metadata=false\n' >> "$runtime_facts_log"
  printf 'volume.writable_metadata_key=%s\n' "$writable_fact_key" \
    >> "$runtime_facts_log"
  record_event "writable-metadata-reports-false"
elif [[ "$writable_fact_status" -eq 0 \
  && "$writable_fact" == "true" ]]; then
  printf 'volume.writable_metadata=true\n' >> "$runtime_facts_log"
  printf 'volume.writable_metadata_key=%s\n' "$writable_fact_key" \
    >> "$runtime_facts_log"
else
  # `diskutil info -plist` is not a frozen schema: the prior ReadOnlyVolume
  # extraction failed on the observed macOS 26.5 runner. These positive keys
  # are optional; the real one-MiB create/remove below remains authoritative.
  printf 'volume.writable_metadata=unavailable\n' >> "$runtime_facts_log"
  record_event "writable-metadata-unavailable"
fi
printf 'volume.filesystem=apfs\n' >> "$runtime_facts_log"

if ! run_quiet_command "writable-preflight" "$temp_root/preflight.raw.log" \
  dd if=/dev/zero of="$mountpoint/writable.preflight" bs=1048576 count=1; then
  if [[ "$writable_fact_status" -eq 0 \
    && "$writable_fact" == "true" ]]; then
    printf 'volume.writable_metadata_contradiction=write-failed\n' \
      >> "$runtime_facts_log"
  fi
  record_event "writable-preflight-failed"
  exit 1
fi
if rm -f -- "$mountpoint/writable.preflight"; then
  record_command_status "remove-writable-preflight" 0
  printf 'volume.writable_preflight=write-and-remove-complete\n' \
    >> "$runtime_facts_log"
  if [[ "$writable_fact_status" -eq 0 \
    && "$writable_fact" == "false" ]]; then
    printf 'volume.writable_metadata_contradiction=write-succeeded\n' \
      >> "$runtime_facts_log"
  fi
else
  record_command_status "remove-writable-preflight" 1
  record_event "writable-preflight-removal-failed"
  exit 1
fi
record_volume_facts "attached"
record_event "complete"

begin_phase "seed-store"
set +e
CLIPY_APFS_PROBE_DIAGNOSTICS=1 \
CLIPY_RUNTIME_DIAGNOSTICS=1 \
"$probe" seed "$store" \
  > "$temp_root/seed.stdout.raw.log" \
  2> "$temp_root/seed.stderr.raw.log"
seed_status=$?
set -e
record_command_status "seed-child" "$seed_status"
collect_probe_diagnostics \
  "$temp_root/seed.stderr.raw.log" "$log_dir/seed-diagnostics.log"
if [[ "$seed_status" -ne 0 ]]; then
  record_event "child-failed"
  exit 1
fi
require_literal_file "$temp_root/seed.stdout.raw.log" "SEED_OK" "seed-token"
printf 'SEED_OK\n' > "$log_dir/seed.stdout.log"
record_volume_facts "seeded"
record_event "complete"

# Card 6B full-disk open cells: a fresh-store open and a seeded-store reopen
# on the filled volume. Open writes only SQLite/WAL scalar files that never
# pass the §16 stamped-plan admission, so each child reports the observed
# branch of a closed typed-or-opened disjunction; the branch is a recorded
# fact, never a failure. The dedicated subdirectory is created before the
# fill and isolates any "opened" residue from the main store's later seed
# verification. Both children are reaped with bounded_wait before their
# stdout files are read, so a hung open cannot stall the lane.
begin_phase "open-full-volume"
if mkdir "$mountpoint/open-full"; then
  record_command_status "create-open-full-directory" 0
else
  record_command_status "create-open-full-directory" 1
  record_event "open-full-directory-creation-failed"
  exit 1
fi
if ! require_competitor_enospc "under-pressure-open"; then
  exit 1
fi

open_full_store="$mountpoint/open-full/history.store"
open_full_status=0
set +e
CLIPY_APFS_PROBE_DIAGNOSTICS=1 \
CLIPY_RUNTIME_DIAGNOSTICS=1 \
"$probe" openFullVolume "$open_full_store" \
  > "$temp_root/open-full.stdout.raw.log" \
  2> "$temp_root/open-full.stderr.raw.log" &
open_full_pid=$!
set -e
record_event "open-full-child-started"
if bounded_wait "$open_full_pid" 30 "open-full-exit"; then
  open_full_status=0
else
  open_full_status=$?
fi
open_full_pid=""
record_command_status "open-full-child" "$open_full_status"
collect_probe_diagnostics \
  "$temp_root/open-full.stderr.raw.log" "$log_dir/open-full-diagnostics.log"
if [[ "$open_full_status" -ne 0 ]]; then
  record_event "child-failed"
  exit 1
fi
require_one_of_literals \
  "$temp_root/open-full.stdout.raw.log" \
  "open-full-token" \
  "$log_dir/open-full.stdout.log" \
  "OPENFULLVOLUME_OPENSTORE_REFUSED" \
  "OPENFULLVOLUME_TRANSACTION_REFUSED" \
  "OPENFULLVOLUME_OPENED"
case "$matched_literal" in
  OPENFULLVOLUME_OPENSTORE_REFUSED)
    open_full_volume_branch="refused-openstore"
    ;;
  OPENFULLVOLUME_TRANSACTION_REFUSED)
    open_full_volume_branch="refused-transaction"
    ;;
  OPENFULLVOLUME_OPENED)
    open_full_volume_branch="opened"
    ;;
  *)
    record_event "open-full-branch-mapping-unexpected"
    exit 1
    ;;
esac
record_event "open-full-branch-recorded"

open_seeded_full_status=0
set +e
CLIPY_APFS_PROBE_DIAGNOSTICS=1 \
CLIPY_RUNTIME_DIAGNOSTICS=1 \
"$probe" openSeededFullVolume "$store" \
  > "$temp_root/open-seeded-full.stdout.raw.log" \
  2> "$temp_root/open-seeded-full.stderr.raw.log" &
open_seeded_full_pid=$!
set -e
record_event "open-seeded-full-child-started"
if bounded_wait "$open_seeded_full_pid" 30 "open-seeded-full-exit"; then
  open_seeded_full_status=0
else
  open_seeded_full_status=$?
fi
open_seeded_full_pid=""
record_command_status "open-seeded-full-child" "$open_seeded_full_status"
collect_probe_diagnostics \
  "$temp_root/open-seeded-full.stderr.raw.log" \
  "$log_dir/open-seeded-full-diagnostics.log"
if [[ "$open_seeded_full_status" -ne 0 ]]; then
  record_event "child-failed"
  exit 1
fi
require_one_of_literals \
  "$temp_root/open-seeded-full.stdout.raw.log" \
  "open-seeded-full-token" \
  "$log_dir/open-seeded-full.stdout.log" \
  "OPENSEEDEDONFULLVOLUME_OPENSTORE_REFUSED" \
  "OPENSEEDEDONFULLVOLUME_TRANSACTION_REFUSED" \
  "OPENSEEDEDONFULLVOLUME_OK"
case "$matched_literal" in
  OPENSEEDEDONFULLVOLUME_OPENSTORE_REFUSED)
    open_seeded_full_volume_branch="refused-openstore"
    ;;
  OPENSEEDEDONFULLVOLUME_TRANSACTION_REFUSED)
    open_seeded_full_volume_branch="refused-transaction"
    ;;
  OPENSEEDEDONFULLVOLUME_OK)
    open_seeded_full_volume_branch="readable"
    ;;
  *)
    record_event "open-seeded-full-branch-mapping-unexpected"
    exit 1
    ;;
esac
record_event "open-seeded-full-branch-recorded"

# The filler is removed as soon as the two open cells are recorded, so the
# volume regains capacity before the capture handshake below.
rm -f -- "$filler"
filler=""
record_volume_facts "after-open-full-release"
record_event "complete"

pressure_input_fifo="$temp_root/pressure.stdin"
pressure_output_fifo="$temp_root/pressure.stdout"
begin_phase "prepare-pressure-handshake"
if mkfifo "$pressure_input_fifo" "$pressure_output_fifo"; then
  record_command_status "create-pressure-fifos" 0
else
  record_command_status "create-pressure-fifos" 1
  record_event "fifo-creation-failed"
  exit 1
fi

# RDWR opens keep FIFO setup nonblocking for the host. The child closes the
# inherited host descriptors and opens only its redirected stdin/stdout ends.
if exec 7<>"$pressure_output_fifo"; then
  record_command_status "open-pressure-output-fifo" 0
else
  record_command_status "open-pressure-output-fifo" 1
  record_event "output-fifo-open-failed"
  exit 1
fi
pressure_output_open=1
if exec 8<>"$pressure_input_fifo"; then
  record_command_status "open-pressure-input-fifo" 0
else
  record_command_status "open-pressure-input-fifo" 1
  record_event "input-fifo-open-failed"
  exit 1
fi
pressure_input_open=1
record_event "complete"
begin_phase "start-pressure-child"
CLIPY_APFS_PROBE_DIAGNOSTICS=1 \
CLIPY_RUNTIME_DIAGNOSTICS=1 \
"$probe" pressureCapture "$store" \
  <"$pressure_input_fifo" >"$pressure_output_fifo" \
  2>"$temp_root/pressure.stderr.raw.log" 7>&- 8>&- &
pressure_pid=$!
record_event "child-started"

ready_line=""
if IFS= read -r -t 30 ready_line <&7; then
  record_command_status "read-pressure-ready" 0
else
  ready_status=$?
  record_command_status "read-pressure-ready" "$ready_status"
  record_event "readiness-timeout-or-eof"
  exit 1
fi
printf '%s\n' "$ready_line" > "$temp_root/pressure-ready.stdout.raw.log"
require_literal_file \
  "$temp_root/pressure-ready.stdout.raw.log" "APFS_PRESSURE_READY" \
  "pressure-ready-token"
printf 'APFS_PRESSURE_READY\n' > "$log_dir/pressure-ready.stdout.log"
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
if printf 'GO\n' >&8; then
  record_command_status "write-pressure-go" 0
else
  record_command_status "write-pressure-go" 1
  record_event "go-write-failed"
  exit 1
fi
if exec 8>&-; then
  record_command_status "close-pressure-input" 0
else
  record_command_status "close-pressure-input" 1
  record_event "pressure-input-close-failed"
  exit 1
fi
pressure_input_open=0
record_event "go-sent"

result_line=""
if IFS= read -r -t 30 result_line <&7; then
  record_command_status "read-pressure-result" 0
else
  result_status=$?
  record_command_status "read-pressure-result" "$result_status"
  collect_probe_diagnostics \
    "$temp_root/pressure.stderr.raw.log" \
    "$log_dir/pressure-diagnostics.log"
  record_event "result-timeout-or-eof"
  exit 1
fi
printf '%s\n' "$result_line" > "$temp_root/pressure-result.stdout.raw.log"
require_literal_file \
  "$temp_root/pressure-result.stdout.raw.log" "PRESSURECAPTURE_OK" \
  "pressure-result-token"
printf 'PRESSURECAPTURE_OK\n' > "$log_dir/pressure-result.stdout.log"

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
  record_command_status "read-pressure-extra-output" 0
  record_event "unexpected-extra-output"
  exit 1
fi
record_command_status "read-pressure-extra-output" 1
if exec 7>&-; then
  record_command_status "close-pressure-output" 0
else
  record_command_status "close-pressure-output" 1
  record_event "pressure-output-close-failed"
  exit 1
fi
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
CLIPY_APFS_PROBE_DIAGNOSTICS=1 \
CLIPY_RUNTIME_DIAGNOSTICS=1 \
"$probe" verifySeed "$store" \
  > "$temp_root/verify.stdout.raw.log" \
  2> "$temp_root/verify.stderr.raw.log"
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
  "$temp_root/verify.stdout.raw.log" "VERIFYSEED_OK" "verify-token"
printf 'VERIFYSEED_OK\n' > "$log_dir/verify.stdout.log"
record_event "complete"

# Card 6B full-disk revise cell: the same FIFO handshake shape as the
# capture cell — the child commits its dedicated 8 MiB blob and verifies the
# seed table before READY, the fill happens only after READY, and the child
# proves both the typed §16 admission refusal and the byte-for-byte
# unchanged seed table before exiting. Cycle 1 closed fds 7/8 on the green
# path, so the pressure_*_open cleanup flags and pressure_pid are reused.
revise_input_fifo="$temp_root/revise.stdin"
revise_output_fifo="$temp_root/revise.stdout"
begin_phase "prepare-revise-handshake"
if mkfifo "$revise_input_fifo" "$revise_output_fifo"; then
  record_command_status "create-revise-fifos" 0
else
  record_command_status "create-revise-fifos" 1
  record_event "fifo-creation-failed"
  exit 1
fi

# RDWR opens keep FIFO setup nonblocking for the host; the child closes the
# inherited host descriptors and opens only its redirected stdin/stdout ends.
if exec 7<>"$revise_output_fifo"; then
  record_command_status "open-revise-output-fifo" 0
else
  record_command_status "open-revise-output-fifo" 1
  record_event "output-fifo-open-failed"
  exit 1
fi
pressure_output_open=1
if exec 8<>"$revise_input_fifo"; then
  record_command_status "open-revise-input-fifo" 0
else
  record_command_status "open-revise-input-fifo" 1
  record_event "input-fifo-open-failed"
  exit 1
fi
pressure_input_open=1
record_event "complete"
begin_phase "start-revise-child"
CLIPY_APFS_PROBE_DIAGNOSTICS=1 \
CLIPY_RUNTIME_DIAGNOSTICS=1 \
"$probe" pressureRevise "$store" \
  <"$revise_input_fifo" >"$revise_output_fifo" \
  2>"$temp_root/revise.stderr.raw.log" 7>&- 8>&- &
pressure_pid=$!
record_event "child-started"

# 60s, not cycle 1's 30: this child commits an 8 MiB blob and writes its
# manifest before publishing READY.
revise_ready_line=""
if IFS= read -r -t 60 revise_ready_line <&7; then
  record_command_status "read-revise-ready" 0
else
  revise_ready_status=$?
  record_command_status "read-revise-ready" "$revise_ready_status"
  record_event "readiness-timeout-or-eof"
  exit 1
fi
printf '%s\n' "$revise_ready_line" > "$temp_root/revise-ready.stdout.raw.log"
require_literal_file \
  "$temp_root/revise-ready.stdout.raw.log" "APFS_PRESSURE_READY" \
  "revise-ready-token"
printf 'APFS_PRESSURE_READY\n' > "$log_dir/revise-ready.stdout.log"
record_event "ready"

begin_phase "revise-fill-volume"
if ! require_competitor_enospc "revise-under-pressure"; then
  exit 1
fi
record_event "complete"

begin_phase "revise-under-pressure"
if printf 'GO\n' >&8; then
  record_command_status "write-revise-go" 0
else
  record_command_status "write-revise-go" 1
  record_event "go-write-failed"
  exit 1
fi
if exec 8>&-; then
  record_command_status "close-revise-input" 0
else
  record_command_status "close-revise-input" 1
  record_event "revise-input-close-failed"
  exit 1
fi
pressure_input_open=0
record_event "go-sent"

revise_result_line=""
if IFS= read -r -t 30 revise_result_line <&7; then
  record_command_status "read-revise-result" 0
else
  revise_result_status=$?
  record_command_status "read-revise-result" "$revise_result_status"
  collect_probe_diagnostics \
    "$temp_root/revise.stderr.raw.log" "$log_dir/revise-diagnostics.log"
  record_event "result-timeout-or-eof"
  exit 1
fi
printf '%s\n' "$revise_result_line" > "$temp_root/revise-result.stdout.raw.log"
require_literal_file \
  "$temp_root/revise-result.stdout.raw.log" "PRESSUREREVISE_OK" \
  "revise-result-token"
printf 'PRESSUREREVISE_OK\n' > "$log_dir/revise-result.stdout.log"

if bounded_wait "$pressure_pid" 15 "revise-exit"; then
  revise_child_status=0
else
  revise_child_status=$?
fi
pressure_pid=""
record_command_status "revise-child" "$revise_child_status"
collect_probe_diagnostics \
  "$temp_root/revise.stderr.raw.log" "$log_dir/revise-diagnostics.log"
if [[ "$revise_child_status" -ne 0 ]]; then
  record_event "child-failed"
  exit 1
fi

revise_extra_line=""
if IFS= read -r -t 1 revise_extra_line <&7 || [[ -n "$revise_extra_line" ]]; then
  record_command_status "read-revise-extra-output" 0
  record_event "unexpected-extra-output"
  exit 1
fi
record_command_status "read-revise-extra-output" 1
if exec 7>&-; then
  record_command_status "close-revise-output" 0
else
  record_command_status "close-revise-output" 1
  record_event "revise-output-close-failed"
  exit 1
fi
pressure_output_open=0
record_volume_facts "revise-after-rejected-revision"
record_event "complete"

begin_phase "release-revise-pressure"
rm -f -- "$filler"
filler=""
record_volume_facts "revise-after-competitor-removal"
record_event "complete"

begin_phase "revise-commit-after-release"
set +e
CLIPY_APFS_PROBE_DIAGNOSTICS=1 \
CLIPY_RUNTIME_DIAGNOSTICS=1 \
"$probe" pressureReviseCommit "$store" \
  > "$temp_root/revise-commit.stdout.raw.log" \
  2> "$temp_root/revise-commit.stderr.raw.log"
revise_commit_status=$?
set -e
record_command_status "revise-commit-child" "$revise_commit_status"
collect_probe_diagnostics \
  "$temp_root/revise-commit.stderr.raw.log" \
  "$log_dir/revise-commit-diagnostics.log"
if [[ "$revise_commit_status" -ne 0 ]]; then
  record_event "child-failed"
  exit 1
fi
require_literal_file \
  "$temp_root/revise-commit.stdout.raw.log" "PRESSUREREVISECOMMIT_OK" \
  "revise-commit-token"
printf 'PRESSUREREVISECOMMIT_OK\n' > "$log_dir/revise-commit.stdout.log"
record_event "complete"

begin_phase "revise-verify-fresh-process"
set +e
CLIPY_APFS_PROBE_DIAGNOSTICS=1 \
CLIPY_RUNTIME_DIAGNOSTICS=1 \
"$probe" pressureReviseVerify "$store" \
  > "$temp_root/revise-verify.stdout.raw.log" \
  2> "$temp_root/revise-verify.stderr.raw.log"
revise_verify_status=$?
set -e
record_command_status "revise-verify-child" "$revise_verify_status"
collect_probe_diagnostics \
  "$temp_root/revise-verify.stderr.raw.log" \
  "$log_dir/revise-verify-diagnostics.log"
if [[ "$revise_verify_status" -ne 0 ]]; then
  record_event "child-failed"
  exit 1
fi
require_literal_file \
  "$temp_root/revise-verify.stdout.raw.log" "PRESSUREREVISEVERIFY_OK" \
  "revise-verify-token"
printf 'PRESSUREREVISEVERIFY_OK\n' > "$log_dir/revise-verify.stdout.log"
record_event "complete"

begin_phase "detach-image"
detach_volume
record_event "complete"

# Delete the raw tool/framework logs and disposable image before publishing a
# success result. The EXIT trap remains the abnormal-path fallback until this
# explicit cleanup has succeeded.
trap - EXIT
if cleanup_resources 0 0; then
  :
else
  final_cleanup_status=$?
  exit "$final_cleanup_status"
fi

set +e
{
  printf 'artifact=%s\n' "HistoryRestartProbe Release product"
  printf 'filesystem=%s\n' "APFS"
  printf 'image_capacity_mib=%s\n' "$image_size_mib"
  printf 'competitor_request_mib=%s\n' "$competitor_size_mib"
  printf 'competitor_result=%s\n' "ENOSPC"
  printf 'seed=%s\n' "complete"
  printf 'pressure_capture=%s\n' "transaction rejected with seed preserved"
  printf 'fresh_verify=%s\n' "seed state readable"
  printf 'open_full_volume=%s\n' "$open_full_volume_branch"
  printf 'open_seeded_full_volume=%s\n' "$open_seeded_full_volume_branch"
  printf 'pressure_revise=%s\n' "revision rejected with seed preserved"
  printf 'pressure_revise_commit=%s\n' \
    "same revision committed after space release"
  printf 'pressure_revise_verify=%s\n' "durable revised state readable"
  printf '%s\n' \
    "evidence_ceiling=Card 6B admission-refusal leaves only; post-admission mid-transaction exhaustion remains the Apple framework crash ceiling (docs/05 §16); remove/clear full-disk tails uncharacterized (zero-demand plans are never admission-refused); V1->V2 migration-on-full-disk is not triggerable through the public API"
} | tee "$log_dir/apfs-enospc-summary.log"
success_summary_status=$?
set -e
if [[ "$success_summary_status" -ne 0 ]]; then
  finish_after_publication_failure \
    "write-success-summary" "$success_summary_status"
fi

current_phase="complete"
if record_event "evidence-passed"; then
  :
else
  evidence_phase_status=$?
  finish_after_publication_failure \
    "write-success-phase" "$evidence_phase_status"
fi
if write_diagnostic_manifest; then
  # Normal success writes its summary and terminal phase first. The manifest
  # is then the absolute final artifact-file write.
  printf 'CLIPY_APFS_MANIFEST status=0\n' >&2
else
  rm -f -- "$diagnostic_manifest_log"
  record_command_status "write-diagnostic-manifest" 1
  record_event "diagnostic-manifest-failed"
  write_exit_summary "complete" 0 1 1
  printf 'CLIPY_APFS_MANIFEST status=1\n' >&2
  exit 1
fi
echo "APFS ENOSPC evidence: capture transaction leaf and fresh seed verification passed"
