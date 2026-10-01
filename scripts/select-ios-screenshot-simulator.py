#!/usr/bin/env python3
"""Select one available named iOS device on the requested, SDK-compatible runtime."""
import argparse
import json
import subprocess


def version(value):
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def select_device(data, name, requested_os, sdk):
    runtimes = [runtime for runtime in data['runtimes']
                if runtime.get('isAvailable') and '.iOS-' in runtime['identifier']
                and version(runtime['version']) <= version(sdk)]
    if requested_os != 'latest':
        runtimes = [runtime for runtime in runtimes
                    if version(runtime['version']) == version(requested_os)]
    if not runtimes:
        raise ValueError(f'No available iOS {requested_os} runtime compatible with SDK {sdk}')
    runtime = max(runtimes, key=lambda item: (version(item['version']), item['identifier']))
    devices = sorted(device['udid'] for device in data['devices'].get(runtime['identifier'], [])
                     if device.get('isAvailable') and device['name'] == name)
    if not devices:
        raise ValueError(f'No available {name!r} device on iOS {runtime["version"]}')
    return devices[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--name', required=True)
    parser.add_argument('--os', default='latest')
    args = parser.parse_args()
    data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '--json']))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
    try:
        print(select_device(data, args.name, args.os, sdk))
    except ValueError as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
