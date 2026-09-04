import os
from pathlib import Path

from cocotb_tools.runner import get_runner


# Ejecuta la simulacion HDL del modelo base usando las variables de entorno.
def main() -> None:
    proj_path = Path(__file__).resolve().parent

    sources = [
        proj_path / "modulo_hdl_sin_cache.v",
        proj_path / "hash_table.v",
        proj_path / "lfsr.v",
        proj_path / "priority_encoder.v",
        proj_path / "switch_simple_fifo.v",
    ]

    runner = get_runner("icarus")

    runner.build(
        sources=sources,
        hdl_toplevel="modulo_hdl_sin_cache",
        parameters={
            "MAC_HASH_DEPTH": int(os.getenv("MAC_HASH_DEPTH", "16384")),
            "MAC_TABLE_COUNT": int(os.getenv("MAC_TABLE_COUNT", "4")),
            "MAC_LOOP_COUNT": int(os.getenv("MAC_LOOP_COUNT", "5")),
        },
        always=True,
        waves=False,
        timescale=("1ns", "1ps"),
    )

    runner.test(
        hdl_toplevel="modulo_hdl_sin_cache",
        test_module="test_completo_sin_cache",
        waves=False,
        extra_env={
            "N_FRAMES": os.getenv("N_FRAMES", "30000"),
            "L_QUEUE": os.getenv("L_QUEUE", "64"),
            "MAC_SPACE": os.getenv("MAC_SPACE", "10000"),
            "ALPHA": os.getenv("ALPHA", "0.7"),
            "BITRATE_BPS": os.getenv("BITRATE_BPS", str(51.2 * 10**9)),
            "PACKET_SIZE_BYTES": os.getenv("PACKET_SIZE_BYTES", "64"),
            "CLK_FREQ_HZ": os.getenv("CLK_FREQ_HZ", str(100 * 10**6)),
        },
    )


if __name__ == "__main__":
    main()
