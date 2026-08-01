#!/usr/bin/env bash

set -euo pipefail

echo "Running the fast CI suite. Scanner integration, timing, and filesystem-event tests run locally via make test."

package_backup="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/find-disk-killer-Package.$$.swift"
cp Package.swift "$package_backup"
restore_package() {
    cp "$package_backup" Package.swift
}
trap restore_package EXIT

if [[ "${CI_CORE_ONLY:-0}" == "1" ]]; then
    # Xcode 16.4's hosted Swift frontend can crash while lowering the large
    # App module. The Xcode build below still validates the complete app;
    # SwiftPM uses the independent core/helper targets here to stay stable.
    perl -0pi -e '
        s/        \.executable\(name: "FindDiskKiller", targets: \["FindDiskKillerApp"\]\)\n//;
        s/\n        \.executableTarget\(\n            name: "FindDiskKillerApp",.*?\n        \),//s;
        s/\n        \.testTarget\(\n            name: "FindDiskKillerAppTests",.*?\n        \),//s;
    ' Package.swift
fi

swift test --build-system native --no-parallel --jobs 1 \
    --skip "${CI_LOCAL_ONLY_TESTS:?CI_LOCAL_ONLY_TESTS is required}"
