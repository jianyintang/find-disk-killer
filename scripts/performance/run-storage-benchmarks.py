#!/usr/bin/env python3
"""Reproduce isolated storage data-structure benchmarks; requires macOS + swiftc."""

import argparse
import json
from pathlib import Path
import re
import statistics
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Output directory (default: new temporary directory)")
    args = parser.parse_args()
    output = args.output or Path(tempfile.mkdtemp(prefix="fdk-storage-benchmark-"))
    output.mkdir(parents=True, exist_ok=True)
    executable = str(output.resolve() / "storage-ledger-benchmark")
    source = Path(__file__).with_name("storage-ledger-benchmark.swift")
    subprocess.run(["swiftc", "-O", "-whole-module-optimization", str(source), "-o", executable], check=True)
    environment = {
        "swift": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
        "macos": subprocess.check_output(["sw_vers"], text=True).strip(),
        "hardware": subprocess.check_output(["sysctl", "hw.model", "hw.memsize"], text=True).strip(),
    }
    (output / "environment.json").write_text(json.dumps(environment, indent=2) + "\n")
    with (output / "verify.jsonl").open("w") as stream:
        for distribution in ["balanced", "skewed"]:
            for count in [1000, 8000, 32000]:
                result = subprocess.run(
                    [executable, "verify", "both", str(count), distribution],
                    capture_output=True, text=True, check=True,
                )
                row = json.loads(result.stdout)
                assert row["equal"], row
                stream.write(json.dumps(row) + "\n")
    all_results = []
    fixtures = [
        ("mutation", [1000, 8000, 32000], ["copied", "inplace", "scoped"], ["balanced", "skewed"]),
        ("ledger", [100000, 1000000], ["rich", "compact"], [None]),
    ]
    with (output / "results.jsonl").open("w") as stream:
        for kind, counts, modes, distributions in fixtures:
            for distribution in distributions:
                for count in counts:
                    for trial in range(3):
                        for mode in modes if trial % 2 == 0 else modes[::-1]:
                            command = ["/usr/bin/time", "-l", executable, kind, mode, str(count)]
                            if distribution:
                                command.append(distribution)
                            result = subprocess.run(command, capture_output=True, text=True, check=True)
                            row = json.loads(result.stdout)
                            peak = re.search(r"(\d+)\s+maximum resident set size", result.stderr)
                            assert peak, result.stderr
                            row.update(trial=trial + 1, time_maxrss_bytes=int(peak.group(1)),
                                       time_stderr=result.stderr.strip())
                            all_results.append(row)
                            stream.write(json.dumps(row) + "\n")
                            stream.flush()
                    print("Measured", kind, distribution or "", count, flush=True)

    checksums, groups = {}, {}
    for row in all_results:
        fixture = (row["kind"], row.get("distribution", ""), row["count"])
        checksums.setdefault(fixture, set()).add(row["checksum"])
        groups.setdefault((*fixture, row["mode"]), []).append(row)
    assert all(len(values) == 1 for values in checksums.values()), checksums
    summary = []
    for (kind, distribution, count, mode), rows in groups.items():
        times = [row["build_ms"] for row in rows]
        summary.append(dict(kind=kind, distribution=distribution, count=count, mode=mode,
                            median_ms=statistics.median(times), min_ms=min(times), max_ms=max(times),
                            median_peak_rss_mib=statistics.median(row["time_maxrss_bytes"] for row in rows) / 2**20,
                            checksum=rows[0]["checksum"]))
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("All equivalent-output checks passed. Results:", output.resolve())


if __name__ == "__main__":
    main()
