#!/usr/bin/env python3
"""Carga una traza en la FPGA y ejecuta una prueba.

El PC escribe la traza en la BRAM del diseño mediante registros AXI-Lite
accesibles por UART/XFCP. Tras iniciar la prueba, el script espera a que el
hardware termine y lee los contadores principales.
"""

import argparse
import csv
import sys
import time
from pathlib import Path

import serial


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_XFCP_PATHS = [
    SCRIPT_DIR.parent / "lib" / "xfcp" / "python",
    Path.home() / "xfcp_python",
]

if len(SCRIPT_DIR.parents) > 2:
    DEFAULT_XFCP_PATHS.insert(
        0,
        SCRIPT_DIR.parents[2] / "code" / "hardware" / "lib" / "xfcp" / "python",
    )


REG_CONTROL = 0x00
REG_STATUS = 0x04
REG_N_FRAMES_TARGET = 0x10
REG_TRACE_COUNT = 0x14
REG_FRAME_GAP_CYCLES = 0x18
REG_MAC_READY_HIGH_CYCLES = 0x1C
REG_MAC_READY_LOW_CYCLES = 0x20

REG_CYCLES_TOTAL = 0x40
REG_FRAMES_GENERATED = 0x44
REG_FRAMES_ACCEPTED_BY_CACHE = 0x48
REG_FRAMES_BLOCKED_BY_CACHE = 0x4C
REG_CACHE_MISS_OUTPUTS = 0x50
REG_FRAMES_FORWARDED_TO_MAC = 0x54
REG_FRAMES_DROPPED_BY_MAC = 0x58
REG_LAST_MAC_GENERATED_LOW = 0x5C
REG_MAC_TABLE_WRITE_REQUESTS = 0x80
REG_MAC_TABLE_WRITE_RESPONSES = 0x84
REG_MAC_TABLE_WRITE_SUCCESS = 0x88
REG_MAC_TABLE_WRITE_FAILED = 0x8C
REG_MAC_TABLE_LEARNED_ENTRIES = 0x90

REG_TRACE_DEPTH = 0x60
REG_TRACE_WRITE_ADDR = 0x68
REG_TRACE_WRITE_MAC_LOW = 0x6C
REG_TRACE_WRITE_MAC_HIGH_COMMIT = 0x70
REG_TRACE_READ_ADDR = 0x74
REG_TRACE_READ_MAC_LOW = 0x78
REG_TRACE_READ_MAC_HIGH = 0x7C


# =========================================================
# Acceso a XFCP y registros AXI-Lite
# =========================================================

def add_xfcp_path(path_arg: str | None) -> None:
    candidates = []

    if path_arg:
        candidates.append(Path(path_arg))

    candidates.extend(DEFAULT_XFCP_PATHS)

    for candidate in candidates:
        if (candidate / "xfcp").exists():
            sys.path.insert(0, str(candidate))
            return

    raise SystemExit(
        "No se ha encontrado la libreria XFCP. Usa --xfcp-python o copia "
        "code/hardware/lib/xfcp/python al servidor."
    )


def write_reg(node, address: int, value: int) -> None:
    node.write(address, int(value & 0xFFFFFFFF).to_bytes(4, "little"))


def read_reg(node, address: int) -> int:
    return int.from_bytes(node.read(address, 4), "little")


def read_trace_entry(node, index: int) -> int:
    write_reg(node, REG_TRACE_READ_ADDR, index)

    time.sleep(0.005)
    _ = read_reg(node, REG_TRACE_READ_MAC_LOW)
    time.sleep(0.001)
    mac_low = read_reg(node, REG_TRACE_READ_MAC_LOW)
    mac_high = read_reg(node, REG_TRACE_READ_MAC_HIGH) & 0xFFFF
    return (mac_high << 32) | mac_low


# =========================================================
# Carga de trazas en BRAM
# =========================================================

def write_trace_entry(node, index: int, mac: int) -> None:
    write_reg(node, REG_TRACE_WRITE_ADDR, index)
    write_reg(node, REG_TRACE_WRITE_MAC_LOW, mac & 0xFFFFFFFF)
    write_reg(node, REG_TRACE_WRITE_MAC_HIGH_COMMIT, (mac >> 32) & 0xFFFF)


def clear_test_state(node, wait_s: float = 0.05) -> None:
    write_reg(node, REG_CONTROL, 0x2)
    time.sleep(wait_s)

    status = read_reg(node, REG_STATUS)
    if status & 0x1:
        raise SystemExit(
            "No se ha podido limpiar el test: el core sigue en running=1."
        )


def read_trace_csv(path: Path, n_frames: int) -> list[int]:
    trace = []

    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            raise SystemExit(f"El CSV de traza esta vacio: {path}")

        for row in reader:
            if "mac_hex" in row and row["mac_hex"]:
                mac = int(row["mac_hex"], 16)
            elif "mac_low" in row and row["mac_low"]:
                mac = int(row["mac_low"], 0)
            else:
                raise SystemExit(
                    "El CSV debe contener una columna 'mac_hex' o 'mac_low'."
                )

            trace.append(mac & ((1 << 48) - 1))

            if n_frames > 0 and len(trace) >= n_frames:
                break

    if not trace:
        raise SystemExit(f"No se ha leido ninguna trama desde: {path}")

    return trace


def load_trace(node, trace: list[int], verify: bool) -> None:
    clear_test_state(node)

    trace_depth = read_reg(node, REG_TRACE_DEPTH)
    if len(trace) > trace_depth:
        raise SystemExit(
            f"La traza tiene {len(trace)} tramas, pero la BRAM solo admite {trace_depth}."
        )

    write_reg(node, REG_TRACE_COUNT, 0)
    write_reg(node, REG_TRACE_WRITE_ADDR, 0)

    for i, mac in enumerate(trace):
        write_reg(node, REG_TRACE_WRITE_MAC_LOW, mac & 0xFFFFFFFF)
        write_reg(node, REG_TRACE_WRITE_MAC_HIGH_COMMIT, (mac >> 32) & 0xFFFF)

        if (i + 1) % 1000 == 0:
            print(f"Cargadas {i + 1}/{len(trace)} tramas")

    write_reg(node, REG_TRACE_COUNT, len(trace))

    if verify and trace:
        for index in sorted(set([0, len(trace) // 2, len(trace) - 1])):
            expected_mac = trace[index]
            read_mac = read_trace_entry(node, index)

            for _ in range(3):
                if read_mac == expected_mac:
                    break
                time.sleep(0.002)
                read_mac = read_trace_entry(node, index)

            if read_mac != expected_mac:
                write_trace_entry(node, index, expected_mac)
                time.sleep(0.002)
                read_mac = read_trace_entry(node, index)

            if read_mac != trace[index]:
                delta = read_mac ^ trace[index]
                raise SystemExit(
                    f"Error verificando traza en {index}: "
                    f"leido 0x{read_mac:012x}, esperado 0x{trace[index]:012x}, "
                    f"xor=0x{delta:012x}"
                )

        write_reg(node, REG_TRACE_WRITE_ADDR, len(trace))


# =========================================================
# Ejecucion de la prueba y lectura de contadores
# =========================================================

def run_test(
    node,
    n_frames: int,
    frame_gap_cycles: int,
    ready_high: int,
    ready_low: int,
    post_run_wait_ms: float = 50.0,
) -> dict[str, int]:
    # ready_high/ready_low se conservan solo para no romper comandos antiguos.
    # En la version MAC_HDL completa el backpressure real lo produce la FIFO
    # MAC interna y ya no se fuerza desde el script.
    _ = (ready_high, ready_low)
    write_reg(node, REG_N_FRAMES_TARGET, n_frames)
    write_reg(node, REG_FRAME_GAP_CYCLES, frame_gap_cycles)

    write_reg(node, REG_CONTROL, 0x1)

    while True:
        status = read_reg(node, REG_STATUS)
        running = status & 0x1
        done = (status >> 1) & 0x1

        if done and not running:
            break

        time.sleep(0.01)

    if post_run_wait_ms > 0:
        time.sleep(post_run_wait_ms / 1000.0)

    return {
        "cycles_total": read_reg(node, REG_CYCLES_TOTAL),
        "frames_generated": read_reg(node, REG_FRAMES_GENERATED),
        "frames_accepted_by_cache": read_reg(node, REG_FRAMES_ACCEPTED_BY_CACHE),
        "frames_blocked_by_cache": read_reg(node, REG_FRAMES_BLOCKED_BY_CACHE),
        "cache_miss_outputs": read_reg(node, REG_CACHE_MISS_OUTPUTS),
        "frames_forwarded_to_mac": read_reg(node, REG_FRAMES_FORWARDED_TO_MAC),
        "frames_dropped_by_mac_backpressure": read_reg(node, REG_FRAMES_DROPPED_BY_MAC),
        "last_mac_generated_low": read_reg(node, REG_LAST_MAC_GENERATED_LOW),
        "mac_table_write_requests": read_reg(node, REG_MAC_TABLE_WRITE_REQUESTS),
        "mac_table_write_responses": read_reg(node, REG_MAC_TABLE_WRITE_RESPONSES),
        "mac_table_write_success": read_reg(node, REG_MAC_TABLE_WRITE_SUCCESS),
        "mac_table_write_failed": read_reg(node, REG_MAC_TABLE_WRITE_FAILED),
        "mac_table_learned_entries": read_reg(node, REG_MAC_TABLE_LEARNED_ENTRIES),
    }


# =========================================================
# Interfaz de consola
# =========================================================

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--uart-port", default="/dev/ttyUSB0")
    parser.add_argument("--baud-rate", type=int, default=115200)
    parser.add_argument("--xfcp-python")
    parser.add_argument("--n-frames", type=int, default=30000)
    parser.add_argument("--frame-gap-cycles", type=int, default=1)
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
    parser.add_argument("--trace-in", required=True)
    parser.add_argument("--no-verify", action="store_true")
    parser.add_argument("--load-only", action="store_true")
    args = parser.parse_args()

    add_xfcp_path(args.xfcp_python)

    import xfcp.interface

    trace = read_trace_csv(Path(args.trace_in), args.n_frames)
    args.n_frames = len(trace)
    print(f"Traza leida desde {args.trace_in}: {len(trace)} tramas")

    interface = xfcp.interface.SerialInterface(args.uart_port, args.baud_rate)
    node = interface.enumerate()

    signature = read_reg(node, REG_CONTROL)
    print(f"Firma register 0x00: 0x{signature:08x}")
    if signature != 0x54464701:
        raise SystemExit("La firma no coincide con cache_core.v. Revisa UART/bitstream.")

    load_trace(node, trace, verify=not args.no_verify)
    print("Traza cargada correctamente en la BRAM.")

    if args.load_only:
        return

    results = run_test(
        node,
        n_frames=args.n_frames,
        frame_gap_cycles=args.frame_gap_cycles,
        ready_high=args.ready_high_cycles,
        ready_low=args.ready_low_cycles,
        post_run_wait_ms=args.post_run_wait_ms,
    )

    print("Resultados:")
    for key, value in results.items():
        print(f"{key}: {value}")


if __name__ == "__main__":
    main()
