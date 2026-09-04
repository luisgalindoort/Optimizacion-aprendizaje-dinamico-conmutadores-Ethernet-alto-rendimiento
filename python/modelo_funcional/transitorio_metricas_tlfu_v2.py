from __future__ import annotations

"""
Este script ejecuta los tres modelos funcionales de python realizando un barrido temporal para estudiar el transitorio
y  guarda  las cuatro metricas utilizadas en la memoria.
"""

import argparse
import csv
import logging
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

from baseline_sim import run_baseline_no_cache
from pipeline_sim import (
    run_parallel_cache_pipeline,
    run_parallel_cms_plus_cache_pipeline,
)

# Evita que la tabla hash reutilizada ensucie la consola con fallos de insercion.
logging.getLogger("hash.CuckooHashTable").setLevel(logging.CRITICAL)

#Parametros de simulacion
N_FRAMES_SWEEP = [500, 1000, 1500, 2000, 3000, 4000, 5000, 7500, 10000, 15000, 20000, 35000]
MAC_SPACES = [1000, 5000, 10000]
BITRATES_BPS = [2_000_000_000, 51_200_000_000]

ALPHA = 0.7
QUEUE_DEPTH = 64
HASH_DEPTH = 4096
PACKET_SIZE_BYTES = 64
CLK_FREQ_HZ = 100_000_000
BASE_SEED = 12345
CMS_THRESHOLD = 2
CMS_FILL_THRESHOLD = 0.90

OUTPUT_CSV = "transitorio_metricas_tlfu_v2.csv"
OUTPUT_DIR = "graficas_transitorio_metricas_tlfu_v2"

MODELS = ["Base", "Con cache", "CMS+cache"]

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


# Convierte un str en entero
def parse_int_list(text: str) -> list[int]:
    return [int(float(value.strip())) for value in text.split(",") if value.strip()]


#Convierte a porcentaje
def pct(num: float, den: float) -> float:
    return (num / den * 100.0) if den else 0.0


#Ajusta velocidad de enlace
def format_bitrate(bitrate_bps: int) -> str:
    value = bitrate_bps / 1e9
    return f"{value:g} Gbps"


#Calcula el porcentaje de tramas filtradas por la cache.
def cache_filtering(stats) -> float:
    accesses = stats.cache_hits + stats.cache_misses
    return pct(stats.cache_hits, accesses)


#Construye una fila del CSV con las cuatro metricas de la memoria.
def metric_row(
    *,
    bitrate_bps: int,
    mac_space: int,
    n_frames: int,
    model: str,
    filtering: float | None,
    dropped: int,
    learned: int,
    unique_macs: int,
    write_efficiency: float,
) -> dict[str, float | int | str]:
    return {
        "bitrate_gbps": bitrate_bps / 1e9,
        "alpha": ALPHA,
        "mac_space": mac_space,
        "n_frames": n_frames,
        "modelo": model,
        "filtrado_pct": "" if filtering is None else filtering,
        "descartes_mac_pct": pct(dropped, n_frames),
        "aprendizaje_pct": pct(learned, unique_macs),
        "eficiencia_pct": write_efficiency * 100.0,
    }


# Ejecuta los tres modelos para un punto concreto del transitorio.
def run_case(bitrate_bps: int, mac_space: int, n_frames: int, seed: int) -> list[dict]:
    common = {
        "n_frames": n_frames,
        "fifo_cap": QUEUE_DEPTH,
        "mac_space": mac_space,
        "alpha": ALPHA,
        "bitrate_bps": bitrate_bps,
        "packet_size_bytes": PACKET_SIZE_BYTES,
        "clk_freq_hz": CLK_FREQ_HZ,
        "mac_cuckoo_table_count": 4,
        "seed": seed,
    }

    
    base = run_baseline_no_cache(**common)
    cache = run_parallel_cache_pipeline(
        **common,
        cache_fifo_cap=QUEUE_DEPTH,
        recent_cache_size=HASH_DEPTH,
        cache_cuckoo_table_count=4,
    )
    tlfu = run_parallel_cms_plus_cache_pipeline(
        **common,
        cache_fifo_cap=QUEUE_DEPTH,
        recent_cache_size=HASH_DEPTH,
        cache_cuckoo_table_count=4,
        cms_threshold=CMS_THRESHOLD,
        cms_cache_admission_fill_threshold=CMS_FILL_THRESHOLD,
    )

    return [
        metric_row(
            bitrate_bps=bitrate_bps,
            mac_space=mac_space,
            n_frames=n_frames,
            model="Base",
            filtering=None,
            dropped=base.dropped_fifo,
            learned=base.unique_src_written,
            unique_macs=base.unique_src_seen,
            write_efficiency=base.write_efficiency,
        ),
        metric_row(
            bitrate_bps=bitrate_bps,
            mac_space=mac_space,
            n_frames=n_frames,
            model="Con cache",
            filtering=cache_filtering(cache),
            dropped=cache.mac_dropped_fifo,
            learned=cache.unique_src_written,
            unique_macs=cache.unique_src_seen,
            write_efficiency=cache.write_efficiency,
        ),
        metric_row(
            bitrate_bps=bitrate_bps,
            mac_space=mac_space,
            n_frames=n_frames,
            model="CMS+cache",
            filtering=cache_filtering(tlfu),
            dropped=tlfu.mac_dropped_fifo,
            learned=tlfu.unique_src_written,
            unique_macs=tlfu.unique_src_seen,
            write_efficiency=tlfu.write_efficiency,
        ),
    ]


# Guarda todas las filas del transitorio en un fichero CSV.
def write_results(rows: list[dict], csv_path: Path) -> None:
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


# Lee el CSV ya generado para  dibujar las graficas.
def read_results(csv_path: Path) -> list[dict]:
    with csv_path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


#Convierte str a float.
def value(row: dict, key: str) -> float:
    text = row[key]
    return float(text) if text != "" else float("nan")


# Genera una figura para una de las metricas estudiadas.
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

        ax.set_title(format_bitrate(int(bitrate * 1e9)))
        ax.set_xlabel("Numero de tramas generadas")
        ax.grid(True, linestyle="--", alpha=0.35)
        if j == 0:
            ax.set_ylabel(METRICS[metric])

    handles, labels = axes[0][0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=3)
    fig.tight_layout(rect=(0, 0, 1, 0.82))

    output_dir.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_dir / f"transitorio_{metric}.png", dpi=300, bbox_inches="tight")
    plt.close(fig)


# Genera las cuatro graficas principales del transitorio.
def plot_all(rows: list[dict], output_dir: Path) -> None:
    for metric in METRICS:
        plot_metric(rows, metric, output_dir)


#Funcion principal lee argumentos, ejecuta el transitorio y guarda resultados.
def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--n-frames", default=",".join(map(str, N_FRAMES_SWEEP)))
    parser.add_argument("--mac-spaces", default=",".join(map(str, MAC_SPACES)))
    parser.add_argument("--bitrates-bps", default=",".join(map(str, BITRATES_BPS)))
    parser.add_argument("--seed", type=int, default=BASE_SEED)
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
                rows.extend(run_case(bitrate_bps, mac_space, n_frames, args.seed))

    write_results(rows, csv_path)
    plot_all(rows, output_dir)
    print(f"CSV guardado en {csv_path}")
    print(f"Graficas guardadas en {output_dir}")


if __name__ == "__main__":
    main()
