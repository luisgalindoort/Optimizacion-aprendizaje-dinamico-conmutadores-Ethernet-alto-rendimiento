#!/usr/bin/env python3
"""Ejecuta el barrido completo sobre la FPGA.

Recorre las trazas CSV generadas previamente, las carga en la BRAM del diseño y
guarda en un CSV las metricas calculadas a partir de los contadores hardware.
"""

import argparse
import csv
import re
import sys
from pathlib import Path

import load_trace_and_run as fpga


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_TRACE_DIR = SCRIPT_DIR.parent / "trazas_macs_posibles_metricas_hdl"
DEFAULT_OUTPUT_CSV = SCRIPT_DIR.parent / "resultados_fpga_macs_posibles.csv"
DEFAULT_BITRATE_GBPS = 51.2

TRACE_NAME_RE = re.compile(
    r"^trace_(?P<bitrate>.+?)_alpha_(?P<alpha>.+?)_"
    r"macspace_(?P<mac_space>\d+)_frames_(?P<n_frames>\d+)\.csv$"
)
TRACE_NAME_NO_BITRATE_RE = re.compile(
    r"^trace_alpha_(?P<alpha>.+?)_"
    r"macspace_(?P<mac_space>\d+)_frames_(?P<n_frames>\d+)\.csv$"
)

HDL_COMPAT_FIELDS = [
    "bitrate_gbps",
    "alpha",
    "mac_space",
    "n_frames",
    "unique_macs_cache",
    "unique_macs_sin_cache",
    "cache_hits",
    "cache_misses",
    "cache_hit_percentage",
    "mac_drop_cache_count",
    "mac_drop_cache_percentage",
    "mac_drop_sin_cache_count",
    "mac_drop_sin_cache_percentage",
    "learned_cache",
    "learned_sin_cache",
    "learned_cache_percentage",
    "learned_sin_cache_percentage",
    "write_eff_cache",
    "write_eff_sin_cache",
    "trace_csv",
]

BARRIDO_MACS_2_COMPAT_FIELDS = [
    "eff_cache",
    "eff_sin_cache",
    "cache_miss_percentage",
    "input_drop_cache",
    "cache_drop_cache",
    "queue_occ_cache",
    "unique_macs_cache_barrido_macs_2",
]

RAW_FPGA_FIELDS = [
    "trace_csv",
    "n_frames_csv",
    "n_frames_run",
    "unique_macs_trace",
    "cycles_total",
    "frames_generated",
    "frames_accepted_by_cache",
    "frames_blocked_by_cache",
    "cache_miss_outputs",
    "cache_hits_estimated",
    "cache_hit_percentage",
    "frames_forwarded_to_mac",
    "frames_dropped_by_mac_backpressure",
    "last_mac_generated_low",
    "mac_table_write_requests",
    "mac_table_write_responses",
    "mac_table_write_success",
    "mac_table_write_failed",
    "mac_table_learned_entries",
    "mac_table_learning_percentage",
    "mac_table_write_efficiency",
]

RESULT_FIELDS = (
    HDL_COMPAT_FIELDS
    + BARRIDO_MACS_2_COMPAT_FIELDS
    + [
        field
        for field in RAW_FPGA_FIELDS
        if field not in HDL_COMPAT_FIELDS + BARRIDO_MACS_2_COMPAT_FIELDS
    ]
)


# =========================================================
# Interpretacion de trazas
# =========================================================

def parse_trace_name(path: Path) -> dict[str, object]:
    match = TRACE_NAME_NO_BITRATE_RE.match(path.name)
    if match:
        alpha_text = match.group("alpha").replace("p", ".")
        return {
            "bitrate_gbps": DEFAULT_BITRATE_GBPS,
            "alpha": float(alpha_text),
            "mac_space": int(match.group("mac_space")),
            "n_frames_csv": int(match.group("n_frames")),
        }

    match = TRACE_NAME_RE.match(path.name)
    if not match:
        return {
            "bitrate_gbps": DEFAULT_BITRATE_GBPS,
            "alpha": "",
            "mac_space": "",
            "n_frames_csv": "",
        }

    bitrate_text = match.group("bitrate")
    alpha_text = match.group("alpha").replace("p", ".")

    if bitrate_text.endswith("gbps"):
        bitrate_gbps = float(bitrate_text[:-4].replace("p", "."))
    else:
        bitrate_gbps = ""

    return {
        "bitrate_gbps": bitrate_gbps,
        "alpha": float(alpha_text),
        "mac_space": int(match.group("mac_space")),
        "n_frames_csv": int(match.group("n_frames")),
    }


def collect_trace_paths(trace_dir: Path, pattern: str, limit: int) -> list[Path]:
    paths = sorted(
        (path for path in trace_dir.glob(pattern) if path.is_file()),
        key=lambda path: (
            parse_trace_name(path)["bitrate_gbps"],
            parse_trace_name(path)["alpha"],
            parse_trace_name(path)["mac_space"],
            parse_trace_name(path)["n_frames_csv"],
            path.name,
        ),
    )
    if limit > 0:
        paths = paths[:limit]
    return paths


# =========================================================
# Calculo de metricas
# =========================================================

def build_row(path: Path, trace: list[int], results: dict[str, int]) -> dict[str, object]:
    metadata = parse_trace_name(path)
    total_generated = results["frames_generated"]
    accepted = results["frames_accepted_by_cache"]
    misses = results["cache_miss_outputs"]
    hits = max(0, accepted - misses)
    cache_accesses = hits + misses
    hit_percentage = hits / cache_accesses * 100.0 if cache_accesses else 0.0
    miss_percentage = misses / cache_accesses * 100.0 if cache_accesses else 0.0
    unique_macs = len(set(trace))
    mac_hw_learned = results.get("mac_table_learned_entries", 0)
    mac_hw_responses = results.get("mac_table_write_responses", 0)
    mac_learning_percentage = mac_hw_learned / unique_macs * 100.0 if unique_macs else 0.0
    mac_drop_count = results.get("frames_dropped_by_mac_backpressure", 0)
    mac_drop_percentage = (
        mac_drop_count / total_generated * 100.0
        if total_generated
        else 0.0
    )
    input_drop_cache = (
        results.get("frames_blocked_by_cache", 0) / total_generated * 100.0
        if total_generated
        else 0.0
    )
    # Comparable efficiency: new entries learned per hardware write response.
    # Raw successful responses are kept separately because repeated writes can
    # complete without increasing the number of learned MACs.
    mac_write_efficiency = mac_hw_learned / mac_hw_responses * 100.0 if mac_hw_responses else 0.0

    row = {
        **metadata,
        "n_frames": len(trace),
        "unique_macs_cache": unique_macs,
        "unique_macs_sin_cache": "",
        "cache_hits": hits,
        "cache_misses": misses,
        "cache_hit_percentage": hit_percentage,
        "mac_drop_cache_count": mac_drop_count,
        "mac_drop_cache_percentage": mac_drop_percentage,
        "mac_drop_sin_cache_count": "",
        "mac_drop_sin_cache_percentage": "",
        "learned_cache": mac_hw_learned,
        "learned_sin_cache": "",
        "learned_cache_percentage": mac_learning_percentage,
        "learned_sin_cache_percentage": "",
        "write_eff_cache": mac_write_efficiency,
        "write_eff_sin_cache": "",
        "trace_csv": str(path),
        "eff_cache": mac_write_efficiency,
        "eff_sin_cache": "",
        "cache_miss_percentage": miss_percentage,
        "input_drop_cache": input_drop_cache,
        "cache_drop_cache": input_drop_cache,
        "queue_occ_cache": "",
        "unique_macs_cache_barrido_macs_2": unique_macs,
        "n_frames_run": len(trace),
        "unique_macs_trace": unique_macs,
        **results,
        "cache_hits_estimated": hits,
        "cache_hit_percentage": hit_percentage,
        "mac_table_learning_percentage": mac_learning_percentage,
        "mac_table_write_efficiency": mac_write_efficiency,
    }

    return {field: row.get(field, "") for field in RESULT_FIELDS}


# =========================================================
# Interfaz de consola
# =========================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Ejecuta en la FPGA las trazas CSV existentes. "
            "Este script no genera ni modifica las trazas."
        )
    )
    parser.add_argument("--uart-port", default="/dev/ttyUSB0")
    parser.add_argument("--baud-rate", type=int, default=115200)
    parser.add_argument("--xfcp-python")
    parser.add_argument(
        "--trace-dir",
        type=Path,
        default=DEFAULT_TRACE_DIR,
        help="Directorio que ya contiene las trazas CSV.",
    )
    parser.add_argument(
        "--pattern",
        default="trace_*.csv",
        help="Patron usado para seleccionar trazas existentes.",
    )
    parser.add_argument("--output-csv", type=Path, default=DEFAULT_OUTPUT_CSV)
    parser.add_argument("--n-frames", type=int, default=0)
    parser.add_argument("--frame-gap-cycles", type=int, default=0)
    parser.add_argument(
        "--ready-high-cycles",
        type=int,
        default=1,
        help="Compatibilidad: ignorado en la version MAC_HDL completa.",
    )
    parser.add_argument(
        "--ready-low-cycles",
        type=int,
        default=0,
        help="Compatibilidad: ignorado en la version MAC_HDL completa.",
    )
    parser.add_argument("--post-run-wait-ms", type=float, default=50.0)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--no-verify", action="store_true")
    args = parser.parse_args()

    trace_paths = collect_trace_paths(args.trace_dir, args.pattern, args.limit)
    if not trace_paths:
        raise SystemExit(f"No se han encontrado trazas en {args.trace_dir}")

    fpga.add_xfcp_path(args.xfcp_python)

    import xfcp.interface

    interface = xfcp.interface.SerialInterface(args.uart_port, args.baud_rate)
    node = interface.enumerate()

    signature = fpga.read_reg(node, fpga.REG_CONTROL)
    print(f"Firma register 0x00: 0x{signature:08x}")
    if signature != 0x54464701:
        raise SystemExit("La firma no coincide con cache_core.v. Revisa UART/bitstream.")

    args.output_csv.parent.mkdir(parents=True, exist_ok=True)
    with args.output_csv.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=RESULT_FIELDS)
        writer.writeheader()

        for index, trace_path in enumerate(trace_paths, start=1):
            print(f"[{index}/{len(trace_paths)}] Ejecutando {trace_path.name}")

            trace = fpga.read_trace_csv(trace_path, args.n_frames)
            fpga.load_trace(node, trace, verify=not args.no_verify)

            results = fpga.run_test(
                node,
                n_frames=len(trace),
                frame_gap_cycles=args.frame_gap_cycles,
                ready_high=args.ready_high_cycles,
                ready_low=args.ready_low_cycles,
                post_run_wait_ms=args.post_run_wait_ms,
            )

            row = build_row(trace_path, trace, results)
            writer.writerow(row)
            f.flush()

            print(
                "  "
                f"frames={row['frames_generated']} "
                f"misses={row['cache_miss_outputs']} "
                f"hits={row['cache_hits_estimated']} "
                f"hit%={float(row['cache_hit_percentage']):.2f}"
            )

    print(f"Resultados guardados en {args.output_csv}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Barrido interrumpido por el usuario.", file=sys.stderr)
        raise
