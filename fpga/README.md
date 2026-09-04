# FPGA

Contiene la integracion del modulo HDL en el entorno de pruebas de la FPGA.

Carpeta `test_hardware/rtl`:

    Modulos de control y modulos desarrollados:
    cache_core.v : nucleo de pruebas para cargar trazas y leer metricas
    fpga.v : modulo superior que conecta el test con UART/XFCP y AXI-Lite
    modulo_hdl_cache.v : modulo HDL caché

    Modulos auxiliares instanciados proporcionados por Carlos Megías:
    hash_table.v : tabla hash instanciada por el modulo HDL
    lfsr.v : modulo auxiliar utilizado por la tabla hash
    priority_encoder.v : modulo auxiliar utilizado por la tabla hash
    switch_simple_fifo.v : cola FIFO utilizada por el modulo HDL
    sync_signal.v : sincronizador de señales de entrada


    Modulos proporcionados por Carlos Megías para la implementacion en la FPGA: 
    fpga.v : : modulo superior que conecta el test con UART/XFCP y AXI-Lite
    sync_signal.v : sincronizador de señales de entrada
    fpga_core.v : modulo original a partir del cual se ha desarrollado cache_core.v para adaptar fpga_core al modulo HDL caché



Carpeta `test_hardware/scripts`:
    load_trace_and_run.py : carga una traza y ejecuta una prueba
    run_fpga_sweep.py : ejecuta el barrido completo en la FPGA

Carpeta `test_hardware/fpga`:
    Makefile : genera el bitstream y permite programar la placa
    config.tcl : define los parametros del proyecto
    fpga.xdc : define las restricciones de la placa
    generate_bit.tcl : genera el bitstream desde Vivado
    program_hw.tcl : programa la FPGA con el bitstream generado


