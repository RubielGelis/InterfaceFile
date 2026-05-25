CREATE OR REPLACE PROCEDURE spInterfaceAmadeus(
    p_op TEXT,
    p_Booking TEXT,
    p_file TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Variables generales de control
    v_line TEXT;
    v_lines TEXT[];
    v_state INT := 0;
    
    -- Variables para la tabla BookingGDS (nombres mapeados exactamente al esquema)
    v_code VARCHAR(10);
    v_type VARCHAR(10);
    v_blanch VARCHAR(25) := '001';
    v_implant VARCHAR(25);
    v_external BOOLEAN := false;
    v_date TIMESTAMP;
    v_currency VARCHAR(3) := 'COP';
    v_exchangeRate DOUBLE PRECISION := 1.0;
    v_tiquetPrinter VARCHAR(25);
    v_seller VARCHAR(25);
    v_client VARCHAR(50);
    v_typetransaction VARCHAR(25) := '1';
    v_iata VARCHAR(25);
    v_description TEXT;
    v_observation TEXT;

    -- Variables temporales auxiliares
    v_nacionalidad INT := 1;
    v_centrocosto VARCHAR(50);
    v_solicita VARCHAR(200);
    v_over VARCHAR(25);
    v_evento VARCHAR(250);
    v_highfare NUMERIC := 0;
    v_lowfare NUMERIC := 0;
    v_fare NUMERIC := 0;
    v_reasoncode VARCHAR(2);
    v_itinerarios TEXT := '';
    v_clases TEXT := '';
    v_pax_cc VARCHAR(20);
    v_lapsoviaje VARCHAR(50);

    v_facturador VARCHAR(6);
    v_aerolinea_vende VARCHAR(2);
    v_pax_ape VARCHAR(40);
    v_pax_name VARCHAR(40);
    v_tkt_prefix VARCHAR(3);
    v_tkt VARCHAR(20);
    
    -- Arrays para almacenar las colecciones (Itinerarios, Pasajeros, Taxes, EMD, Pagos)
    v_iti_origenes TEXT[] := '{}';
    v_iti_destinos TEXT[] := '{}';
    v_iti_vuelos TEXT[] := '{}';
    v_iti_clases TEXT[] := '{}';
    v_iti_aerolineas TEXT[] := '{}';
    v_iti_fechas_salida TIMESTAMP[] := '{}';
    v_iti_horas_salida TEXT[] := '{}';
    v_iti_horas_llegada TEXT[] := '{}';
    v_iti_co2 NUMERIC[] := '{}';

    v_pax_nombres TEXT[] := '{}';
    v_pax_apellidos TEXT[] := '{}';
    v_pax_tiquetes TEXT[] := '{}';
    v_pax_idx INT := 0;

    v_tax_codes TEXT[] := '{}';
    v_tax_vals NUMERIC[] := '{}';

    v_emd_codigos TEXT[] := '{}';
    v_emd_descripciones TEXT[] := '{}';
    v_emd_totales NUMERIC[] := '{}';

    v_pay_tipos TEXT[] := '{}';
    v_pay_tarjetas TEXT[] := '{}';
    v_pay_montos NUMERIC[] := '{}';

    -- IDs de inserción
    v_booking_gds_id INT;
    v_booking_product_gds_id INT;
    v_booking_product_emd_id INT;
    
    -- Utilidades
    v_pos_barra INT;
    v_pos_punto_coma INT;
    v_sub_line TEXT;
    v_imp_code VARCHAR(2);
    
    -- Variables para Tarifas
    v_arr_tarifas TEXT[];
    v_am_tarifa NUMERIC := 0;
    v_am_tarifalocal NUMERIC := 0;
    v_am_total NUMERIC := 0;
    
    -- Variables para EMD
    v_emd_arr TEXT[];
    v_emd_codigo VARCHAR(50);
    v_emd_index VARCHAR(50);
    v_emd_descripcion VARCHAR(500);
    v_i INT;
BEGIN
    -- 1. Separar el archivo por saltos de línea
    v_lines := string_to_array(p_Booking, E'\n');
    
    -- Estado de la reserva
    IF p_Booking LIKE '%ENDX%' OR p_Booking LIKE '%END%' OR p_Booking LIKE '%CHD%' THEN
        v_state := 1;
    ELSE
        v_state := 0;
        RAISE EXCEPTION 'Reserva no confirmada: %', p_file;
    END IF;

    -- ==============================================================
    -- LECTURA ÚNICA DEL ARCHIVO: Extracción de datos y colecciones
    -- ==============================================================
    FOREACH v_line IN ARRAY v_lines
    LOOP
        v_line := rtrim(v_line, E'\r');
        
        -- D- Fechas (D-02JAN...)
        IF starts_with(v_line, 'D-') THEN
            IF length(v_line) >= 22 THEN
                BEGIN
                    v_date := to_date(substring(v_line from 17 for 6), 'YYMMDD');
                EXCEPTION WHEN OTHERS THEN
                    v_date := CURRENT_TIMESTAMP;
                END;
            END IF;
            
        -- A- Aerolínea Vendedora
        ELSIF starts_with(v_line, 'A-') THEN
            v_aerolinea_vende := substring(v_line from 11 for 2);
            
        -- C- Agentes (Tiqueteador, Facturador, Vendedor)
        ELSIF starts_with(v_line, 'C-') THEN
            v_seller := substring(v_line from 22 for 2);
            v_facturador := substring(v_line from 18 for 6);
            v_tiquetPrinter := substring(v_line from 9 for 6);
            
        -- M- Localizador usualmente
        ELSIF starts_with(v_line, 'M-') AND v_code IS NULL THEN
            v_code := substring(v_line from 7 for 6);

        -- H- ITINERARIOS (Guardar en arrays)
        ELSIF starts_with(v_line, 'H-') AND v_line NOT LIKE '%VOID%' THEN
            v_iti_origenes := array_append(v_iti_origenes, substring(v_line from 11 for 3));
            v_iti_destinos := array_append(v_iti_destinos, substring(v_line from 33 for 3));
            v_iti_vuelos := array_append(v_iti_vuelos, substring(v_line from 61 for 4));
            v_iti_clases := array_append(v_iti_clases, substring(v_line from 66 for 1));
            v_iti_aerolineas := array_append(v_iti_aerolineas, trim(substring(v_line from 55 for 2)));
            
            -- CO2
            IF length(v_line) > 20 AND position('CO2-' in v_line) > 0 THEN
                BEGIN
                    v_iti_co2 := array_append(v_iti_co2, cast(replace(substring(v_line from position('CO2-' in v_line) + 4 for position('KG' in v_line) - (position('CO2-' in v_line) + 4)), 'KG', '') as NUMERIC));
                EXCEPTION WHEN OTHERS THEN v_iti_co2 := array_append(v_iti_co2, 0.0); END;
            ELSE
                v_iti_co2 := array_append(v_iti_co2, 0.0);
            END IF;

            -- Fechas (Asumiendo el año de v_date)
            DECLARE
                v_mes_str VARCHAR(3); v_mes VARCHAR(2); v_dia VARCHAR(2); v_anio VARCHAR(4);
            BEGIN
                v_anio := to_char(COALESCE(v_date, CURRENT_TIMESTAMP), 'YYYY');
                v_mes_str := substring(v_line from 72 for 3);
                v_dia := substring(v_line from 70 for 2);
                v_mes := CASE v_mes_str
                    WHEN 'JAN' THEN '01' WHEN 'FEB' THEN '02' WHEN 'MAR' THEN '03'
                    WHEN 'APR' THEN '04' WHEN 'MAY' THEN '05' WHEN 'JUN' THEN '06'
                    WHEN 'JUL' THEN '07' WHEN 'AUG' THEN '08' WHEN 'SEP' THEN '09'
                    WHEN 'OCT' THEN '10' WHEN 'NOV' THEN '11' WHEN 'DEC' THEN '12'
                    ELSE '01'
                END;
                v_iti_fechas_salida := array_append(v_iti_fechas_salida, to_timestamp(v_anio || v_mes || v_dia, 'YYYYMMDD'));
            EXCEPTION WHEN OTHERS THEN
                v_iti_fechas_salida := array_append(v_iti_fechas_salida, COALESCE(v_date, CURRENT_TIMESTAMP));
            END;

            v_iti_horas_salida := array_append(v_iti_horas_salida, substring(v_line from 75 for 2) || substring(v_line from 77 for 2));
            v_iti_horas_llegada := array_append(v_iti_horas_llegada, substring(v_line from 80 for 2) || substring(v_line from 82 for 2));

        -- I- PASAJEROS (Guardar en arrays)
        ELSIF starts_with(v_line, 'I-') THEN
            v_sub_line := substring(v_line from 9);
            v_pos_barra := position('/' in v_sub_line);
            v_pos_punto_coma := position(';' in v_sub_line);
            
            IF v_pos_barra > 0 AND v_pos_punto_coma > 0 THEN
                v_pax_ape := substring(v_sub_line from 1 for v_pos_barra - 1);
                v_pax_name := substring(v_sub_line from v_pos_barra + 1 for v_pos_punto_coma - v_pos_barra - 1);
                
                v_pax_name := replace(v_pax_name, 'MRS', '');
                v_pax_name := replace(v_pax_name, 'MR', '');
                
                v_pax_nombres := array_append(v_pax_nombres, TRIM(v_pax_name));
                v_pax_apellidos := array_append(v_pax_apellidos, TRIM(v_pax_ape));
                v_pax_tiquetes := array_append(v_pax_tiquetes, ''); -- Se actualizará cuando llegue T-
                v_pax_idx := v_pax_idx + 1;
            END IF;

        -- T- TIQUETES (Actualizar el pasajero actual y dejar v_tkt seteado)
        ELSIF starts_with(v_line, 'T-') THEN
            v_sub_line := substring(v_line from 4);
            v_tkt_prefix := substring(v_sub_line from 1 for 3);
            v_tkt := v_tkt_prefix || '-' || substring(v_sub_line from 5);
            
            IF v_pax_idx > 0 THEN
                v_pax_tiquetes[v_pax_idx] := v_tkt;
            END IF;

        -- KFTF - IMPUESTOS Y TAXES
        ELSIF starts_with(v_line, 'KFTF') THEN
            v_imp_code := substring(v_line from 14 for 2);
            v_tax_codes := array_append(v_tax_codes, COALESCE(v_imp_code, 'XX'));
            v_tax_vals := array_append(v_tax_vals, 0.00);

        -- TARIFAS (K-F, K-R, KS-F, KS-R, ATC, K-B)
        ELSIF starts_with(v_line, 'K-F') OR starts_with(v_line, 'K-R') OR starts_with(v_line, 'KS-F') OR starts_with(v_line, 'KS-R') THEN
            v_arr_tarifas := string_to_array(v_line, ';');
            
            IF array_length(v_arr_tarifas, 1) >= 13 THEN
                v_currency := trim(substring(v_arr_tarifas[1] from 4 for 3));
                BEGIN v_am_tarifa := cast(substring(v_arr_tarifas[1] from 7) as NUMERIC); EXCEPTION WHEN OTHERS THEN v_am_tarifa := 0; END;
                BEGIN v_am_tarifalocal := cast(substring(v_arr_tarifas[2] from 4) as NUMERIC); EXCEPTION WHEN OTHERS THEN v_am_tarifalocal := 0; END;
                BEGIN v_am_total := cast(substring(v_arr_tarifas[13] from 4 for 11) as NUMERIC); EXCEPTION WHEN OTHERS THEN v_am_total := 0; END;
            END IF;

        -- EMD - Electronic Miscellaneous Document
        ELSIF starts_with(v_line, 'EMD') THEN
            v_emd_arr := string_to_array(v_line, ';');
            
            IF array_length(v_emd_arr, 1) >= 32 THEN
                v_emd_codigo := substring(v_emd_arr[1] from 4);
                v_emd_descripcion := trim(v_emd_arr[19]);
                BEGIN
                    v_emd_totales := array_append(v_emd_totales, cast(substring(v_emd_arr[32] from 4) as NUMERIC));
                EXCEPTION WHEN OTHERS THEN 
                    v_emd_totales := array_append(v_emd_totales, 0.0); 
                END;
                
                v_emd_codigos := array_append(v_emd_codigos, v_emd_codigo);
                v_emd_descripciones := array_append(v_emd_descripciones, v_emd_descripcion);
            END IF;

        -- FP - FORMAS DE PAGO
        ELSIF starts_with(v_line, 'FP') THEN
            v_pay_tipos := array_append(v_pay_tipos, 'CC');
            v_pay_tarjetas := array_append(v_pay_tarjetas, substring(v_line from 10 for 16));
            v_pay_montos := array_append(v_pay_montos, 0.00);

        -- Otros Remarks (Cabecera)
        ELSIF v_line LIKE '%CENTRO COSTO%' THEN
            v_centrocosto := left(substring(v_line from position('CENTRO COSTO' in v_line) + 13), 50);
        ELSIF v_line LIKE '%SOLICITA%' THEN
            v_solicita := left(substring(v_line from position('SOLICITA' in v_line) + 9), 200);
        ELSIF v_line LIKE '%LAPSO VIAJE%' THEN
            v_lapsoviaje := left(substring(v_line from position('LAPSO VIAJE' in v_line) + 12), 50);
        ELSIF v_line LIKE '%-CEDULA%' THEN
            v_pax_cc := left(trim(substring(v_line from position('-CEDULA' in v_line) + 7)), 20);
        ELSIF starts_with(v_line, 'FT*F*') THEN
            v_over := substring(v_line from 6 for length(v_line) - 5);
        ELSIF starts_with(v_line, 'FT') THEN
            v_over := substring(v_line from 3 for length(v_line) - 2);
        ELSIF starts_with(v_line, 'RM*LF=') THEN
            BEGIN v_lowfare := cast(substring(v_line from 7) as NUMERIC); EXCEPTION WHEN OTHERS THEN v_lowfare := 0; END;
        ELSIF starts_with(v_line, 'RM*FF=') THEN
            BEGIN v_highfare := cast(substring(v_line from 7) as NUMERIC); EXCEPTION WHEN OTHERS THEN v_highfare := 0; END;
        ELSIF starts_with(v_line, 'RM*SVD') THEN
            v_reasoncode := substring(v_line from 7 for 2);
        ELSIF starts_with(v_line, 'RM EVENTO/') THEN
            v_sub_line := substring(v_line from 11);
            v_pos_barra := position('/' in v_sub_line);
            IF v_pos_barra > 0 THEN v_evento := substring(v_sub_line from 1 for v_pos_barra - 1); END IF;
        ELSIF starts_with(v_line, 'RM*FV/77/CON-') THEN
            v_observation := substring(v_line from 14);
        ELSIF starts_with(v_line, 'RM*NC-') AND v_client IS NULL THEN
            v_pos_barra := position('/' in v_line);
            IF v_pos_barra > 0 THEN v_client := replace(substring(v_line from position('-' in v_line) + 1 for v_pos_barra - position('-' in v_line) - 1), '/', ''); END IF;
        END IF;

    END LOOP;

    -- ==============================================================
    -- INSERCIÓN EN TABLAS (Se realiza al final de leer todas las líneas)
    -- ==============================================================

    -- Tipo reserva y Descripcion combinada
    v_type := substring(v_lines[1] from 1 for 3);

    -- Combinar descripciones (evento + solicita si existen)
    v_description := COALESCE(v_evento, '') || ' ' || COALESCE(v_solicita, '');

    -- 1. Cabecera
    INSERT INTO "BookingGDS" (
        "code", "type", "blanch", "implant", "external", "gds", "date", 
        "currency", "exchangeRate", "tiquetPrinter", "seller", "client", 
        "booking", "typetransaction", "iata", "description", "observation", "state"
    ) VALUES (
        COALESCE(v_code, 'DESC'), 
        COALESCE(v_type, 'RES'), 
        v_blanch, 
        v_implant, 
        v_external, 
        2, 
        COALESCE(v_date, CURRENT_TIMESTAMP), 
        v_currency, 
        v_exchangeRate, 
        COALESCE(v_tiquetPrinter, ''), 
        COALESCE(v_seller, ''), 
        COALESCE(v_client, ''), 
        p_Booking, 
        v_typetransaction, 
        v_iata, 
        v_description, 
        v_observation, 
        CAST(v_state AS VARCHAR)
    ) RETURNING "id" INTO v_booking_gds_id;

    -- 2. Producto Padre (Vuelo)
    INSERT INTO "BookingProductGDS" (
        "bookingId", "code", "type", "description", "prestadoracode", 
        "quantity", "price", "reservationCode", "inNationality", "state", "typeproduct"
    ) VALUES (
        v_booking_gds_id, COALESCE(v_tkt, 'VUE'), 'flight', 'flight', v_aerolinea_vende, 
        1, v_am_total, v_code, v_nacionalidad, 'NUEVO', 'VUE'
    ) RETURNING "id" INTO v_booking_product_gds_id;

    -- 3. Detalle Itinerarios
    FOR v_i IN 1 .. array_length(v_iti_origenes, 1) LOOP
        IF v_iti_origenes[v_i] IS NOT NULL THEN
            INSERT INTO "BookingProductItinerayGDS" (
                "id_bookingproductgds", "cd_origen", "cd_destino", "cd_clase", "ds_NumVuelo", 
                "fecha_salida", "hora_salida", "hora_llegada", "terminal", "cd_aero_siglas", "am_co2"
            ) VALUES (
                v_booking_product_gds_id, v_iti_origenes[v_i], v_iti_destinos[v_i], v_iti_clases[v_i], v_iti_vuelos[v_i], 
                v_iti_fechas_salida[v_i], v_iti_horas_salida[v_i], v_iti_horas_llegada[v_i], v_iti_destinos[v_i], v_iti_aerolineas[v_i], v_iti_co2[v_i]
            );
        END IF;
    END LOOP;

    -- 4. Detalle Pasajeros
    FOR v_i IN 1 .. array_length(v_pax_nombres, 1) LOOP
        IF v_pax_nombres[v_i] IS NOT NULL THEN
            INSERT INTO "BookingProductPassangerGDS" (
                "id_bookingproductgds", "ds_nombres", "ds_apellidos", "cd_tiquete"
            ) VALUES (
                v_booking_product_gds_id, v_pax_nombres[v_i], v_pax_apellidos[v_i], v_pax_tiquetes[v_i]
            );
        END IF;
    END LOOP;

    -- 5. Detalle Impuestos (Taxes)
    FOR v_i IN 1 .. array_length(v_tax_codes, 1) LOOP
        IF v_tax_codes[v_i] IS NOT NULL THEN
            INSERT INTO "BookingProductTaxGDS" (
                "id_bookingproductgds", "cd_impuesto", "am_valor"
            ) VALUES (
                v_booking_product_gds_id, v_tax_codes[v_i], v_tax_vals[v_i]
            );
        END IF;
    END LOOP;

    -- 6. Productos EMD
    FOR v_i IN 1 .. array_length(v_emd_codigos, 1) LOOP
        IF v_emd_codigos[v_i] IS NOT NULL THEN
            INSERT INTO "BookingProductGDS" (
                "bookingId", "code", "type", "description", "prestadoracode", 
                "quantity", "price", "reservationCode", "inNationality", "state", "typeproduct"
            ) VALUES (
                v_booking_gds_id, v_emd_codigos[v_i], '1', v_emd_descripciones[v_i], v_aerolinea_vende, 
                1, v_emd_totales[v_i], v_code, v_nacionalidad, 'NUEVO', 'EMD'
            ) RETURNING "id" INTO v_booking_product_emd_id;
            
            -- Si los EMD tienen sus propios impuestos, itinerarios o pasajeros, se asociarian a v_booking_product_emd_id
        END IF;
    END LOOP;

    -- 7. Formas de Pago
    FOR v_i IN 1 .. array_length(v_pay_tipos, 1) LOOP
        IF v_pay_tipos[v_i] IS NOT NULL THEN
            INSERT INTO "BookingProductoPaymentGDS" (
                "id_bookingproductgds", "cd_tipopago", "ds_tarjeta", "am_monto"
            ) VALUES (
                v_booking_product_gds_id, v_pay_tipos[v_i], v_pay_tarjetas[v_i], v_pay_montos[v_i]
            );
        END IF;
    END LOOP;

    RAISE NOTICE 'Amadeus Booking % successfully parsed and inserted.', v_code;

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error processing Amadeus file: % - %', SQLSTATE, SQLERRM;
    ROLLBACK;
    RAISE;
END;
$$;
