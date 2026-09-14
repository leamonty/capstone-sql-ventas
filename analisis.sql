-- ============================================================================
-- PROYECTO CAPSTONE: ANALISIS EXPLORATORIO DE UNA TIENDA LATINOAMERICANA
-- Archivo: analisis.sql
-- Base esperada: capstone_project
-- ============================================================================
-- Criterio de negocio utilizado en todo el analisis:
--   * "Completado" y "Enviado" representan ventas realizadas.
--   * "Cancelado" no genera ingreso.
--   * "En proceso" todavia no se considera ingreso confirmado.
-- Este criterio evita mezclar facturacion realizada con demanda no concretada.

SET search_path TO public;


-- ============================================================================
-- 1. DIAGNOSTICO Y LIMPIEZA PREVIA
-- ============================================================================

-- 1.1 Control de volumen.
-- Sirve para detectar cargas incompletas antes de confiar en cualquier KPI.
SELECT 'paises' AS tabla, COUNT(*) AS filas FROM paises
UNION ALL SELECT 'categorias', COUNT(*) FROM categorias
UNION ALL SELECT 'tipos_cliente', COUNT(*) FROM tipos_cliente
UNION ALL SELECT 'sucursales', COUNT(*) FROM sucursales
UNION ALL SELECT 'empleados', COUNT(*) FROM empleados
UNION ALL SELECT 'clientes', COUNT(*) FROM clientes
UNION ALL SELECT 'productos', COUNT(*) FROM productos
UNION ALL SELECT 'pedidos', COUNT(*) FROM pedidos
UNION ALL SELECT 'detalle_pedidos', COUNT(*) FROM detalle_pedidos;

-- 1.2 Nulos en campos criticos.
-- Antes de sumar ventas se comprueba que fechas, precios, cantidades y totales
-- no esten ausentes. El dataset entregado debe devolver cero en todos los casos.
SELECT
    COUNT(*) FILTER (WHERE pe.fecha_pedido IS NULL) AS pedidos_sin_fecha,
    COUNT(*) FILTER (WHERE pe.total IS NULL) AS pedidos_sin_total
FROM pedidos AS pe;

SELECT
    COUNT(*) FILTER (WHERE pr.precio IS NULL) AS productos_sin_precio,
    COUNT(*) FILTER (WHERE pr.stock IS NULL) AS productos_sin_stock
FROM productos AS pr;

SELECT
    COUNT(*) FILTER (WHERE dp.precio_unitario IS NULL) AS detalles_sin_precio,
    COUNT(*) FILTER (WHERE dp.cantidad IS NULL) AS detalles_sin_cantidad,
    COUNT(*) FILTER (WHERE dp.subtotal IS NULL) AS detalles_sin_subtotal
FROM detalle_pedidos AS dp;

-- 1.3 Verificacion de tipos DATE/TIMESTAMP y NUMERIC/DECIMAL.
-- Esta consulta revisa el catalogo de PostgreSQL; permite demostrar que los
-- campos analiticos no fueron importados accidentalmente como texto.
SELECT
    table_name,
    column_name,
    data_type,
    numeric_precision,
    numeric_scale
FROM information_schema.columns
WHERE table_schema = 'public'
  AND (
       (table_name = 'empleados' AND column_name = 'fecha_ingreso')
    OR (table_name = 'clientes' AND column_name = 'fecha_registro')
    OR (table_name = 'productos' AND column_name = 'precio')
    OR (table_name = 'pedidos' AND column_name IN ('fecha_pedido', 'total'))
    OR (table_name = 'detalle_pedidos'
        AND column_name IN ('precio_unitario', 'subtotal'))
  )
ORDER BY table_name, column_name;

-- 1.4 Integridad del total del pedido.
-- Se compara el total de cabecera con la suma de sus lineas. Una diferencia
-- mayor a un centavo indicaria un pedido que requiere revision contable.
WITH totales_detalle AS (
    SELECT
        dp.pedido_id,
        SUM(dp.subtotal) AS total_calculado
    FROM detalle_pedidos AS dp
    GROUP BY dp.pedido_id
)
SELECT
    COUNT(*) FILTER (
        WHERE ABS(pe.total - COALESCE(td.total_calculado, 0::NUMERIC)) > 0.01
    ) AS pedidos_con_diferencias,
    MAX(ABS(pe.total - COALESCE(td.total_calculado, 0::NUMERIC)))
        AS diferencia_maxima
FROM pedidos AS pe
LEFT JOIN totales_detalle AS td
    ON td.pedido_id = pe.pedido_id;

-- 1.5 Capa analitica limpia.
-- No se reemplazan datos validos de la fuente. COALESCE define reglas defensivas
-- para futuras cargas: usa el precio de catalogo si falta el precio de venta,
-- la fecha de registro si faltara la fecha del pedido y cero para medidas de un
-- LEFT JOIN sin coincidencia. Tambien etiqueta ventas sin empleado asignado.
CREATE OR REPLACE VIEW vw_ventas_limpias AS
SELECT
    pe.pedido_id,
    COALESCE(pe.fecha_pedido, cl.fecha_registro::TIMESTAMP) AS fecha_venta,
    pe.estado,
    pe.total AS total_pedido,
    cl.cliente_id,
    CONCAT_WS(' ', cl.nombre, cl.apellido) AS cliente,
    su.sucursal_id,
    su.nombre_sucursal,
    COALESCE(
        NULLIF(TRIM(CONCAT_WS(' ', em.nombre, em.apellido)), ''),
        'Sin empleado asignado'
    ) AS empleado,
    pr.producto_id,
    pr.codigo_producto,
    pr.nombre_producto,
    ca.categoria_id,
    ca.nombre_categoria,
    COALESCE(dp.cantidad, 0)::INTEGER AS cantidad_limpia,
    COALESCE(dp.precio_unitario, pr.precio, 0::NUMERIC)::NUMERIC(10, 2)
        AS precio_unitario_limpio,
    COALESCE(
        dp.subtotal,
        dp.cantidad * COALESCE(dp.precio_unitario, pr.precio),
        0::NUMERIC
    )::NUMERIC(12, 2) AS importe_linea,
    COALESCE(pr.stock, 0)::INTEGER AS stock_limpio
FROM pedidos AS pe
JOIN clientes AS cl
    ON cl.cliente_id = pe.cliente_id
JOIN sucursales AS su
    ON su.sucursal_id = pe.sucursal_id
LEFT JOIN empleados AS em
    ON em.empleado_id = pe.empleado_id
JOIN detalle_pedidos AS dp
    ON dp.pedido_id = pe.pedido_id
JOIN productos AS pr
    ON pr.producto_id = dp.producto_id
JOIN categorias AS ca
    ON ca.categoria_id = pr.categoria_id;

COMMENT ON VIEW vw_ventas_limpias IS
    'Detalle de ventas con reglas defensivas de COALESCE para el analisis Capstone';

-- Control posterior: la vista debe contener 597 lineas y no debe producir
-- fechas, precios ni importes nulos.
SELECT
    COUNT(*) AS filas_vista,
    COUNT(*) FILTER (WHERE fecha_venta IS NULL) AS fechas_nulas,
    COUNT(*) FILTER (WHERE precio_unitario_limpio IS NULL) AS precios_nulos,
    COUNT(*) FILTER (WHERE importe_linea IS NULL) AS importes_nulos
FROM vw_ventas_limpias;

-- ============================================================================
-- 2. PREGUNTAS DE NEGOCIO
-- ============================================================================

-- PREGUNTA 1 (requerida): ¿quienes son los 5 clientes con mayor gasto total?
-- El ranking identifica el segmento de mayor valor para acciones de fidelizacion.
-- Se excluyen cancelados y pedidos en proceso para no sobreestimar el ingreso.
SELECT
    cl.cliente_id,
    CONCAT_WS(' ', cl.nombre, cl.apellido) AS cliente,
    COUNT(pe.pedido_id) AS pedidos_realizados,
    ROUND(COALESCE(SUM(pe.total), 0::NUMERIC), 2) AS gasto_total,
    ROUND(COALESCE(AVG(pe.total), 0::NUMERIC), 2) AS ticket_promedio
FROM clientes AS cl
JOIN pedidos AS pe
    ON pe.cliente_id = cl.cliente_id
WHERE pe.estado IN ('Completado', 'Enviado')
GROUP BY cl.cliente_id, cl.nombre, cl.apellido
ORDER BY gasto_total DESC, cl.cliente_id
LIMIT 5;

-- PREGUNTA 2 (requerida): ¿como evolucionan las ventas totales por mes?
-- DATE_TRUNC normaliza todas las fechas al primer dia del mes. LAG agrega una
-- comparacion contra el mes anterior para distinguir crecimiento y contraccion.
WITH ventas_mensuales AS (
    SELECT
        DATE_TRUNC('month', pe.fecha_pedido)::DATE AS mes,
        COUNT(*) AS pedidos_realizados,
        SUM(pe.total) AS ventas_totales
    FROM pedidos AS pe
    WHERE pe.estado IN ('Completado', 'Enviado')
    GROUP BY DATE_TRUNC('month', pe.fecha_pedido)::DATE
),
comparacion AS (
    SELECT
        vm.*,
        LAG(vm.ventas_totales) OVER (ORDER BY vm.mes) AS ventas_mes_anterior
    FROM ventas_mensuales AS vm
)
SELECT
    TO_CHAR(c.mes, 'YYYY-MM') AS mes,
    c.pedidos_realizados,
    ROUND(c.ventas_totales, 2) AS ventas_totales,
    ROUND(c.ventas_mes_anterior, 2) AS ventas_mes_anterior,
    ROUND(
        CASE
            WHEN c.ventas_mes_anterior IS NULL OR c.ventas_mes_anterior = 0
                THEN NULL
            ELSE
                (c.ventas_totales - c.ventas_mes_anterior)
                / c.ventas_mes_anterior * 100
        END,
        2
    ) AS variacion_mensual_pct
FROM comparacion AS c
ORDER BY c.mes;

-- PREGUNTA 3 (requerida): ¿cuales son los 3 productos menos vendidos?
-- Los LEFT JOIN conservan productos sin ventas. COALESCE transforma la ausencia
-- de movimientos en cero, algo esencial para detectar inventario inmovilizado.
SELECT
    pr.producto_id,
    pr.codigo_producto,
    pr.nombre_producto,
    ca.nombre_categoria,
    COALESCE(
        SUM(dp.cantidad) FILTER (
            WHERE pe.estado IN ('Completado', 'Enviado')
        ),
        0
    ) AS unidades_vendidas,
    ROUND(
        COALESCE(
            SUM(dp.subtotal) FILTER (
                WHERE pe.estado IN ('Completado', 'Enviado')
            ),
            0::NUMERIC
        ),
        2
    ) AS ingreso_generado
FROM productos AS pr
JOIN categorias AS ca
    ON ca.categoria_id = pr.categoria_id
LEFT JOIN detalle_pedidos AS dp
    ON dp.producto_id = pr.producto_id
LEFT JOIN pedidos AS pe
    ON pe.pedido_id = dp.pedido_id
GROUP BY
    pr.producto_id,
    pr.codigo_producto,
    pr.nombre_producto,
    ca.nombre_categoria
ORDER BY unidades_vendidas ASC, ingreso_generado ASC, pr.producto_id
LIMIT 3;

-- PREGUNTA 4 (requerida): ¿que pedidos lideran el ingreso dentro de cada
-- categoria? Se calcula el importe aportado por cada pedido a cada categoria y
-- RANK() lo compara solo con pedidos de esa misma categoria. Se muestran los
-- tres primeros puestos; los empates reciben la misma posicion.
WITH venta_pedido_categoria AS (
    SELECT
        vl.categoria_id,
        vl.nombre_categoria,
        vl.pedido_id,
        MIN(vl.fecha_venta)::DATE AS fecha_pedido,
        MIN(vl.cliente) AS cliente,
        SUM(vl.importe_linea) AS venta_en_categoria
    FROM vw_ventas_limpias AS vl
    WHERE vl.estado IN ('Completado', 'Enviado')
    GROUP BY
        vl.categoria_id,
        vl.nombre_categoria,
        vl.pedido_id
),
ranking AS (
    SELECT
        vpc.*,
        RANK() OVER (
            PARTITION BY vpc.categoria_id
            ORDER BY vpc.venta_en_categoria DESC
        ) AS posicion_categoria
    FROM venta_pedido_categoria AS vpc
)
SELECT
    r.nombre_categoria,
    r.posicion_categoria,
    r.pedido_id,
    r.fecha_pedido,
    r.cliente,
    ROUND(r.venta_en_categoria, 2) AS venta_en_categoria
FROM ranking AS r
WHERE r.posicion_categoria <= 3
ORDER BY r.nombre_categoria, r.posicion_categoria, r.pedido_id;

-- PREGUNTA 5 (adicional): ¿que sucursales generan mas ventas?
-- Esta vista compara facturacion, volumen, alcance de clientes y ticket promedio.
-- Permite detectar sucursales referentes y otras que necesitan un plan comercial.
SELECT
    su.sucursal_id,
    su.nombre_sucursal,
    su.ciudad,
    COUNT(pe.pedido_id) AS pedidos_realizados,
    COUNT(DISTINCT pe.cliente_id) AS clientes_atendidos,
    ROUND(SUM(pe.total), 2) AS ventas_totales,
    ROUND(AVG(pe.total), 2) AS ticket_promedio
FROM sucursales AS su
JOIN pedidos AS pe
    ON pe.sucursal_id = su.sucursal_id
WHERE pe.estado IN ('Completado', 'Enviado')
GROUP BY su.sucursal_id, su.nombre_sucursal, su.ciudad
ORDER BY ventas_totales DESC, su.sucursal_id;

-- ============================================================================
-- 3. CONTROL GERENCIAL COMPLEMENTARIO
-- ============================================================================

-- La distribucion por estado cuantifica cuanto dinero ya es venta, cuanto sigue
-- en proceso y cuanto se perdio por cancelaciones. CASE traduce estados tecnicos
-- a una lectura ejecutiva y agrega otra funcion avanzada al proyecto.
SELECT
    CASE
        WHEN pe.estado IN ('Completado', 'Enviado') THEN 'Venta realizada'
        WHEN pe.estado = 'En proceso' THEN 'Pendiente'
        WHEN pe.estado = 'Cancelado' THEN 'Venta perdida'
        ELSE 'Estado no clasificado'
    END AS situacion_comercial,
    COUNT(*) AS cantidad_pedidos,
    ROUND(SUM(pe.total), 2) AS importe_asociado,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS porcentaje_pedidos
FROM pedidos AS pe
GROUP BY
    CASE
        WHEN pe.estado IN ('Completado', 'Enviado') THEN 'Venta realizada'
        WHEN pe.estado = 'En proceso' THEN 'Pendiente'
        WHEN pe.estado = 'Cancelado' THEN 'Venta perdida'
        ELSE 'Estado no clasificado'
    END
ORDER BY cantidad_pedidos DESC;

SELECT * FROM paises;
SELECT * FROM categorias;


-- Revision opcional del plan de ejecucion. Se deja comentada porque ANALYZE
-- ejecuta la consulta y su salida depende del entorno y del volumen disponible.
-- EXPLAIN (ANALYZE, BUFFERS)
-- SELECT pe.cliente_id, SUM(pe.total)
-- FROM pedidos AS pe
-- WHERE pe.estado IN ('Completado', 'Enviado')
-- GROUP BY pe.cliente_id
-- ORDER BY SUM(pe.total) DESC
-- LIMIT 5;
