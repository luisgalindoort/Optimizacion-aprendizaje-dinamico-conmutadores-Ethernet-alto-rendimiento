"""Banco de prueba cocotb para el modelo HDL base.

Aplica la misma generacion de trafico que el modelo con cache, pero conecta las
tramas directamente a la cola y tabla MAC. Se utiliza como referencia para
comparar el efecto del filtrado.
"""

import os
import random

import cocotb
from cocotb.triggers import RisingEdge, Timer


# Reloj configurable según CLK_FREQ_HZ
async def clock_gen(dut, clk_freq_hz):
    period_ns = 1e9 / clk_freq_hz
    half_period_ns = period_ns / 2.0

    dut._log.info(
        f"[CLOCK] Frecuencia={clk_freq_hz:.0f} Hz "
        f"Periodo={period_ns:.3f} ns"
    )

    while True:
        dut.clk.value = 0
        await Timer(half_period_ns, unit="ns")
        dut.clk.value = 1
        await Timer(half_period_ns, unit="ns")


# Reset inicial del banco de prueba
async def reset_dut(dut):
    dut.rst.value = 1
    dut.learn_request_mac_in.value = 0
    dut.learn_request_port_in.value = 0
    dut.learn_request_valid_in.value = 0
    dut.learn_request_ready_in.value = 1

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    dut.rst.value = 0

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


# Generacion de tramas con distribucion Zipf
def generate_random_frames(
    n_frames,
    port_width,
    seed=12345,
    p_arrival=1.0,
    mac_space=50,
    alpha=1.0,
):
    rnd = random.Random(seed)
    frames = []

    max_port_value = (1 << port_width) - 1
    mac_pool = rnd.sample(range(1 << 48), mac_space)

    ranks = list(range(1, mac_space + 1))
    weights = [1.0 / (rank ** alpha) for rank in ranks]

    while len(frames) < n_frames:
        if rnd.random() > p_arrival:
            continue

        mac = rnd.choices(
            population=mac_pool,
            weights=weights,
            k=1,
        )[0]

        port = rnd.randint(1, max_port_value)
        frames.append((mac, port))

    return frames


# Envio de tramas respetando la velocidad configurada
async def send_frames_with_bitrate(
    dut,
    frames,
    bitrate_bps,
    packet_size_bytes,
    clk_freq_hz,
):
    dut.learn_request_mac_in.value = 0
    dut.learn_request_port_in.value = 0
    dut.learn_request_valid_in.value = 0

    await RisingEdge(dut.clk)

    packet_bits = packet_size_bytes * 8
    bits_per_cycle = bitrate_bps / clk_freq_hz
    bit_accumulator = 0.0

    index = 0

    sent_frames = []
    dropped_frames = []

    while index < len(frames):
        bit_accumulator += bits_per_cycle
        packet_arrives = False

        if bit_accumulator >= packet_bits:
            bit_accumulator -= packet_bits
            packet_arrives = True

        if packet_arrives:
            mac, port = frames[index]

            dut.learn_request_mac_in.value = mac
            dut.learn_request_port_in.value = port
            dut.learn_request_valid_in.value = 1

            await RisingEdge(dut.clk)

            ready = int(dut.learn_request_ready_out.value)

            if ready:
                sent_frames.append((mac, port))
            else:
                dropped_frames.append((mac, port))

            index += 1

            dut.learn_request_mac_in.value = 0
            dut.learn_request_port_in.value = 0
            dut.learn_request_valid_in.value = 0

        else:
            dut.learn_request_mac_in.value = 0
            dut.learn_request_port_in.value = 0
            dut.learn_request_valid_in.value = 0

            await RisingEdge(dut.clk)

    dut.learn_request_mac_in.value = 0
    dut.learn_request_port_in.value = 0
    dut.learn_request_valid_in.value = 0

    await RisingEdge(dut.clk)

    return sent_frames, dropped_frames


class MacHdlMonitor:
    def __init__(self, dut):
        self.dut = dut
        self.output_frames = []
        self.stop = False

    async def run(self):
        while not self.stop:
            await RisingEdge(self.dut.clk)


            valid = int(self.dut.learn_request_valid_out.value)
            if valid:
                mac = int(self.dut.learn_request_mac_out.value)
                port = int(self.dut.learn_request_port_out.value)
                self.output_frames.append((mac, port))



async def wait_mac_hdl_drained(dut, expected_requests, max_cycles):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)

        requests = int(dut.mac_table_write_requests.value)
        responses = int(dut.mac_table_write_responses.value)
        fifo_depth = int(dut.mac_fifo_status_depth.value)
        waiting_response = int(dut.mac_write_wait_response_reg.value)
        fifo_valid = int(dut.mac_fifo_rd_valid.value)

        if (
            requests == expected_requests
            and responses == expected_requests
            and fifo_depth == 0
            and waiting_response == 0
            and fifo_valid == 0
        ):
            return True

    return False


async def wait_mac_hdl_ready(dut, max_cycles):
    for cycle in range(1, max_cycles + 1):
        await RisingEdge(dut.clk)

        if int(dut.mac_write_ready.value) == 1:
            dut._log.info(
                f"MAC HDL lista para escritura tras {cycle} ciclos de espera"
            )
            return True

    dut._log.warning(
        f"mac_write_ready sigue a 0 tras {max_cycles} ciclos de espera"
    )
    return False


@cocotb.test()
async def test_modulo_sin_cache_con_cola_y_tabla_mac(dut):
    n_frames = int(os.getenv("N_FRAMES", "120"))
    p_arrival = float(os.getenv("P_ARRIVAL", "1.0"))
    mac_space = int(os.getenv("MAC_SPACE", "50"))
    alpha = float(os.getenv("ALPHA", "1.0"))

    bitrate_bps = float(os.getenv("BITRATE_BPS", "1000000000"))
    packet_size_bytes = int(os.getenv("PACKET_SIZE_BYTES", "64"))
    clk_freq_hz = float(os.getenv("CLK_FREQ_HZ", "100000000"))
    startup_wait_cycles = int(os.getenv("STARTUP_WAIT_CYCLES", "10000"))
    drain_cycles = int(os.getenv("MAC_DRAIN_CYCLES", "10000"))

    port_width = len(dut.learn_request_port_in)

    packet_bits = packet_size_bytes * 8
    bits_per_cycle = bitrate_bps / clk_freq_hz
    cycles_per_packet = packet_bits / bits_per_cycle if bits_per_cycle else 0.0

    cocotb.start_soon(clock_gen(dut, clk_freq_hz))

    await reset_dut(dut)
    await wait_mac_hdl_ready(dut, startup_wait_cycles)

    frames = generate_random_frames(
        n_frames=n_frames,
        port_width=port_width,
        seed=12345,
        p_arrival=p_arrival,
        mac_space=mac_space,
        alpha=alpha,
    )

    monitor = MacHdlMonitor(dut)
    monitor_task = cocotb.start_soon(monitor.run())

    sent_frames, dropped_input_frames = await send_frames_with_bitrate(
        dut=dut,
        frames=frames,
        bitrate_bps=bitrate_bps,
        packet_size_bytes=packet_size_bytes,
        clk_freq_hz=clk_freq_hz,
    )

    drained = await wait_mac_hdl_drained(
        dut=dut,
        expected_requests=len(sent_frames),
        max_cycles=drain_cycles,
    )

    if not drained:
        dut._log.warning(
            "No se vacio completamente la tabla MAC HDL: "
            f"requests={int(dut.mac_table_write_requests.value)}, "
            f"responses={int(dut.mac_table_write_responses.value)}, "
            f"fifo_depth={int(dut.mac_fifo_status_depth.value)}"
        )

    monitor.stop = True
    await RisingEdge(dut.clk)
    await monitor_task

    total_in = len(frames)
    dropped_by_input_backpressure = len(dropped_input_frames)

    unique_input_macs = {mac for mac, _ in frames}

    mac_hw_responses = int(dut.mac_table_write_responses.value)
    mac_hw_learned_entries = int(dut.mac_table_learned_entries.value)

    write_efficiency = (
        mac_hw_learned_entries / mac_hw_responses
        if mac_hw_responses else 0.0
    )

    input_drop_percentage = (
        dropped_by_input_backpressure / total_in * 100.0
        if total_in else 0.0
    )

    learned_percentage = (
        mac_hw_learned_entries / len(unique_input_macs) * 100.0
        if unique_input_macs else 0.0
    )

    dut._log.info("========================================")
    dut._log.info("RESULTADOS DEL ESTUDIO SIN CACHE")
    dut._log.info("Parametros de trafico")
    dut._log.info("Distribucion usada: Zipf")
    dut._log.info(f"ALPHA: {alpha}")
    dut._log.info(f"MAC_SPACE: {mac_space}")
    dut._log.info(f"Bitrate configurado: {bitrate_bps:.0f} bit/s")
    dut._log.info(f"Frames entrada generados: {total_in}")
    dut._log.info(f"MACs distintas generadas: {len(unique_input_macs)}")

    dut._log.info("----------------------------------------")
    dut._log.info("Metricas de saturacion")
    dut._log.info(f"Frames perdidos por congestion en entrada: {dropped_by_input_backpressure}")
    dut._log.info(f"% descartes por saturacion en MAC: {input_drop_percentage:.2f}%")

    dut._log.info("----------------------------------------")
    dut._log.info("Metricas de aprendizaje")
    dut._log.info(
        f"MACs aprendidas en tabla MAC HDL: "
        f"{mac_hw_learned_entries}/{len(unique_input_macs)}"
    )
    dut._log.info(f"% MACs aprendidas HDL/generadas: {learned_percentage:.2f}%")
    dut._log.info(f"Eficiencia de escritura MAC HDL: {write_efficiency:.2%}")
    dut._log.info("========================================")
