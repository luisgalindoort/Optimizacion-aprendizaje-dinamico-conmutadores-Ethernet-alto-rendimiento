from __future__ import annotations

from dataclasses import dataclass
from collections import deque
import random
from typing import Deque, Optional, Tuple, List, Set

from Hash_table import CuckooHashingTableParallel


@dataclass(frozen=True)
class Packet:
    t: int
    in_port: int
    src_mac: int
    dst_mac: int


#Define por que puerto entra la trama generada
class TDMAScheduler:

    def __init__(self, ports: List[int] = [1, 2, 3], weights: Optional[List[int]] = None):
        self.ports = ports
        self.weights = weights or [1] * len(ports)
        self.seq: List[int] = []

        for p, w in zip(self.ports, self.weights):
            self.seq += [p] * w

        self.i = 0

    def next_port(self) -> int:
        p = self.seq[self.i]
        self.i = (self.i + 1) % len(self.seq)
        return p


#Genera la direccion MAC siguiendo la distribucion de Zipf
def build_zipf_mac_generator(
    mac_space: int,
    alpha: float,
    seed: int = 12345,
):
    rnd = random.Random(seed)
    mac_pool = rnd.sample(range(1 << 48), mac_space)

    ranks = list(range(1, mac_space + 1))
    weights = [1.0 / (rank ** alpha) for rank in ranks]

    def generate_mac():
        return rnd.choices(
            population=mac_pool,
            weights=weights,
            k=1,
        )[0]

    return generate_mac, rnd

#Clase que genera la cola fifo de la tabla MAC, permite medir su ocupacion y paquetes descartados
class FIFO:

    def __init__(self, capacity: int):
        self.capacity = capacity
        self.q: Deque[Packet] = deque()

    def push(self, pkt: Packet) -> bool:
        if len(self.q) >= self.capacity:
            return False

        self.q.append(pkt)
        return True

    def pop(self) -> Optional[Packet]:
        return self.q.popleft() if self.q else None

    def __len__(self) -> int:
        return len(self.q)

#Escritor de la tabla MAC, modela el tiempo que tarda una dirección en escribirse
class MacWriter:

    def __init__(self):
        self.busy_left = 0

    def tick(self) -> None:
        if self.busy_left > 0:
            self.busy_left -= 1

    def is_ready(self) -> bool:
        return self.busy_left == 0

    def start_write(self, cycles: int) -> None:
        self.busy_left = max(1, cycles)

#Clase con las distintas metricas utilizadas durante el modelado
@dataclass
class Stats:
    slots: int
    requested_frames: int = 0

    offered: int = 0
    enqueued: int = 0
    dropped_fifo: int = 0
    written: int = 0

    mac_write_attempts: int = 0
    mac_write_success: int = 0
    mac_write_failed: int = 0
    mac_write_repeated: int = 0
    mac_write_unlearned: int = 0

    mac_write_cycles_total: int = 0
    mac_write_cycles_avg: float = 0.0
    mac_write_cycles_max: int = 0

    mac_utilization: float = 0.0
    mac_utilization_entries: int = 0

    fifo_avg_occ: float = 0.0
    fifo_max_occ: int = 0

    unique_src_seen: int = 0
    unique_src_written: int = 0

    frequent_src_seen: int = 0
    frequent_src_written: int = 0
    frequent_write_events: int = 0

    @property
    def throughput_per_slot(self) -> float:
        return self.written / self.slots if self.slots > 0 else 0.0

    @property
    def offered_per_slot(self) -> float:
        return self.offered / self.slots if self.slots > 0 else 0.0

    @property
    def learning_ratio_src(self) -> float:
        return (
            self.unique_src_written / self.unique_src_seen
            if self.unique_src_seen > 0
            else 0.0
        )

    @property
    def learning_ratio_freq_src(self) -> float:
        return (
            self.frequent_src_written / self.frequent_src_seen
            if self.frequent_src_seen > 0
            else 0.0
        )

    @property
    def write_efficiency(self) -> float:
        return (
            self.mac_write_success / self.mac_write_attempts
            if self.mac_write_attempts > 0
            else 0.0
        )

    @property
    def write_efficiency_freq(self) -> float:
        return (
            self.frequent_write_events / self.written
            if self.written > 0
            else 0.0
        )

#Traduce la salida de hash_table.py
def decode_insert_result(insert_result, default_key):
    if len(insert_result) == 3:
        success, loops, returned_key = insert_result
    else:
        success, loops = insert_result
        returned_key = default_key

    return success, loops, returned_key

#Define el tiempo de escritura por loop de la hash_table
def write_latency_from_loops(
    loops: int,
    first_write_cycles: int,
    next_write_cycles: int,
) -> int:
    return first_write_cycles + loops * next_write_cycles

#Funcion principal que ejecuta la simulacion del modelo base

def run_baseline_no_cache(

    #define variables y les asigna valor por defecto si no se introducen al llamar a la funcion
    slots: Optional[int] = None,
    n_frames: Optional[int] = None,

    p_arrivals: Tuple[float, float, float] = (1.0, 1.0, 1.0),
    tdma_weights: Tuple[int, int, int] = (1, 1, 1),

    fifo_cap: int = 64,

    mac_cap: int = 16384,
    mac_space: int = 50_000,
    seed: int = 0,

    alpha: float = 0.7,
    bitrate_bps: float = 1_000_000_000,
    packet_size_bytes: int = 64,
    clk_freq_hz: float = 100_000_000,

    freq_pair_threshold: int = 5,

    mac_cuckoo_table_count: int = 4,
    cuckoo_bin_size: int = 1,
    mac_cuckoo_max_loop: int = 5,

    first_write_cycles: int = 5,
    next_write_cycles: int = 4,

    drain_cycles: int = 10000,
    port_width: int = 8,

    **ignored_kwargs,
) -> Stats:

    if slots is None and n_frames is None:
        raise ValueError("Debes indicar slots o n_frames")

    tdma = TDMAScheduler([1, 2, 3], list(tdma_weights))
    fifo = FIFO(fifo_cap)
    writer = MacWriter()

    #Crea la tabla MAC con la funcion de CuckooHashing
    mactable = CuckooHashingTableParallel(
        key_width=48,
        cell_count=mac_cap,
        table_count=mac_cuckoo_table_count,
        bin_size=cuckoo_bin_size,
        max_loop=mac_cuckoo_max_loop,
        hash_type="LFSR",
        insertion_initial_filter=1,
        insertion_initial_strategy=0,
        insertion_reallocate_filter=1,
        insertion_reallocate_strategy=0,
    )

    #Genera direccion Mac
    generate_zipf_mac, traffic_rng = build_zipf_mac_generator(
        mac_space=mac_space,
        alpha=alpha,
        seed=seed,
    )

    #Convierte velocidad de enlace a ciclos
    packet_bits = packet_size_bytes * 8
    bits_per_cycle = bitrate_bps / clk_freq_hz

    cycles_per_packet = (
        packet_bits / bits_per_cycle
        if bits_per_cycle > 0
        else 1
    )

    bit_accumulator = 0.0

    st = Stats(
        slots=0,
        requested_frames=n_frames or 0,
    )

    fifo_sum = 0
    fifo_max = 0
    monitor_samples = 0

    seen_src: Set[int] = set()
    written_src: Set[int] = set()

    src_counts = {}
    write_counts = {}

    generated_packets = 0
    t = 0
    source_done = False
    ready_for_input = len(fifo) < fifo_cap

    #Se calcula el numero maximo de ciclos necesarios para transmitir y procesar todas las tramas de la simulacion
    if n_frames is not None:
        max_cycles = (
            int(n_frames * cycles_per_packet) + 1
            + drain_cycles
            + first_write_cycles * n_frames
            + next_write_cycles * n_frames
        )
    else:
        max_cycles = slots

    #Bucle principal con limite el numero maximo de ciclos calculado
    while t < max_cycles:

        sel_pkt = None

        #Generador de trafico

        if not source_done:
            bit_accumulator += bits_per_cycle

            if bit_accumulator >= packet_bits:
                bit_accumulator -= packet_bits

                sel_port = tdma.next_port()

                if traffic_rng.random() <= p_arrivals[sel_port - 1]:
                    src_mac = generate_zipf_mac()
                    in_port = traffic_rng.randint(1, (1 << port_width) - 1)

                    sel_pkt = Packet(
                        t=t,
                        in_port=in_port,
                        src_mac=src_mac,
                        dst_mac=0,
                    )

                    generated_packets += 1

                    if n_frames is not None and generated_packets >= n_frames:
                        source_done = True

            if n_frames is None and slots is not None and t >= slots:
                source_done = True

        #Si se genera una trama, intenta entrar en la cola, si no puede se descarta
        if sel_pkt is not None:
            st.offered += 1

            seen_src.add(sel_pkt.src_mac)
            src_counts[sel_pkt.src_mac] = src_counts.get(sel_pkt.src_mac, 0) + 1

            if ready_for_input and fifo.push(sel_pkt):
                st.enqueued += 1
            else:
                st.dropped_fifo += 1

        #Prepara el estado de la cola para saber si puede aceptar una mac en el siguiente ciclo
        ready_for_input = len(fifo) < fifo_cap

        #Escritor de la tabla MAC
        if writer.is_ready() and len(fifo) > 0:
            pkt = fifo.pop()

            st.mac_write_attempts += 1

            lookup_before = mactable.lookup(pkt.src_mac)

            insert_result = mactable.insert(
                key=pkt.src_mac,
                effective=True,
            )

            success, loops, returned_key = decode_insert_result(
                insert_result,
                pkt.src_mac,
            )

            if success:
                st.mac_write_success += 1
                st.written += 1

                written_src.add(pkt.src_mac)
                write_counts[pkt.src_mac] = write_counts.get(pkt.src_mac, 0) + 1

            else:
                st.mac_write_failed += 1

                if lookup_before is not None:
                    st.mac_write_repeated += 1
                    written_src.add(pkt.src_mac)
                else:
                    st.mac_write_unlearned += 1

            #Calcula el numero de ciclos usados en la escritura 
            total_write_cycles = write_latency_from_loops(
                loops=loops,
                first_write_cycles=first_write_cycles,
                next_write_cycles=next_write_cycles,
            )

            st.mac_write_cycles_total += total_write_cycles
            st.mac_write_cycles_max = max(
                st.mac_write_cycles_max,
                total_write_cycles,
            )

            #Bloquea el escritor durante esos ciclos para simular la espera
            writer.start_write(total_write_cycles)

        writer.tick()

        fifo_sum += len(fifo)
        fifo_max = max(fifo_max, len(fifo))
        monitor_samples += 1

        t += 1

        if n_frames is not None:
            if source_done and len(fifo) == 0 and writer.is_ready():
                break

    st.slots = t

    st.fifo_avg_occ = (
        fifo_sum / monitor_samples
        if monitor_samples > 0
        else 0.0
    )

    st.fifo_max_occ = fifo_max

    st.mac_write_cycles_avg = (
        st.mac_write_cycles_total / st.mac_write_attempts
        if st.mac_write_attempts > 0
        else 0.0
    )

    st.mac_utilization = mactable.get_utilization()
    st.mac_utilization_entries = mactable.get_utilization_entries()

    st.unique_src_seen = len(seen_src)
    st.unique_src_written = len(written_src)

    frequent_seen = {
        k
        for k, v in src_counts.items()
        if v >= freq_pair_threshold
    }

    frequent_written = written_src & frequent_seen

    st.frequent_src_seen = len(frequent_seen)
    st.frequent_src_written = len(frequent_written)
    st.frequent_write_events = sum(
        cnt
        for mac, cnt in write_counts.items()
        if mac in frequent_seen
    )

    return st


def print_stats(name: str, st: Stats) -> None:
    print(f"\n{name}")
    print("-" * len(name))

    print(f"slots                  : {st.slots}")
    print(f"requested_frames       : {st.requested_frames}")
    print(f"offered                : {st.offered}")
    print(f"enqueued               : {st.enqueued}")
    print(f"dropped_fifo           : {st.dropped_fifo}")
    print(f"written                : {st.written}")

    print(f"throughput/slot        : {st.throughput_per_slot:.6f}")
    print(f"offered/slot           : {st.offered_per_slot:.6f}")

    print(f"fifo_avg_occ           : {st.fifo_avg_occ:.3f}")
    print(f"fifo_max_occ           : {st.fifo_max_occ}")

    print(f"mac_write_attempts     : {st.mac_write_attempts}")
    print(f"mac_write_success      : {st.mac_write_success}")
    print(f"mac_write_failed       : {st.mac_write_failed}")
    print(f"mac_write_repeated     : {st.mac_write_repeated}")
    print(f"mac_write_unlearned    : {st.mac_write_unlearned}")
    print(f"write_efficiency       : {st.write_efficiency * 100:.2f}%")

    print(f"mac_write_cycles_total : {st.mac_write_cycles_total}")
    print(f"mac_write_cycles_avg   : {st.mac_write_cycles_avg:.2f}")
    print(f"mac_write_cycles_max   : {st.mac_write_cycles_max}")

    print(f"mac_utilization        : {st.mac_utilization:.2f}%")
    print(f"mac_utilization_entries: {st.mac_utilization_entries}")

    print(f"unique_src_seen        : {st.unique_src_seen}")
    print(f"unique_src_written     : {st.unique_src_written}")
    print(f"learning_ratio_src     : {st.learning_ratio_src:.6f}")

    print(f"frequent_src_seen      : {st.frequent_src_seen}")
    print(f"frequent_src_written   : {st.frequent_src_written}")
    print(f"learning_ratio_freq_src: {st.learning_ratio_freq_src:.6f}")
    print(f"frequent_write_events  : {st.frequent_write_events}")
    print(f"write_efficiency_freq  : {st.write_efficiency_freq:.6f}")
