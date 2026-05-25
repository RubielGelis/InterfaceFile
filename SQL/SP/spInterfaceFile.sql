CREATE OR REPLACE PROCEDURE spInterfaceFile(
    op TEXT,
    Booking TEXT,
    file TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    file_extension TEXT;
BEGIN
    -- Extract the file extension
    file_extension := lower(substring(file from '\.[^\.]*$'));

    IF file_extension = '.fil' THEN
        -- Call Sabre procedure
        CALL spInterfaceSabre(op, Booking, file);
    ELSE
        -- Call Amadeus procedure
        CALL spInterfaceAmadeus(op, Booking, file);
    END IF;
END;
$$;
