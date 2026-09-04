# Proyecto final

Esta carpeta contiene la version final del codigo utilizado en el trabajo. Se
han dejado los modelos y los scripts necesarios para ejecutar los test y obtener las distintas metricas presentadas en la memoria.

Se ha creado una carpeta para cada etapa del modelado.

- Python: modelo funcional en Python. Incluye el modelo base, el modelo con cache y el modelo CMS+cache.
- HDL: incluye el modelo con cache y el modelo sin cache, dos scripts de runner que lanzan los test, el test principal que ejecuta la simulacion, y dos scripts de barrido (barrido de MACS y transitorio) para lanzar los test completos que se incluyen en la memoria.
- FPGA: entorno de pruebas para generar el bitstream y reportes de Vivado, distintos modulos utilizados y los scripts para cargar las trazas y realizar los test.
