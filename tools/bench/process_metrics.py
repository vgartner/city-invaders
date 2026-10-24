"""Read macOS per-process counters without a debugger or another process.

ABI: Apple SDK sys/resource.h, rusage_info_v2 (160 bytes), libproc
proc_pid_rusage. Page-ins are not proof of swapping; disk counters describe
actual kernel-accounted I/O, not all logical reads. Never sum RSS/footprint
with Godot's overlapping allocation counters. Other OSes report unavailable.
"""
import ctypes
import os
import sys


class RUsageV2(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins",
            "wired_size", "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime",
            "child_user_time", "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups",
            "child_pageins", "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten")]


class ProcessMetrics:
    def __init__(self, pid):
        self.pid, self.start = pid, None
        self.error = None
        self.lib = None
        if sys.platform != "darwin":
            self.error = "native process counters currently supported on macOS only"
        else:
            try:
                self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
                self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
                self.lib.proc_pid_rusage.restype = ctypes.c_int
            except OSError as error:
                self.error = str(error)

    def sample(self):
        if self.error:
            return {"available": False, "reason": self.error}
        usage = RUsageV2()
        if self.lib.proc_pid_rusage(self.pid, 2, ctypes.byref(usage)) != 0:
            return {"available": False, "reason": os.strerror(ctypes.get_errno())}
        if self.start is not None and self.start != usage.proc_start_abstime:
            return {"available": False, "reason": "PID belongs to a different process now"}
        self.start = usage.proc_start_abstime
        return {"available": True, "rss_mb": usage.resident_size / 1048576,
                "footprint_mb": usage.phys_footprint / 1048576, "pageins": usage.pageins,
                "disk_read_bytes": usage.diskio_bytesread, "disk_write_bytes": usage.diskio_byteswritten}
