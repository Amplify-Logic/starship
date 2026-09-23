#!/usr/bin/env bash
# Behavior tests for the gateway v2 quarantine artifact importer (Step 2 sub-order 7).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMPORTER="$ROOT/bin/fm-action-artifact-import-v2.py"
TMP=$(fm_test_tmproot fm-action-artifact-import-v2)
ARCHIVES="$TMP/archives"
mkdir -p "$ARCHIVES"

# The hostile archives the Step 1 regression pack builds, plus the ones its two
# probes do not cover. Built here rather than committed so no repository file is
# ever itself a traversal payload.
build_archives() {
  python3 - "$ARCHIVES" <<'PY'
import io
import pathlib
import sys
import tarfile
import zipfile

root = pathlib.Path(sys.argv[1])


def member(archive, name, payload=b"SYNTHETIC"):
    info = tarfile.TarInfo(name)
    info.size = len(payload)
    archive.addfile(info, io.BytesIO(payload))


with tarfile.open(root / "traversal.tar", "w") as archive:
    member(archive, "../../outside-canary", b"SYNTHETIC_TRAVERSAL")

with tarfile.open(root / "symlink.tar", "w") as archive:
    link = tarfile.TarInfo("escape-link")
    link.type = tarfile.SYMTYPE
    link.linkname = "../../outside-canary"
    archive.addfile(link)
    member(archive, "escape-link/payload", b"SYNTHETIC_SYMLINK")

with tarfile.open(root / "absolute.tar", "w") as archive:
    member(archive, "/etc/synthetic-canary")

with tarfile.open(root / "hardlink.tar", "w") as archive:
    member(archive, "real")
    link = tarfile.TarInfo("hard")
    link.type = tarfile.LNKTYPE
    link.linkname = "real"
    archive.addfile(link)

with tarfile.open(root / "device.tar", "w") as archive:
    node = tarfile.TarInfo("null")
    node.type = tarfile.CHRTYPE
    node.devmajor = 1
    node.devminor = 3
    archive.addfile(node)

with tarfile.open(root / "duplicate.tar", "w") as archive:
    member(archive, "same.txt", b"first")
    member(archive, "same.txt", b"second")

with tarfile.open(root / "control.tar", "w") as archive:
    member(archive, "bad\nname.txt")

with tarfile.open(root / "empty.tar", "w"):
    pass

with tarfile.open(root / "good.tar", "w") as archive:
    member(archive, "dir/file.txt", b"hello")
    member(archive, "dir/nested/other.txt", b"world")

with zipfile.ZipFile(root / "traversal.zip", "w") as archive:
    archive.writestr("../../outside-canary", "SYNTHETIC_TRAVERSAL")

with zipfile.ZipFile(root / "symlink.zip", "w") as archive:
    info = zipfile.ZipInfo("escape-link")
    info.external_attr = (0o120777 << 16)
    archive.writestr(info, "../../outside-canary")

with zipfile.ZipFile(root / "good.zip", "w") as archive:
    archive.writestr("dir/file.txt", "hello")
PY
}

# The exact argv contract bin/fm-worker-boundary-regression.sh uses for
# --artifact-adapter, including its own pass condition: nonzero exit, the
# destination still empty, and the outside canary unchanged.
expect_rejected() {  # <archive> <label>
  local archive=$1 label=$2 destination outside rc
  destination="$TMP/dest-$label"
  outside="$TMP/outside-$label"
  rm -rf "$destination"
  mkdir -p "$destination"
  printf 'SYNTHETIC_OUTSIDE_UNCHANGED\n' > "$outside"
  set +e
  "$IMPORTER" --input "$archive" --destination "$destination" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$label: importer accepted a hostile archive"
  [ -z "$(ls -A "$destination")" ] || fail "$label: destination is not empty after a refusal"
  [ "$(cat "$outside")" = SYNTHETIC_OUTSIDE_UNCHANGED ] || fail "$label: the outside canary changed"
}

test_hostile_archives_are_refused_and_import_nothing() {
  build_archives
  expect_rejected "$ARCHIVES/traversal.tar" traversal
  expect_rejected "$ARCHIVES/symlink.tar" symlink
  expect_rejected "$ARCHIVES/absolute.tar" absolute
  expect_rejected "$ARCHIVES/hardlink.tar" hardlink
  expect_rejected "$ARCHIVES/device.tar" device
  expect_rejected "$ARCHIVES/duplicate.tar" duplicate
  expect_rejected "$ARCHIVES/control.tar" control
  expect_rejected "$ARCHIVES/empty.tar" empty
  expect_rejected "$ARCHIVES/traversal.zip" traversal-zip
  expect_rejected "$ARCHIVES/symlink.zip" symlink-zip
  pass "every hostile archive is refused, imports nothing, and leaves the outside canary unchanged"
}

test_a_clean_archive_imports_whole() {
  local destination out
  build_archives
  destination="$TMP/dest-good"
  mkdir -p "$destination"
  out=$("$IMPORTER" --input "$ARCHIVES/good.tar" --destination "$destination")
  assert_contains "$out" '"outcome":"imported"' "a clean archive imports"
  assert_present "$destination/dir/file.txt" "imported file"
  assert_present "$destination/dir/nested/other.txt" "imported nested file"
  [ "$(cat "$destination/dir/file.txt")" = hello ] || fail "imported content must be exact"

  destination="$TMP/dest-good-zip"
  mkdir -p "$destination"
  out=$("$IMPORTER" --input "$ARCHIVES/good.zip" --destination "$destination")
  assert_contains "$out" '"outcome":"imported"' "a clean zip imports"
  assert_present "$destination/dir/file.txt" "imported zip file"
  pass "a clean archive imports whole, from either container format"
}

test_import_never_merges_into_an_occupied_destination() {
  local destination out rc
  build_archives
  destination="$TMP/dest-occupied"
  mkdir -p "$destination"
  printf 'someone else put this here\n' > "$destination/existing.txt"
  set +e
  out=$("$IMPORTER" --input "$ARCHIVES/good.tar" --destination "$destination" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "occupied destination"
  assert_contains "$out" 'destination is not empty' "an import never merges into files it did not place"
  [ "$(cat "$destination/existing.txt")" = 'someone else put this here' ] || fail "the existing file must be untouched"

  set +e
  out=$("$IMPORTER" --input "$ARCHIVES/good.tar" --destination "$TMP/does-not-exist" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing destination"
  assert_contains "$out" 'destination is not an existing directory' "the importer does not invent its destination"
  pass "an import refuses an occupied or missing destination instead of merging or creating one"
}

test_inspect_reports_without_importing() {
  local out rc
  build_archives
  out=$("$IMPORTER" --input "$ARCHIVES/good.tar" --inspect)
  assert_contains "$out" '"outcome":"accepted"' "inspect accepts a clean archive"
  assert_contains "$out" '"member_count":2' "inspect counts members"
  set +e
  out=$("$IMPORTER" --input "$ARCHIVES/traversal.tar" --inspect 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "inspect refuses a hostile archive"
  assert_contains "$out" 'escapes the destination' "inspect names the reason"
  pass "inspect reports the same verdict without importing anything"
}

test_hostile_archives_are_refused_and_import_nothing
test_a_clean_archive_imports_whole
test_import_never_merges_into_an_occupied_destination
test_inspect_reports_without_importing
