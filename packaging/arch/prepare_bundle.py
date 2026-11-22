"""Check a trusted, locally built bundle; normalize only its staging copy."""
import os
import pathlib
import re
import subprocess
import sys

# Use the host's loader defaults and stable readelf labels.
tool_env = {'PATH': os.environ.get('PATH', os.defpath), 'LC_ALL': 'C'}


def system_loader(runner, header):
    match = re.search(r'\[Requesting program interpreter: ([^\]\n]+)\]', header)
    loader = pathlib.Path(match[1]) if match else None
    system = pathlib.Path('/lib64/ld-linux-x86-64.so.2')
    if (loader is None or not loader.is_absolute() or not loader.is_file()
            or loader.resolve() != system.resolve()):
        raise SystemExit(f'Expected the system glibc interpreter in PT_INTERP: {runner}')
    return loader


def check_closure(path, needed, loader):
    if not needed:
        print('statically linked (no DT_NEEDED)\n')
        return

    error = f'Unresolved ELF closure: {path}'
    try:
        probe = subprocess.run([loader, '--list', path], env=tool_env,
                               capture_output=True, text=True)
    except OSError as exc:
        raise SystemExit(f'{error}\nCould not run {loader}: {exc}') from exc
    diagnostics = (probe.stderr + probe.stdout).strip()
    if probe.returncode:
        raise SystemExit(f'{error}\nLoader exited with status {probe.returncode}\n{diagnostics}')
    if not probe.stdout.strip():
        raise SystemExit(f'{error}\nEmpty loader output\n{diagnostics}')
    if re.search(r' => not found[ \t]*$', probe.stdout, re.M):
        raise SystemExit(f'{error}\n{diagnostics}')

    # Require a direct dependency so the loader's own entry or vDSO alone cannot pass.
    resolutions = re.findall(
        r'^[ \t]*(?:(.+?) => )?(/.+) \(0x[0-9a-fA-F]+\)[ \t]*$', probe.stdout, re.M)
    if not any((name in needed or resolved in needed or pathlib.Path(resolved).name in needed)
               and pathlib.Path(resolved).is_file() for name, resolved in resolutions):
        raise SystemExit(f'{error}\nNo dependency resolutions in loader output\n{diagnostics}')
    if probe.stderr:
        sys.stderr.write(probe.stderr)
    print(probe.stdout)


bundle = pathlib.Path(sys.argv[1]).resolve(strict=True)
runner = bundle / 'fqapp'
for relative in ('fqapp', 'lib/libfqapi_core.so', 'lib/libflutter_linux_gtk.so',
                 'lib/libapp.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin'):
    if not (bundle / relative).is_file():
        raise SystemExit(f'Missing bundle member: {relative}')

elfs = []
loader = None
for path in bundle.rglob('*'):
    if path.is_symlink():
        raise SystemExit(f'Bundle symlink requires review: {path}')
    if not path.is_file():
        continue
    with path.open('rb') as stream:
        if stream.read(4) != b'\x7fELF':
            continue
    if b'/home/' in path.read_bytes():
        print(f'DIAGNOSTIC PATH LIMITATION: {path.relative_to(bundle)} contains /home/ strings')
    header = subprocess.check_output(['readelf', '-hlW', path], env=tool_env, text=True)
    if 'Advanced Micro Devices X86-64' not in header:
        raise SystemExit(f'Not an x86_64 ELF: {path}')
    rpath = '$ORIGIN/lib' if path == runner else '$ORIGIN'
    if path.name == 'libdartjni.so':
        raise SystemExit('Unexpected Java plugin: build in an environment without a JDK')
    if re.search(r'^[ \t]+DYNAMIC[ \t]', header, re.M):
        subprocess.run(['patchelf', '--set-rpath', rpath, path], env=tool_env, check=True)
    dynamic = subprocess.check_output(['readelf', '-dW', path], env=tool_env, text=True)
    if '/tmp/' in dynamic or '/home/' in dynamic:
        raise SystemExit(f'Build paths in dynamic section: {path}\n{dynamic}')
    needed = re.findall(r'\(NEEDED\).*\[([^\]]+)\]', dynamic)
    if path == runner:
        loader = system_loader(runner, header)
        if ('libgcc_s.so.1' not in needed or 'libflutter_linux_gtk.so' not in needed or
                needed.index('libgcc_s.so.1') > needed.index('libflutter_linux_gtk.so')):
            raise SystemExit('System unwinder must precede Flutter in DT_NEEDED')
    elfs.append((path, dynamic, needed))

if loader is None:
    raise SystemExit(f'Not an ELF runner: {runner}')

# Resolve only after every bundled dependency has its final RUNPATH.
for path, dynamic, needed in elfs:
    print(path.relative_to(bundle))
    for line in dynamic.splitlines():
        if 'NEEDED' in line or 'RUNPATH' in line:
            print(line)
    check_closure(path, needed, loader)
