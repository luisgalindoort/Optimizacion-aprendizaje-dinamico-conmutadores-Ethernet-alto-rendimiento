from __future__ import annotations

from dataclasses import dataclass
import random
from typing import Optional, Tuple, List, Set, Sequence
import simpy

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
def build_zipf_weights(mac_space: int, alpha: float) -> List[float]:
    ranks = list(range(1, mac_space + 1))
    return [1.0 / (rank ** alpha) for rank in ranks]


def build_hdl_mac_pool(mac_space: int, rnd: random.Random) -> List[int]:
    return rnd.sample(range(1 << 48), mac_space)


def traffic_generator(
    t: int,
    mac_pool: List[int],
    zipf_weights: List[float],
    rnd: random.Random,
    port_width: int,
) -> Packet:

    src = rnd.choices(
        population=mac_pool,
        weights=zipf_weights,
        k=1,
    )[0]

    port = rnd.randint(1, (1 << port_width) - 1)

    return Packet(
        t=t,
        in_port=port,
        src_mac=src,
        dst_mac=0,
    )

#Clase que define el estimador de frecuencias de TFLU, y sus funciones de lectura,escritura y aging
class CountMinSketch:

    def __init__(self, d: int, w: int, counter_bits: int = 8, seed: int = 0):
        assert d >= 1
        assert w >= 2 and (w & (w - 1) == 0)

        self.d = d
        self.w = w
        self.max_count = (1 << counter_bits) - 1
        self.tables = [[0] * w for _ in range(d)]

        rng = random.Random(seed)
        self.seeds = [rng.getrandbits(32) for _ in range(d)]

    def _hash(self, x: int, i: int) -> int:
        h = (x ^ self.seeds[i]) * 2654435761
        return (h & 0xFFFFFFFF) & (self.w - 1)

    def read_estimate(self, x: int) -> int:
        estimate = self.max_count

        for i in range(self.d):
            j = self._hash(x, i)
            value = self.tables[i][j]
            if value < estimate:
                estimate = value

        return estimate

    def update(self, x: int) -> int:
        estimate = self.max_count

        for i in range(self.d):
            j = self._hash(x, i)
            value = self.tables[i][j]

            if value < self.max_count:
                value += 1
                self.tables[i][j] = value

            if value < estimate:
                estimate = value

        return estimate

    def age(self) -> None:
        for row in self.tables:
            for index, value in enumerate(row):
                row[index] = value // 2

#Se definen las clases de las distintas etapas pipeline del modelo
@dataclass
class PipeS1:
    pkt: Packet
    cache_hit: bool
    cms_estimate_before: int


@dataclass
class PipeS2:
    pkt: Packet
    cache_hit: bool
    cms_estimate_before: int


@dataclass
class PipeS3:
    pkt: Packet
    cache_hit: bool
    cms_estimate_before: int


@dataclass
class PipeS4:
    pkt: Packet
    cms_estimate_before: int
    admitted_to_mac: bool

#Clase que recoge las distintas metricas utilizadas
@dataclass
class Stats:
    slots: int
    requested_frames: int = 0

    offered: int = 0

    mac_enqueued: int = 0
    mac_dropped_fifo: int = 0

    cache_write_attempts: int = 0
    cache_write_enqueued: int = 0
    cache_write_dropped_fifo: int = 0

    written: int = 0

    mac_write_attempts: int = 0
    mac_write_success: int = 0
    mac_write_failed: int = 0
    mac_write_repeated: int = 0
    mac_write_unlearned: int = 0

    cache_write_success: int = 0
    cache_write_failed: int = 0
    cache_write_repeated: int = 0
    cache_write_unlearned: int = 0

    mac_write_cycles_total: int = 0
    mac_write_cycles_avg: float = 0.0
    mac_write_cycles_max: int = 0

    cache_write_cycles_total: int = 0
    cache_write_cycles_avg: float = 0.0
    cache_write_cycles_max: int = 0

    mac_utilization: float = 0.0
    mac_utilization_entries: int = 0

    cache_utilization: float = 0.0
    cache_utilization_entries: int = 0

    fifo_avg_occ: float = 0.0
    fifo_max_occ: int = 0

    cache_fifo_avg_occ: float = 0.0
    cache_fifo_max_occ: int = 0

    cache_hits: int = 0
    cache_misses: int = 0
    suppressed: int = 0

    dropped_tlfu: int = 0
    passed_tlfu: int = 0
    cms_updates: int = 0
    cms_aging_events: int = 0

    unique_src_seen: int = 0
    unique_src_written: int = 0
    unique_cache_writes: int = 0

    stage0_queries_issued: int = 0
    stage1_latency_passes: int = 0
    stage2_latency_passes: int = 0
    stage3_latency_passes: int = 0
    stage4_mac_admits: int = 0
    stage5_cache_decisions: int = 0

    frequent_src_seen: int = 0
    frequent_src_written: int = 0
    frequent_write_events: int = 0

    @property
    def enqueued(self) -> int:
        return self.mac_enqueued

    @property
    def dropped_fifo(self) -> int:
        return self.mac_dropped_fifo

    @property
    def throughput_per_slot(self) -> float:
        return self.written / self.slots if self.slots > 0 else 0.0

    @property
    def offered_per_slot(self) -> float:
        return self.offered / self.slots if self.slots > 0 else 0.0

    @property
    def learning_ratio_src(self) -> float:
        return self.unique_src_written / self.unique_src_seen if self.unique_src_seen > 0 else 0.0

    @property
    def write_efficiency(self) -> float:
        return (
            self.mac_write_success / self.mac_write_attempts
            if self.mac_write_attempts > 0 else 0.0
        )

    @property
    def cache_write_efficiency(self) -> float:
        return (
            self.cache_write_success / self.cache_write_attempts
            if self.cache_write_attempts > 0 else 0.0
        )

    @property
    def cache_write_efficiency_unique(self) -> float:
        return (
            self.unique_cache_writes / self.cache_write_enqueued
            if self.cache_write_enqueued > 0 else 0.0
        )

    @property
    def learning_ratio_freq_src(self) -> float:
        return (
            self.frequent_src_written / self.frequent_src_seen
            if self.frequent_src_seen > 0 else 0.0
        )

    @property
    def write_efficiency_freq(self) -> float:
        return (
            self.frequent_write_events / self.written
            if self.written > 0 else 0.0
        )

#En esta clase se define la simulacion completa del modelo CMS + CACHE Y SOLO CACHE
class PipelineSimPyModel:

    def __init__(
        self,
        slots: Optional[int],
        n_frames: Optional[int],
        p_arrivals: Tuple[float, float, float],
        tdma_weights: Tuple[int, int, int],

        fifo_cap: int,
        cache_fifo_cap: int,

        mac_cap: int,
        mac_space: int,
        write_cycles: int,
        full_policy: str,
        seed: int,

        bitrate_bps: int,
        packet_size_bytes: int,
        clk_freq_hz: int,
        alpha: float,

        recent_cache_size: int,

        freq_pair_threshold: int,
        trace_macs: Optional[Sequence[int]] = None,
        trace_port: int = 1,

        use_cms: bool = True,
        cms_d: int = 4,
        cms_w: int = 2048,
        cms_counter_bits: int = 8,
        cms_threshold: int = 2,
        cms_cache_admission_fill_threshold: float = 0.90,
        cms_aging_period: int = 0,

        mac_cuckoo_table_count: int = 4,
        cache_cuckoo_table_count: int = 4,
        cuckoo_bin_size: int = 1,
        mac_cuckoo_max_loop: int = 5,
        cache_cuckoo_max_loop: int = 8,

        port_width: int = 8,
        cache_lookup_latency_cycles: int = 4,

        first_write_cycles: int = 5,
        next_write_cycles: int = 4,
        cache_first_write_cycles: int = 5,
        cache_next_write_cycles: int = 4,
        mac_fifo_prefetch_cycles: int = 1,
        cache_fifo_prefetch_cycles: int = 2,
        drain_cycles: int = 10000,
    ):
        self.slots = slots
        self.n_frames = n_frames
        self.drain_cycles = drain_cycles

        self.p_arrivals = p_arrivals
        self.tdma_weights = tdma_weights

        self.fifo_cap = fifo_cap
        self.cache_fifo_cap = cache_fifo_cap

        self.mac_cap = mac_cap
        self.mac_space = mac_space

        self.write_cycles = write_cycles
        self.first_write_cycles = first_write_cycles
        self.next_write_cycles = next_write_cycles
        self.cache_first_write_cycles = cache_first_write_cycles
        self.cache_next_write_cycles = cache_next_write_cycles
        self.mac_fifo_prefetch_cycles = mac_fifo_prefetch_cycles
        self.cache_fifo_prefetch_cycles = cache_fifo_prefetch_cycles
        self.full_policy = full_policy
        self.seed = seed

        self.bitrate_bps = bitrate_bps
        self.packet_size_bytes = packet_size_bytes
        self.clk_freq_hz = clk_freq_hz
        self.alpha = alpha
        self.trace_macs = list(trace_macs) if trace_macs is not None else None
        self.trace_port = trace_port

        bits_per_packet = self.packet_size_bytes * 8
        bits_per_cycle = self.bitrate_bps / self.clk_freq_hz

        self.packet_bits = bits_per_packet
        self.bits_per_cycle = bits_per_cycle
        self.cycles_per_packet = (
            bits_per_packet / bits_per_cycle
            if bits_per_cycle > 0
            else 1.0
        )
        self.port_width = port_width
        self.cache_lookup_latency_cycles = cache_lookup_latency_cycles

        self.rnd = random.Random(seed)
        self.mac_pool = build_hdl_mac_pool(mac_space, self.rnd)
        self.zipf_weights = build_zipf_weights(mac_space, alpha)

        self.recent_cache_size = recent_cache_size
        self.freq_pair_threshold = freq_pair_threshold

        self.use_cms = use_cms
        self.cms_threshold = cms_threshold
        self.cms_cache_admission_fill_threshold = cms_cache_admission_fill_threshold
        self.cms_aging_period = cms_aging_period
        self.cms = (
            CountMinSketch(cms_d, cms_w, cms_counter_bits, seed + 999)
            if use_cms
            else None
        )

         #Crea el entorno de Simpy para modelar eventos discretos
        self.env = simpy.Environment()

        self.tdma = TDMAScheduler([1, 2, 3], list(tdma_weights))

        self.mactable = CuckooHashingTableParallel(
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

        self.cache_table = CuckooHashingTableParallel(
            key_width=48,
            cell_count=recent_cache_size,
            table_count=cache_cuckoo_table_count,
            bin_size=cuckoo_bin_size,
            max_loop=cache_cuckoo_max_loop,
            hash_type="LFSR",
            insertion_initial_filter=1,
            insertion_initial_strategy=0,
            insertion_reallocate_filter=1,
            insertion_reallocate_strategy=0,
        )

        self.st = Stats(
            slots=0,
            requested_frames=n_frames or 0,
        )

        self.seen_src: Set[int] = set()
        self.written_src: Set[int] = set()
        self.cache_written_src: Set[int] = set()

        self.src_counts = {}
        self.write_counts = {}

        self.mac_fifo_sum = 0
        self.mac_fifo_max = 0

        self.cache_fifo_sum = 0
        self.cache_fifo_max = 0

        self.ready_for_mac_input = True
        self.ready_for_cache_write_input = True

        self.monitor_samples = 0

        self.source_done = False
        self.stage1_active = False
        self.stage2_active = False
        self.stage3_active = False
        self.stage4_active = False
        self.stage5_active = False
        self.mac_writer_active = False
        self.cache_writer_active = False

        self.s1_store = simpy.Store(self.env)
        self.s2_store = simpy.Store(self.env)
        self.s3_store = simpy.Store(self.env)
        self.s4_store = simpy.Store(self.env)
        self.s5_store = simpy.Store(self.env)

        self.mac_fifo_mem_store = simpy.Store(self.env, capacity=fifo_cap)
        self.mac_fifo_out_store = simpy.Store(self.env, capacity=1)
        self.cache_fifo_mem_store = simpy.Store(self.env, capacity=cache_fifo_cap)
        self.cache_fifo_out_store = simpy.Store(self.env, capacity=1)

    #Termina la simulacion cuando ya se han procesado todas las tramas
    def system_empty(self) -> bool:
        return (
            self.source_done
            and len(self.s1_store.items) == 0
            and len(self.s2_store.items) == 0
            and len(self.s3_store.items) == 0
            and len(self.s4_store.items) == 0
            and len(self.s5_store.items) == 0
            and len(self.mac_fifo_mem_store.items) == 0
            and len(self.mac_fifo_out_store.items) == 0
            and len(self.cache_fifo_mem_store.items) == 0
            and len(self.cache_fifo_out_store.items) == 0
            and not self.stage1_active
            and not self.stage2_active
            and not self.stage3_active
            and not self.stage4_active
            and not self.stage5_active
            and not self.mac_writer_active
            and not self.cache_writer_active
        )

    def mac_fifo_occupancy(self) -> int:
        return (
            len(self.mac_fifo_mem_store.items)
            + len(self.mac_fifo_out_store.items)
        )

    def mac_accept_occupancy(self) -> int:
        return len(self.mac_fifo_mem_store.items) + 2

    def cache_fifo_occupancy(self) -> int:
        return (
            len(self.cache_fifo_mem_store.items)
            + len(self.cache_fifo_out_store.items)
        )

    #Etapa inicial que genera las tramas y la pasa a la primera etapa del pipeline
    def source_process(self):
        t = 0
        bit_accumulator = 0.0
        generated_packets = 0

        while True:

            if self.n_frames is not None:
                if generated_packets >= self.n_frames:
                    break
            else:
                if self.slots is not None and t >= self.slots:
                    break

            bit_accumulator += self.bits_per_cycle

            if bit_accumulator >= self.packet_bits:
                bit_accumulator -= self.packet_bits

                if self.trace_macs is not None:
                    pkt = Packet(
                        t=t,
                        in_port=self.trace_port,
                        src_mac=self.trace_macs[generated_packets],
                        dst_mac=0,
                    )
                else:
                    sel_port = self.tdma.next_port()
                    if self.rnd.random() > self.p_arrivals[sel_port - 1]:
                        yield self.env.timeout(1)
                        t += 1
                        continue
                    pkt = traffic_generator(
                        t=t,
                        mac_pool=self.mac_pool,
                        zipf_weights=self.zipf_weights,
                        rnd=self.rnd,
                        port_width=self.port_width,
                    )

                generated_packets += 1

                self.st.offered += 1
                self.seen_src.add(pkt.src_mac)
                self.src_counts[pkt.src_mac] = self.src_counts.get(pkt.src_mac, 0) + 1

                cms_estimate_before = (
                    self.cms.read_estimate(pkt.src_mac)
                    if self.cms is not None
                    else 0
                )

                yield self.s1_store.put(
                    PipeS1(
                        pkt=pkt,
                        cache_hit=False,
                        cms_estimate_before=cms_estimate_before,
                    )
                )

                self.st.stage0_queries_issued += 1

            yield self.env.timeout(1)
            t += 1

        self.source_done = True

    #Etapa de latencia
    def stage1_process(self):
        while True:
            reg_s1: PipeS1 = yield self.s1_store.get()
            self.stage1_active = True

            yield self.env.timeout(1)

            yield self.s2_store.put(
                PipeS2(
                    pkt=reg_s1.pkt,
                    cache_hit=reg_s1.cache_hit,
                    cms_estimate_before=reg_s1.cms_estimate_before,
                )
            )

            self.st.stage1_latency_passes += 1
            self.stage1_active = False

    #Etapa de latencia
    def stage2_process(self):
        while True:
            reg_s2: PipeS2 = yield self.s2_store.get()
            self.stage2_active = True

            yield self.env.timeout(1)

            yield self.s3_store.put(
                PipeS3(
                    pkt=reg_s2.pkt,
                    cache_hit=reg_s2.cache_hit,
                    cms_estimate_before=reg_s2.cms_estimate_before,
                )
            )

            self.st.stage2_latency_passes += 1
            self.stage2_active = False

    #Etapa de latencia
    def stage3_process(self):
        while True:
            reg_s3: PipeS3 = yield self.s3_store.get()
            self.stage3_active = True

            yield self.env.timeout(1)

            yield self.s4_store.put(reg_s3)

            self.st.stage3_latency_passes += 1
            self.stage3_active = False


    def stage4_process(self):
        while True:
            reg_s3: PipeS3 = yield self.s4_store.get()
            self.stage4_active = True

            pkt = reg_s3.pkt
            key = pkt.src_mac
            extra_lookup_cycles = max(
                0,
                self.cache_lookup_latency_cycles - 3,
            )

            if extra_lookup_cycles:
                yield self.env.timeout(extra_lookup_cycles)

            cache_hit = self.cache_table.lookup(key) is not None

             # Si hay hit, la trama se filtra y no genera escritura en la tabla MAC.
            if cache_hit:
                self.st.cache_hits += 1
                self.st.suppressed += 1

            else:
                self.st.cache_misses += 1

                admitted_to_mac = False

                if (
                    self.ready_for_mac_input
                    and self.mac_accept_occupancy() < self.fifo_cap
                ):

                    yield self.mac_fifo_mem_store.put(pkt)

                    self.st.mac_enqueued += 1
                    self.st.stage4_mac_admits += 1
                    admitted_to_mac = True

                else:
                    self.st.mac_dropped_fifo += 1

                # Para un miss, se separa la decision de escritura de la cache para el caso de cache y cms +cache
                if self.cms is not None:
                    yield self.s5_store.put(
                        PipeS4(
                            pkt=pkt,
                            cms_estimate_before=reg_s3.cms_estimate_before,
                            admitted_to_mac=admitted_to_mac,
                        )
                    )
                elif admitted_to_mac:
                    self.st.cache_write_attempts += 1

                    if (
                        self.ready_for_cache_write_input
                        and len(self.cache_fifo_mem_store.items) < self.cache_fifo_cap
                    ):

                        yield self.cache_fifo_mem_store.put(key)

                        self.st.cache_write_enqueued += 1

                    else:
                        self.st.cache_write_dropped_fifo += 1

            self.stage4_active = False

    def stage5_process(self):
        while True:
             # Recibe los misses de cache que necesitan aplicar la condicion del  CMS.
            reg_s4 = yield self.s5_store.get()
            self.stage5_active = True

            key = reg_s4.pkt.src_mac

            yield self.env.timeout(1)

            cms_estimate_after = reg_s4.cms_estimate_before + 1

            self.cms.update(key)
            self.st.cms_updates += 1

            # Si la cache aun no esta llena, se admite directamente la nueva MAC.
            if self._cache_fill_ratio() < self.cms_cache_admission_fill_threshold:
                self.st.passed_tlfu += 1
                should_update_cache = True
            elif cms_estimate_after >= self.cms_threshold:
                self.st.passed_tlfu += 1
                should_update_cache = True
            else:
                self.st.dropped_tlfu += 1
                should_update_cache = False

             # Si se cumplen ambas condiciones, se manda  la escritura hacia la cache.
            if should_update_cache and reg_s4.admitted_to_mac:
                self.st.cache_write_attempts += 1

                if (
                    self.ready_for_cache_write_input
                    and len(self.cache_fifo_mem_store.items) < self.cache_fifo_cap
                ):

                    yield self.cache_fifo_mem_store.put(key)

                    self.st.cache_write_enqueued += 1

                else:
                    self.st.cache_write_dropped_fifo += 1

            self.st.stage5_cache_decisions += 1
            self.stage5_active = False

    def _decode_insert_result(self, insert_result, default_key):
        if len(insert_result) == 3:
            success, loops, returned_key = insert_result
        else:
            success, loops = insert_result
            returned_key = default_key

        return success, loops, returned_key

    #Calcula ocupacion de la cache 
    def _cache_fill_ratio(self) -> float:
        if self.recent_cache_size <= 0:
            return 1.0
        return self.cache_table.get_utilization_entries() / self.recent_cache_size

    #Calcula la latencia de escritura
    def _write_latency_from_loops(
        self,
        loops: int,
        first_write_cycles: Optional[int] = None,
        next_write_cycles: Optional[int] = None,
    ) -> int:
        first = (
            self.first_write_cycles
            if first_write_cycles is None
            else first_write_cycles
        )
        next_cycles = (
            self.next_write_cycles
            if next_write_cycles is None
            else next_write_cycles
        )

        return first + loops * next_cycles

    #Funcion para sacer un elemento de la fifo mac y pasarlo al escritor de la cola MAC
    def mac_fifo_prefetch_process(self):
        while True:
            pkt: Packet = yield self.mac_fifo_mem_store.get()

            if self.mac_fifo_prefetch_cycles:
                yield self.env.timeout(self.mac_fifo_prefetch_cycles)

            yield self.mac_fifo_out_store.put(pkt)

    #Funcion para escribir direcciones en la tabla MAC
    def mac_writer_process(self):
        while True:
            pkt: Packet = yield self.mac_fifo_out_store.get()
            self.mac_writer_active = True

            self.st.mac_write_attempts += 1

            lookup_before = self.mactable.lookup(pkt.src_mac)

            yield self.env.timeout(self.first_write_cycles)

            insert_result = self.mactable.insert(
                key=pkt.src_mac,
                effective=True,
            )

            success, loops, _ = self._decode_insert_result(
                insert_result,
                pkt.src_mac,
            )

            if success:
                self.st.mac_write_success += 1
                self.st.written += 1

                self.written_src.add(pkt.src_mac)
                self.write_counts[pkt.src_mac] = self.write_counts.get(pkt.src_mac, 0) + 1

            else:
                self.st.mac_write_failed += 1

                if lookup_before is not None:
                    self.st.mac_write_repeated += 1
                    self.written_src.add(pkt.src_mac)
                else:
                    self.st.mac_write_unlearned += 1

            total_write_cycles = self._write_latency_from_loops(loops)

            self.st.mac_write_cycles_total += total_write_cycles
            self.st.mac_write_cycles_max = max(
                self.st.mac_write_cycles_max,
                total_write_cycles,
            )

            remaining_write_cycles = max(
                0,
                total_write_cycles - self.first_write_cycles,
            )

            if remaining_write_cycles:
                yield self.env.timeout(remaining_write_cycles)

            self.mac_writer_active = False

    #Funcion para sacer un elemento de la fifo cache y pasarlo al escritor de la cola cache
    def cache_fifo_prefetch_process(self):
        while True:
            key: int = yield self.cache_fifo_mem_store.get()

            if self.cache_fifo_prefetch_cycles:
                yield self.env.timeout(self.cache_fifo_prefetch_cycles)

            yield self.cache_fifo_out_store.put(key)

    #Funcion para esribir direcciones en la cache
    def cache_writer_process(self):
        while True:
            key: int = yield self.cache_fifo_out_store.get()
            self.cache_writer_active = True

            lookup_before = self.cache_table.lookup(key)

            latency_result = self.cache_table.insert(
                key=key,
                effective=False,
            )

            _, loops, _ = self._decode_insert_result(
                latency_result,
                key,
            )

            hash_write_cycles = self._write_latency_from_loops(
                loops,
                first_write_cycles=self.cache_first_write_cycles,
                next_write_cycles=self.cache_next_write_cycles,
            )

            yield self.env.timeout(hash_write_cycles)
            yield self.env.timeout(0)

            insert_result = self.cache_table.insert(
                key=key,
                effective=True,
            )

            success, loops, _ = self._decode_insert_result(
                insert_result,
                key,
            )

            if success:
                self.st.cache_write_success += 1
                self.cache_written_src.add(key)

            else:
                self.st.cache_write_failed += 1

                if lookup_before is not None:
                    self.st.cache_write_repeated += 1
                else:
                    self.st.cache_write_unlearned += 1

            busy_write_cycles = hash_write_cycles

            self.st.cache_write_cycles_total += busy_write_cycles
            self.st.cache_write_cycles_max = max(
                self.st.cache_write_cycles_max,
                busy_write_cycles,
            )

            self.cache_writer_active = False

    #Mecanismo de aging
    def aging_process(self):
        if self.cms is None or self.cms_aging_period <= 0:
            return

        while True:
            yield self.env.timeout(self.cms_aging_period)
            self.cms.age()
            self.st.cms_aging_events += 1

    #modela si la cola de la tabla mac y cache pueden aceptar una nueva entrada
    def mac_ready_process(self):
        while True:
            yield self.env.timeout(1)

    
            self.ready_for_mac_input = (
                self.mac_accept_occupancy() < self.fifo_cap
            )
            self.ready_for_cache_write_input = (
                len(self.cache_fifo_mem_store.items) < self.cache_fifo_cap
            )

    #Funcion para monitorizar metricas
    def monitor_process(self):
        while True:
            yield self.env.timeout(1)

            mac_occ = self.mac_fifo_occupancy()
            cache_occ = self.cache_fifo_occupancy()

            self.mac_fifo_sum += mac_occ
            self.cache_fifo_sum += cache_occ

            self.mac_fifo_max = max(self.mac_fifo_max, mac_occ)
            self.cache_fifo_max = max(self.cache_fifo_max, cache_occ)

            self.monitor_samples += 1

    #funcion para calcular las metricas finales cuando termina la simulación
    def finalize(self) -> Stats:
        self.st.slots = int(self.env.now)

        self.st.fifo_avg_occ = (
            self.mac_fifo_sum / self.monitor_samples
            if self.monitor_samples > 0
            else 0.0
        )

        self.st.fifo_max_occ = self.mac_fifo_max

        self.st.cache_fifo_avg_occ = (
            self.cache_fifo_sum / self.monitor_samples
            if self.monitor_samples > 0
            else 0.0
        )

        self.st.cache_fifo_max_occ = self.cache_fifo_max

        self.st.mac_write_cycles_avg = (
            self.st.mac_write_cycles_total / self.st.mac_write_attempts
            if self.st.mac_write_attempts > 0
            else 0.0
        )

        self.st.cache_write_cycles_avg = (
            self.st.cache_write_cycles_total / self.st.cache_write_enqueued
            if self.st.cache_write_enqueued > 0
            else 0.0
        )

        self.st.mac_utilization = self.mactable.get_utilization()
        self.st.mac_utilization_entries = self.mactable.get_utilization_entries()

        self.st.cache_utilization = self.cache_table.get_utilization()
        self.st.cache_utilization_entries = self.cache_table.get_utilization_entries()

        self.st.unique_src_seen = len(self.seen_src)
        self.st.unique_src_written = len(self.written_src)
        self.st.unique_cache_writes = len(self.cache_written_src)

        frequent_seen = {
            k
            for k, v in self.src_counts.items()
            if v >= self.freq_pair_threshold
        }

        frequent_written = self.written_src & frequent_seen

        self.st.frequent_src_seen = len(frequent_seen)
        self.st.frequent_src_written = len(frequent_written)

        self.st.frequent_write_events = sum(
            cnt
            for mac, cnt in self.write_counts.items()
            if mac in frequent_seen
        )

        return self.st

    #Lanza los distintos procesos
    def run(self) -> Stats:
        self.env.process(self.source_process())
        self.env.process(self.stage1_process())
        self.env.process(self.stage2_process())
        self.env.process(self.stage3_process())
        self.env.process(self.stage4_process())
        self.env.process(self.stage5_process())
        self.env.process(self.mac_ready_process())
        self.env.process(self.mac_fifo_prefetch_process())
        self.env.process(self.mac_writer_process())
        self.env.process(self.cache_fifo_prefetch_process())
        self.env.process(self.cache_writer_process())
        self.env.process(self.monitor_process())
        if self.cms is not None and self.cms_aging_period > 0:
            self.env.process(self.aging_process())

        if self.n_frames is not None:
            max_time = (
                int(self.n_frames * self.cycles_per_packet) + 1
                + self.drain_cycles
                + self.first_write_cycles * self.n_frames
                + self.next_write_cycles * self.n_frames
            )

            while self.env.now < max_time:
                self.env.run(until=self.env.now + 1)

                if self.system_empty():
                    break

        else:
            self.env.run(until=self.slots)

        return self.finalize()

#Funcion para lanzar el modelo completo, con la variable use_cms se puede elegir lanzar el modelo con CMS o sin CMS

def run_parallel_cms_cache_pipeline(
    slots: Optional[int] = None,
    n_frames: Optional[int] = None,

    p_arrivals: Tuple[float, float, float] = (1.0, 1.0, 1.0),
    tdma_weights: Tuple[int, int, int] = (1, 1, 1),

    fifo_cap: int = 64,
    cache_fifo_cap: int = 64,

    mac_cap: int = 16384,
    mac_space: int = 50_000,
    write_cycles: int = 4,
    full_policy: str = "evict_lru",
    seed: int = 0,

    bitrate_bps: int = 1_000_000_000,
    packet_size_bytes: int = 64,
    clk_freq_hz: int = 100_000_000,
    alpha: float = 0.6,
    trace_macs: Optional[Sequence[int]] = None,
    trace_port: int = 1,

    recent_cache_size: int = 4096,

    freq_pair_threshold: int = 5,

    use_cms: bool = True,
    cms_d: int = 4,
    cms_w: int = 2048,
    cms_counter_bits: int = 8,
    cms_threshold: int = 2,
    cms_cache_admission_fill_threshold: float = 0.90,
    cms_aging_period: int = 0,

    mac_cuckoo_table_count: int = 4,
    cache_cuckoo_table_count: int = 4,
    cuckoo_bin_size: int = 1,
    mac_cuckoo_max_loop: int = 5,
    cache_cuckoo_max_loop: int = 8,

    port_width: int = 8,
    cache_lookup_latency_cycles: int = 4,

    first_write_cycles: int = 5,
    next_write_cycles: int = 4,
    cache_first_write_cycles: int = 5,
    cache_next_write_cycles: int = 4,
    mac_fifo_prefetch_cycles: int = 1,
    cache_fifo_prefetch_cycles: int = 2,
    drain_cycles: int = 10000,
) -> Stats:

    if slots is None and n_frames is None:
        raise ValueError("Debes indicar slots o n_frames")

    sim = PipelineSimPyModel(
        slots=slots,
        n_frames=n_frames,
        p_arrivals=p_arrivals,
        tdma_weights=tdma_weights,
        fifo_cap=fifo_cap,
        cache_fifo_cap=cache_fifo_cap,
        mac_cap=mac_cap,
        mac_space=mac_space,
        write_cycles=write_cycles,
        full_policy=full_policy,
        seed=seed,
        bitrate_bps=bitrate_bps,
        packet_size_bytes=packet_size_bytes,
        clk_freq_hz=clk_freq_hz,
        alpha=alpha,
        trace_macs=trace_macs,
        trace_port=trace_port,
        recent_cache_size=recent_cache_size,
        freq_pair_threshold=freq_pair_threshold,
        use_cms=use_cms,
        cms_d=cms_d,
        cms_w=cms_w,
        cms_counter_bits=cms_counter_bits,
        cms_threshold=cms_threshold,
        cms_cache_admission_fill_threshold=cms_cache_admission_fill_threshold,
        cms_aging_period=cms_aging_period,
        mac_cuckoo_table_count=mac_cuckoo_table_count,
        cache_cuckoo_table_count=cache_cuckoo_table_count,
        cuckoo_bin_size=cuckoo_bin_size,
        mac_cuckoo_max_loop=mac_cuckoo_max_loop,
        cache_cuckoo_max_loop=cache_cuckoo_max_loop,
        port_width=port_width,
        cache_lookup_latency_cycles=cache_lookup_latency_cycles,
        first_write_cycles=first_write_cycles,
        next_write_cycles=next_write_cycles,
        cache_first_write_cycles=cache_first_write_cycles,
        cache_next_write_cycles=cache_next_write_cycles,
        mac_fifo_prefetch_cycles=mac_fifo_prefetch_cycles,
        cache_fifo_prefetch_cycles=cache_fifo_prefetch_cycles,
        drain_cycles=drain_cycles,
    )

    return sim.run()


def run_parallel_cache_pipeline(**kwargs) -> Stats:
    return run_parallel_cms_cache_pipeline(use_cms=False, **kwargs)


def run_parallel_cms_plus_cache_pipeline(**kwargs) -> Stats:
    return run_parallel_cms_cache_pipeline(use_cms=True, **kwargs)


def print_stats(name: str, st: Stats) -> None:
    print(f"\n{name}")
    print("-" * len(name))

    print(f"slots                       : {st.slots}")
    print(f"requested_frames            : {st.requested_frames}")
    print(f"offered                     : {st.offered}")

    print(f"mac_enqueued                : {st.mac_enqueued}")
    print(f"mac_dropped_fifo            : {st.mac_dropped_fifo}")
    print(f"written                     : {st.written}")

    print(f"throughput/slot             : {st.throughput_per_slot:.6f}")
    print(f"offered/slot                : {st.offered_per_slot:.6f}")

    print(f"mac_fifo_avg_occ            : {st.fifo_avg_occ:.3f}")
    print(f"mac_fifo_max_occ            : {st.fifo_max_occ}")

    print(f"cache_fifo_avg_occ          : {st.cache_fifo_avg_occ:.3f}")
    print(f"cache_fifo_max_occ          : {st.cache_fifo_max_occ}")

    print(f"cache_hits                  : {st.cache_hits}")
    print(f"cache_misses                : {st.cache_misses}")
    print(f"suppressed                  : {st.suppressed}")
    print(f"dropped_tlfu                : {st.dropped_tlfu}")
    print(f"passed_tlfu                 : {st.passed_tlfu}")
    print(f"cms_updates                 : {st.cms_updates}")
    print(f"cms_aging_events            : {st.cms_aging_events}")

    print(f"cache_write_attempts        : {st.cache_write_attempts}")
    print(f"cache_write_enqueued        : {st.cache_write_enqueued}")
    print(f"cache_write_dropped_fifo    : {st.cache_write_dropped_fifo}")
    print(f"cache_write_success         : {st.cache_write_success}")
    print(f"cache_write_failed          : {st.cache_write_failed}")
    print(f"cache_write_repeated        : {st.cache_write_repeated}")
    print(f"cache_write_unlearned       : {st.cache_write_unlearned}")
    print(f"cache_write_efficiency      : {st.cache_write_efficiency * 100:.2f}%")

    print(f"cache_write_cycles_total    : {st.cache_write_cycles_total}")
    print(f"cache_write_cycles_avg      : {st.cache_write_cycles_avg:.2f}")
    print(f"cache_write_cycles_max      : {st.cache_write_cycles_max}")

    print(f"mac_write_attempts          : {st.mac_write_attempts}")
    print(f"mac_write_success           : {st.mac_write_success}")
    print(f"mac_write_failed            : {st.mac_write_failed}")
    print(f"mac_write_repeated          : {st.mac_write_repeated}")
    print(f"mac_write_unlearned         : {st.mac_write_unlearned}")
    print(f"write_efficiency            : {st.write_efficiency * 100:.2f}%")

    print(f"mac_write_cycles_total      : {st.mac_write_cycles_total}")
    print(f"mac_write_cycles_avg        : {st.mac_write_cycles_avg:.2f}")
    print(f"mac_write_cycles_max        : {st.mac_write_cycles_max}")

    print(f"mac_utilization             : {st.mac_utilization:.2f}%")
    print(f"mac_utilization_entries     : {st.mac_utilization_entries}")

    print(f"cache_utilization           : {st.cache_utilization:.2f}%")
    print(f"cache_utilization_entries   : {st.cache_utilization_entries}")

    print(f"unique_src_seen             : {st.unique_src_seen}")
    print(f"unique_src_written          : {st.unique_src_written}")
    print(f"learning_ratio_src          : {st.learning_ratio_src:.6f}")

    print(f"unique_cache_writes         : {st.unique_cache_writes}")
    print(f"cache_write_eff_unique      : {st.cache_write_efficiency_unique * 100:.2f}%")

    print(f"frequent_src_seen           : {st.frequent_src_seen}")
    print(f"frequent_src_written        : {st.frequent_src_written}")
    print(f"learning_ratio_freq_src     : {st.learning_ratio_freq_src:.6f}")
    print(f"frequent_write_events       : {st.frequent_write_events}")
    print(f"write_efficiency_freq       : {st.write_efficiency_freq:.6f}")

    print(f"stage0_queries_issued       : {st.stage0_queries_issued}")
    print(f"stage1_latency_passes       : {st.stage1_latency_passes}")
    print(f"stage2_latency_passes       : {st.stage2_latency_passes}")
    print(f"stage3_latency_passes       : {st.stage3_latency_passes}")
    print(f"stage4_mac_admits           : {st.stage4_mac_admits}")
    print(f"stage5_cache_decisions      : {st.stage5_cache_decisions}")
