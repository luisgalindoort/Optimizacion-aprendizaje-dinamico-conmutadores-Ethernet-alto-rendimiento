# HDL

Contiene la version HDL completa del modulo de aprendizaje.

Módulos desarrollados: 
    modulo_hdl_cache.v
    modulo_hdl_sin_cache.v

Módulos instanciados proporcionados por Carlos Megías utilizados en el desarrollo del modulo principal:
    hash_table.v
    lfsr.v
    priority_encoder.v
    switch_simple_fifo.v

Test principales :
    barrido_macs_posibles_metricas_v2.py : genera el barrido de direcciones MAC posibles
    transitorio_metricas_hdl_v2.py : genera el transitorio temporal.

Script auxiliares para que funcionen los test principales : 
    Test_completo.py
    test_completo_sin_cache.py
    runner_v2.py
    runner_sin_cache_v2.py