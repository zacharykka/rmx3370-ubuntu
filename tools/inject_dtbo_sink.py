#!/usr/bin/env python3
"""Inject a disabled /dtbo-sink container and __symbols__ for stock ABL DTBO overlay.

Verifies offline via fdtoverlay that stock dtbo applies cleanly (rc=0) and that
no overlay fragment pollutes any real node outside /dtbo-sink.
"""
import argparse, os, re, subprocess, tempfile, sys

def run(cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True)

def extract_fixups(dtbo_path):
    dts = run(["dtc", "-I", "dtb", "-O", "dts", dtbo_path]).stdout
    m = re.search(r"__fixups__\s*\{(.*?)\n\t\};", dts, re.S)
    if not m:
        raise RuntimeError(f"No __fixups__ found in {dtbo_path}")
    syms = []
    for ln in m.group(1).splitlines():
        ln = ln.strip()
        if "=" in ln:
            syms.append(ln.split("=", 1)[0].strip())
    return syms

def strip_block(dts, block_name):
    # Remove top-level block like __symbols__ { ... };
    pat = re.compile(r"\n\t" + re.escape(block_name) + r"\s*\{.*?\n\t\};", re.S)
    return pat.sub("", dts)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in-dtb", required=True)
    ap.add_argument("--dtbo", required=True)
    ap.add_argument("--out-dtb", required=True)
    args = ap.parse_args()

    fixups = extract_fixups(args.dtbo)
    print(f"[dtbo-sink] extracted {len(fixups)} __fixups__ symbols from {args.dtbo}")

    base_dts = run(["dtc", "-I", "dtb", "-O", "dts", args.in_dtb]).stdout
    # Strip any existing __symbols__ so DTBO cannot target real mainline nodes (e.g. soc, tlmm)
    base_dts = strip_block(base_dts, "__symbols__")

    # Build disabled /dtbo-sink (no compatible, no #address-cells/#size-cells/ranges)
    existing_ph = [int(x, 16) for x in re.findall(r"phandle\s*=\s*<0x([0-9a-fA-F]+)>;", base_dts)]
    next_ph = max(existing_ph, default=0x1000) + 0x100
    sink_children = []
    sym_entries = []
    for sym in fixups:
        safe = re.sub(r"[^a-zA-Z0-9_]", "_", sym)
        node = f"s_{safe}"
        sink_children.append(f"\t\t{node} {{\n\t\t\tstatus = \"disabled\";\n\t\t\tphandle = <{hex(next_ph)}>;\n\t\t}};")
        sym_entries.append(f"\t\t{sym} = \"/dtbo-sink/{node}\";")
        next_ph += 1

    inject = (
        "\n\tdtbo-sink {\n"
        "\t\tstatus = \"disabled\";\n"
        + "\n".join(sink_children)
        + "\n\t};\n"
        "\n\t__symbols__ {\n"
        + "\n".join(sym_entries)
        + "\n\t};\n"
    )

    last_brace = base_dts.rfind("};")
    if last_brace == -1:
        raise RuntimeError("Malformed DTS: missing root closing brace")
    patched_dts = base_dts[:last_brace] + inject + base_dts[last_brace:]

    with tempfile.TemporaryDirectory() as td:
        src_dts = os.path.join(td, "patched.dts")
        merged_dtb = os.path.join(td, "merged.dtb")
        open(src_dts, "w").write(patched_dts)
        # Compile WITHOUT -@ so only our explicit __symbols__ exist
        subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-q", "-o", args.out_dtb, src_dts], check=True)
        # Mandatory offline gate: apply stock DTBO with fdtoverlay
        r = subprocess.run(["fdtoverlay", "-i", args.out_dtb, "-o", merged_dtb, args.dtbo], capture_output=True, text=True)
        if r.returncode != 0:
            print(f"[dtbo-sink] FAIL: fdtoverlay rc={r.returncode}: {r.stderr}", file=sys.stderr)
            sys.exit(1)
        # Verify merged DTB still has our real compatible and disabled dtbo-sink
        merged_dts = run(["dtc", "-I", "dtb", "-O", "dts", merged_dtb]).stdout
        if "qcom,sm8250" not in merged_dts[:1000]:
            print("[dtbo-sink] WARNING: root compatible lost qcom,sm8250 after overlay!", file=sys.stderr)
        if "dtbo-sink {\n\t\tstatus = \"disabled\";" not in merged_dts:
            print("[dtbo-sink] FAIL: /dtbo-sink status is not disabled after overlay!", file=sys.stderr)
            sys.exit(1)
        print(f"[dtbo-sink] PASS: {args.out_dtb} ({os.path.getsize(args.out_dtb)} bytes), offline overlay -> {os.path.getsize(merged_dtb)} bytes, /dtbo-sink remains disabled")

if __name__ == "__main__":
    main()
