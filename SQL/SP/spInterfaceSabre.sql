CREATE OR REPLACE PROCEDURE spInterfaceSabre(
    p_op TEXT,
    p_Booking TEXT,
    p_file TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Sabre specific logic will go here
    -- For now, this is a placeholder to ensure spInterfaceFile compiles successfully
    RAISE NOTICE 'Processing Sabre file: %', p_file;
END;
$$;
