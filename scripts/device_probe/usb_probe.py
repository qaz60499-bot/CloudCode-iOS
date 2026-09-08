"""Read-only, bounded USB evidence capture using the already installed pymobiledevice3.

Never installs apps, resets pairing, flushes or deletes reports. Output is local.
"""
import argparse
import asyncio
import datetime as dt
import json
import logging
import pathlib
import re


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def relevant(line):
    # Do not collect unrelated SpringBoard/backboardd motion traffic.
    return bool(re.search(
        r"CloudCode|com\.cloudcode|CloudCodeRootHelper|CloudCodeVisionHelper|Vision|AXRuntime|CoreVideo|CoreML|RunningBoard|launchd|amfid|jetsam|memorystatus",
        line,
        re.I,
    ))


async def capture(out, seconds):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    from pymobiledevice3.services.os_trace import OsTraceService
    from pymobiledevice3.services.crash_reports import CrashReportsManager
    from pymobiledevice3.services.syslog import SyslogService

    out.mkdir(parents=True, exist_ok=False)
    snapshot = {"schemaVersion": 1, "startedAtUTC": now(), "readOnly": True}
    async with await create_using_usbmux(autopair=False, connection_type="USB") as device:
        snapshot["device"] = {k: await device.get_value(key=k) for k in
                              ("ProductType", "ProductVersion", "BuildVersion", "TimeIntervalSince1970")}
        async with InstallationProxyService(device) as proxy:
            apps = await proxy.get_apps(bundle_identifiers=["com.cloudcode.ios"])
            app = apps.get("com.cloudcode.ios", {})
            snapshot["app"] = {k: app[k] for k in (
                "CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString",
                "ApplicationType", "Path", "Container", "Entitlements", "TSRootBinaries") if k in app}
        async with OsTraceService(device) as trace:
            processes = (await trace.get_pid_list()).get("Payload", {})
            snapshot["processes"] = [{"pid": pid, "name": info.get("ProcessName")}
                                     for pid, info in processes.items()
                                     if "CloudCode" in info.get("ProcessName", "")]
        async with CrashReportsManager(device) as crashes:
            paths = await crashes.ls("/", depth=2)
            snapshot["reports"] = [p for p in paths if re.search(r"CloudCode|JetsamEvent", p)]
        (out / "snapshot.json").write_text(json.dumps(snapshot, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({"snapshot": str(out / "snapshot.json"), "processes": snapshot["processes"]}), flush=True)
        if seconds:
            count = 0
            with (out / "syslog.jsonl").open("w", encoding="utf-8") as stream:
                async with SyslogService(device) as syslog:
                    try:
                        async with asyncio.timeout(seconds):
                            async for line in syslog.watch():
                                if isinstance(line, bytes):
                                    line = line.decode("utf-8", errors="replace")
                                if not relevant(line):
                                    continue
                                stream.write(json.dumps({"receivedAtUTC": now(), "line": line[:16384]}, ensure_ascii=False) + "\n")
                                stream.flush()
                                count += 1
                                if stream.tell() >= 8 * 1024 * 1024:
                                    break
                    except TimeoutError:
                        pass
            print(json.dumps({"finishedAtUTC": now(), "filteredLines": count}), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--seconds", type=int, default=0, choices=range(0, 601), metavar="0..600")
    args = parser.parse_args()
    logging.getLogger("pymobiledevice3").setLevel(logging.ERROR)
    try:
        asyncio.run(asyncio.wait_for(capture(args.out, args.seconds), timeout=args.seconds + 45))
    except Exception as error:
        # Exception repr can embed device identifiers. Keep console errors bounded and non-sensitive.
        print(json.dumps({"errorType": type(error).__name__, "status": "capture_failed"}))
        raise SystemExit(1)
