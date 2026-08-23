#!/usr/bin/env bash
# Linux-runnable regression loop for the failure observability boundary. Fake
# macOS commands stop at image creation, after build bootstrap but before any
# APFS state exists, and require the EXIT path to retain safe diagnostics.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/clipy-apfs-diag-test.XXXXXX")"
runner_temp="$fixture_root/runner-temp"
log_dir="$fixture_root/published-logs"
fake_bin="$fixture_root/fake-bin"
probe="$fixture_root/HistoryRestartProbe"
captured_stderr="$fixture_root/script.stderr.log"
raw_uuid="01234567-89AB-CDEF-0123-456789ABCDEF"

cleanup_fixture() {
  if [[ "${CLIPY_KEEP_APFS_DIAGNOSTIC_FIXTURE:-0}" == "1" ]]; then
    printf 'kept_fixture=%s\n' "$fixture_root" >&2
  else
    rm -rf -- "$fixture_root"
  fi
}
trap cleanup_fixture EXIT
mkdir -p "$runner_temp" "$fake_bin"

printf '#!/usr/bin/env bash\nexit 0\n' > "$probe"
chmod +x "$probe"

printf '#!/usr/bin/env bash\nprintf "mock release build complete\\n"\n' \
  > "$fake_bin/swift"
chmod +x "$fake_bin/swift"

cat > "$fake_bin/hdiutil" <<'FAKE_HDIUTIL'
#!/usr/bin/env bash
last_argument=""
for argument in "$@"; do
  last_argument="$argument"
done
printf 'create failed image=%s device=/dev/disk42 parent=disk42s1 uuid=%s\n' \
  "$last_argument" '01234567-89AB-CDEF-0123-456789ABCDEF' >&2
printf 'localizedDescription=retained-debug-detail userInfo=retained-debug-keys\n' >&2
printf 'host=/Users/runner/work/Clipy file=file:///private/tmp/clipy.dmg\n' >&2
exit 9
FAKE_HDIUTIL
chmod +x "$fake_bin/hdiutil"

set +e
(
  cd "$repo_root"
  PATH="$fake_bin:$PATH" \
  CLIPY_APFS_PROBE_PATH="$probe" \
    bash scripts/ci/run_apfs_enospc.sh "$log_dir" "$runner_temp"
) 2> "$captured_stderr"
script_status=$?
set -e

if [[ "$script_status" -eq 0 ]]; then
  echo "expected injected hdiutil failure" >&2
  exit 1
fi
grep -Fxq 'result=failure' "$log_dir/failure-summary.log"
grep -Fxq 'exit_phase=create-image' "$log_dir/failure-summary.log"
grep -Fxq 'body_status=1' "$log_dir/failure-summary.log"
grep -Fxq 'cleanup_status=0' "$log_dir/failure-summary.log"
grep -Fxq 'outgoing_status=1' "$log_dir/failure-summary.log"
grep -Fq 'file=raw-bounded/hdiutil-create.log' \
  "$log_dir/diagnostic-manifest.log"
grep -Fq "$fixture_root" "$log_dir/raw-bounded/hdiutil-create.log"
grep -Fq '/dev/disk42' "$log_dir/raw-bounded/hdiutil-create.log"
grep -Fq 'disk42s1' "$log_dir/raw-bounded/hdiutil-create.log"
grep -Fq "$raw_uuid" "$log_dir/raw-bounded/hdiutil-create.log"
grep -Fq 'localizedDescription=retained-debug-detail' \
  "$log_dir/raw-bounded/hdiutil-create.log"
grep -Fq 'userInfo=retained-debug-keys' \
  "$log_dir/raw-bounded/hdiutil-create.log"
grep -Fq '/Users/runner/work/Clipy' \
  "$log_dir/raw-bounded/hdiutil-create.log"
grep -Fq 'file:///private/tmp/clipy.dmg' \
  "$log_dir/raw-bounded/hdiutil-create.log"
grep -Fq 'CLIPY_APFS_DIAGNOSTIC failure-summary.log' "$captured_stderr"

echo "APFS diagnostic early-failure regression passed"
