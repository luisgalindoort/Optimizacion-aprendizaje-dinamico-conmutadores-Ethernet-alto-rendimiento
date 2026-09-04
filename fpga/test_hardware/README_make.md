# Explicación de los make


Todo se tiene que ejecutar desde este directorio.

Generar el bitstream:

    make

Generar el bitstream y cargarlo en la placa:

    make program

Cargar en la placa un bitstream ya generado:

    make program-only


Ejecutar una prueba con una traza concreta ejemplo : 

    make run TRACE=../trazas_macs_posibles_metricas_hdl/trace_alpha_0p7_macspace_10000_frames_30000.csv


Ejecutar el barrido completo de trazas:

    make sweep

El barrido guarda los resultados en:

resultados_fpga_macs_posibles.csv
