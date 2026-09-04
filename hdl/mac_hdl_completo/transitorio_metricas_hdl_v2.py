"""Transitorio HDL simplificado.

Ejecuta el modelo con cache y el modelo base variando el numero de tramas.
El CSV final guarda solo las cuatro metricas usadas en la memoria.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


# Parametros del transitorio.
N_FRAMES_SWEEP = [500, 1000, 1500, 2000, 3000, 4000, 5000, 7500, 10000, 15000, 20000, 35000]
MAC_SPACES = [1000, 5000, 10000]
BITRATES_BPS = [2_000_000_000, 51_200_000_000]
ALPHA = 0.7

QUEUE_DEPTH = 64
HASH_DEPTH = 4096
TABLE_COUNT = 4
PACKET_SIZE_BYTES = 64
CLK_FREQ_HZ = 100_000_000

RUNNER_CACHE = "runner_v2.py"
RUNNER_BASE = "runner_sin_cache_v2.py"
OUTPUT_CSV = "transitorio_metricas_hdl_v2.csv"
OUTPUT_DIR = "graficas_transitorio_metricas_hdl_v2"

MODELS = ["Base", "Con cache"]

METRICS = {
    "filtrado_pct": "Filtrado por cache (%)",
    "descartes_mac_pct": "Descartes en MAC (%)",
    "aprendizaje_pct": "Direcciones MAC distintas aprendidas (%)",
    "eficiencia_pct": "Eficiencia de escritura (%)",
}

plt.rcParams.update(
    {
        "font.size": 16,
        "axes.labelsize": 18,
        "axes.titlesize": 20,
        "legend.fontsize": 14,
        "xtick.labelsize": 15,
        "ytick.labelsize": 15,
        "lines.linewidth": 2.4,
        "lines.markersize": 7.0,
    }
)


#Convierte un srt a int
def parse_int_list(text: str) -> list[int]:
    return [int(float(value.strip())) for value in text.split(",") if value.strip()]


#Calcula porcentaje
def pct(num: float, den: float) -> float:
    return (num / den * 100.0) if den else 0.0



def format_bitrate(bitrate_bps: int) -> str:
    return f"{bitrate_bps / 1e9:g} Gbps"


#Ejecuta el runner para un punto
def run_simulation(
    runner_name: str,
    script_dir: Path,
    *,
    bitrate_bps: int,
    mac_space: int,
    n_frames: int,
) -> str:
    env = os.environ.copy()
    env.update(
        {
            "HASH_DEPTH": str(HASH_DEPTH),
            "TABLE_COUNT": str(TABLE_COUNT),
            "MAC_HASH_DEPTH": str(16_384),
            "MAC_TABLE_COUNT": str(TABLE_COUNT),
            "MAC_LOOP_COUNT": str(5),
            "N_FRAMES": str(n_frames),
            "L_QUEUE": str(QUEUE_DEPTH),
            "MAC_SPACE": str(mac_space),
            "ALPHA": str(ALPHA),
            "BITRATE_BPS": str(bitrate_bps),
            "PACKET_SIZE_BYTES": str(PACKET_SIZE_BYTES),
            "CLK_FREQ_HZ": str(CLK_FREQ_HZ),
        }
    )

    result = subprocess.run(
        [sys.executable, runner_name],
        cwd=script_dir,
        env=env,
        capture_output=True,
        text=True,
    )

    output = result.stdout + result.stderr
    if result.returncode != 0 or re.search(r"\bFAIL=[1-9][0-9]*\b", output):
        print(output)
        raise RuntimeError(f"Error ejecutando {runner_name}")

    return output


# Extrae un float de la salida 
def extract_float(output: str, pattern: str, metric_name: str) -> float:
    match = re.search(pattern, output)
    if not match:
        print(output)
        raise ValueError(f"No se encontro la metrica: {metric_name}")
    return float(match.group(1))


# Extrae un entero de la salida 
def extract_int(output: str, pattern: str, metric_name: str) -> int:
    return int(round(extract_float(output, pattern, metric_name)))


#Lee la metrica de aprendizaje de los tests HDL.
def extract_learned_ratio(output: str) -> tuple[int, int]:
    match = re.search(
        r"MACs aprendidas en tabla MAC HDL:\s*([0-9]+)\s*/\s*([0-9]+)",
        output,
    )
    if not match:
        match = re.search(
            r"MACs aprendidas o ya existentes:\s*([0-9]+)\s*/\s*([0-9]+)",
            output,
        )
    if not match:
        print(output)
        raise ValueError("No se encontro la metrica de aprendizaje")

    return int(match.group(1)), int(match.group(2))


#Convierte la salida del modelo con cache en las cuatro metricas finales.
def parse_cache_output(output: str, n_frames: int) -> dict[str, float]:
    hits = extract_int(output, r"Cache hits:\s*([0-9.]+)", "Cache hits")
    misses = extract_int(output, r"Cache misses:\s*([0-9.]+)", "Cache misses")
    dropped = extract_int(
        output,
        r"Misses que no produjeron salida HDL:\s*([0-9.]+)",
        "Descartes MAC",
    )
    learned, unique = extract_learned_ratio(output)
    efficiency = extract_float(
        output,
        r"Eficiencia de escritura MAC HDL:\s*([0-9.]+)%",
        "Eficiencia de escritura",
    )

    return {
        "filtrado_pct": pct(hits, hits + misses),
        "descartes_mac_pct": pct(dropped, n_frames),
        "aprendizaje_pct": pct(learned, unique),
        "eficiencia_pct": efficiency,
    }


#Convierte la salida del modelo base en las cuatro metricas finales.
def parse_base_output(output: str, n_frames: int) -> dict[str, float | str]:
    dropped = extract_int(
        output,
        r"Frames perdidos por congesti.n en entrada:\s*([0-9.]+)",
        "Descartes MAC",
    )
    learned, unique = extract_learned_ratio(output)
    efficiency = extract_float(
        output,
        r"Eficiencia de escritura(?: MAC HDL| en MAC):\s*([0-9.]+)%",
        "Eficiencia de escritura",
    )

    return {
        "filtrado_pct": "",
        "descartes_mac_pct": pct(dropped, n_frames),
        "aprendizaje_pct": pct(learned, unique),
        "eficiencia_pct": efficiency,
    }



def metric_row(
    *,
    bitrate_bps: int,
    mac_space: int,
    n_frames: int,
    model: str,
    metrics: dict,
) -> dict:
    return {
        "bitrate_gbps": bitrate_bps / 1e9,
        "alpha": ALPHA,
        "mac_space": mac_space,
        "n_frames": n_frames,
        "modelo": model,
        **metrics,
    }


#Ejecuta modelo con cache y modelo base para un punto concreto del transitorio.
def run_case(
    script_dir: Path,
    *,
    bitrate_bps: int,
    mac_space: int,
    n_frames: int,
) -> list[dict]:
    cache_output = run_simulation(
        RUNNER_CACHE,
        script_dir,
        bitrate_bps=bitrate_bps,
        mac_space=mac_space,
        n_frames=n_frames,
    )
    base_output = run_simulation(
        RUNNER_BASE,
        script_dir,
        bitrate_bps=bitrate_bps,
        mac_space=mac_space,
        n_frames=n_frames,
    )

    return [
        metric_row(
            bitrate_bps=bitrate_bps,
            mac_space=mac_space,
            n_frames=n_frames,
            model="Base",
            metrics=parse_base_output(base_output, n_frames),
        ),
        metric_row(
            bitrate_bps=bitrate_bps,
            mac_space=mac_space,
            n_frames=n_frames,
            model="Con cache",
            metrics=parse_cache_output(cache_output, n_frames),
        ),
    ]


#Guarda los resultados en CSV.
def write_results(rows: list[dict], csv_path: Path) -> None:
    with csv_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


#Lee el CSV ya generado para volver a dibujar las graficas.
def read_results(csv_path: Path) -> list[dict]:
    with csv_path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


#Convierte un campo del CSV a numero.
def value(row: dict, key: str) -> float:
    text = row[key]
    return float(text) if text != "" else float("nan")


#Plotea metricas
def plot_metric(rows: list[dict], metric: str, output_dir: Path) -> None:
    bitrates = sorted({float(row["bitrate_gbps"]) for row in rows})
    mac_spaces = sorted({int(row["mac_space"]) for row in rows})

    fig, axes = plt.subplots(
        1,
        len(bitrates),
        figsize=(15, 5),
        sharex=True,
        sharey=True,
        squeeze=False,
    )

    for j, bitrate in enumerate(bitrates):
        ax = axes[0][j]
        for mac_space in mac_spaces:
            for model in MODELS:
                if metric == "filtrado_pct" and model == "Base":
                    continue

                subset = [
                    row
                    for row in rows
                    if float(row["bitrate_gbps"]) == bitrate
                    and int(row["mac_space"]) == mac_space
                    and row["modelo"] == model
                ]
                subset.sort(key=lambda row: int(row["n_frames"]))
                if not subset:
                    continue

                style = "--" if model == "Base" else "-"
                ax.plot(
                    [int(row["n_frames"]) for row in subset],
                    [value(row, metric) for row in subset],
                    linestyle=style,
                    marker="o",
                    label=f"{model} - MAC_SPACE={mac_space}",
                )

        ax.set_title(f"{bitrate:g} Gbps")
        ax.set_xlabel("Numero de tramas generadas")
        ax.grid(True, linestyle="--", alpha=0.35)
        if j == 0:
            ax.set_ylabel(METRICS[metric])

    handles, labels = axes[0][0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=3)
    fig.tight_layout(rect=(0, 0, 1, 0.82))

    output_dir.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_dir / f"transitorio_hdl_{metric}.png", dpi=300, bbox_inches="tight")
    plt.close(fig)


#Genera las cuatro graficas principales.
def plot_all(rows: list[dict], output_dir: Path) -> None:
    for metric in METRICS:
        plot_metric(rows, metric, output_dir)


##Funcion principal del transitorio,lee argumentos, ejecuta el barrido y guarda resultados.
def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--n-frames", default=",".join(map(str, N_FRAMES_SWEEP)))
    parser.add_argument("--mac-spaces", default=",".join(map(str, MAC_SPACES)))
    parser.add_argument("--bitrates-bps", default=",".join(map(str, BITRATES_BPS)))
    parser.add_argument("--output-csv", default=OUTPUT_CSV)
    parser.add_argument("--output-dir", default=OUTPUT_DIR)
    parser.add_argument("--plot-only", action="store_true")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    csv_path = script_dir / args.output_csv
    output_dir = script_dir / args.output_dir

    if args.plot_only:
        rows = read_results(csv_path)
        plot_all(rows, output_dir)
        print(f"Graficas generadas desde {csv_path}")
        return

    rows: list[dict] = []
    for bitrate_bps in parse_int_list(args.bitrates_bps):
        for mac_space in parse_int_list(args.mac_spaces):
            for n_frames in parse_int_list(args.n_frames):
                print(
                    f"BITRATE={format_bitrate(bitrate_bps)} | "
                    f"MAC_SPACE={mac_space} | N_FRAMES={n_frames}"
                )
                rows.extend(
                    run_case(
                        script_dir,
                        bitrate_bps=bitrate_bps,
                        mac_space=mac_space,
                        n_frames=n_frames,
                    )
                )

    write_results(rows, csv_path)
    plot_all(rows, output_dir)
    print(f"CSV guardado en {csv_path}")
    print(f"Graficas guardadas en {output_dir}")


if __name__ == "__main__":
    main()
