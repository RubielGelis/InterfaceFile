CREATE OR REPLACE PROCEDURE spInterfaceSabre(
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
    v_state INTEGER := 0;
    
    -- Variables para la tabla BookingGDS
    v_code VARCHAR(10);
    v_type VARCHAR(10) := 'RES';
    v_blanch VARCHAR(25) := 'OFP';
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
    v_nacionalidad INTEGER := 1;
    v_centrocosto VARCHAR(50);
    v_solicita VARCHAR(200);
    v_over VARCHAR(25);
    v_evento VARCHAR(250);
    v_highfare NUMERIC := 0;
    v_lowfare NUMERIC := 0;
    v_fare NUMERIC := 0;
    v_reasoncode VARCHAR(2);
    v_pax_cc VARCHAR(20);
    v_lapsoviaje VARCHAR(50);

    v_facturador VARCHAR(6);
    v_aerolinea_vende VARCHAR(2);
    v_pax_ape VARCHAR(40);
    v_pax_name VARCHAR(40);
    v_pax_prefix VARCHAR(3);
    v_tkt_prefix VARCHAR(3);
    v_tkt VARCHAR(20);
    
    -- Arrays para almacenar las colecciones
    v_iti_origenes TEXT[] := '{}';
    v_iti_destinos TEXT[] := '{}';
    v_iti_vuelos TEXT[] := '{}';
    v_iti_clases TEXT[] := '{}';
    v_iti_aerolineas TEXT[] := '{}';
    v_iti_fechas_llegada TIMESTAMP[] := '{}';
    v_iti_fechas_salida TIMESTAMP[] := '{}';
    v_iti_horas_salida TEXT[] := '{}';
    v_iti_horas_llegada TEXT[] := '{}';
    v_iti_co2 NUMERIC[] := '{}';

    v_pax_nombres TEXT[] := '{}';
    v_pax_apellidos TEXT[] := '{}';
    v_pax_prefixs TEXT[] := '{}';
    v_pax_tiquetes TEXT[] := '{}';
    v_pax_idx INTEGER := 0;

    v_tax_codes TEXT[] := '{}';
    v_tax_vals NUMERIC[] := '{}';

    -- Variables de pago
    v_pay_tipos TEXT[] := '{}';
    v_pay_tarjetas TEXT[] := '{}';
    v_pay_montos NUMERIC[] := '{}';
    v_pay_numbers TEXT[] := '{}';
    v_pay_expiries TEXT[] := '{}';
    v_pay_approvals TEXT[] := '{}';

    -- Variables para Hotel GK
    v_hotel_destinations TEXT[] := '{}';
    v_hotel_descriptions TEXT[] := '{}';
    v_hotel_checkins TIMESTAMP[] := '{}';
    v_hotel_nights INTEGER[] := '{}';

    -- IDs de inserción
    v_booking_gds_id INTEGER;
    v_booking_product_gds_id INTEGER;
    v_booking_product_hotel_id INTEGER;
    
    -- Utilidades
    v_pos_barra INTEGER;
    v_pos_slash INTEGER;
    v_sub_line TEXT;
    
    -- Variables para Tarifas
    v_am_tarifa NUMERIC := 0;
    v_am_impuestos NUMERIC := 0;
    v_am_otros NUMERIC := 0;
    v_am_tarifalocal NUMERIC := 0;
    v_am_total NUMERIC := 0;
    
    -- Variable para parámetro LeerM6
    v_leer_m6 BOOLEAN := false;
    v_val_m6 TEXT;

    v_i INTEGER;
    v_id_master_branch INTEGER;
    v_id_master_implant INTEGER;
    v_id_master_client INTEGER;
    v_id_master_seller INTEGER;
    v_id_master_provider INTEGER;
    v_id_master_product INTEGER;
    v_id_master_ticketprinter INTEGER;
    v_id_master_prestadora INTEGER;
    v_id_master_chargeandtax INTEGER;
    p_interfaces INTEGER := 2;
    v_err_context text := '';
BEGIN
    -- Obtención de IDs de Maestros
    SELECT 
        MAX(CASE WHEN code = 'Branch' THEN id END),
        MAX(CASE WHEN code = 'Implant' THEN id END),
        MAX(CASE WHEN code = 'Client' THEN id END),
        MAX(CASE WHEN code = 'Seller' THEN id END),
        MAX(CASE WHEN code = 'Provider' THEN id END),
        MAX(CASE WHEN code = 'Product' THEN id END),
        MAX(CASE WHEN code = 'TicketPrinter' THEN id END),
        MAX(CASE WHEN code = 'Prestadora' THEN id END),
        MAX(CASE WHEN code = 'ChargeAndTax' THEN id END)
    INTO 
        v_id_master_branch, v_id_master_implant, v_id_master_client, 
        v_id_master_seller, v_id_master_provider, v_id_master_product,
        v_id_master_ticketprinter, v_id_master_prestadora, v_id_master_chargeandtax
    FROM public."Master"
    WHERE code IN ('Branch', 'Implant', 'Client', 'Seller', 'Provider', 'Product', 'TicketPrinter', 'Prestadora', 'ChargeAndTax');

    -- Consultar si el parámetro LeerM6 está activo (soporta 'S', 's', '1', 'TRUE')
    SELECT COALESCE(value, '0') INTO v_val_m6 FROM public."SystemParameter" WHERE code = 'LeerM6' LIMIT 1;
    IF v_val_m6 IN ('1', 'S', 's', 'true', 'TRUE') THEN
        v_leer_m6 := true;
    END IF;
    
    -- Separar el archivo por saltos de línea
    v_lines := string_to_array(p_Booking, E'\n');
    
    -- Estado de la reserva
    --IF p_Booking LIKE '%ENDX%' OR p_Booking LIKE '%END%' OR p_Booking LIKE '%CHD%' THEN
    --    v_state := 1;
    --ELSE
    --    v_state := 0;
    --    RAISE EXCEPTION 'Reserva Sabre no confirmada: %', p_file;
    --END IF;

    -- ==============================================================
    -- LECTURA DEL ARCHIVO: Extracción de datos y colecciones
    -- ==============================================================
    FOREACH v_line IN ARRAY v_lines
    LOOP
        v_line := rtrim(v_line, E'\r');
        
        -- 1. LINEA AA: Información de la reserva
        IF starts_with(v_line, 'AA') THEN
            -- Record Locator
            v_code := trim(substring(v_line from 57 for 6));
            
            -- Fecha de PNR (e.g. 15MAR en index 3-7)
            DECLARE
                v_mes_str VARCHAR(3);
                v_mes VARCHAR(2);
                v_dia VARCHAR(2);
                v_anio VARCHAR(4);
            BEGIN
                v_anio := to_char(CURRENT_DATE, 'YYYY');
                v_mes_str := substring(v_line from 5 for 3);
                v_dia := substring(v_line from 3 for 2);
                v_mes := CASE v_mes_str
                    WHEN 'JAN' THEN '01' WHEN 'FEB' THEN '02' WHEN 'MAR' THEN '03'
                    WHEN 'APR' THEN '04' WHEN 'MAY' THEN '05' WHEN 'JUN' THEN '06'
                    WHEN 'JUL' THEN '07' WHEN 'AUG' THEN '08' WHEN 'SEP' THEN '09'
                    WHEN 'OCT' THEN '10' WHEN 'NOV' THEN '11' WHEN 'DEC' THEN '12'
                    ELSE '01'
                END;
                v_date := to_timestamp(v_anio || v_mes || v_dia, 'YYYYMMDD');
            EXCEPTION WHEN OTHERS THEN
                v_date := CURRENT_TIMESTAMP;
            END;

            -- IATA (index 58-65 de la misma linea si existe)
            IF length(v_line) >= 70 THEN
                v_iata := substring(v_line from 63 for 8);
            END IF;

        -- 2. LINEA M1: Pasajero
        ELSIF starts_with(v_line, 'M1') THEN
            v_sub_line := trim(substring(v_line from 5 for 50));
            v_pos_barra := position('/' in v_sub_line);
            
            IF v_pos_barra > 0 THEN
                v_pax_ape := substring(v_sub_line from 1 for v_pos_barra - 1);
                v_pax_name := substring(v_sub_line from v_pos_barra + 1);
                
                -- Limpiar títulos comunes
                v_pax_name := replace(v_pax_name, 'MRS', '');
                v_pax_name := replace(v_pax_name, 'MR', '');
                v_pax_name := replace(v_pax_name, 'MS', '');
                v_pax_name := replace(v_pax_name, 'MSTR', '');
                v_pax_name := replace(v_pax_name, 'MISS', '');
                
                v_pax_prefix := RIGHT(TRIM(v_pax_name), 2);
                IF v_pax_prefix NOT IN ('MR', 'MS', 'DR') THEN
                    v_pax_prefix := 'MR';
                END IF;
                
                v_pax_nombres := array_append(v_pax_nombres, TRIM(v_pax_name));
                v_pax_apellidos := array_append(v_pax_apellidos, TRIM(v_pax_ape));
                v_pax_tiquetes := array_append(v_pax_tiquetes, ''); -- Se asocia en M5
                v_pax_prefixs := array_append(v_pax_prefixs, TRIM(v_pax_prefix));
                v_pax_idx := v_pax_idx + 1;
            END IF;

        -- 3. LINEA M2: Tarifas, Impuestos 
        ELSIF starts_with(v_line, 'M2') THEN
            DECLARE
                v_parts TEXT[];
                v_idx INTEGER;
                v_elem TEXT;
                v_val_str TEXT;
                v_code_str TEXT;
                v_total_currency VARCHAR(3);
                v_local_fare_currency VARCHAR(3);
            BEGIN
                v_parts := regexp_split_to_array(trim(v_line), '\s+');
                
                IF array_length(v_parts, 1) >= 4 THEN
                    -- Base Currency and Base Fare
                    v_currency := v_parts[3];
                    BEGIN
                        v_am_tarifa := cast(v_parts[4] as NUMERIC);
                    EXCEPTION WHEN OTHERS THEN
                        v_am_tarifa := 0;
                    END;
                    v_am_tarifalocal := v_am_tarifa; -- Valor por defecto
                    
                    -- Escaneo de Taxes (elementos que terminen en código de impuesto de 2 letras)
                    v_idx := 5;
                    WHILE v_idx <= array_length(v_parts, 1) LOOP
                        v_elem := v_parts[v_idx];
                        IF v_elem ~ '^\d+(\.\d+)?[A-Z]{2}$' THEN
                            v_val_str := substring(v_elem from '^\d+(\.\d+)?');
                            v_code_str := right(v_elem, 2);
                            
                            -- Homologación de impuesto
                            v_code_str := public."fnEquivalenceInterface"(p_interfaces, v_id_master_chargeandtax, v_code_str);
                            
                            v_tax_codes := array_append(v_tax_codes, v_code_str);
                            v_tax_vals := array_append(v_tax_vals, cast(v_val_str as NUMERIC));
                            v_idx := v_idx + 1;
                        ELSE
                            EXIT;
                        END IF;
                    END LOOP;
                    
                    -- Total e Impuestos locales
                    IF v_idx < array_length(v_parts, 1) AND v_parts[v_idx] ~ '^[A-Z]{3}$' THEN
                        v_total_currency := v_parts[v_idx];
                        BEGIN
                            v_am_total := cast(v_parts[v_idx+1] as NUMERIC);
                        EXCEPTION WHEN OTHERS THEN
                            v_am_total := 0;
                        END;
                        
                        -- Revisar si hay conversión de tarifa local más adelante
                        IF v_idx+3 <= array_length(v_parts, 1) AND v_parts[v_idx+2] ~ '^[A-Z]{3}$' THEN
                            v_local_fare_currency := v_parts[v_idx+2];
                            BEGIN
                                v_am_tarifalocal := cast(v_parts[v_idx+3] as NUMERIC);
                            EXCEPTION WHEN OTHERS THEN
                                v_am_tarifalocal := v_am_tarifa;
                            END;
                        END IF;
                    END IF;
                END IF;
            END;

        -- 4. LINEA M3: Itinerarios (HK es Vuelo, GK es Hotel)
        ELSIF starts_with(v_line, 'M3') THEN
            DECLARE
                v_status VARCHAR(2);
                v_iti_tipo VARCHAR(3);
                v_seg_idx VARCHAR(2);
            BEGIN
                v_seg_idx := substring(v_line from 3 for 2);
                v_status := substring(v_line from 8 for 2);
                v_iti_tipo := substring(v_line from 15 for 3);
                
                IF v_status = 'HK' AND v_iti_tipo = 'AIR' THEN
                    -- Segmento de Vuelo
                    v_iti_origenes := array_append(v_iti_origenes, substring(v_line from 19 for 3));
                    v_iti_destinos := array_append(v_iti_destinos, substring(v_line from 39 for 3));
                    v_iti_vuelos := array_append(v_iti_vuelos, substring(v_line from 61 for 4));
                    v_iti_clases := array_append(v_iti_clases, substring(v_line from 66 for 1));
                    v_iti_aerolineas := array_append(v_iti_aerolineas, trim(substring(v_line from 59 for 2)));
                    
                    v_iti_horas_salida := array_append(v_iti_horas_salida, substring(v_line from 68 for 4));
                    v_iti_horas_llegada := array_append(v_iti_horas_llegada, substring(v_line from 73 for 4));
                    v_iti_co2 := array_append(v_iti_co2, 0.0);
                    
                    -- Fecha de salida del itinerario (e.g. 20MAR)
                    DECLARE
                        v_mes_str VARCHAR(3); v_mes VARCHAR(2); v_dia VARCHAR(2); v_anio VARCHAR(4); v_horas VARCHAR(5);
                    BEGIN
                        v_anio := to_char(COALESCE(v_date, CURRENT_TIMESTAMP), 'YYYY');
                        v_mes_str := substring(v_line from 12 for 3);
                        v_dia := substring(v_line from 10 for 2);
                        v_mes := CASE v_mes_str
                            WHEN 'JAN' THEN '01' WHEN 'FEB' THEN '02' WHEN 'MAR' THEN '03'
                            WHEN 'APR' THEN '04' WHEN 'MAY' THEN '05' WHEN 'JUN' THEN '06'
                            WHEN 'JUL' THEN '07' WHEN 'AUG' THEN '08' WHEN 'SEP' THEN '09'
                            WHEN 'OCT' THEN '10' WHEN 'NOV' THEN '11' WHEN 'DEC' THEN '12'
                            ELSE '01'
                        END;
                        v_horas := substring(v_line from 68 for 2) || ':' || substring(v_line from 70 for 2);
                        v_iti_fechas_salida := array_append(v_iti_fechas_salida, to_timestamp(v_anio || v_mes || v_dia || ' ' || v_horas, 'YYYYMMDD HH24:MI'));
                        v_iti_fechas_llegada := array_append(v_iti_fechas_llegada, to_timestamp(v_anio || v_mes || v_dia || ' ' || v_horas, 'YYYYMMDD HH24:MI'));
                    EXCEPTION WHEN OTHERS THEN
                        v_iti_fechas_salida := array_append(v_iti_fechas_salida, COALESCE(v_date, CURRENT_TIMESTAMP));
                        v_iti_fechas_llegada := array_append(v_iti_fechas_llegada, COALESCE(v_date, CURRENT_TIMESTAMP));
                    END;
                    
                ELSIF v_status = 'GK' THEN
                    -- Segmento de Hotel
                    DECLARE
                        v_htl_desc TEXT;
                        v_htl_dest VARCHAR(3);
                        v_htl_nights INTEGER := 1;
                        v_htl_checkin TIMESTAMP;
                    BEGIN
                        -- Descripcion del hotel (e.g. BOG/FROSCH TRAVEL)
                        v_htl_desc := trim(substring(v_line from 36));
                        v_pos_slash := position('/' in v_htl_desc);
                        IF v_pos_slash > 0 THEN
                            v_htl_dest := substring(v_htl_desc from 1 for v_pos_slash - 1);
                            v_htl_desc := substring(v_htl_desc from v_pos_slash + 1);
                        ELSE
                            v_htl_dest := 'BOG';
                        END IF;
                        
                        -- Cantidad/Noches
                        BEGIN
                            v_htl_nights := cast(substring(v_line from 33 for 2) as INTEGER);
                        EXCEPTION WHEN OTHERS THEN
                            v_htl_nights := 1;
                        END;
                        
                        -- Fecha de Checkin (e.g. 11SEP)
                        DECLARE
                            v_mes_str VARCHAR(3); v_mes VARCHAR(2); v_dia VARCHAR(2); v_anio VARCHAR(4);
                        BEGIN
                            v_anio := to_char(COALESCE(v_date, CURRENT_TIMESTAMP), 'YYYY');
                            v_mes_str := substring(v_line from 12 for 3);
                            v_dia := substring(v_line from 10 for 2);
                            v_mes := CASE v_mes_str
                                WHEN 'JAN' THEN '01' WHEN 'FEB' THEN '02' WHEN 'MAR' THEN '03'
                                WHEN 'APR' THEN '04' WHEN 'MAY' THEN '05' WHEN 'JUN' THEN '06'
                                WHEN 'JUL' THEN '07' WHEN 'AUG' THEN '08' WHEN 'SEP' THEN '09'
                                WHEN 'OCT' THEN '10' WHEN 'NOV' THEN '11' WHEN 'DEC' THEN '12'
                                ELSE '01'
                            END;
                            v_htl_checkin := to_timestamp(v_anio || v_mes || v_dia, 'YYYYMMDD');
                        EXCEPTION WHEN OTHERS THEN
                            v_htl_checkin := COALESCE(v_date, CURRENT_TIMESTAMP);
                        END;
                        
                        v_hotel_destinations := array_append(v_hotel_destinations, v_htl_dest);
                        v_hotel_descriptions := array_append(v_hotel_descriptions, v_htl_desc);
                        v_hotel_nights := array_append(v_hotel_nights, v_htl_nights);
                        v_hotel_checkins := array_append(v_hotel_checkins, v_htl_checkin);
                    END;
                END IF;
            END;

        -- 5. LINEA M5: Tiquete y Formas de Pago
        ELSIF starts_with(v_line, 'M5') THEN
            DECLARE
                v_parts TEXT[];
                v_tkt_full VARCHAR(20);
                v_pax_num INTEGER := 1;
                
                -- Variables de pago locales
                v_pay_part TEXT;
                v_pay_type VARCHAR(10) := NULL;
                v_pay_card_type VARCHAR(10) := NULL;
                v_pay_card_num TEXT := NULL;
                v_pay_card_exp TEXT := NULL;
                v_pay_card_auth TEXT := NULL;
                
                v_m5_fare NUMERIC := 0;
                v_m5_tax1 NUMERIC := 0;
                v_m5_tax2 NUMERIC := 0;
                v_m5_total NUMERIC := 0;
                v_tax2_str TEXT;
            BEGIN
                v_parts := regexp_split_to_array(trim(v_line), '/');
                IF array_length(v_parts, 1) >= 1 THEN
                    -- Formato: M50201  AV#6040372596
                    -- Quitar M5, pasajero idx, etc.
                    v_sub_line := substring(v_parts[1] from 7); -- index de tiquete completo
                    v_pos_barra := position('#' in v_sub_line);
                    
                    IF v_pos_barra > 0 THEN
                        v_aerolinea_vende := substring(v_sub_line from 1 for v_pos_barra - 1);
                        v_tkt := substring(v_sub_line from v_pos_barra + 1);
                        v_tkt_full := v_aerolinea_vende || '-' || v_tkt;
                        
                        -- Extraer el índice del pasajero (pos 3-4 del primer campo, e.g. M50201 -> pasajero 01)
                        BEGIN
                            v_pax_num := cast(substring(v_parts[1] from 5 for 2) as INTEGER);
                        EXCEPTION WHEN OTHERS THEN
                            v_pax_num := 1;
                        END;
                        
                        IF v_pax_num <= v_pax_idx THEN
                            v_pax_tiquetes[v_pax_num] := v_tkt_full;
                        END IF;
                    END IF;
                END IF;

                -- Procesar forma de pago (usualmente en la posición 7)
                IF array_length(v_parts, 1) >= 7 THEN
                    v_pay_part := trim(v_parts[7]);
                    
                    -- Calcular valor total del tiquete desde la línea M5
                    BEGIN
                        v_m5_fare := COALESCE(nullif(trim(v_parts[3]), ''), '0')::NUMERIC;
                    EXCEPTION WHEN OTHERS THEN
                        v_m5_fare := 0;
                    END;
                    BEGIN
                        v_m5_tax1 := COALESCE(nullif(trim(v_parts[4]), ''), '0')::NUMERIC;
                    EXCEPTION WHEN OTHERS THEN
                        v_m5_tax1 := 0;
                    END;
                    IF array_length(v_parts, 1) >= 5 THEN
                        v_tax2_str := trim(v_parts[5]);
                        v_tax2_str := regexp_replace(v_tax2_str, '^[^0-9]+', '');
                        BEGIN
                            v_m5_tax2 := COALESCE(nullif(v_tax2_str, ''), '0')::NUMERIC;
                        EXCEPTION WHEN OTHERS THEN
                            v_m5_tax2 := 0;
                        END;
                    END IF;
                    
                    v_m5_total := v_m5_fare + v_m5_tax1 + v_m5_tax2;
                    IF v_m5_total = 0 THEN
                        v_m5_total := v_am_total;
                    END IF;

                    IF starts_with(v_pay_part, 'CA') THEN
                        v_pay_type := 'CA';
                    ELSIF starts_with(v_pay_part, 'CC') THEN
                        v_pay_type := 'CC';
                        
                        -- Extraer detalles de la tarjeta de crédito
                        DECLARE
                            v_cc_rest TEXT := trim(substring(v_pay_part from 3));
                        BEGIN
                            -- Extraer tipo de tarjeta (los primeros 2 caracteres si son letras)
                            IF v_cc_rest ~ '^[A-Z]{2}' THEN
                                v_pay_card_type := substring(v_cc_rest from 1 for 2);
                                v_cc_rest := trim(substring(v_cc_rest from 3));
                            END IF;
                            
                            -- Número de tarjeta (hasta encontrar espacio o barra)
                            v_pay_card_num := regexp_replace(v_cc_rest, '[/\s].*$', '');
                            
                            -- Expiración y Autorización desde las siguientes partes si existen
                            IF array_length(v_parts, 1) >= 8 AND trim(v_parts[8]) ~ '^\d{4}$' THEN
                                v_pay_card_exp := substring(trim(v_parts[8]) from 1 for 2) || '/' || substring(trim(v_parts[8]) from 3 for 2);
                            ELSIF array_length(v_parts, 1) >= 8 AND trim(v_parts[8]) ~ '^\d{2}/\d{2}$' THEN
                                v_pay_card_exp := trim(v_parts[8]);
                            END IF;
                            
                            IF array_length(v_parts, 1) >= 9 AND trim(v_parts[9]) !~ '^\d\.\d' AND trim(v_parts[9]) NOT IN ('1','F','E') THEN
                                v_pay_card_auth := trim(v_parts[9]);
                            END IF;
                        END;
                    END IF;
                    
                    -- Registrar forma de pago encontrada
                    IF v_pay_type IS NOT NULL THEN
                        v_pay_tipos := array_append(v_pay_tipos, v_pay_type);
                        v_pay_tarjetas := array_append(v_pay_tarjetas, COALESCE(v_pay_card_type, ''));
                        v_pay_numbers := array_append(v_pay_numbers, COALESCE(v_pay_card_num, ''));
                        v_pay_expiries := array_append(v_pay_expiries, COALESCE(v_pay_card_exp, ''));
                        v_pay_approvals := array_append(v_pay_approvals, COALESCE(v_pay_card_auth, ''));
                        v_pay_montos := array_append(v_pay_montos, v_m5_total);
                    END IF;
                END IF;
            END;

        -- 6. LINEA M6: Desglose de impuestos (si parámetro LeerM6 está activo)
        ELSIF starts_with(v_line, 'M6') AND v_leer_m6 THEN
            DECLARE
                v_tax_sub TEXT;
                v_pos_xt INTEGER;
                v_tax_match RECORD;
                v_code_str TEXT;
            BEGIN
                v_pos_xt := position('XT' in v_line);
                IF v_pos_xt > 0 THEN
                    -- Extraer subcadena después de 'XT'
                    v_tax_sub := substring(v_line from v_pos_xt + 2);
                    
                    -- Limpiar el impuesto consolidado 'XT' de la lista
                    DECLARE
                        v_new_codes TEXT[] := '{}';
                        v_new_vals NUMERIC[] := '{}';
                    BEGIN
                        FOR v_i IN 1 .. COALESCE(array_length(v_tax_codes, 1), 0) LOOP
                            IF v_tax_codes[v_i] <> 'XT' THEN
                                v_new_codes := array_append(v_new_codes, v_tax_codes[v_i]);
                                v_new_vals := array_append(v_new_vals, v_tax_vals[v_i]);
                            END IF;
                        END LOOP;
                        v_tax_codes := v_new_codes;
                        v_tax_vals := v_new_vals;
                    END;
                    
                    -- Agregar impuestos detallados de M6
                    FOR v_tax_match IN SELECT (regexp_matches(v_tax_sub, '(\d+)([A-Z]{2})', 'g'))[1] as amount, (regexp_matches(v_tax_sub, '(\d+)([A-Z]{2})', 'g'))[2] as code LOOP
                        IF v_tax_match.code IS NOT NULL THEN
                            v_code_str := public."fnEquivalenceInterface"(p_interfaces, v_id_master_chargeandtax, v_tax_match.code);
                            v_tax_codes := array_append(v_tax_codes, v_code_str);
                            v_tax_vals := array_append(v_tax_vals, cast(v_tax_match.amount as NUMERIC));
                        END IF;
                    END LOOP;
                END IF;
            END;

        -- 7. LINEAS M8 y M9: Remarks y Metadata
        ELSIF starts_with(v_line, 'M8') OR starts_with(v_line, 'M9') THEN
            -- Centro de Costo
            IF v_line LIKE '%CENTRO COSTO%' THEN
                v_centrocosto := left(substring(v_line from position('CENTRO COSTO' in v_line) + 13), 50);
            ELSIF v_line LIKE '%CENTRO DE COSTOS%' THEN
                v_centrocosto := left(substring(v_line from position('CENTRO DE COSTOS' in v_line) + 17), 50);
            ELSIF v_line LIKE '%CCINT*%' THEN
                v_centrocosto := left(substring(v_line from position('CCINT*' in v_line) + 7), 50);
            -- Solicita
            ELSIF v_line LIKE '%SOLICITA%' THEN
                v_solicita := left(substring(v_line from position('SOLICITA' in v_line) + 9), 200);
            -- Lapso Viaje
            ELSIF v_line LIKE '%LAPSO VIAJE%' THEN
                v_lapsoviaje := left(substring(v_line from position('LAPSO VIAJE' in v_line) + 12), 50);
            -- Cedula
            ELSIF v_line LIKE '%-CEDULA%' THEN
                v_pax_cc := left(trim(substring(v_line from position('-CEDULA' in v_line) + 7)), 20);
            ELSIF v_line LIKE '%NIT/%' THEN
                v_client := left(trim(substring(v_line from position('NIT/' in v_line) + 4)), 50);
            -- Evento
            ELSIF v_line LIKE '%EVENTO/%' THEN
                v_evento := left(substring(v_line from position('EVENTO/' in v_line) + 7), 250);
            -- Cliente de Remark específico
            ELSIF starts_with(v_line, 'M804Z*CLIQCID-') THEN
                v_client := substring(v_line from 15);
            END IF;
        END IF;
    END LOOP;

    -- ==============================================================
    -- PERSISTENCIA DE DATOS
    -- ==============================================================
    
    -- Tipo reserva
    v_type := COALESCE(v_type, 'RES');
    v_description := COALESCE(v_evento, '') || ' ' || COALESCE(v_solicita, '');

    -- 1. Cabecera (Upsert)
    v_booking_gds_id := NULL;
    IF v_code IS NOT NULL THEN
        SELECT id INTO v_booking_gds_id FROM public."BookingGDS" WHERE "code" = v_code LIMIT 1;
    END IF;

    IF v_booking_gds_id IS NOT NULL THEN
        -- Actualizar cabecera existente
        UPDATE public."BookingGDS" SET
            "type" = v_type, 
            "blanch" = v_blanch, 
            "implant" = v_implant, 
            "external" = v_external, 
            "gds" = 1, -- Sabre
            "date" = COALESCE(v_date, CURRENT_TIMESTAMP), 
            "currency" = v_currency, 
            "exchangeRate" = v_exchangeRate, 
            "tiquetPrinter" = COALESCE(v_tiquetPrinter, ''), 
            "seller" = COALESCE(v_seller, ''), 
            "client" = COALESCE(v_client, ''), 
            "booking" = p_Booking, 
            "typetransaction" = v_typetransaction, 
            "iata" = v_iata, 
            "description" = v_description, 
            "observation" = v_observation, 
            "state" = CAST(v_state AS VARCHAR)
        WHERE "id" = v_booking_gds_id;

        -- Eliminar detalles anteriores
        DELETE FROM public."BookingProductPaymentGDS" WHERE "bookingProductId" IN (SELECT id FROM public."BookingProductGDS" WHERE "bookingId" = v_booking_gds_id);
        DELETE FROM public."BookingProductTaxGDS" WHERE "bookingProductId" IN (SELECT id FROM public."BookingProductGDS" WHERE "bookingId" = v_booking_gds_id);
        DELETE FROM public."BookingProductPassangerGDS" WHERE "bookingProductId" IN (SELECT id FROM public."BookingProductGDS" WHERE "bookingId" = v_booking_gds_id);
        DELETE FROM public."BookingProductItineraryGDS" WHERE "bookingProductId" IN (SELECT id FROM public."BookingProductGDS" WHERE "bookingId" = v_booking_gds_id);
        DELETE FROM public."BookingProductGDS" WHERE "bookingId" = v_booking_gds_id;
    ELSE
        -- Insertar nueva cabecera
        INSERT INTO public."BookingGDS" (
            "code", "type", "blanch", "implant", "external", "gds", "date", 
            "currency", "exchangeRate", "tiquetPrinter", "seller", "client", 
            "booking", "typetransaction", "iata", "description", "observation", "state"
        ) VALUES (
            COALESCE(v_code, 'DESC'), 
            v_type, 
            v_blanch, 
            v_implant, 
            v_external, 
            1, -- Sabre
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
    END IF;

    -- 2. Producto Vuelo
    INSERT INTO public."BookingProductGDS" (
        "bookingId", "code", "type", "description", "prestadoracode", 
        "quantity", "price", "reservationCode", "inNationality", "state", "typeproduct"
    ) VALUES (
        v_booking_gds_id, COALESCE(v_tkt, 'VUE'), 'flight', 'flight', v_aerolinea_vende, 
        1, v_am_total, v_code, v_nacionalidad, 'NUEVO', 'VUE'
    ) RETURNING "id" INTO v_booking_product_gds_id;

    -- 3. Detalle Itinerarios de Vuelo
    FOR v_i IN 1 .. COALESCE(array_length(v_iti_origenes, 1), 0) LOOP
        IF v_iti_origenes[v_i] IS NOT NULL THEN
            INSERT INTO public."BookingProductItineraryGDS" (
                "bookingProductId", "orden", "origin", "destination", "class", "checkInDate", 
                "checkOutDate", "terminal", "prestadoraCode", "farebasis", "Numflight", "Typeflight", "amount"
            ) VALUES (
                v_booking_product_gds_id, v_i, v_iti_origenes[v_i], v_iti_destinos[v_i], v_iti_clases[v_i], v_iti_fechas_salida[v_i], 
                v_iti_fechas_llegada[v_i], v_iti_destinos[v_i], v_iti_aerolineas[v_i], '', v_iti_vuelos[v_i], '', COALESCE(v_iti_co2[v_i],'0') 
            );
        END IF;
    END LOOP;

    -- 4. Detalle Pasajeros
    FOR v_i IN 1 .. COALESCE(array_length(v_pax_nombres, 1), 0) LOOP
        IF v_pax_nombres[v_i] IS NOT NULL THEN
            INSERT INTO public."BookingProductPassangerGDS" (
                "bookingProductId", "code", "firstnm", "lastnm", "prefix","identification","phone","email"
            ) VALUES (
                v_booking_product_gds_id, v_i::TEXT, v_pax_nombres[v_i], v_pax_apellidos[v_i], v_pax_prefixs[v_i], v_pax_tiquetes[v_i],'',''
            );
        END IF;
    END LOOP;

    -- 5. Detalle Impuestos (Taxes)
    IF COALESCE(v_am_tarifalocal,0)<>0 THEN
        INSERT INTO public."BookingProductTaxGDS" (
            "bookingProductId", "code", "name", "type", "ismain", "percentage", "amount"
        ) VALUES (
            v_booking_product_gds_id,'TAR','Tarifa','CHARGE',true,0, v_am_tarifalocal
        );
    END IF;
    
    FOR v_i IN 1 .. COALESCE(array_length(v_tax_codes, 1), 0) LOOP
        IF v_tax_codes[v_i] IS NOT NULL THEN
            INSERT INTO public."BookingProductTaxGDS" (
                "bookingProductId", "code", "name", "type", "ismain", "percentage", "amount"
            ) VALUES (
                v_booking_product_gds_id, v_tax_codes[v_i], v_tax_codes[v_i], 'tax', false, 0, (COALESCE(v_tax_vals[v_i],'0')::DOUBLE PRECISION)
            );
            v_am_impuestos := v_am_impuestos + COALESCE(v_tax_vals[v_i],'0')::NUMERIC; 
        END IF;
    END LOOP;
    
    v_am_otros := COALESCE(v_am_total,0) - COALESCE(v_am_tarifalocal,0) - COALESCE(v_am_impuestos,0); 
    IF COALESCE(v_am_otros,0)<>0 THEN
        INSERT INTO public."BookingProductTaxGDS" (
            "bookingProductId", "code", "name", "type", "ismain", "percentage", "amount"
        ) VALUES (
            v_booking_product_gds_id,'OTR','Otros','CHARGE',false,0, v_am_otros
        );
    END IF;

    -- 6. Detalle Formas de Pago
    FOR v_i IN 1 .. COALESCE(array_length(v_pay_tipos, 1), 0) LOOP
        IF v_pay_tipos[v_i] IS NOT NULL THEN
            INSERT INTO public."BookingProductPaymentGDS" (
                "bookingProductId", "bookingProductFEEId", "code", "name", "type", "typecreditcard", 
                "numbercreditcard", "vouchercreditcard", "expiredcreditcard", "authcreditcard", "quotas", 
                "bank", "square", "reference", "policy", "policyannex", "amount"
            ) VALUES (
                v_booking_product_gds_id, NULL, v_pay_tipos[v_i], v_pay_tipos[v_i], v_pay_tipos[v_i], v_pay_tarjetas[v_i],
                COALESCE(v_pay_numbers[v_i], ''), '', COALESCE(v_pay_expiries[v_i], '__/__'), COALESCE(v_pay_approvals[v_i], ''), 0,
                '', '', '', '', '', COALESCE(v_pay_montos[v_i], 0)
            );
        END IF;
    END LOOP;

    -- 7. Agregar Productos de Hotel (GK)
    FOR v_i IN 1 .. COALESCE(array_length(v_hotel_descriptions, 1), 0) LOOP
        IF v_hotel_descriptions[v_i] IS NOT NULL THEN
            INSERT INTO public."BookingProductGDS" (
                "bookingId", "code", "type", "description", "prestadoracode", 
                "quantity", "price", "reservationCode", "inNationality", "state", "typeproduct",
                "checkInDate", "nights", "destination"
            ) VALUES (
                v_booking_gds_id, v_code || '_HTL_' || v_i, 'hotel', v_hotel_descriptions[v_i], 'HOTEL', 
                1, 0.0, v_code, v_nacionalidad, 'NUEVO', 'HOT',
                v_hotel_checkins[v_i], v_hotel_nights[v_i], v_hotel_destinations[v_i]
            );
        END IF;
    END LOOP;

    RAISE NOTICE 'Sabre Booking % successfully parsed and inserted.', v_code ;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err_context = PG_EXCEPTION_CONTEXT;
    RAISE NOTICE 'Error processing Sabre file: % - % - %', SQLSTATE, SQLERRM, v_err_context;
    ROLLBACK;
    RAISE;
END;
$$;
