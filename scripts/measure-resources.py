#!/usr/bin/env python3
"""Observe an already running VPNGPT without changing its UI or sending probes.

Example: ./scripts/measure-resources.py --duration 30 --output build/perf/after.json
macOS libproc supplies cumulative CPU time and memory. CPU excludes child
processes and 100 percent means one fully occupied core. Child launches and
state-file changes are sampled lower bounds: short-lived children or several
writes between samples can be missed. UI visibility, scan activity, and machine
load are deliberately not controlled; compare only equivalent observed scenes.
"""

import argparse
import ctypes
import datetime
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time


class RUsageV2(ctypes.Structure):
    # sys/resource.h, struct rusage_info_v2; CPU user/system times are nanoseconds.
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64)
        for name in (
            "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups",
            "ri_interrupt_wkups", "ri_pageins", "ri_wired_size",
            "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime",
            "ri_proc_exit_abstime", "ri_child_user_time", "ri_child_system_time",
            "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
            "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread",
            "ri_diskio_byteswritten",
        )
    ]


class ProcessObserver:
    def __init__(self, pid):
        self.pid = pid
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype = ctypes.c_int
        self.lib.proc_name.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_name.restype = ctypes.c_int
        self.lib.proc_listpids.argtypes = [
            ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int,
        ]
        self.lib.proc_listpids.restype = ctypes.c_int
        if ctypes.sizeof(RUsageV2) != 160:
            raise RuntimeError("Unexpected macOS rusage_info_v2 layout")
        if self.name(pid) != "VPNGPT":
            raise RuntimeError("Selected PID is not VPNGPT")
        self.start = self.usage().ri_proc_start_abstime

    def name(self, pid):
        name = ctypes.create_string_buffer(1024)
        size = self.lib.proc_name(pid, name, len(name))
        return name.value.decode("utf-8", errors="replace") if size > 0 else None

    def usage(self):
        usage = RUsageV2()
        if self.lib.proc_pid_rusage(self.pid, 2, ctypes.byref(usage)) != 0:
            raise RuntimeError("VPNGPT exited or its resource counters became unavailable")
        if usage.ri_proc_exit_abstime:
            raise RuntimeError("VPNGPT exited during measurement")
        if hasattr(self, "start") and usage.ri_proc_start_abstime != self.start:
            raise RuntimeError("VPNGPT PID was reused; measurement aborted")
        return usage

    def curl_children(self):
        # PROC_PPID_ONLY limits enumeration to this application's direct children.
        # Read executable names only, never argument lists or other applications.
        needed = self.lib.proc_listpids(6, self.pid, None, 0)
        if needed <= 0:
            return set()
        buffer = (ctypes.c_int * (needed // ctypes.sizeof(ctypes.c_int) + 32))()
        used = self.lib.proc_listpids(6, self.pid, buffer, ctypes.sizeof(buffer))
        if used < 0:
            raise RuntimeError("Cannot enumerate VPNGPT child processes")
        return {
            pid for pid in buffer[:used // ctypes.sizeof(ctypes.c_int)]
            if pid > 0 and self.name(pid) == "curl"
        }


def discover_pid():
    result = subprocess.run(
        ["/usr/bin/pgrep", "-x", "VPNGPT"], capture_output=True, text=True,
    )
    pids = result.stdout.split()
    if result.returncode not in (0, 1) or len(pids) != 1:
        raise RuntimeError("Expected one VPNGPT process; specify --pid explicitly")
    return int(pids[0])


def state_stamp(path):
    try:
        stat = path.stat()
        return stat.st_mtime_ns, stat.st_ino
    except FileNotFoundError:
        return None


def memory_summary(values):
    mib = 1024 * 1024
    return {
        "mean_mib": round(statistics.fmean(values) / mib, 3),
        "max_mib": round(max(values) / mib, 3),
    }


def measure(args):
    observer = ProcessObserver(args.pid or discover_pid())
    state_path = Path.home() / "Library/Application Support/VPNGPT/state.json"
    started_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    first = observer.usage()
    began = time.monotonic()
    resident = [first.ri_resident_size]
    footprint = [first.ri_phys_footprint]
    seen_curl = observer.curl_children()
    initial_curl = len(seen_curl)
    previous_stamp = state_stamp(state_path)
    writes = 0
    sample_number = 1
    last = first
    while True:
        deadline = min(began + sample_number * args.interval, began + args.duration)
        time.sleep(max(0, deadline - time.monotonic()))
        last = observer.usage()
        ended = time.monotonic()
        resident.append(last.ri_resident_size)
        footprint.append(last.ri_phys_footprint)
        seen_curl.update(observer.curl_children())
        stamp = state_stamp(state_path)
        writes += int(stamp != previous_stamp)
        previous_stamp = stamp
        if ended - began >= args.duration:
            break
        sample_number += 1
    # A final identity check also covers process exit during child enumeration.
    observer.usage()
    wall = ended - began
    user_seconds = (last.ri_user_time - first.ri_user_time) / 1e9
    system_seconds = (last.ri_system_time - first.ri_system_time) / 1e9
    if user_seconds < 0 or system_seconds < 0:
        raise RuntimeError("CPU counters moved backwards; measurement aborted")
    return {
        "schema_version": 1,
        "scenario": "observed; UI visibility, user activity and scan state uncontrolled",
        "started_at_utc": started_at,
        "pid": observer.pid,
        "process_start_abstime": observer.start,
        "requested_duration_seconds": args.duration,
        "wall_seconds": round(wall, 6),
        "sample_interval_seconds": args.interval,
        "samples": len(resident),
        "cpu": {
            "user_seconds": round(user_seconds, 6),
            "system_seconds": round(system_seconds, 6),
            "total_seconds": round(user_seconds + system_seconds, 6),
            "percent_one_core": round((user_seconds + system_seconds) / wall * 100, 4),
        },
        "rss": memory_summary(resident),
        "physical_footprint": memory_summary(footprint),
        "curl_children_existing_at_start": initial_curl,
        "curl_child_launches_observed": len(seen_curl) - initial_curl,
        "state_file_changes_observed": writes,
        "limitations": [
            "CPU covers the app process only; excludes curl and proxy core CPU.",
            "Child launches and state-file changes are sampled lower bounds.",
            "No network probes are issued and no UI or app lifecycle changes are made.",
            "Observed scenes are not a controlled performance comparison.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, help="VPNGPT PID; default discovers a single instance")
    parser.add_argument("--duration", type=float, default=30, help="seconds (default: 30)")
    parser.add_argument("--interval", type=float, default=0.25, help="sampling interval in seconds")
    parser.add_argument("--output", type=Path, help="save full report JSON")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This observer requires macOS libproc")
    if args.duration <= 0 or args.interval <= 0 or (args.pid is not None and args.pid <= 0):
        parser.error("PID, duration and interval must be positive")
    try:
        report = measure(args)
        encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(encoded, encoding="utf-8")
        print(encoded, end="")
    except (OSError, RuntimeError) as error:
        print(f"Measurement failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
