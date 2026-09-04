import math
import random
import logging

import mmh3
import cityhash
import xxhash
import siphash

from cocotb.triggers import RisingEdge

# LFSR hash functions parameters
lfsr_width=32
lfsr_poly=[0x04c11db7, 0xedb88320, 0x1dca6d1f, 0xc8f698af, 0xa581de0f, 
           0x01f960ef, 0x27673637, 0x66715bad, 0x03afce8f, 
           0x5a0849e7, 0x28ba08bb, 0x3b328ffb, 0x46000001,
           0x0e92c2cd, 0x1c46e3df, 0x18e8dda9, 0x1dfa979b,
           0x000000af, 0x0e838e4d, 0x0b72ac3b, 0x50d7c9b7]
lfsr_config="GALOIS"
lfsr_feed_forward=0
reverse=1
state_in=0xffffffff


siphash_key = b"0123456789ABCDEF"


def fnv1a_32(data: bytes) -> int:
    h = 2166136261
    for byte in data:
        h ^= byte
        h = (h * 16777619) & 0xFFFFFFFF
    return h


soft_hash_func = {
    0: lambda key: mmh3.hash(key, signed=False),
    1: lambda key: cityhash.CityHash32(key),
    2: lambda key: xxhash.xxh32(key).intdigest(),
    3: lambda key: siphash.SipHash_2_4(siphash_key, key).hash(),
    4: lambda key: fnv1a_32(key),
}


async def wait_cycles(clk, n):
    for _ in range(n):
        await RisingEdge(clk)


class HashTableSoftware():
    def __init__(self, key_width=48, cell_count=1024, bin_size=1, func_index=0):
        
        self.hash = soft_hash_func[func_index]
        
        self.key_width = key_width
        self.cell_count = cell_count
        self.bin_size = bin_size

        # depth of the table
        self.depth = int(cell_count/bin_size)
        self.depth_power = (self.depth & (self.depth-1)) == 0

        # address width (number of bits needed to index the table)
        self.address_width = math.ceil(math.log(self.depth, 2))
        # mask to apply to hash result to obtain address for indexing the table
        self.address_mask = 2**self.address_width-1
        
        # each table entry is a list of bin_size tuples: [key, active]
        self.table = [[[0, False] for y in range(self.bin_size)] for x in range(self.depth)]
        # counter of cells used
        self.word_count = 0

        # set logger
        self.log = logging.getLogger(f'hash.CuckooHashTable.HashTableSoftware')
        self.log.info(f'Parallel hash table using software functions hash function')
        self.log.info(f"  Number of cells: {self.cell_count}")
        self.log.info(f"  Number of buckets per entry: {self.bin_size}")
        self.log.info(f"  Number of entries: {self.depth}")
        self.log.info(f"  Entry width: {self.key_width} bits")
        self.log.info(f"  Address width: {self.address_width} bits")
        
    def get_address(self, key):
        # get hash index for table
        state_out = self.hash(key.to_bytes(length=int(self.key_width/8), byteorder='little'))
        # select bits based on table depth
        if self.depth_power:
            address = state_out & self.address_mask
        else:
            address = state_out % self.depth

        return address

    def read(self, key):
        # obtain address
        address = self.get_address(key)
        # retrieve entry using masked address
        table_tuple_list = self.table[address]
        
        return table_tuple_list
    
    def lookup(self, key):
        # read table entry
        table_tuple_list = self.read(key)
        # check read tuples are active and stored key is the same as the used key
        for tuple in table_tuple_list:
            if tuple[0] == key and tuple[1]:
                return True

        return False
    
    def check(self, key):
        """ Check if all tuples in the entry are occupied (true) """
        # read table entry
        table_tuple_list = self.read(key)
        # check read tuples are active
        for tuple in table_tuple_list:
            if not tuple[1]:
                return False

        return True

    def delete(self, key):
        # obtain address
        address = self.get_address(key)
        # read table entry
        table_tuple_list = self.table[address]
        # check read tuples to forget matching active association and decrease counter
        for tuple, i in zip(table_tuple_list, range(self.bin_size)):
            if tuple[0] == key and tuple[1]:
                self.word_count -= 1
                self.table[address][i] = [0, False]
                return True
            
        return False

    def write(self, key, bin_index, effective=True):
        # obtain address
        address = self.get_address(key)
        # read table entry
        table_tuple_list = self.table[address]
        # check if any read tuple is inactive to write on it and increase counter
        for tuple, i in zip(table_tuple_list, range(self.bin_size)):
            if not tuple[1]:
                if effective:
                    self.word_count += 1
                    self.table[address][i] = [key, True]
                    # return replaced value (expected [0, False])
                    return tuple
                else:
                    return tuple

        # if none of the tuples was empty, randomly choose one tuple of the entry to write on it
        # if a bin index is specified as input parameter, use it
        if len(bin_index):
            tuple_index = random.choice(bin_index)
        else:
            tuple_index = random.randrange(0, self.bin_size)
        tuple = self.table[address][tuple_index]
        if effective:
            self.table[address][tuple_index] = [key, True]
        # return replaced value
        return tuple
    
    def get_utilization(self):            
        return 100*self.word_count/self.cell_count


class LFSRHash():
    """ LFSR module adapted from that of Alex Forencich from verilog-lfsr repository"""
    def __init__(self, lfsr_width, lfsr_poly, lfsr_config, lfsr_feed_forward, reverse, data_width):
        self.lfsr_width = lfsr_width
        self.lfsr_poly = lfsr_poly
        self.lfsr_config = lfsr_config
        self.lfsr_feed_forward = lfsr_feed_forward
        self.reverse = reverse
        self.data_width = data_width
        
        # get state and data mask
        self.mask = list()

        for n in range(lfsr_width+data_width):
            lfsr_mask_state = [0 for x in range(lfsr_width)]
            lfsr_mask_data = [0 for x in range(lfsr_width)]
            output_mask_state = [0 for x in range(data_width)]
            output_mask_data = [0 for x in range(data_width)]
            
            state_val = 0
            data_val = 0
        
            data_mask = 1 << (data_width - 1)
        
            # init bit masks
            for i in range(lfsr_width):
                lfsr_mask_state[i] = 1 << i
                lfsr_mask_data[i] = 0
        
            for i in range(data_width):
                output_mask_state[i] = 0
                if i < lfsr_width:
                    output_mask_state[i] = 1 << i
                output_mask_data[i] = 0
        
            if lfsr_config == "FIBONACCI":
                # Fibonacci configuration
                while data_mask != 0:
                    # determine shift in value
                    # current value in last FF, XOR with input data bit (MSB first)
                    state_val = lfsr_mask_state[lfsr_width-1]
                    data_val = lfsr_mask_data[lfsr_width-1]
                    data_val = data_val ^ data_mask
                    
                    # add XOR inputs from correct indices
                    for j in range(1, lfsr_width):
                        if (lfsr_poly >> j) & 1:
                            state_val = lfsr_mask_state[j-1] ^ state_val
                            data_val = lfsr_mask_data[j-1] ^ data_val
                    
                    # shift
                    for j in reversed(range(1, lfsr_width)):
                        lfsr_mask_state[j] = lfsr_mask_state[j-1]
                        lfsr_mask_data[j] = lfsr_mask_data[j-1]
                        
                    for j in reversed(range(1, data_width)):
                        output_mask_state[j] = output_mask_state[j-1]
                        output_mask_data[j] = output_mask_data[j-1]
                    
                    output_mask_state[0] = state_val
                    output_mask_data[0] = data_val
                    
                    if lfsr_feed_forward:
                        # only shift in new input data
                        state_val = 0
                        data_val = data_mask
                    
                    lfsr_mask_state[0] = state_val
                    lfsr_mask_data[0] = data_val
                    
                    data_mask = data_mask >> 1
            else:
                # Galois configuration
                while data_mask != 0:
                    # determine shift in value
                    # current value in last FF, XOR with input data bit (MSB first)
                    state_val = lfsr_mask_state[lfsr_width-1]
                    data_val = lfsr_mask_data[lfsr_width-1]
                    data_val = data_val ^ data_mask
        
                    # shift
                    for j in reversed(range(1, lfsr_width)):
                        lfsr_mask_state[j] = lfsr_mask_state[j-1]
                        lfsr_mask_data[j] = lfsr_mask_data[j-1]
                        
                    for j in reversed(range(1, data_width)):
                        output_mask_state[j] = output_mask_state[j-1]
                        output_mask_data[j] = output_mask_data[j-1]
                        
                    output_mask_state[0] = state_val
                    output_mask_data[0] = data_val
                    
                    if lfsr_feed_forward:
                        # only shift in new input data
                        state_val = 0
                        data_val = data_mask
                    
                    lfsr_mask_state[0] = state_val
                    lfsr_mask_data[0] = data_val
                    
                    # add XOR inputs from correct indices
                    for j in range(1, lfsr_width):
                        if (lfsr_poly >> j) & 1:
                            lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val
                            lfsr_mask_data[j] = lfsr_mask_data[j] ^ data_val
                    
                    data_mask = data_mask >> 1
        
            # reverse bits if selected
            if reverse:
                if n < lfsr_width:
                    state_val = '{:0{width}b}'.format(lfsr_mask_state[lfsr_width-n-1], width=lfsr_width)
                    state_val = int(state_val[::-1], 2)
                    data_val = '{:0{width}b}'.format(lfsr_mask_data[lfsr_width-n-1], width=data_width)
                    data_val = int(data_val[::-1], 2)
                else:
                    state_val = '{:0{width}b}'.format(output_mask_state[data_width-(n-lfsr_width)-1], width=lfsr_width)
                    state_val = int(state_val[::-1], 2)
                    data_val = '{:0{width}b}'.format(output_mask_data[data_width-(n-lfsr_width)-1], width=data_width)
                    data_val = int(data_val[::-1], 2)
            else:
                if n < lfsr_width:
                    state_val = lfsr_mask_state[n]
                    data_val = lfsr_mask_data[n]
                else:
                    state_val = output_mask_state[n-lfsr_width]
                    data_val = output_mask_data[n-lfsr_width]
                   
            self.mask.append(data_val << lfsr_width | state_val)
            
    def hash(self, key, state_in):
        state_out = 0
        data_out = 0
    
        for n in range(self.lfsr_width):
            state_n = ((key << self.lfsr_width | state_in) & self.mask[n])
            state_out = ((sum(map(int, format(state_n, "b"))) & 1) << n) | state_out
        
        for n in range(self.data_width):
            data_n = ((key << self.lfsr_width | state_in) & self.mask[n+self.lfsr_width])
            data_out = ((sum(map(int, format(data_n, "b"))) & 1) << n) | data_out
        
        return state_out, data_out


class HashTableLFSR(LFSRHash):
    def __init__(self, key_width=48, cell_count=1024, bin_size=1, lfsr_width=32, lfsr_poly=0x04c11db7, 
                 lfsr_config="GALOIS", lfsr_feed_forward=0, reverse=1, state_in=0xffffffff):
        
        super().__init__(lfsr_width, lfsr_poly, lfsr_config, lfsr_feed_forward, reverse, key_width)
        
        self.key_width = key_width
        self.cell_count = cell_count
        self.bin_size = bin_size

        # depth of the table
        self.depth = int(cell_count/bin_size)
        self.depth_power = (self.depth & (self.depth-1)) == 0

        self.state_in = state_in
        # address width (number of bits needed to index the table)
        self.address_width = math.ceil(math.log(self.depth, 2))
        # mask to apply to hash result to obtain address for indexing the table
        self.address_mask = 2**self.address_width-1
        
        # each table entry is a list of bin_size tuples: [key, active]
        self.table = [[[0, False] for y in range(self.bin_size)] for x in range(self.depth)]
        # counter of cells used
        self.word_count = 0

        # set logger
        self.log = logging.getLogger(f'hash.CuckooHashTable.HashTableLFSR')
        self.log.info(f'Parallel hash table using LFSR with {hex(lfsr_poly)} ponynomial as hash function')
        self.log.info(f"  Number of cells: {self.cell_count}")
        self.log.info(f"  Number of buckets per entry: {self.bin_size}")
        self.log.info(f"  Number of entries: {self.depth}")
        self.log.info(f"  Entry width: {self.key_width} bits")
        self.log.info(f"  Address width: {self.address_width} bits")
        
    def get_address(self, key):
        # get hash index for table
        state_out, data_out = self.hash(key, self.state_in)
        # select bits based on table depth
        if self.depth_power:
            address = state_out & self.address_mask
        else:
            address = state_out % self.depth

        return address

    def read(self, key):
        # obtain address
        address = self.get_address(key)
        # retrieve entry using masked address
        table_tuple_list = self.table[address]
        
        return table_tuple_list
    
    def lookup(self, key):
        # read table entry
        table_tuple_list = self.read(key)
        # check read tuples are active and stored key is the same as the used key
        for tuple in table_tuple_list:
            if tuple[0] == key and tuple[1]:
                return True

        return False
    
    def check(self, key):
        """ Check if all tuples in the entry are occupied (true) """
        # read table entry
        table_tuple_list = self.read(key)
        # check read tuples are active
        for tuple in table_tuple_list:
            if not tuple[1]:
                return False

        return True

    def delete(self, key):
        # obtain address
        address = self.get_address(key)
        # read table entry
        table_tuple_list = self.table[address]
        # check read tuples to forget matching active association and decrease counter
        for tuple, i in zip(table_tuple_list, range(self.bin_size)):
            if tuple[0] == key and tuple[1]:
                self.word_count -= 1
                self.table[address][i] = [0, False]
                return True
            
        return False

    def write(self, key, bin_index, effective=True):
        # obtain address
        address = self.get_address(key)
        # read table entry
        table_tuple_list = self.table[address]
        # check if any read tuple is inactive to write on it and increase counter
        for tuple, i in zip(table_tuple_list, range(self.bin_size)):
            if not tuple[1]:
                if effective:
                    self.word_count += 1
                    self.table[address][i] = [key, True]
                    # return replaced value (expected [0, False])
                    return tuple
                else:
                    return tuple

        # if none of the tuples was empty, randomly choose one tuple of the entry to write on it
        # if a bin index is specified as input parameter, use it
        if len(bin_index):
            tuple_index = random.choice(bin_index)
        else:
            tuple_index = random.randrange(0, self.bin_size)
        tuple = self.table[address][tuple_index]
        self.table[address][tuple_index] = [key, True]
        # return replaced value
        return tuple
    
    def get_utilization(self):            
        return 100*self.word_count/self.cell_count


class CuckooHashingTableParallel():
    def __init__(self, key_width=48, cell_count=1024, table_count=2, bin_size=1, max_loop=100, hash_type="LFSR", 
                 insertion_initial_filter=1, insertion_initial_strategy=0, insertion_reallocate_filter=1, insertion_reallocate_strategy=0, *args):
        self.key_width = key_width
        self.cell_count = cell_count
        self.table_count = table_count
        self.bin_size = bin_size
        self.max_loop = max_loop

        # depth of the global table
        self.depth = int(self.cell_count/self.bin_size)

        # number of cells of each parallel table
        self.table_cell_count = int(self.cell_count / self.table_count)

        # set logger
        self.log = logging.getLogger(f'hash.CuckooHashTable')
        self.log.info(f"Cuckoo Hashing Table")
        self.log.info(f"  Number of cells: {self.cell_count}")
        self.log.info(f"  Number of parallel tables: {self.table_count}")
        self.log.info(f"  Number of buckets per entry: {self.bin_size}")
        self.log.info(f"  Number of entries: {self.depth}")
        self.log.info(f"  Entry width: {self.key_width} bits")
        self.log.info(f"  Maximum number of loops for insertion: {self.max_loop}")

        self.tables = []

        # parallel tables use LFSR as hash function
        if hash_type == "LFSR":
            for i in range(table_count):    
                self.tables.append(
                    HashTableLFSR(
                        key_width=key_width,
                        cell_count=self.table_cell_count,
                        bin_size=bin_size,
                        lfsr_width=lfsr_width,
                        lfsr_poly=lfsr_poly[i],
                        lfsr_config=lfsr_config,
                        lfsr_feed_forward=lfsr_feed_forward,
                        reverse=reverse,
                        state_in=state_in
                    )
                )
        elif hash_type == "SOFTWARE":
            for i in range(table_count):
                self.tables.append(
                    HashTableSoftware(
                        key_width=key_width,
                        cell_count=self.table_cell_count,
                        bin_size=bin_size,
                        func_index=i
                    )
                )

        self.insertion_initial_filter = insertion_initial_filter
        self.insertion_initial_strategy = insertion_initial_strategy
        self.insertion_reallocate_filter = insertion_reallocate_filter
        self.insertion_reallocate_strategy = insertion_reallocate_strategy

        self.start_last_table = self.table_count-1

    def lookup(self, key):
        for table, i in zip(self.tables, range(self.table_count)):
            if table.lookup(key):
                return i
        return None

    def insert(self, key, effective=True):
        # check if already in table (in any of the parallel tables)
        table_present = self.lookup(key)
        if table_present is not None:
            self.log.debug(f'Insertion error: key {key} already present in parallel table {table_present})')
            return False, 0
        # advance to insertion
        else:
            # get starting table
            start_table, bin_index = self.get_initial_table(key=key)
            self.start_last_table = start_table

            # initialize
            current_key = key

            # loop iterations
            table_index = start_table
            for i in range(self.max_loop):
                # get table
                table = self.tables[table_index]
                # write new value in that position and retrieve old content in that key
                table_tuple = table.write(current_key, bin_index=bin_index[table_index], effective=effective)
                # check if it was active
                if table_tuple[1]:
                    # prepare for writing old value to next table
                    self.log.debug(f'Insertion loop {i} with current key {current_key} and parallel table {table_index}')
                    current_key = table_tuple[0]
                else:
                    # if it was inactive, successful insertion
                    self.log.debug(f'Insertion successful: key {key} inserted in parallel table {table_index}')
                    return True, i, key
                
                # update with index for next table
                table_index, bin_index = self.get_next_table(table_index=table_index, key=current_key)
                
            self.log.error((f'Insertion error: key {current_key} unlearned'))

            return False, i, current_key

    async def insert_sync_cocotb(self, key, clk, effective=True, first_write_cycles=5, next_write_cycles=4):
        # check if already in table (in any of the parallel tables)
        table_present = self.lookup(key)
        if table_present is not None:
            self.log.debug(f'Insertion error: key {key} already present in parallel table {table_present})')
            await wait_cycles(clk, first_write_cycles)
            return False, 0, key, first_write_cycles

        # get starting table
        start_table, bin_index = self.get_initial_table(key=key)
        self.start_last_table = start_table

        # initialize
        current_key = key
        table_index = start_table
        total_write_cycles = 0

        # loop iterations
        for i in range(self.max_loop):
            # meter el retardo dentro del propio bucle de inserción
            if i == 0:
                await wait_cycles(clk, first_write_cycles)
                total_write_cycles += first_write_cycles
            else:
                await wait_cycles(clk, next_write_cycles)
                total_write_cycles += next_write_cycles

            # get table
            table = self.tables[table_index]

            # write new value in that position and retrieve old content in that key
            table_tuple = table.write(
                current_key,
                bin_index=bin_index[table_index],
                effective=effective
            )

            # check if it was active
            if table_tuple[1]:
                # prepare for writing old value to next table
                self.log.debug(f'Insertion loop {i} with current key {current_key} and parallel table {table_index}')
                current_key = table_tuple[0]
            else:
                # if it was inactive, successful insertion
                self.log.debug(f'Insertion successful: key {key} inserted in parallel table {table_index}')
                return True, i, key, total_write_cycles

            # update with index for next table
            table_index, bin_index = self.get_next_table(table_index=table_index, key=current_key)

        self.log.error((f'Insertion error: key {current_key} unlearned'))
        return False, i, current_key, total_write_cycles

    def get_initial_table(self, key):
        # filter tables
        tables_filtered = []
        bin_index = {i:[] for i in range(self.table_count)}

        if self.insertion_initial_filter == 0:
            # all tables are considered
            tables_filtered = [i for i in range(self.table_count)]
        else:
            # only tables with free locations are considered
            table_occupied = [table.check(key) for table in self.tables]
            tables_filtered = [i for i in range(self.table_count) if not table_occupied[i]]
            
            if not len(tables_filtered):
                # if all tables are occupied
                if self.insertion_initial_filter == 1:
                    # all tables are considered
                    tables_filtered = [i for i in range(self.table_count)]
                else:
                    # breadth first search
                    for i in range(self.table_count):
                        # read keys currently stored in that position in table i
                        table_tuple_list = self.tables[i].read(key)
                        for k in range(self.bin_size):
                            for j in range(self.table_count):
                                if i != j:
                                    # check if a key stored in table i has a free location in table j
                                    if self.tables[j].check(table_tuple_list[k][0]) is False:
                                        # table i is considered
                                        if i not in tables_filtered:
                                            tables_filtered.append(i)

                                        # add bins
                                        bin_index[i].append(k)

                    if not len(tables_filtered):
                        # if all tables are occupied, all tables are considered
                        tables_filtered = [i for i in range(self.table_count)]

        # apply selection strategy
        if self.insertion_initial_strategy == 0:
            return min(tables_filtered), bin_index

        elif self.insertion_initial_strategy == 1:
            return random.choice(tables_filtered), bin_index

        elif self.insertion_initial_strategy == 2:
            start_table = self.start_last_table + 1 if self.start_last_table < self.table_count-1 else 0

            for i in range(self.table_count):
                if start_table in tables_filtered:
                    return start_table, bin_index
                start_table = start_table + 1 if start_table < self.table_count-1 else 0
            return start_table, bin_index

        elif self.insertion_initial_strategy == 3:
            utilizations = [self.tables[i].get_utilization() for i in tables_filtered]
            return tables_filtered[min(range(len(utilizations)), key=utilizations.__getitem__)], bin_index

    def get_next_table(self, table_index, key):
        # filter tables
        tables_filtered = []
        bin_index = {i:[] for i in range(self.table_count)}

        if self.insertion_reallocate_filter == 0:
            # all tables are considered
            tables_filtered = [i for i in range(self.table_count) if i != table_index]
        else:
            # only tables with free locations are considered
            table_occupied = [table.check(key) for table in self.tables]
            tables_filtered = [i for i in range(self.table_count) if not table_occupied[i] and i != table_index]
            
            if not len(tables_filtered):
                # if all tables are occupied
                if self.insertion_reallocate_filter == 1:
                    # all tables are considered
                    tables_filtered = [i for i in range(self.table_count) if i != table_index]
                else:
                    # breadth first search
                    for i in range(self.table_count):
                        # read keys currently stored in that position in table i
                        table_tuple_list = self.tables[i].read(key)
                        for k in range(self.bin_size):
                            for j in range(self.table_count):
                                if i != j:
                                    # check if a key stored in table i has a free location in table j
                                    if self.tables[j].check(table_tuple_list[k][0]) is False:
                                        # table i is considered
                                        if i not in tables_filtered:
                                            tables_filtered.append(i)

                                        # add bins
                                        bin_index[i].append(k)

                    if not len(tables_filtered):
                        # if all tables are occupied, all tables are considered
                        tables_filtered = [i for i in range(self.table_count) if i != table_index]

        # apply selection strategy
        if self.insertion_reallocate_filter == 0 or tables_filtered == [i for i in range(self.table_count) if i != table_index]:
            if table_index < self.table_count-1:
                return table_index + 1, bin_index 
            else:
                return 0, bin_index

        elif self.insertion_reallocate_strategy == 0:
            return min(tables_filtered), bin_index

        elif self.insertion_reallocate_strategy == 1:
            return random.choice(tables_filtered), bin_index

        elif self.insertion_reallocate_strategy == 2:
            next_table = table_index + 1 if table_index < self.table_count-1 else 0

            for i in range(self.table_count):
                if next_table in tables_filtered:
                    return next_table, bin_index
                next_table = next_table + 1 if next_table < self.table_count-1 else 0
            return next_table, bin_index

        elif self.insertion_reallocate_strategy == 3:
            utilizations = [self.tables[i].get_utilization() for i in tables_filtered]
            return tables_filtered[min(range(len(utilizations)), key=utilizations.__getitem__)], bin_index

    def delete(self, key):
        # check if already in table
        table_present = self.lookup(key)
        if table_present is not None:
            self.tables[table_present].delete(key)
            self.log.debug(f'Deletion successful: deleted key {key} was present in parallel table {table_present}')
            return True
        else:
            self.log.debug(f'Deletion error: key {key} is not present in table')
            return False

    def print_utilization(self):
        word_count = []
        for table in self.tables:
            word_count.append(table.word_count)
            
        print(f'Table: {sum(word_count)} entries occupied, {100*sum(word_count)/self.cell_count}% utilization')

        for i in range(self.table_count):
            print(f'\tTable {i}: {word_count[i]} entries occupied, {100*word_count[i]/self.table_cell_count}% utilization')

    def get_parallel_utilization(self):
        utilizations = []
        for table in self.tables:
            utilizations.append(table.get_utilization())
        return utilizations

    def get_parallel_utilization_entries(self):
        word_count = []
        for table in self.tables:
            word_count.append(table.word_count)
        return word_count

    def get_utilization_entries(self):
        word_count = []
        for table in self.tables:
            word_count.append(table.word_count)
        return sum(word_count)

    def get_utilization(self):
        word_count = []
        for table in self.tables:
            word_count.append(table.word_count)
        return 100*sum(word_count)/self.cell_count
