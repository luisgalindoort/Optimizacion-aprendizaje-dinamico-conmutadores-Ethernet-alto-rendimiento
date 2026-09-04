"""Banco de prueba cocotb para el modelo HDL con cache.

Genera una secuencia de tramas, la aplica al modulo ciclo a ciclo y recoge las
metricas principales de cache y tabla MAC. Los parametros se leen desde
variables de entorno para que los scripts de barrido puedan reutilizar el mismo
test.
"""

import random
import cocotb
from cocotb.triggers import RisingEdge, Timer, with_timeout
import os
from collections import deque


# Reloj configurable según CLK_FREQ_HZ
async def clock_gen(dut, clk_freq_hz):
    period_ns = 1e9 / clk_freq_hz
    half_period_ns = period_ns / 2.0

    dut._log.info(
        f"[CLOCK] Frecuencia={clk_freq_hz:.0f} Hz "
        f"Periodo={period_ns:.3f} ns "
        f"Half={half_period_ns:.3f} ns"
    )

    while True:
        dut.clk.value = 0
        await Timer(half_period_ns, unit="ns")
        dut.clk.value = 1
        await Timer(half_period_ns, unit="ns")


# Reset
async def reset_dut(dut):
    dut.rst.value = 1
    dut.learn_request_mac_in.value = 0
    dut.learn_request_port_in.value = 0
    dut.learn_request_valid_in.value = 0
    dut.learn_request_ready_in.value = 0

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    dut.rst.value = 0

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


# Generación de tramas con distribución Zipf
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
            k=1
        )[0]

        port = rnd.randint(1, max_port_value)
        frames.append((mac, port))

    return frames


def logic_to_int_safe(value, default=0):
    try:
        return int(value)
    except (ValueError, TypeError):
        return default


def dut_signal_to_int(dut, name, default=0):
    try:
        return logic_to_int_safe(getattr(dut, name).value, default)
    except AttributeError:
        return default


# Monitor de caché
class CacheSaturationMonitor:
    def __init__(self, dut):
        self.dut = dut
        self.stop = False
        self.cache_hits = 0
        self.cache_misses = 0

    async def run(self):
        while not self.stop:
            await RisingEdge(self.dut.clk)

            if int(self.dut.rst.value):
                continue

            query_response_valid = dut_signal_to_int(
                self.dut,
                "query_response_valid",
            )
            query_response_error = dut_signal_to_int(
                self.dut,
                "query_response_error",
            )

            if query_response_valid:
                if query_response_error:
                    self.cache_misses += 1
                else:
                    self.cache_hits += 1


# Cola + tabla MAC



class MacHDLMonitor:
    def __init__(self, dut):
        self.dut = dut

        self.accepted_frames = []
        self.processed_frames = []
        self.insert_results = []

        self.output_macs_seen = set()
        self.pending_write_data = deque()

        self.stop = False
        self.input_finished = False

    def is_drained(self):
        return (
            self.input_finished
            and len(self.processed_frames) == len(self.accepted_frames)
        )

    async def run(self):
        while not self.stop:
            await RisingEdge(self.dut.clk)

            if int(self.dut.rst.value):
                continue


            if logic_to_int_safe(self.dut.output_hs.value):
                mac = int(self.dut.response_mac.value)
                port = int(self.dut.response_port.value)

                self.accepted_frames.append((mac, port))
                self.output_macs_seen.add(mac)


            if logic_to_int_safe(self.dut.mac_write_hs.value):
                self.pending_write_data.append(
                    int(self.dut.mac_fifo_rd_data.value)
                )


            if logic_to_int_safe(self.dut.mac_write_response_valid.value):
                data = (
                    self.pending_write_data.popleft()
                    if self.pending_write_data
                    else 0
                )
                mac = data & ((1 << 48) - 1)
                port = data >> 48
                success = not bool(
                    logic_to_int_safe(self.dut.mac_write_response_error.value)
                )

                self.processed_frames.append((mac, port))
                self.insert_results.append(
                    {
                        "mac": mac,
                        "port": port,
                        "success": success,
                    }
                )


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

    presented_frames = []
    accepted_input_frames = []
    dropped_input_frames = []

    while index < len(frames):

        bit_accumulator += bits_per_cycle

        packet_arrives = False

        if bit_accumulator >= packet_bits:
            bit_accumulator -= packet_bits
            packet_arrives = True

        if packet_arrives:
            mac, port = frames[index]

            presented_frames.append((mac, port))

            dut.learn_request_mac_in.value = mac
            dut.learn_request_port_in.value = port
            dut.learn_request_valid_in.value = 1

            await RisingEdge(dut.clk)

            ready = logic_to_int_safe(dut.learn_request_ready_out.value)

            if ready:
                accepted_input_frames.append((mac, port))
            else:
                dropped_input_frames.append((mac, port))

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

    return presented_frames, accepted_input_frames, dropped_input_frames



# Test principal


@cocotb.test()
async def test_modulo_con_cola_y_tabla_mac(dut):
    N_FRAMES = int(os.getenv("N_FRAMES", "120"))

    STARTUP_WAIT_CYCLES = int(os.getenv("STARTUP_WAIT_CYCLES", "10000"))
    CACHE_DRAIN_CYCLES = int(os.getenv("CACHE_DRAIN_CYCLES", "200"))

    P_ARRIVAL = float(os.getenv("P_ARRIVAL", "1.0"))
    MAC_SPACE = int(os.getenv("MAC_SPACE", "50"))
    ALPHA = float(os.getenv("ALPHA", "1.0"))

    BITRATE_BPS = float(os.getenv("BITRATE_BPS", "1000000000"))
    PACKET_SIZE_BYTES = int(os.getenv("PACKET_SIZE_BYTES", "64"))
    CLK_FREQ_HZ = float(os.getenv("CLK_FREQ_HZ", "100000000"))

    PORT_WIDTH = len(dut.learn_request_port_in)

    packet_bits = PACKET_SIZE_BYTES * 8
    bits_per_cycle = BITRATE_BPS / CLK_FREQ_HZ
    cycles_per_packet = packet_bits / bits_per_cycle if bits_per_cycle else 0.0

    cocotb.start_soon(clock_gen(dut, CLK_FREQ_HZ))

    dut._log.info("========================================")
    dut._log.info("CONFIGURACIÓN DE TRÁFICO")
    dut._log.info("Distribución: Zipf")
    dut._log.info(f"ALPHA: {ALPHA}")
    dut._log.info(f"MAC_SPACE: {MAC_SPACE}")
    dut._log.info(f"Bitrate configurado: {BITRATE_BPS:.0f} bit/s")
    dut._log.info(f"Tamaño paquete: {PACKET_SIZE_BYTES} bytes")
    dut._log.info(f"Frecuencia reloj: {CLK_FREQ_HZ:.0f} Hz")
    dut._log.info(f"Bits por ciclo: {bits_per_cycle:.4f}")
    dut._log.info(f"Ciclos por paquete: {cycles_per_packet:.2f}")
    dut._log.info(f"STARTUP_WAIT_CYCLES: {STARTUP_WAIT_CYCLES}")
    dut._log.info(f"CACHE_DRAIN_CYCLES: {CACHE_DRAIN_CYCLES}")
    dut._log.info("========================================")

    await reset_dut(dut)

    ready_ok = False

    for i in range(STARTUP_WAIT_CYCLES):
        await RisingEdge(dut.clk)

        cache_ready = logic_to_int_safe(dut.learn_request_ready_out.value) == 1
        mac_ready = logic_to_int_safe(dut.mac_write_ready.value) == 1

        if cache_ready and mac_ready:
            ready_ok = True
            dut._log.info(
                f"ready cache y MAC HDL=1 tras {i + 1} ciclos de espera"
            )
            break

    if not ready_ok:
        dut._log.warning(
            f"ready cache/MAC HDL sigue a 0 tras {STARTUP_WAIT_CYCLES} ciclos"
        )

    dut._log.info(
        f"ready_out antes de enviar tráfico: "
        f"{logic_to_int_safe(dut.learn_request_ready_out.value)}"
    )

    frames = generate_random_frames(
        n_frames=N_FRAMES,
        port_width=PORT_WIDTH,
        seed=12345,
        p_arrival=P_ARRIVAL,
        mac_space=MAC_SPACE,
        alpha=ALPHA,
    )

    hdl_mac_monitor = MacHDLMonitor(dut)
    hdl_mac_monitor_task = cocotb.start_soon(hdl_mac_monitor.run())
    cache_monitor = CacheSaturationMonitor(dut)
    cache_monitor_task = cocotb.start_soon(cache_monitor.run())

    _, _, dropped_input_frames = await send_frames_with_bitrate(
        dut=dut,
        frames=frames,
        bitrate_bps=BITRATE_BPS,
        packet_size_bytes=PACKET_SIZE_BYTES,
        clk_freq_hz=CLK_FREQ_HZ,
    )

    hdl_mac_monitor.input_finished = True

    for _ in range(CACHE_DRAIN_CYCLES):
        await RisingEdge(dut.clk)

    drained = False

    for _ in range(10000):
        await RisingEdge(dut.clk)

        if hdl_mac_monitor.is_drained():
            drained = True
            break

    if not drained:
        dut._log.warning(
            f"No se vació completamente el sistema antes del timeout de drenaje: "
            f"accepted={len(hdl_mac_monitor.accepted_frames)}, "
            f"processed={len(hdl_mac_monitor.processed_frames)}"
        )


    hdl_mac_monitor.stop = True
    await RisingEdge(dut.clk)

    cache_monitor.stop = True
    await RisingEdge(dut.clk)

    await with_timeout(hdl_mac_monitor_task, 50000, "ns")
    await with_timeout(cache_monitor_task, 50000, "ns")

    assert hdl_mac_monitor.processed_frames == hdl_mac_monitor.accepted_frames, (
        f"\nRecibido en cola: {hdl_mac_monitor.accepted_frames}\n"
        f"Procesado en tabla: {hdl_mac_monitor.processed_frames}"
    )

    total_generated = len(frames)
    total_dropped_input = len(dropped_input_frames)
    total_output = len(hdl_mac_monitor.accepted_frames)

    unique_generated_macs = {mac for mac, _ in frames}
    unique_output_macs = hdl_mac_monitor.output_macs_seen

    attempted_macs = {
        result["mac"]
        for result in hdl_mac_monitor.insert_results
    }

    missing_macs = unique_output_macs - attempted_macs

    assert not missing_macs, (
        "Estas MACs salieron del DUT pero nunca llegaron al escritor MAC: "
        + ", ".join(f"0x{mac:012X}" for mac in sorted(missing_macs))
    )

    mac_hw_responses = int(dut.mac_table_write_responses.value)
    mac_hw_learned_entries = int(dut.mac_table_learned_entries.value)

    write_efficiency_hw = (
        mac_hw_learned_entries / mac_hw_responses
        if mac_hw_responses else 0.0
    )

    input_drop_percentage = (
        total_dropped_input / total_generated * 100.0
        if total_generated else 0.0
    )

    learned_percentage_over_generated = (
        mac_hw_learned_entries / len(unique_generated_macs) * 100.0
        if unique_generated_macs else 0.0
    )

    misses_without_output = cache_monitor.cache_misses - total_output

    dut._log.info("========================================")
    dut._log.info("RESULTADOS DEL ESTUDIO")
    dut._log.info("Parametros de trafico")
    dut._log.info("Distribucion usada: Zipf")
    dut._log.info(f"ALPHA: {ALPHA}")
    dut._log.info(f"MAC_SPACE: {MAC_SPACE}")
    dut._log.info(f"Bitrate configurado: {BITRATE_BPS:.0f} bit/s")
    dut._log.info(f"Frames entrada generados: {total_generated}")
    dut._log.info(f"MACs distintas generadas: {len(unique_generated_macs)}")

    dut._log.info("----------------------------------------")
    dut._log.info("Metricas de cache")
    dut._log.info(f"Cache hits: {cache_monitor.cache_hits}")
    dut._log.info(f"Cache misses: {cache_monitor.cache_misses}")

    dut._log.info("----------------------------------------")
    dut._log.info("Metricas de saturacion")
    dut._log.info(f"Misses que no produjeron salida HDL: {misses_without_output}")
    dut._log.info(f"% descartes por saturacion en MAC: {input_drop_percentage:.2f}%")

    dut._log.info("----------------------------------------")
    dut._log.info("Metricas de aprendizaje")
    dut._log.info(
        f"MACs aprendidas en tabla MAC HDL: "
        f"{mac_hw_learned_entries}/{len(unique_generated_macs)}"
    )
    dut._log.info(
        f"% MACs aprendidas HDL/generadas: "
        f"{learned_percentage_over_generated:.2f}%"
    )
    dut._log.info(f"Eficiencia de escritura MAC HDL: {write_efficiency_hw:.2%}")
    dut._log.info("========================================")
