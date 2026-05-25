CREATE procedure spInterfaceAmadeus 
	@Op varchar(10)=NULL
	,@Booking TEXT = NULL 
WITH Encryption
AS
Begin
	-- Set NOCOUNT ON: Previene que conjuntos de resultados extras interfieran con 
	-- expresiones Select
	Set NOCOUNT ON;

    -- Declaracion e inicializacion de variables
  	Declare @maxretries INT			    , -- Maximo numero de reintentos
	 		@timeout	NVARCHAR(4000)  , -- Tiempo de espera maximo por bloqueo de registros
	 		@stmt 		NVARCHAR(4000)  , -- Cadena de instrucciones T-SQL
	 		@msg 		VARCHAR(max)	,
	 		@error 		INT				, --Error retornado por el SP
			@retval		TINYINT 		; -- Valor de retorno de este procedimiento: 0:Exito ; 1:Error(Bloque Catch)
	

  	
  	-- Manejo de tiempo de espera y de reintentos por bloqueo de tablas/registros  
   	Select @maxretries = convert(INT,Valor) From dbo.Parametros Where Id = 60 ;
	Select @timeout    = convert(NVARCHAR(4000),Valor) From dbo.Parametros Where Id = 50 ;		
	Set @stmt = N'Set LOCK_TIMEOUT '+ltrim(rtrim(@timeout))
	EXEC sp_executesql @stmt,N''
	
		----------------------------------------------------------
		-- Cargando los datos de la reserva en variables y		--
		-- en variables tipo tabla, para proceder a insertar	--
		-- en las tablas de reservas							--
		----------------------------------------------------------
		

		Select @Archivo = @Booking	
		--Comportamiento del sistema
		DECLARE @ComportamientoSistema VARCHAR(100),@bl_ReservasGDSNoCofirmadas BIT	/*rgelis 2013/11/17 req.17704*/
		SELECT @ComportamientoSistema = RTRIM(Valor) FROM dbo.Parametros WHERE id = 240
		SELECT @bl_ReservasGDSNoCofirmadas=CASE WHEN Valor='S' THEN 1 ELSE 0 END FROM dbo.Parametros WHERE id = 295	/*rgelis 2013/11/17 req.17704*/
		SELECT @bl_ReservasGDSNoCofirmadas = ISNULL(@bl_ReservasGDSNoCofirmadas,0) /*rgelis 2013/11/17 req.17704*/  
		DECLARE @bl_TomarYQYRAmadeusReservaGDS BIT
		SELECT @bl_TomarYQYRAmadeusReservaGDS=CASE WHEN LTRIM(RTRIM(Valor))='S' THEN 1 ELSE 0 END FROM dbo.Parametros WHERE id = 601	/*rgelis 2013/11/17 req.17704*/
		SELECT @bl_TomarYQYRAmadeusReservaGDS = ISNULL(@bl_TomarYQYRAmadeusReservaGDS,0)
    	-- Bloque TRY
    	Begin TRY 	
			--Iniciando / salvando transaccion dependiendo si ya esta iniciada o no--
		  	Begin TRAN;
	
			------------------------------------------------------
			-- Obtenemos la informacion contenida en el archivo --
			------------------------------------------------------
			Declare @GDS AS VARCHAR(MAX), @Sucursal CHAR(5), @Implante CHAR(5), @bl_externo INT
			Select 
				@GDS = ds_reserva,
				@Sucursal = cd_sucursal,
				@Implante = cd_implante,				
				@Archivo = ds_archivo,
				@bl_externo = bl_externo
			From dbo.ReservasGDS_Temp Where ID=@IdReserva

			IF @ComportamientoSistema = 'República Dominicana'
				SET @GDS = REPLACE(@GDS,'#',';')
			
			SET @GDS = REPLACE(@GDS,'EXEMPT',SPACE(6)) --rgelis 2018/03/27 ticket:
			--TRUNCATE TABLE ReservasGDS_Temp
			--Partimos la informacion en Filas
			Declare @TableValores AS TABLE(id INT IDENTITY, ds_Moneda CHAR(3),am_tarifaLocal MONEY, am_tarifa MONEY, am_total MONEY, am_iva MONEY, am_tua MONEY, am_comb MONEY, am_vat MONEY, am_iva2 MONEY) /*rgelis 2013/12/09 req.17703*/
			CREATE TABLE #TableValoresAux (id INT IDENTITY,Fila VARCHAR(max)) /*rgelis 2013/12/09 req.17703*/
			DECLARE @MaxFilaAux INT,@CountAux INT /*rgelis 2013/12/09 req.17703*/	
			Declare @TableReserva AS TABLE(id INT IDENTITY,Fila VARCHAR(max))
			Declare @TableEMDValores AS TABLE(id INT IDENTITY, ds_Moneda CHAR(3),am_tarifaLocal MONEY, am_tarifa MONEY, am_total MONEY, cd_codigo CHAR(3), cd_index CHAR(25),cd_AerolineaPenalidad CHAR(3), cd_Penalidad CHAR(11),cd_Aerolinea CHAR(3), cd_tiquete CHAR(11),FP1 CHAR(3),FP1_Val MONEY,FP1_TC CHAR(2),FP1_TC_number CHAR(16),FP1_TC_exp CHAR(5),FP1_TC_aprob CHAR(6),FP1_TC_voucher CHAR(6),FP2 CHAR(3),FP2_Val MONEY,FP2_TC CHAR(2),FP2_TC_number CHAR(16),FP2_TC_exp CHAR(5),FP2_TC_aprob CHAR(6), FP2_TC_voucher CHAR(6), Descripcion VARCHAR(500), am_iva MONEY, am_tua MONEY, am_comb MONEY, am_vat MONEY, am_iva2 MONEY) /*rgelis 2014/07/11 req.20502*/ /*rgelis 2017/02/09 req.47238*/ --rgelis 2017/04/10 req.... Correcion de por caso en gematours
			Insert Into @TableReserva
				EXEC SpSplitMejorado @GDS,'
				',0
			UPDATE @TableReserva
			Set fila  = replace(fila,char(10),'')
	
			--Jramirez 20180208 --Reservas IMR son de uso interno no deben ser procesadas por la interfaz
			IF EXISTS (Select 1 From @TableReserva where id=3 and rtrim(fila) like '%IMR')
			BEGIN 
				Rollback Tran;
				Select Consecutivo=2 
				Return 0
			END

			--Estado de la reserva. Si la reserva no termina en ENDX, quiere decir que no ha sido confirmada.
			-- 0 = Sin confirmar
			-- 1 = Confirmada
			Declare @estado TINYINT
			
			--Select fila From @TableReserva
			If exists (Select * From @TableReserva Where fila like '%ENDX%' or ((@ComportamientoSistema = 'Ecuador' OR @bl_ReservasGDSNoCofirmadas=1) AND fila like '%END%')) /*rgelis 2013/11/17 req.17704*/
			Begin 
				Set @estado = 1;
			End
			Else If exists (Select * From @TableReserva Where fila like '%CHD%')
			Begin
				Set @estado = 1;
			End			
			Else
			Begin
				Set @estado = 0
				RAISERROR ('Reserva no confirmada',16,5001);
			End
			
			--R88490 - Jramirez - EMD 7D(Terranova)
			Declare @AIROPT Varchar(2)
			Select @AIROPT = substring(Fila,12,2) From @TableReserva Where Id = 1
			

			---------------------------------
			------ Variables Generales ------
			---------------------------------
			Declare
				@MaxFila INT,
				@Count INT,	
				@TipoReserva CHAR(10),
				@CodigoReserva CHAR(10),
				@CodigoAerolinea CHAR(2),
				@VarAux VARCHAR(MAX),
				@AnoReserva CHAR(2),
				@in_AnoReserva INT,
				@MesReserva CHAR(2),
				@DiaReserva CHAR(2),
				@FechaReserva SMALLDATETIME,
				@AerolineaVende CHAR(2),
				@Vendedor CHAR(3),
				@Tiqueteador CHAR(6),
				@Facturador CHAR(6),
				@Nacionalidad INT,
				@Origen CHAR(3),
				@Destino CHAR(3),
				@cd_Cliente CHAR(10),
				@cd_centrocosto VARCHAR(50),				
				@CodReserva_alterno VARCHAR(6),
				@CodAerolinea_alterno CHAR(2),
				@ds_solicita VARCHAR(200),
				@cd_Pax_CC VARCHAR(20),
				@ds_lapsoviaje VARCHAR(50),
				@cd_PasaportePax VARCHAR(25),
				@Cd_IATA Varchar(25),
				@ds_Observaciones VARCHAR(8000)
			
			--Codigo de la moneda local de la agencia
			Declare @Cod_TarifaLocalAgencia Varchar(3) /*rgelis 2013/09/25 req.17118*/
			Select @Cod_TarifaLocalAgencia  = rtrim(Valor) from dbo.parametros Where Id = 10 /*rgelis 2013/09/25 req.17118*/
								
			--Para la aerolinea de tiquetes Externos
			Declare @AerolineaExterna CHAR(3),@CodAerolineaExterna CHAR(2)
			--Revisados en dolares
			Declare @bl_KS_R Int,@ds_TOMARKSRAMADEUS CHAR(1)
			Declare @ds_TOMARKFTRAMADEUS CHAR(1) --rgelis 2017/06/22 req.50487
			Declare @bl_ATC Int,@ds_TOMARATCAMADEUS CHAR(1) --rgelis 2018/02/20 req.99999
			Declare @bl_KS_F Int,@ds_TOMARKSFAMADEUS CHAR(1),@ds_TOMARKSTFAMADEUS CHAR(1) --inicio rgelis 2018/11/14 req.74260 
			SET @ds_TOMARKSFAMADEUS = 'N'
			SET @ds_TOMARKSTFAMADEUS = 'N'
			SET @bl_KS_F = 0 --fin rgelis 2018/11/14 req.74260
			Set @bl_KS_R = 0
			SET @bl_ATC = 0 --rgelis 2018/02/20 req.99999
			SELECT @ds_TOMARKSRAMADEUS=rtrim(Valor) FROM Parametros WHERE Id=333
			SELECT @ds_TOMARKFTRAMADEUS=rtrim(Valor) FROM Parametros WHERE Id=483 --rgelis 2017/06/22 req.50487
			SELECT @ds_TOMARATCAMADEUS=rtrim(Valor) FROM Parametros WHERE Id=518 --rgelis 2018/02/20 req.99999
			SELECT @bl_ATC=CASE WHEN LTRIM(@ds_TOMARATCAMADEUS)='S' THEN 1 ELSE 0 END --rgelis 2018/02/20 req.99999

			
			--Id de la Reserva a insertar
			Declare @Id_ReservasGDS INT 
			--Detalles del Tkt a insertar			
			Declare
				@Id INT,
				@PaxApe CHAR (40),
				@PaxName CHAR (40),
				@PaxPrefix CHAR (4),
				@Tkt CHAR (10),
				@TktPrefix CHAR (3),
				@TktRevisado CHAR (10),
				@TktRevisadoPrefix CHAR (3),
				@FP1 CHAR (3),
				@FP1_Val MONEY,
				@FP1_TC CHAR (2),
				@FP1_TC_number CHAR (16),
				@FP1_TC_exp CHAR (5),
				@FP1_TC_aprob CHAR (6),
				@FP2 CHAR (3),
				@FP2_Val MONEY,
				@FP2_TC CHAR (2),
				@FP2_TC_number CHAR (16),
				@FP2_TC_exp CHAR (5),
				@FP2_TC_aprob CHAR (6),
				@Tao MONEY,
				@TaoIva MONEY,
				@Recargo MONEY,
				@RecargoIva MONEY,
				@TktId CHAR (10),
				--Valores contado y credito del tkt
				@am_TarifaContado MONEY,
				@am_IvaContado MONEY,
				@am_OtrosContado MONEY,
				@am_TarifaCredito MONEY,
				@am_IvaCredito MONEY,
				@am_OtrosCredito MONEY,
				-- Over de Aerolinea
				@cd_over VARCHAR(25),
				@FPTAO CHAR (3), --inicio rgelis 2017/02/21 req.47359
				@FPTAO_Val MONEY,
				@FPTAO_TC CHAR (2),
				@FPTAO_TC_number CHAR (16),
				@FPTAO_TC_exp CHAR (4),
				@FPTAO_TC_aprob CHAR(6), --fin rgelis 2017/02/21 req.47359
				@FP1_TC_voucher CHAR(6), --inicio rgelis 2017/06/05 req.48084
				@FP2_TC_voucher CHAR(6),
				@FPTAO_TC_voucher CHAR(6), --inicio rgelis 2017/06/05 req.48084
				@in_cantpax int, --rgelis 2017/08/24 req.35871
				@cd_Pseudo VARCHAR(5), --rgelis 2017/08/30 req.52081
				@in_cuotasTarjetaTAO INT; 
			Declare @TomarTiqueteadorFacturadorAmadeus Varchar(1)
			DECLARE @bl_usada INT --rgelis 2018/12/12 req.74918
			--Informacion de pasajero y formas de pago	   
			Declare @Table_Pax TABLE (
					Id INT IDENTITY NOT NULL,
					PaxApe VARCHAR(40),
					PaxName VARCHAR(40),
					PaxPrefix CHAR(4),
					Tkt CHAR(10),
					TktPrefix CHAR(3),		
					TktRevisado CHAR(10),
					TktRevisadoPrefix CHAR(3),
					FP1 CHAR(3),
					FP1_Val MONEY,
					FP1_TC CHAR(2),
					FP1_TC_number CHAR(16),
					FP1_TC_exp CHAR(5),
					FP1_TC_aprob CHAR(6),
					FP1_TC_voucher CHAR(6),
					FP2 CHAR(3),
					FP2_Val MONEY,
					FP2_TC CHAR(2),
					FP2_TC_number CHAR(16),
					FP2_TC_exp CHAR(5),
					FP2_TC_aprob CHAR(6),
					FP2_TC_voucher CHAR(6),
					Tao MONEY,
					TaoIva MONEY,
					Recargo MONEY,
					RecargoIva MONEY,
					TktId CHAR(10) null,
					Pasaporte VARCHAR(25) null,
					FPTAO CHAR (3), --inicio rgelis 2017/02/21 req.47359
					FPTAO_Val MONEY,
					FPTAO_TC CHAR (2),
					FPTAO_TC_number CHAR (16),
					FPTAO_TC_exp CHAR (4),
					FPTAO_TC_aprob CHAR(6) null, --fin rgelis 2017/02/21 req.47359
					in_cantpax INT, --rgelis 2017/08/24 req.35871
					cd_Pseudo VARCHAR(5) NULL --rgelis 2017/08/30 req.52081
				)	
											
			
			Declare @Table_CodigoReservas TABLE
			(
			id INT IDENTITY,
			CodigoAerolinea CHAR (2),
			CodigoReserva VARCHAR(20)
			)

			Declare @ReservaGDS_FormasPagos TABLE 
			(
			id						INT IDENTITY NOT NULL,
			in_orden				INT NOT NULL,
			cd_reserva				VARCHAR(12) NOT NULL,
			cd_consecutivo			VARCHAR(25) NOT NULL,
			cd_tipoitem				VARCHAR(25) NULL,
			cd_codigo				VARCHAR(50) NOT NULL,
			ds_nombre				VARCHAR(50) NOT NULL,
			cd_tipotarjeta			VARCHAR(2) NULL,
			ds_numerotarjeta		VARCHAR(16) NULL,
			ds_vouchertarjeta		VARCHAR(25) NULL,
			ds_expiraciontarjeta	VARCHAR(5) NULL,
			ds_autorizaciontarjeta	VARCHAR(25) NULL,
			in_coutas				INT NULL,
			cd_banco				VARCHAR(3) NULL,
			ds_cheque				VARCHAR(30) NULL,
			ds_plaza				VARCHAR(30) NULL,
			ds_referencia			VARCHAR(50) NULL,
			ds_Poliza				VARCHAR(20) NULL,
			ds_PolizaAnexo			VARCHAR(20) NULL,
			am_valor				MONEY NOT NULL
			)

			Declare 
				@cd_Segmento CHAR(3),
				@in_PaxActual INT,
				@Cadena VARCHAR(MAX),
				@PosPlus INT,
				@PosPlusBarra INT,
				@PosBarra INT,
				@PosBarra2 INT,
				@PosPuntoComa INT,
				@PosIndex INT /*rgelis 2015/07/13 req.25868*/
				 
			--inicio rgelis 2017/03/10 req.48084
			DECLARE @CamposGDSValores TABLE(Tiqueteador VARCHAR(6)
									 ,Vendedor VARCHAR(3)
									 ,Cliente VARCHAR(25)
									 ,RazonSocialCliente VARCHAR(250)
									 ,DireccionCliente VARCHAR(50)
									 ,PaisCliente VARCHAR(25)
									 ,TelefonoCliente VARCHAR(25)
									 ,EmailCliente VARCHAR(100)
									 ,CiudadCliente VARCHAR(50)
									 ,CodigoIata VARCHAR(25)
									 ,PasaportePax VARCHAR(25)
									 ,[over] VARCHAR(25)
									 ,tourcodereserva VARCHAR(25)
									 ,tourcodetiquete VARCHAR(25)
									 ,contrato VARCHAR(25)
									 ,Evento VARCHAR(250)
									 ,Categoria VARCHAR(25)
									 ,centrocosto VARCHAR(50)
									 ,sucursal VARCHAR(5)
									 ,implante VARCHAR(5)
									 ,Autorizacion VARCHAR(25) --inicio rgelis 2017/06/05 req.48084
									 ,Voucher VARCHAR(10)
									 ,Autorizacion2 VARCHAR(25)
									 ,Voucher2 VARCHAR(10)
									 ,AutorizacionTAO VARCHAR(25)
									 ,VoucherTAO VARCHAR(10)	  --fin rgelis 2017/06/05 req.48084
									 ,CantidadPasajero INT --rgelis 2017/08/24 req.35871
									 ,Pseudo VARCHAR(5) --rgelis 2017/08/30 req.52081
									 ,Proveedor VARCHAR(25) --ini rgelis 2019/09/26 req.103173
									 ,Conceptofacturacion VARCHAR(3)
									 ,Tiposervicio VARCHAR(3)
									 ,Descripcionservicios VARCHAR(500)
									 ,Pasajeros VARCHAR(100)
									 ,PasajerosNombres VARCHAR(50)
									 ,PasajerosApellidos VARCHAR(50) --fin rgelis 2019/09/26 req.103173
									 ,ds_Observaciones VARCHAR(8000)
									 ,FormaPagoTAO VARCHAR(3)
									 ,TarjetaCreditoTAO CHAR(2)
									 ,NumeroTarjetaTAO CHAR(16)
									 ,VencimientoTarjetaTAO CHAR(5)
									 ,CuotasTarjetaTAO INT
									 ,FormaPago VARCHAR(3)
									 ,TarjetaCredito CHAR(2)
									 ,NumeroTarjeta CHAR(16)
									 ,VencimientoTarjeta CHAR(5)
									 ,CuotasTarjeta INT
									 )
			INSERT INTO @CamposGDSValores(Tiqueteador,Vendedor,Cliente,RazonSocialCliente,DireccionCliente,PaisCliente,TelefonoCliente,EmailCliente,CiudadCliente
								,CodigoIata,PasaportePax,[over],tourcodereserva,tourcodetiquete,contrato,Evento,Categoria,centrocosto,sucursal,implante
								,Autorizacion,Voucher,Autorizacion2,Voucher2,AutorizacionTAO,VoucherTAO,CantidadPasajero,Pseudo --inicio rgelis 2017/06/05 req.48084 --rgelis 2017/08/24 req.35871 --rgelis 2017/08/30 req.52081
								,Proveedor, Conceptofacturacion, Pasajeros, PasajerosNombres, PasajerosApellidos,ds_Observaciones
								,FormapagoTAO,TarjetaCreditoTAO,NumeroTarjetaTAO,VencimientoTarjetaTAO,CuotasTarjetaTAO,Formapago,TarjetaCredito,NumeroTarjeta,VencimientoTarjeta,CuotasTarjeta) --figelis 2019/09/26 req.103173 
			SELECT Tiqueteador,Vendedor,Cliente,RazonSocialCliente,DireccionCliente,PaisCliente,TelefonoCliente,EmailCliente,CiudadCliente
				  ,CodigoIata,PasaportePax,[over],tourcodereserva,tourcodetiquete,contrato,Evento,Categoria,centrocosto,sucursal,implante
				  ,Autorizacion,Voucher,Autorizacion2,Voucher2,AutorizacionTAO,VoucherTAO,CantidadPasajero,Pseudo --rgelis 2017/08/30 req.52081 --inicio rgelis 2017/06/05 req.48084 --rgelis 2017/08/24 req.35871
				  ,Proveedor, Conceptofacturacion, Pasajeros, PasajerosNombres, PasajerosApellidos, ds_Observaciones  --figelis 2019/09/26 req.103173 
				  ,FormaPagoTAO,TarjetaCreditoTAO,NumeroTarjetaTAO,VencimientoTarjetaTAO,CuotasTarjetaTAO,FormaPago,TarjetaCredito,NumeroTarjeta,VencimientoTarjeta,CuotasTarjeta
			FROM dbo.fnza_ConfiguracionCamposGDS_ObtenerValores_Table(NULL,@GDS,2)
			--fin rgelis 2017/03/10 req.48084						  
				   
			--Obtenemos el tipo de reserva
			Select @TipoReserva = substring(Fila,1,3) 
			From @TableReserva Where id = 1
										
			Select 
				@VarAux = substring(Fila,118,len(fila))
			From @TableReserva Where id = 4	 
			
			Select 
				@CodReserva_alterno = substring(Fila,7,6)
			From @TableReserva Where id = 4	 

			IF @AIROPT <> '7D'
			BEGIN
				Select 
					@CodAerolinea_alterno = substring(Fila,charindex(';',Fila)+1,2)
				From @TableReserva Where id = 5
			END

			--Insertamos las aerolineas y los codigos de las reservas encontradas		
			Insert Into @Table_CodigoReservas(CodigoReserva)
			EXEC SpSplitMejorado @VarAux,';',0	
			
			-- actualizamos la tablas de tal manera que las aerolineas y los codigos
			-- de las reservas queden con las estructura deseada
			UPDATE @Table_CodigoReservas
			Set CodigoAerolinea = LEFT(CodigoReserva,2),
			CodigoReserva = substring(CodigoReserva,4,len(CodigoReserva))
			
			
			--Si es anulado el codigo de la aerolinea no viene en la linea 5
			IF EXISTS (SELECT * From @TableReserva Where id = 2 AND Fila LIKE '%Void%')
			BEGIN 
				--Obtenemos el codigo de la primera reserva
				Select TOP 1 
					@CodigoReserva = CodigoReserva,
					@CodigoAerolinea = CodigoAerolinea
				From @Table_CodigoReservas Where CodigoReserva is not null and CodigoReserva <> ''
				ORDER BY id DESC 
			END 
			ELSE 
			BEGIN 
				--Obtenemos el codigo de la primera reserva
				Select TOP 1 
					@CodigoReserva = CodigoReserva,
					@CodigoAerolinea = CodigoAerolinea
				From @Table_CodigoReservas Where CodigoReserva is not null and CodigoReserva <> ''
				ORDER BY id 			
				
				--Le colocamos el codigo alterno de la aerolinea
				Set @CodigoAerolinea=@CodAerolinea_alterno						
							
			END 
			
			If ISNULL(@CodigoReserva,'') <> @CodReserva_alterno AND ISNULL(@CodReserva_alterno,'') <> ''
			Begin 
				Set @CodigoReserva = @CodReserva_alterno
			End 
			
			--Obtenemos el Codigo IATA
			Declare @Table_IATA TABLE
			(
			id INT IDENTITY,
			cd_iata VARCHAR(25)
			)
			Set @VarAux=''
			SELECT @VarAux = Fila From @TableReserva Where Id = 4
			Insert Into @Table_IATA
			EXEC SpSplitMejorado @VarAux,';',0	
			Select @cd_iata = cd_iata from @Table_IATA Where id = 10

			--Obtenemos la aerolinea externa
			Select @AerolineaExterna = rtrim(Valor) From dbo.Parametros Where Id = 239
			Select @CodAerolineaExterna = cd_siglas From dbo.Entidades Where cd_codigo = @AerolineaExterna			
			
			If @CodigoReserva IS NULL OR @CodigoReserva = ''
			Begin
				  	Declare @bl_permit			 BIT 	, -- Permiso de ejecucion del proceso
				  			@bl_as 	   			 BIT	, -- Auditar exito
					 		@bl_af 			     BIT	, -- Auditar fallido	 		
							@procmsg	VARCHAR(8000)	, -- Mensaje devuelto por procedimientos llamados desde este procedimiento
							@procret 	BIT 			, -- Valor de retorno de los proce		
							@cd_consecutivo CHAR(8)		; -- Consecutivo del proceso
				
				
					EXEC @procret = dbo.spza_IncrementaConsecutivo_sys_entidades @Id_Sys_Entidades = 31,
													@cd_consecutivo = @cd_consecutivo OUTPUT ,
													@errmsg	= @procmsg OUTPUT;			
													
					Set @CodigoReserva = RIGHT(@cd_consecutivo,6)
	
			End 
		
			--------------------------------------------------------------------
			-- Datos adicionales Opcionales por el cliente.
			--------------------------------------------------------------------
			--Centro de costo del cliente
			If (Select TOP 1 len(fila) - CHARINDEX('CENTRO COSTO',fila)+13 From @TableReserva Where FILA LIKE '%CENTRO COSTO%') > 0
			Begin
				Select 
					@cd_centrocosto=left(substring(fila,CHARINDEX('CENTRO COSTO',fila)+13,len(fila)),50)
				From @TableReserva Where FILA LIKE '%CENTRO COSTO%'
			End
		
			If (Select TOP 1 len(fila) - CHARINDEX('CENTRO DE COSTO',fila)+16 From @TableReserva Where FILA LIKE '%CENTRO DE COSTO%') > 0
			Begin
				Select 
					@cd_centrocosto=left(substring(fila,CHARINDEX('CENTRO DE COSTO',fila)+16,len(fila)),50)
				From @TableReserva Where FILA LIKE '%CENTRO DE COSTO%'
			End		
			--Quitamos el caracter (:) 
			Set @cd_centrocosto = REPLACE(@cd_centrocosto,':','')

			--Lapso de Viaje
			If (Select TOP 1 len(fila) - CHARINDEX('LAPSO VIAJE',fila)+12 From @TableReserva Where FILA LIKE '%LAPSO VIAJE%') > 0
			Begin
				Select 
					@ds_lapsoviaje=left(substring(fila,CHARINDEX('LAPSO VIAJE',fila)+12,len(fila)),50)
				From @TableReserva Where FILA LIKE '%LAPSO VIAJE%'
			End
			
			If (Select TOP 1 len(fila) - CHARINDEX('LAPSO DE VIAJE',fila)+15 From @TableReserva Where FILA LIKE '%LAPSO DE VIAJE%') > 0
			Begin
				Select 
					@ds_lapsoviaje=left(substring(fila,CHARINDEX('LAPSO DE VIAJE',fila)+15,len(fila)),50)
				From @TableReserva Where FILA LIKE '%LAPSO DE VIAJE%'
			End				
			
			--Solicita
			If (Select top 1 len(fila) - CHARINDEX('SOLICITA',fila)+9 From @TableReserva Where FILA LIKE '%SOLICITA%') > 0
			Begin							
				Select 
					@ds_solicita=left(substring(fila,CHARINDEX('SOLICITA',fila)+9,len(fila)),200)
				From @TableReserva Where FILA LIKE '%SOLICITA%'
			End			  
		
			--Cedula Pax
			If (Select top 1 len(fila) - CHARINDEX('-CEDULA',fila)+8 From @TableReserva Where FILA LIKE '%-CEDULA%') > 0
			Begin
				Select 
					@cd_Pax_CC=left(ltrim(rtrim(substring(fila,CHARINDEX('-CEDULA',fila)+7,len(fila)))),20)
				From @TableReserva Where FILA LIKE '%-CEDULA%'
			End	
					
			--CON-CC
			If (Select top 1 len(fila) - CHARINDEX('CON-CC',fila)+7 From @TableReserva Where FILA LIKE '%CON-CC%') > 0
			Begin
				Select 
					@cd_Pax_CC=left(substring(fila,CHARINDEX('CON-CC',fila)+7,len(fila)),20)
				From @TableReserva Where FILA LIKE '%CON-CC%'
			End	
					
			-- Valido que la reserva no este anulada	
			IF NOT EXISTS (SELECT * From @TableReserva Where id = 2 AND Fila LIKE '%Void%')
			BEGIN 			
			
				Select 
					@AnoReserva = substring(ltrim(Fila),17,2),--3
					@MesReserva = substring(ltrim(Fila),19,2),--5
					@DiaReserva = substring(ltrim(Fila),21,2)--7
				From @TableReserva Where LEFT(fila,2) = 'D-' --id = 8 --rgelis 2018/05/31 ticket.23157 
				Set @FechaReserva = '20'+@AnoReserva+@MesReserva+@DiaReserva
 			
				Set @in_AnoReserva = '20'+@AnoReserva

				Select @AerolineaVende = substring(Fila,11,2) 
				From @TableReserva Where LEFT(fila,2) = 'A-' --id = 5 --rgelis 2018/05/31 ticket.23157 
				
				Select @TomarTiqueteadorFacturadorAmadeus = Valor From Parametros Where Id=555

				--@Tiqueteador = substring(Fila,18,6) --Gematours lo usa asi.
				Select 
					@Vendedor = substring(Fila,22,2),
					@Facturador = substring(Fila,18,6),
					@Tiqueteador = substring(Fila,CASE WHEN @TomarTiqueteadorFacturadorAmadeus = 'S' Then 18 Else 9 END,6)
--					
				From @TableReserva Where LEFT(fila,2) = 'C-' --id = 7 --rgelis 2018/05/31 ticket.23157 		

				Select 
					@Nacionalidad = CASE substring(Fila,3,1) WHEN 'X' THEN 2 Else 1 End,
					@Origen = substring(Fila,8,3),
					@Destino = substring(Fila,11,3) 		
				From @TableReserva Where id = 9
					
				/*Jramirez 20171018 - */
				Declare @ReservasSabreUnicaNacionalidad Varchar(50)
				Select @ReservasSabreUnicaNacionalidad = rtrim(Valor) From dbo.Parametros Where Id = 501
				IF @ReservasSabreUnicaNacionalidad  = 'Internacional'
				Begin
					Set @Nacionalidad = 2
				End

				-----------------------------------------
				----- Segemento 'H-' Itinerarios --------
				-----------------------------------------
				Declare @Itinerarios VARCHAR(63)
				Declare @Clases VARCHAR(29)
				Declare @MaxFile INT, @Itinerario VARCHAR(MAX),@cd_origen CHAR(3), @cd_destino CHAR(3), @MaxId INT, @VarItinerario CHAR(3),@PrimerTkt varchar(11)					
				Declare @bl_PermitirVOID BIT /*rgelis 2016/06/07 req.30086*/
				Declare @Table_ItinerariosAux TABLE	(id INT IDENTITY, Valor CHAR(3))			
				Declare @Table_Itinerarios TABLE
				(
				id INT IDENTITY,
				cd_origen CHAR (3),
				cd_destino CHAR (3),
				cd_clase CHAR (1),
				ds_NumVuelo VARCHAR(25),
				fecha_salida SMALLDATETIME,
				hora_salida VARCHAR (5),
				hora_llegada VARCHAR (5),
				terminal VARCHAR (50),
				cd_aero_siglas CHAR(2),
				cd_farebasis VARCHAR(25),
				bl_anulado INT,
				am_co2 MONEY
				)
				Declare @Table_FareBasis TABLE
				(
				id INT IDENTITY,
				cd_farebasis VARCHAR(25)
				)
				Set @VarAux=''
				SELECT @VarAux = SUBSTRING(Fila,3,LEN(fila)-2) From @TableReserva Where LEFT(fila,2) = 'M-' AND fila NOT LIKE '%VOID%'			
				Insert Into @Table_FareBasis
				EXEC SpSplitMejorado @VarAux,';',0
				
				SET @bl_PermitirVOID=0	 /*rgelis 2016/06/07 req.30086*/
				SELECT @bl_PermitirVOID=CASE WHEN LTRIM(Valor)='S' THEN 1 ELSE 0 END from parametros where id=456 					
						
				Insert Into @Table_Itinerarios (cd_origen,cd_destino,cd_clase,ds_NumVuelo,fecha_salida,hora_salida,hora_llegada,terminal,cd_aero_siglas,bl_anulado,am_co2)
				Select 
					CASE WHEN bl_anulado = 1 THEN Origen ELSE Origen END, /*rgelis 2016/06/07 req.30086*/
					CASE WHEN bl_anulado = 1 THEN Destino ELSE Destino END, 
					CASE WHEN bl_anulado = 1 THEN Clase ELSE Clase END,  /*rgelis 2016/06/07 req.30086*/
					Numero_Vuelo AS 'ds_NumVuelo', 
					ISNULL(convert(SMALLDATETIME,CASE WHEN Mes_Salida > Mes_llegada OR @MesReserva > Mes_Salida THEN convert(CHAR(4),@in_AnoReserva+1) Else convert(CHAR(4),@in_AnoReserva) End+Mes_Salida+Dia_Salida),'19000101') AS 'Fecha_salida',  /*rgelis 2016/06/07 req.30086*/
					--convert(SMALLDATETIME,CASE WHEN Mes_llegada < Mes_Salida THEN convert(CHAR(4),@in_AnoReserva+1) Else convert(CHAR(4),@in_AnoReserva) End+Mes_llegada+Dia_llegada) AS 'Fecha_llegada', 
					Hora_Salida+Minuto_Salida AS 'Hora_salida', 
					Hora_llegada+Minuto_llegada	AS 'Hora_llegada',
					Destino AS 'Terminal',
					CASE WHEN bl_anulado = 1 THEN '' ELSE LEFT(rtrim(Aerolinea),2) END AS 'cd_aero_siglas',
					bl_anulado,
					am_co2 = ISNULL(am_co2,0)
				From (
					Select 
					substring(Fila,11,3) AS 'Origen',
					substring(Fila,33,3) AS 'Destino',
					substring(Fila,66,1) AS 'Clase',
					substring(Fila,61,4) AS 'Numero_Vuelo',
					substring(Fila,55,4) AS 'Aerolinea',
					'Mes_Salida' = CASE substring(Fila,72,3)  
									WHEN 'JAN' THEN  '01'
									WHEN 'FEB' THEN  '02'
									WHEN 'MAR' THEN  '03'
									WHEN 'APR' THEN  '04'
									WHEN 'MAY' THEN  '05'
									WHEN 'JUN' THEN  '06'
									WHEN 'JUL' THEN  '07'
									WHEN 'AUG' THEN  '08'
									WHEN 'SEP' THEN  '09'
									WHEN 'OCT' THEN  '10'
									WHEN 'NOV' THEN  '11'
									WHEN 'DEC' THEN  '12'
								End,
					substring(Fila,70,2) AS 'Dia_Salida',
					substring(Fila,75,2) AS 'Hora_Salida',
					substring(Fila,77,2) AS 'Minuto_Salida',
					'Mes_llegada' = CASE substring(Fila,87,3)  
									WHEN 'JAN' THEN  '01'
									WHEN 'FEB' THEN  '02'
									WHEN 'MAR' THEN  '03'
									WHEN 'APR' THEN  '04'
									WHEN 'MAY' THEN  '05'
									WHEN 'JUN' THEN  '06'
									WHEN 'JUL' THEN  '07'
									WHEN 'AUG' THEN  '08'
									WHEN 'SEP' THEN  '09'
									WHEN 'OCT' THEN  '10'
									WHEN 'NOV' THEN  '11'
									WHEN 'DEC' THEN  '12'
								End,		
					substring(Fila,85,2) AS 'Dia_llegada',
					substring(Fila,80,2) AS 'Hora_llegada',
					substring(Fila,82,2) AS 'Minuto_llegada',
					bl_anulado =  CASE WHEN Fila LIKE '%VOID%' THEN 1 ELSE 0 END,
					am_co2=CASE WHEN LEN(Fila)>20 AND CHARINDEX('CO2-',Fila)>0 AND ISNUMERIC(REPLACE(SUBSTRING(Fila,CHARINDEX('CO2-',Fila)+4,CHARINDEX('KG',Fila)),'KG',''))=1 THEN CONVERT(MONEY,REPLACE(SUBSTRING(Fila,CHARINDEX('CO2-',Fila)+4,CHARINDEX('KG',Fila)),'KG','')) ELSE 0 END
					--am_co2=CASE WHEN ISNUMERIC(REPLACE(RIGHT(Fila,LEN(Fila)-CHARINDEX('CO2-',Fila)-3),'KG',''))=1 THEN CONVERT(MONEY,REPLACE(RIGHT(Fila,LEN(Fila)-CHARINDEX('CO2-',Fila)-3),'KG','')) ELSE 0 END
					From @TableReserva Where LEFT(fila,2) = 'H-' AND (fila NOT LIKE '%VOID%' OR @bl_PermitirVOID=1)	 /*rgelis 2016/06/07 req.30086*/
					) AS Consulta			
				Select @MaxFile = @@ROWCOUNT
				
				--Actualizamos el fare basis del itinerario
				UPDATE TI SET cd_farebasis = tfb.cd_farebasis
				FROM @Table_Itinerarios ti
				INNER JOIN @Table_FareBasis tfb ON tfb.id = ti.id
				
				Set @Count = 1
				While @Count <= @MaxFile
				Begin 	
					--SELECT 	@cd_origen AS '@cd_origen'
					Select @cd_origen = CASE WHEN bl_anulado = 1 THEN '' ELSE cd_origen END, @cd_destino = CASE WHEN bl_anulado = 1 THEN '' ELSE cd_destino END From @Table_Itinerarios Where Id = @Count
					Select @MaxId = MAX(id) From @Table_ItinerariosAux
					Select @VarItinerario = Valor From @Table_ItinerariosAux Where id = @MaxId				
					--Select @MaxId, @VarAux, @cd_origen,@cd_destino					
					If ((@VarItinerario <> @cd_origen OR @VarItinerario IS NULL) AND @cd_origen<>'') 
					Begin 
						Insert Into @Table_ItinerariosAux(Valor)
						Select @cd_origen
					End 
						
					If ((@VarItinerario <> @cd_destino OR @VarItinerario IS NULL) AND @cd_destino<>'') 
					Begin
						Insert Into @Table_ItinerariosAux(Valor)
						Select @cd_destino
					End 
					
					Set @Count = @Count + 1
				End

				Set @Itinerarios=''
				Select @Itinerarios = @Itinerarios + Valor + '/' From @Table_ItinerariosAux 
				IF LEN(RTRIM(@Itinerarios)) > 0 
					Select @Itinerarios = left(@Itinerarios,len(@Itinerarios)-1)
				
				-- Obtenemos los itinerarios
				--Set @Itinerarios=''
				--Select @Itinerarios = @Itinerarios + cd_origen + '/' From @Table_itinerarios
				--Select @Itinerarios = @Itinerarios + cd_destino From @Table_itinerarios Where id = (Select max(id) From @Table_itinerarios)			
				--Select @Itinerarios
										
				-- Obtenemos las clases
				Set @clases = ''
				Select @clases = @clases + CASE WHEN cd_clase IS NULL OR cd_clase = '' THEN '' Else cd_clase + '/' End From @Table_itinerarios
				-- Select @clases = @clases + cd_clase + '/' From @Table_itinerarios
				IF LEN(RTRIM(@clases)) > 0 
					Set  @clases = substring(@clases,1,len(@clases)-1)
				
				--debug
				--Select * From @Table_Itinerarios
					
	   			-------------------------------------------------------
				---------- Segemento 'K-F' Tarifa de Tiquetes ---------
				-- si no existe se busca en Tiquetes revisados 'K-R' --
				-------------------------------------------------------
				Declare 
				@am_tarifa MONEY,
				@cd_MonedaTarifa CHAR(3),
				@am_tarifalocal MONEY,
				@cd_MonedaTarifalocal CHAR(3),
				@am_total MONEY,
				@cd_Monedatotal CHAR(3), --rgelis 2018/11/14 req.74260
				@am_tcambiousd MONEY,
				@cd_MonedaTarifaAux CHAR(3),
				@am_tarifaAux MONEY,
				@am_tarifalocalAux MONEY,
				@cd_MonedaTarifalocalAux CHAR(3),
				@am_totalAux MONEY,
				@cd_linea VARCHAR(4)
				--Inicializamos la tabla
				/*inicio rgelis 2013/12/09 req.17703*/
				INSERT INTO #TableValoresAux(Fila)  
				Select Fila From @TableReserva Where LEFT(fila,3) in ('K-F','K-R','K-I','ATC','K-B') OR LEFT(fila,4) in ('KS-R','KN-I','KS-I','KN-B','KS-F'); --rgelis 2018/11/14 req.74260
				
				Select @MaxFilaAux = @@ROWCOUNT;
				
				Set @CountAux = 1
			
				--TRUNCATE TABLE Table_Aux_GDS
				--Set @VarAux=''		
				--Select @VarAux = Fila From @TableReserva Where LEFT(fila,3) = 'K-F'	
				--If @VarAux <> '' AND @VarAux IS NOT NULL 
				--Begin 
				--	Select @am_tarifalocal = substring(Campo,4,len(campo)) From Table_Aux_GDS Where id = 2
				--	Select @cd_MonedaTarifalocal = substring(Campo,1,3) From Table_Aux_GDS Where id = 2				
				--End 
				--If @VarAux = '' OR @VarAux IS NULL 
				--Begin
				--	Select @VarAux = Fila From @TableReserva Where LEFT(fila,3) = 'K-R'
				--End 

				--/*rgelis 2013/03/14 se comentario porque estaba ingresando en KS-R y os valores vienen mal en halcon*/
				--If exists(Select Fila From @TableReserva Where LEFT(fila,4) = 'KS-R')
				--Begin
				--	--Select @VarAux = replace(fila,'KS-R','K-R') From @TableReserva Where LEFT(fila,4) = 'KS-R'
				--	--Valor Revisado en Dolares
				--	Set @bl_KS_R = 1
				--End 
				While @CountAux <= @MaxFilaAux
				BEGIN
					TRUNCATE TABLE Table_Aux_GDS

					Set @VarAux=''
					Set @cd_linea=''
					Select @VarAux = Fila, @cd_linea=LEFT(Fila,3) From #TableValoresAux Where LEFT(Fila,3) = 'K-F' AND  id = @CountAux 	 
					
					If @VarAux = '' OR @VarAux IS NULL 
					Begin
						Select @VarAux = Fila, @cd_linea=LEFT(Fila,3) From #TableValoresAux Where LEFT(Fila,3) = 'K-R' AND id = @CountAux
					End

					If @VarAux = '' OR @VarAux IS NULL 
					Begin
						Select @VarAux = Fila, @cd_linea=LEFT(Fila,3) From #TableValoresAux Where LEFT(Fila,3) = 'ATC' AND id = @CountAux
					End

					If @VarAux = '' OR @VarAux IS NULL 
					Begin
						Select @VarAux = Fila, @cd_linea=LEFT(Fila,3) From #TableValoresAux Where LEFT(Fila,3) = 'K-B' AND id = @CountAux
					End

					IF @ComportamientoSistema <> 'Ecuador'
					Begin
						If @VarAux = '' OR @VarAux IS NULL 
						Begin
							Select @VarAux = Fila, @cd_linea=LEFT(Fila,3) From #TableValoresAux Where LEFT(Fila,3) = 'K-I' AND id = @CountAux
						End 
						If @VarAux = '' OR @VarAux IS NULL 
						Begin
							Select @VarAux = replace(Fila,'KN-I','K-I'), @cd_linea=LEFT(Fila,4) From #TableValoresAux Where LEFT(Fila,4) = 'KN-I' AND id = @CountAux
						End
					
						If @VarAux = '' OR @VarAux IS NULL 
						Begin
							Select @VarAux = replace(fila,'KS-I','K-I'), @cd_linea=LEFT(Fila,4) From #TableValoresAux Where LEFT(Fila,4) = 'KS-I' AND id = @CountAux
						End
						If @VarAux = '' OR @VarAux IS NULL --Registros se agregan para que puedan subir reservas en colaereo
						Begin
							Select @VarAux = replace(fila,'Kn-b','K-b'), @cd_linea=LEFT(Fila,4) From #TableValoresAux Where LEFT(Fila,4) = 'Kn-b' AND id = @CountAux
						End
					end	  
					
					/*rgelis 2013/03/14 se comentario porque estaba ingresando en KS-R y os valores vienen mal en halcon*/
					If exists(Select Fila From #TableValoresAux Where LEFT(Fila,4) = 'KS-R' AND id = @CountAux)
					Begin
						IF @ds_TOMARKSRAMADEUS = 'S' 
						BEGIN 
							Select @VarAux = replace(fila,'KS-R','K-R'), @cd_linea=LEFT(Fila,4) From #TableValoresAux Where LEFT(Fila,4) = 'KS-R' AND id = @CountAux
						END
						--Valor Revisado en Dolares
						Set @bl_KS_R = 1
					End
					If exists(Select Fila From #TableValoresAux Where LEFT(Fila,4) = 'KS-F' AND id = @CountAux)
					BEGIN
						IF @ds_TOMARKSFAMADEUS = 'S' 
						BEGIN 
							Select @VarAux = replace(fila,'KS-F','K-F'), @cd_linea=LEFT(Fila,4) From #TableValoresAux Where LEFT(Fila,4) = 'KS-F' AND id = @CountAux
						END
						Set @bl_KS_F = 1
					END  
					Insert Into Table_Aux_GDS
					EXEC SpSplitMejorado @VarAux,';',0	

					
					IF @cd_linea<>'ATC'
					BEGIN
						
						Select @am_tarifa = substring(Campo,7,len(campo)) From Table_Aux_GDS Where id = 1
						Select @cd_MonedaTarifa = rtrim(substring(Campo,4,3)) From Table_Aux_GDS Where id = 1 /*rgelis 2013/09/25 req.17118*/
						--IF EXISTS (SELECT * FROM dbo.Parametros WHERE id = 240 AND Valor<>'Ecuador' and @bl_KS_R = 0) /*rgelis 2013/09/25 req.17118*/
						IF @bl_KS_R = 0 /*rgelis 2013/09/25 req.17118*/
						BEGIN 
							Select @am_tarifalocal = CASE WHEN ISNUMERIC(substring(Campo,4,len(campo)))=1 THEN Convert(Money,substring(Campo,4,len(campo))) ELSE 0 END From Table_Aux_GDS Where id = 2 /*rgelis 2013/03/21 se cambia para que valide si viene letra y no numero*/
						END

						Select @cd_MonedaTarifalocal = substring(Campo,1,3) From Table_Aux_GDS Where id = 2
						Select @am_total = substring(Campo,4,11) From Table_Aux_GDS Where id = 13
						Select @cd_Monedatotal=rtrim(ltrim(substring(Campo,1,3))) From Table_Aux_GDS Where id = 13 --inicio rgelis 2018/11/14 req.74260
							
						IF (@cd_Monedatotal='' AND @cd_linea ='K-F' AND @ComportamientoSistema = 'Costa Rica') 
						BEGIN
							SET @ds_TOMARKSFAMADEUS = 'S'
							SET @ds_TOMARKSTFAMADEUS = 'S'
						END 
						ELSE IF (@cd_linea ='K-R' AND @ComportamientoSistema = 'Costa Rica') 
						BEGIN
							SET @ds_TOMARKSRAMADEUS = 'S'
						END--fin rgelis 2018/11/14 req.74260
							  
						IF (@ds_TOMARKSRAMADEUS = 'S' AND @bl_KS_R = 1)
						BEGIN
							Select @am_tarifa = CASE WHEN @am_total=0 THEN 0 ELSE @am_tarifa END
								   ,@am_tarifalocal = @am_total
							Delete FROM @TableValores
						END

						Set @am_tarifa = ISNULL(@am_tarifa,0)
						Set @am_tarifalocal = ISNULL(@am_tarifalocal,0)
						Set @am_total = ISNULL(@am_total,0)
				
						Select @am_tcambiousd = substring(Campo,1,11) From Table_Aux_GDS Where id = 14
						If @am_tcambiousd = 0 
						Begin
							Set @am_tcambiousd = 1
						End 	
						/*inicio rgelis 2013/09/25 req.17118*/								
						If @bl_KS_R = 1 And @am_tcambiousd > 1	
						Begin
							Set @am_tarifa = @am_tarifa * @am_tcambiousd
						End
						Else If isnull(@cd_MonedaTarifa,'') <> '' AND @Cod_TarifaLocalAgencia <> @cd_MonedaTarifa And @am_tcambiousd > 1 AND @am_tarifalocal > 0
						BEGIN
							Set @am_tarifa = @am_tarifalocal
						END

					END
					ELSE IF (EXISTS(SELECT Fila FROM @TableReserva WHERE LEFT(fila,3) IN ('EMD','ICW','MFP') OR LEFT(fila,4) IN ('TMCD','TMCN')) AND @bl_ATC=1) --rgelis 2017/11/21 req.54786 --rgelis 2018/02/20 req.99999 
					BEGIN 
						
						SELECT @am_tarifaAux = CASE WHEN ISNUMERIC(substring(Campo,4,len(campo)))=1 THEN Convert(Money,substring(Campo,4,len(campo))) ELSE 0 END From Table_Aux_GDS Where id = 3
						SELECT @cd_MonedaTarifaAux = substring(Campo,1,3) From Table_Aux_GDS Where id = 3
						SELECT @am_tarifalocalAux = CASE WHEN ISNUMERIC(substring(Campo,4,len(campo)))=1 THEN Convert(Money,substring(Campo,4,len(campo))) ELSE 0 END From Table_Aux_GDS Where id = 3
						SELECT @cd_MonedaTarifalocalAux = substring(Campo,1,3) From Table_Aux_GDS Where id = 3
						
						IF @ComportamientoSistema = 'Colombia'
						BEGIN
							SELECT @am_totalAux =CASE WHEN ISNUMERIC(substring(Campo,4,len(campo)))=1 THEN Convert(Money,substring(Campo,4,len(campo))) ELSE 0 END From Table_Aux_GDS Where id = 8
						END
						ELSE
						BEGIN
							SELECT @am_totalAux =CASE WHEN ISNUMERIC(substring(Campo,4,len(campo)))=1 THEN Convert(Money,substring(Campo,4,len(campo))) ELSE 0 END From Table_Aux_GDS Where id = 7
						END 

						IF @am_tarifaAux > 0
						BEGIN
							SET @am_tarifa=@am_tarifaAux
							SET @cd_MonedaTarifa = @cd_MonedaTarifaAux
						END
						IF @am_tarifalocalAux > 0
						BEGIN
							SET @am_tarifalocal = @am_tarifalocalAux
							SET @cd_MonedaTarifalocal= @cd_MonedaTarifalocalAux
						END
						IF @am_totalAux > 0
						BEGIN
							SET @am_total=@am_totalAux
						END
					END
					--select  @am_tarifalocal as'@am_tarifalocal',* from @TableValores
					if not exists(select * from @TableValores)
					begin
						INSERT INTO @TableValores (ds_moneda, am_tarifaLocal, am_tarifa, am_total, am_iva, am_tua, am_comb, am_vat, am_iva2) 
						SELECT ds_moneda=@cd_MonedaTarifalocal
							   ,am_tarifaLocal = @am_tarifalocal
							   ,am_tarifa=@am_tarifa
							   ,am_total=@am_total
							   ,0 ,0 ,0, 0, 0
					end
					else
					begin
						UPDATE @TableValores
						SET	 ds_moneda = @cd_MonedaTarifalocal
							,am_tarifaLocal = @am_tarifalocal
							,am_tarifa = @am_tarifa
							,am_total	= @am_total
						--WHERE id=@CountAux
					end	
					SET @CountAux = @CountAux + 1
					/*fin rgelis 2013/09/25 req.17118*/
			   		--Select @am_tarifa AS '@am_tarifa',@am_tarifalocal AS '@am_tarifalocal',@am_tcambiousd
					
				END
				/*fin rgelis 2013/12/09 req.17703*/
				
				----------------------------------------------------------
				--EMD Para reservas con AIROPT = 7D
				----------------------------------------------------------
				IF @AIROPT = '7D'
				BEGIN
					TRUNCATE TABLE #TableValoresAux
				
					INSERT INTO #TableValoresAux(Fila)  
					Select Fila From @TableReserva Where LEFT(fila,3) in ('EMD') 
				
					Select @MaxFilaAux = @@ROWCOUNT;
				
					Set @CountAux = 1
					While @CountAux <= @MaxFilaAux
					BEGIN
							TRUNCATE TABLE Table_Aux_GDS
							Set @VarAux = '' 	
							Select @VarAux = Fila From #TableValoresAux Where LEFT(fila,3) in ('EMD') AND id = @CountAux 
						
							Insert Into Table_Aux_GDS
							EXEC SpSplitMejorado @VarAux,';',0	
							Select @MaxFila = @@ROWCOUNT
							--Select @VarAux As '@VarAux'
							--Select * From Table_Aux_GDS

							Select @cd_MonedaTarifalocal = substring(Campo,1,3) From Table_Aux_GDS Where id = 29
							Select @am_total = substring(Campo,4,11) From Table_Aux_GDS Where id = 29
							Select @am_tarifalocal = @am_total
							Select @am_total = @am_total
							--Select @cd_Monedatotal=rtrim(ltrim(substring(Campo,1,3))) From Table_Aux_GDS Where id = 29

							IF NOT EXISTS(SELECT * FROM @TableValores)
							BEGIN
								INSERT INTO @TableValores (ds_moneda, am_tarifaLocal, am_tarifa, am_total, am_iva, am_tua, am_comb, am_vat , am_iva2) 
								SELECT ds_moneda=@cd_MonedaTarifalocal
									   ,am_tarifaLocal = @am_tarifalocal
									   ,am_tarifa=@am_tarifa
									   ,am_total=@am_total
									   ,0 ,0 ,0, 0, 0
							END
							ELSE
							BEGIN
								UPDATE @TableValores
								SET	 ds_moneda = @cd_MonedaTarifalocal
									,am_tarifaLocal = @am_tarifalocal
									,am_tarifa = @am_tarifa
									,am_total	= @am_total
								--WHERE id=@CountAux
							END
							SET @CountAux = @CountAux + 1 
					END
				END
				----------------------------------------------------------		
				---- Segemento 'KFTF' Extrae informacion de impuestos ----
				----------------------------------------------------------
				Declare 
					@am_IVA MONEY,
					@am_Tasas MONEY,
					@am_CMB MONEY,
					@am_Otr MONEY,
					@cd_ImpCode CHAR(2),
					@Len INT,
					@ds_Otr CHAR(1),
					@am_iva2 MONEY
				Set @Count = 1	
				Set @VarAux=''
				
				/*inicio rgelis 2013/12/09 req.17703*/
				--Inicializamos la tabla
				--TRUNCATE TABLE Table_Aux_GDS
				--Set @VarAux = '' 	
				--Select @VarAux = Fila From @TableReserva Where LEFT(fila,4) = 'KFTF'

				TRUNCATE TABLE #TableValoresAux

				INSERT INTO #TableValoresAux(Fila)
				Select Fila From @TableReserva Where (LEFT(fila,4) in ('KFTF','KNTB','KFTB','KSTF') OR (LEFT(fila,4)='KSTF' AND @ds_TOMARKSTFAMADEUS='S')) --rgelis 2018/11/14 req.74260
				Select @MaxFilaAux = @@ROWCOUNT
				SET @CountAux = 1
				
				While @CountAux <= @MaxFilaAux
				BEGIN
						TRUNCATE TABLE Table_Aux_GDS
						Set @VarAux = '' 	
						Select @VarAux = Fila From #TableValoresAux Where LEFT(fila,4) in ('KFTF','KNTB','KFTB','KSTF') AND id = @CountAux --rgelis 2018/11/14 req.74260
						
						Insert Into Table_Aux_GDS
						EXEC SpSplitMejorado @VarAux,';',0	
						Select @MaxFila = @@ROWCOUNT
						Declare @TamanoValor int
						
						SELECT @am_IVA = 0
							   ,@am_Tasas = 0
						       ,@am_CMB = 0
						       ,@am_Otr = 0
							   ,@cd_ImpCode =''
							   ,@Count =1
							   ,@am_iva2 = 0

						While @Count <= @MaxFila
						Begin 
							Select @Len = len(Campo) From Table_Aux_GDS Where id = @Count
					
							If exists(Select * From Table_Aux_GDS Where id = @Count and Campo like '%usd%' AND @Nacionalidad = 1)
							Begin
								Select @cd_ImpCode = substring(Campo,12,2) From Table_Aux_GDS Where id = @Count
								Set @TamanoValor = 7 
							End
					
					
							If ltrim(rtrim(isnull(@cd_ImpCode,''))) = '' And @Len >= 15	 /*rgelis 2013/12/16 req.18157*/
							BEGIN
								Select @cd_ImpCode = substring(Campo,14,2) From Table_Aux_GDS Where id = @Count
								Set @TamanoValor = 9
							End 
							-- YS = IVA de la tarifa del Tkt --EC IVA Ecuador --DO Iva Republica Dominicana
							-- YQ = Cargo por Combustible del Tkt
							-- CO = Tasa aeroportuaria del Tkt --ED Tasas ECuador
							If @cd_ImpCode ='YS' OR @cd_ImpCode ='EC' Or @cd_ImpCode ='DO' Or @cd_ImpCode='CR' Or (@cd_ImpCode='IF' And @ComportamientoSistema = 'Salvador')
							Begin
								If ((@cd_ImpCode = 'YS' And (@ComportamientoSistema = 'Ecuador' Or @ComportamientoSistema='República Dominicana' OR @ComportamientoSistema = 'Costa Rica'))
								   OR (@cd_ImpCode = 'EC' AND @ComportamientoSistema='República Dominicana')
								   OR (@cd_ImpCode = 'EC' AND (@ComportamientoSistema='Colombia' OR @ComportamientoSistema='Costa Rica')) --rgelis 2017/06/21 req.50787
								   OR (@cd_ImpCode = 'DO' AND (@ComportamientoSistema='Colombia' OR @ComportamientoSistema='Costa Rica')))
								Begin
									Select @am_Otr = isnull(@am_Otr,0) + convert(money,substring(Campo,5,@TamanoValor)) From Table_Aux_GDS Where id = @Count
								End
								ELSE If @cd_ImpCode = 'EC' And @ComportamientoSistema <> 'Ecuador' And @ComportamientoSistema <> 'República Dominicana'
								BEGIN
									Select @am_IVA = isnull(@am_IVA,0)
								END
								ELSE If @cd_ImpCode = 'IF' And @ComportamientoSistema = 'Salvador' 
								BEGIN
									Select @am_IVA = isnull(@am_IVA,0) + CASE WHEN ISNUMERIC(substring(Campo,5,@TamanoValor))=1 THEN convert(money,substring(Campo,5,@TamanoValor)) ELSE 0 END From Table_Aux_GDS Where id = @Count	
								END
								ELSE If @cd_ImpCode = 'CR' And @ComportamientoSistema = 'Costa Rica' 
								BEGIN
									Select @am_IVA = isnull(@am_IVA,0) + CASE WHEN ISNUMERIC(substring(Campo,5,@TamanoValor))=1 THEN convert(money,substring(Campo,5,@TamanoValor)) ELSE 0 END From Table_Aux_GDS Where id = @Count	
								END
								ELSE
								Begin
									--Select @am_IVA = isnull(@am_IVA,0) + convert(money, substring(Campo,5,@TamanoValor)) From Table_Aux_GDS Where id = @Count /*rgelis 2013/03/21 se cambia para que valide si viene letra y no numero*/
									Select @am_IVA = isnull(@am_IVA,0) + CASE WHEN ISNUMERIC(substring(Campo,5,@TamanoValor))=1 THEN convert(money,substring(Campo,5,@TamanoValor)) ELSE 0 END From Table_Aux_GDS Where id = @Count	/*rgelis 2013/03/21 se cambia para que valide si viene letra y no numero*/
								End
							End 
							Else If @cd_ImpCode ='CO' And (@ComportamientoSistema <> 'Ecuador' AND @ComportamientoSistema<>'República Dominicana')
							Begin
								Select @am_Tasas = isnull(@am_Tasas,0) + CASE isnumeric(convert(money,substring(Campo,5,@TamanoValor))) WHEN 1 THEN convert(money,substring(Campo,5,@TamanoValor)) Else 0 End  From Table_Aux_GDS Where id = @Count
							End 
							Else If @cd_ImpCode ='ED' And @ComportamientoSistema = 'Ecuador'
							Begin
								Select @am_Tasas = isnull(@am_Tasas,0) + CASE isnumeric(convert(money,substring(Campo,5,@TamanoValor))) WHEN 1 THEN convert(money,substring(Campo,5,@TamanoValor)) Else 0 End  From Table_Aux_GDS Where id = @Count
							End
							Else If (@cd_ImpCode ='YQ' OR (@cd_ImpCode ='YR' And (@ComportamientoSistema = 'Ecuador' Or @ComportamientoSistema='República Dominicana' Or @bl_TomarYQYRAmadeusReservaGDS=1))) /*rgelis 2013/09/28 req.17117*/
							Begin
								Select @am_CMB = isnull(@am_CMB,0) +convert(money,substring(Campo,5,@TamanoValor)) From Table_Aux_GDS Where id = @Count
							End
							Else If (@cd_ImpCode ='N8' And @ComportamientoSistema IN ('Costa Rica')) /*jramirez 2019/07/04 R90597*/
							Begin
								Select @am_iva2 = isnull(@am_iva2,0) +convert(money,substring(Campo,5,@TamanoValor)) From Table_Aux_GDS Where id = @Count
							End
							Else If len(rtrim(@cd_ImpCode)) = 2
							Begin
								Select @am_Otr = isnull(@am_Otr,0) + convert(money,substring(Campo,5,@TamanoValor)) From Table_Aux_GDS Where id = @Count
							End 
							Set @cd_ImpCode=''			 						
							Set @Count = @Count + 1
						End 
							
						Set @am_IVA = isnull(@am_IVA,0)
						Set @am_Tasas = isnull(@am_Tasas,0)
						Set @am_CMB = isnull(@am_CMB,0)
						Set @am_Otr = isnull(@am_Otr,0)
						Set @am_iva2 = isnull(@am_iva2,0)
						
						UPDATE @TableValores
						SET	 am_iva = @am_IVA
							,am_tua = @am_Tasas
							,am_comb = @am_CMB
							,am_vat	= @am_Otr
							,am_iva2=@am_iva2
							,am_tarifaLocal = am_tarifalocal - isnull(@am_iva2,0)
							,am_tarifa = am_tarifa - isnull(@am_iva2,0)
						WHERE id=@CountAux
						SET @CountAux = @CountAux + 1 
				END
				/*fin rgelis 2013/12/09 req.17703*/					
				--Comision de la aerolinea
				Declare @am_comision MONEY
				Set @VarAux = '' 	
				Select @VarAux = Fila From @TableReserva Where LEFT(fila,5) = 'FM*M*'			
				If @VarAux <> ''
				Begin
					Set @PosPuntoComa = CHARINDEX(';',@VarAux)
					If @PosPuntoComa > 0
					Begin
						Select @am_comision = CASE WHEN ISNUMERIC(substring(@VarAux,6,@PosPuntoComa-6))=1 THEN convert(Money,substring(@VarAux,6,@PosPuntoComa-6)) ELSE 0 END
					End
					Else
					Begin
						Select @am_comision = CASE WHEN ISNUMERIC(substring(@VarAux,6,len(@VarAux)-5))=1 THEN convert(Money,substring(@VarAux,6,len(@VarAux)-5)) ELSE 0 END
					End
				End

				TRUNCATE TABLE #TableValoresAux

				INSERT INTO #TableValoresAux(Fila)
				Select Fila From @TableReserva Where LEFT(fila,4) = 'KFTR'
				Select @MaxFilaAux = @@ROWCOUNT
				SET @CountAux = 1
						
				--Inicializamos la tabla Revisados
				IF @ComportamientoSistema = 'Ecuador' OR @ComportamientoSistema='República Dominicana' OR @ComportamientoSistema='Costa Rica' OR @ds_TOMARKFTRAMADEUS='S' --rgelis 2017/06/22 req.50487
				BEGIN 
					/*inicio rgelis 2013/12/09 req.17703*/
					--TRUNCATE TABLE Table_Aux_GDS
					--Set @VarAux = '' 	
					--Select @VarAux = Fila From @TableReserva Where LEFT(fila,4) = 'KFTR'
					--Insert Into Table_Aux_GDS
					--EXEC SpSplitMejorado @VarAux,';',0
					While @CountAux <= @MaxFilaAux
					BEGIN
						TRUNCATE TABLE Table_Aux_GDS
						Set @VarAux = '' 	
						Select @VarAux = Fila From #TableValoresAux Where LEFT(fila,4) = 'KFTR' AND id = @CountAux
						Insert Into Table_Aux_GDS
						EXEC SpSplitMejorado @VarAux,';',0	
						Select @MaxFila = @@ROWCOUNT
						SELECT @am_IVA = 0
							   ,@am_Tasas = 0
						       ,@am_CMB = 0
						       ,@am_Otr = 0
							   ,@cd_ImpCode =''
							   ,@Count = 1
							   ,@am_iva2 = 0
			   			While @Count <= @MaxFila
						Begin  
							Select @cd_ImpCode = substring(Campo,14,2),@ds_Otr=substring(Campo,1,1) From Table_Aux_GDS Where id = @Count
							If @cd_ImpCode ='YS' OR @cd_ImpCode ='EC' Or @cd_ImpCode ='DO' Or @cd_ImpCode ='CR' Or @cd_ImpCode ='NI' Or @cd_ImpCode ='IF'
							Begin
								If ((@cd_ImpCode = 'YS' And (@ComportamientoSistema = 'Ecuador' Or @ComportamientoSistema='República Dominicana'))
									OR (@cd_ImpCode = 'EC' AND @ComportamientoSistema='República Dominicana')
									OR (@cd_ImpCode = 'EC' AND (@ComportamientoSistema='Colombia' OR @ComportamientoSistema='Costa Rica')) --rgelis 2017/06/21 req.50787
									OR (@cd_ImpCode = 'DO' AND @ComportamientoSistema='Colombia')
									OR (@ds_Otr='O' AND (@ComportamientoSistema='Ecuador' OR @ComportamientoSistema='Colombia' OR @ComportamientoSistema='República Dominicana'))
									OR (@cd_ImpCode = 'NI' AND @ComportamientoSistema<>'Nicaragua')
									OR (@cd_ImpCode = 'IF' AND @ComportamientoSistema<>'Salvador')) --inicio rgelis 2017/12/06 correciones por terranova que no esta tomando el iva de esta linea 
								Begin
									if (@ds_Otr<>'O' AND @ComportamientoSistema='Costa Rica') OR (@ComportamientoSistema<>'Costa Rica') 
									Begin   
										Select @am_Otr = isnull(@am_Otr,0) + substring(Campo,5,9) From Table_Aux_GDS Where id = @Count And substring(Campo,1,1)<>'O' --para desacrtar los impuestos con O adelante
									End
								End
								ELSE If (@cd_ImpCode = 'IF' And @ComportamientoSistema = 'Salvador' AND @ds_Otr<>'O')
								Begin
									Select @am_IVA = isnull(@am_IVA,0) + substring(Campo,5,9) From Table_Aux_GDS Where id = @Count 
								End
								ELSE If (@cd_ImpCode = 'CR' And @ComportamientoSistema = 'Costa Rica' AND @ds_Otr<>'O')
								Begin
									Select @am_IVA = isnull(@am_IVA,0) + substring(Campo,5,9) From Table_Aux_GDS Where id = @Count 
								End
								Else 
								Begin  
									if NOT(@cd_ImpCode = 'EC' AND @ComportamientoSistema='Costa Rica')
										Select @am_IVA = isnull(@am_IVA,0) +substring(Campo,5,9) From Table_Aux_GDS Where id = @Count And substring(Campo,1,1)<>'O' /*rgelis 2013/02/28 req.12908*/
								End
							End	 
							Else If (@cd_ImpCode ='CO' And @ComportamientoSistema <> 'Ecuador' AND @ComportamientoSistema<>'República Dominicana')
							Begin
								Select @am_Tasas = isnull(@am_Tasas,0) + CASE isnumeric(substring(Campo,5,9)) WHEN 1 THEN Convert(Money,substring(Campo,5,9)) Else 0 End  From Table_Aux_GDS Where id = @Count And substring(Campo,1,1)<>'O'/*rgelis 2013/02/28 req.12908*/
							End
							Else If @cd_ImpCode ='ED' And @ComportamientoSistema = 'Ecuador'
							Begin
								Select @am_Tasas = isnull(@am_Tasas,0) + CASE isnumeric(substring(Campo,5,9)) WHEN 1 THEN Convert(Money,substring(Campo,5,9)) Else 0 End  From Table_Aux_GDS Where id = @Count And substring(Campo,1,1)<>'O'/*rgelis 2013/02/28 req.12908*/
							End 
							Else If (@cd_ImpCode ='YQ' OR (@cd_ImpCode ='YR' And (@ComportamientoSistema = 'Ecuador' OR @ComportamientoSistema='República Dominicana' Or @bl_TomarYQYRAmadeusReservaGDS=1))) /*rgelis 2013/09/28 req.17117*/
							Begin
								Select @am_CMB = isnull(@am_CMB,0) +substring(Campo,5,9) From Table_Aux_GDS Where id = @Count And substring(Campo,1,1)<>'O'/*rgelis 2013/02/28 req.12908*/
							End
							Else If (@cd_ImpCode ='N8' And @ComportamientoSistema IN ('Costa Rica')) /*jramirez 2019/07/04 R90597*/
							Begin
								Select @am_iva2 = isnull(@am_iva2,0) +convert(money,substring(Campo,5,9)) From Table_Aux_GDS Where id = @Count And substring(Campo,1,1)<>'O' --rgelis 2019/11/05 ticket:102395
							End
							Else If len(rtrim(@cd_ImpCode)) = 2 
							Begin
								IF (
									@ComportamientoSistema<>'Costa Rica' OR 
									(@cd_ImpCode IN('CP','SQ','RC','CA','XD','XC','XB','UK','QQ','XV','MX','QV','JD') AND @ds_Otr<>'O' AND @ComportamientoSistema='Costa Rica') --rgelis 2018/03/20 ticket:14124 --rgelis 2018/04/18 ticket:17614
									) 
								BEGIN
									Select @am_Otr = isnull(@am_Otr,0) + substring(Campo,5,9) From Table_Aux_GDS Where id = @Count AND @ds_Otr<>'O' 
								END
							End 									
							Set @Count = @Count + 1
						End 
				
						Set @am_IVA = isnull(@am_IVA,0)
						Set @am_Tasas = isnull(@am_Tasas,0)
						Set @am_CMB = isnull(@am_CMB,0)
						Set @am_Otr = isnull(@am_Otr,0)
						Set @am_IVA2 = isnull(@am_IVA2,0)
						UPDATE @TableValores
						SET	 am_iva = @am_IVA
							,am_tua = @am_Tasas
							,am_comb = @am_CMB
							,am_vat	= @am_Otr
							,am_iva2 = @am_IVA2
							,am_tarifaLocal = am_tarifalocal - isnull(@am_iva2,0)
							,am_tarifa = am_tarifa - isnull(@am_iva2,0)
						WHERE id=@CountAux
						SET @CountAux = @CountAux + 1
						 
					 END
					 /*fin rgelis 2013/12/09 req.17703*/
				END 
				
				
				/*inicio rgelis 2013/12/09 req.17703*/

				TRUNCATE TABLE #TableValoresAux

				INSERT INTO #TableValoresAux(Fila)
				Select Fila From @TableReserva Where LEFT(fila,4) IN ('KFTI','KNTI','KSTI')
				Select @MaxFilaAux = @@ROWCOUNT
				SET @CountAux = 1

				IF (@ComportamientoSistema <> 'Ecuador' AND @ComportamientoSistema<>'República Dominicana')
				BEGIN
					While @CountAux <= @MaxFilaAux
					BEGIN
						TRUNCATE TABLE Table_Aux_GDS
						Set @VarAux = '' 	
						Select @VarAux = Fila From #TableValoresAux Where LEFT(fila,4) IN ('KFTI','KNTI','KSTI') AND id = @CountAux
						Insert Into Table_Aux_GDS
						EXEC SpSplitMejorado @VarAux,';',0	
						Select @MaxFila = @@ROWCOUNT
						SELECT @am_IVA = 0
							   ,@am_Tasas = 0
						       ,@am_CMB = 0
						       ,@am_Otr = 0
							   ,@cd_ImpCode =''
							   ,@Count = 1
							   ,@am_IVA2 = 0
			   			While @Count <= @MaxFila
						Begin 
							Select @cd_ImpCode = substring(Campo,14,2) From Table_Aux_GDS Where id = @Count
					
							If @cd_ImpCode ='YS'
							Begin
								Select @am_IVA = isnull(@am_IVA,0) +substring(Campo,5,9) From Table_Aux_GDS Where id = @Count And substring(Campo,1,1)<>'O'
							End 
							ELSE If (@cd_ImpCode ='CR' AND @ComportamientoSistema='Costa Rica')
							Begin
								Select @am_IVA = isnull(@am_IVA,0) +substring(Campo,5,9) From Table_Aux_GDS Where id = @Count And substring(Campo,1,1)<>'O'
							End
							Else If @cd_ImpCode ='CO' 
							Begin
								Select @am_Tasas = isnull(@am_Tasas,0) + CASE isnumeric(substring(Campo,5,9)) WHEN 1 THEN substring(Campo,5,9) Else 0 End  From Table_Aux_GDS Where id = @Count And substring(Campo,1,1)<>'O'
							End
							--Else If @cd_ImpCode ='ED' And @ComportamientoSistema = 'Ecuador'
							--Begin
							--	Select @am_Tasas = isnull(@am_Tasas,0) + CASE isnumeric(substring(Campo,5,9)) WHEN 1 THEN substring(Campo,5,9) Else 0 End  From Table_Aux_GDS Where id = @Count And substring(Campo,1,1)<>'O'
							--End 
							Else If @cd_ImpCode ='YQ'  
							Begin
								Select @am_CMB = isnull(@am_CMB,0) +substring(Campo,5,9) From Table_Aux_GDS Where id = @Count And substring(Campo,1,1)<>'O'
							End
							Else If (@cd_ImpCode ='N8' And @ComportamientoSistema IN ('Costa Rica')) /*jramirez 2019/07/04 R90597*/
							Begin
								Select @am_iva2 = isnull(@am_iva2,0) +convert(money,substring(Campo,5,9)) From Table_Aux_GDS Where id = @Count AND substring(Campo,1,1)<>'O' --rgelis 2019/11/05 ticket:102395
							End
							Else If len(rtrim(@cd_ImpCode)) = 2
							Begin
								Select @am_Otr = isnull(@am_Otr,0) + substring(Campo,5,9) From Table_Aux_GDS Where id = @Count
							End 			
										
							Set @Count = @Count + 1
						End 
				
						Set @am_IVA = isnull(@am_IVA,0)
						Set @am_Tasas = isnull(@am_Tasas,0)
						Set @am_CMB = isnull(@am_CMB,0)
						Set @am_Otr = isnull(@am_Otr,0)
						Set @am_IVA2 = isnull(@am_IVA2,0)
						UPDATE @TableValores
						SET	 am_iva = @am_IVA
							,am_tua = @am_Tasas
							,am_comb = @am_CMB
							,am_vat	= @am_Otr
							,am_iva2 = @am_IVA2
							,am_tarifaLocal = am_tarifalocal - isnull(@am_iva2,0)
							,am_tarifa = am_tarifa - isnull(@am_iva2,0)
						WHERE id=@CountAux
						SET @CountAux = @CountAux + 1
						 
					 END
				END
				/*fin rgelis 2013/12/09 req.17703*/

				--Debug
				-- Select * from  @TableValores
				--	@am_Otr as '@am_Otr'
				--	,@am_CMB as '@am_CMB'
				--	,@am_Tasas as '@am_Tasas'
				--	,@am_IVA as '@am_IVA'

				/*inicio rgelis 2014/07/11 req.20502*/
				DECLARE @TablaFPEMD Table(id INT IDENTITY,ds_StrFP VARCHAR(500))
				Declare @ds_MonedaEMD CHAR(3)
				       ,@am_tarifaLocalEMD MONEY
					   ,@am_tarifaEMD MONEY
					   ,@am_totalEMD MONEY
					   ,@cd_codigoEMD CHAR(3)
					   ,@cd_indexEMD CHAR(25) --rgelis 2017/04/10 req.... Correcion de por caso en gematours
 					   ,@cd_AerolineaPenalidadEMD CHAR(3)
					   ,@cd_PenalidadEMD CHAR(11)
					   ,@cd_AerolineaEMD CHAR(3)
					   ,@cd_tiqueteEMD CHAR(11)
					   ,@cd_campo CHAR(3)
					   ,@FP1EMD CHAR (3)
					   ,@FP1_ValEMD MONEY
					   ,@FP1_TCEMD CHAR (2)
					   ,@FP1_TC_numberEMD CHAR (16)
					   ,@FP1_TC_expEMD CHAR (5)
					   ,@FP1_TC_aprobEMD CHAR (6)
					   ,@FP2EMD CHAR (3)
					   ,@FP2_ValEMD MONEY
					   ,@FP2_TCEMD CHAR (2)
					   ,@FP2_TC_numberEMD CHAR (16)
					   ,@FP2_TC_expEMD CHAR (5)
					   ,@FP2_TC_aprobEMD CHAR (6)
					   ,@am_ivaEMD MONEY /*inicio rgelis 2017/02/09 req.47238*/
					   ,@am_tuaEMD MONEY
					   ,@am_combEMD MONEY
					   ,@am_vatEMD MONEY /*inicio rgelis 2017/02/09 req.47238*/
					   ,@am_iva2EMD MONEY
					   
				TRUNCATE TABLE #TableValoresAux
				INSERT INTO #TableValoresAux(Fila)
				Select Fila From @TableReserva Where LEFT(fila,3) IN ('EMD','ICW','MFP') OR LEFT(fila,4) IN ('TMCD','TMCN')
				Select @MaxFilaAux = @@ROWCOUNT;
				Set @CountAux = 1
			
				While @CountAux <= @MaxFilaAux
				BEGIN
					TRUNCATE TABLE Table_Aux_GDS
					Set @VarAux = '' 	
					Select @VarAux = Fila From #TableValoresAux Where LEFT(fila,3)='EMD'and id = @CountAux
					Insert Into Table_Aux_GDS
					EXEC SpSplitMejorado @VarAux,';',0	
					insert into	@TableEMDValores(ds_Moneda, am_tarifaLocal, am_tarifa, am_total, cd_codigo, cd_index, cd_AerolineaPenalidad, cd_Penalidad,cd_Aerolinea, cd_tiquete, FP1, FP1_Val, FP1_TC, FP1_TC_number, FP1_TC_exp, FP1_TC_aprob,FP2, FP2_Val, FP2_TC, FP2_TC_number, FP2_TC_exp, FP2_TC_aprob,Descripcion, am_iva, am_tua, am_comb, am_vat, am_iva2) /*rgelis 2017/02/09 req.47238*/
					select
						ds_Moneda=MAX(ds_Moneda)
						,am_tarifaLocal=MAX(am_tarifaLocal)
						,am_tarifa=MAX(am_tarifa)
						,am_total=MAX(am_total)
						,cd_codigo=MAX(cd_codigo)
						,cd_index=MAX(cd_index)
						,cd_AerolineaPenalidad=MAX(cd_AerolineaPenalidad)
						,cd_Penalidad=MAX(cd_Penalidad)
						,cd_Aerolinea=MAX(cd_Aerolinea)
						,cd_tiquete=MAX(cd_tiquete)
						,FP1=MAX(FP1)
						,FP1_Val=MAX(FP1_Val)
						,FP1_TC=MAX(FP1_TC)
						,FP1_TC_number=MAX(FP1_TC_number)
						,FP1_TC_exp=MAX(FP1_TC_exp)
						,FP1_TC_aprob=MAX(FP1_TC_aprob)
						,FP2=MAX(FP2)
						,FP2_Val=MAX(FP2_Val)
						,FP2_TC=MAX(FP2_TC)
						,FP2_TC_number=MAX(FP2_TC_number)
						,FP2_TC_exp=MAX(FP2_TC_exp)
						,FP2_TC_aprob=MAX(FP2_TC_aprob)
						,Descripcion=MAX(Descripcion)
						,am_iva = MAX(am_iva)
						,am_tua = MAX(am_tua)
						,am_comb = MAX(am_comb)
						,am_vat = MAX(am_vat)
						,am_iva2 = MAX(am_iva2)
					FROM (	
						SELECT ds_Moneda=CASE WHEN e.id=29 THEN substring(e.Campo,1,3) ELSE '' END
								,am_tarifaLocal=CASE WHEN e.id=27 THEN Convert(money,substring(e.Campo,4,LEN(e.Campo))) ELSE 0 END
								,am_tarifa=CASE WHEN e.id=29 THEN Convert(money,substring(e.Campo,4,LEN(e.Campo))) ELSE 0 END
								,am_total=CASE WHEN e.id=32 THEN Convert(money,substring(e.Campo,4,LEN(e.Campo))) ELSE 0 END
								,cd_codigo= CASE WHEN e.id=1 THEN substring(Campo,4,LEN(e.Campo)) ELSE '' END
								,cd_index= CASE WHEN e.id=6 THEN substring(Campo,1,LEN(e.Campo)) ELSE '' END
								,cd_AerolineaPenalidad=CASE WHEN e.id=3 THEN substring(e.Campo,1,3) ELSE '' END
								,cd_Penalidad=''
								,cd_Aerolinea=''
								,cd_tiquete=''
								,FP1=''
								,FP1_Val=0
								,FP1_TC=''
								,FP1_TC_number=''
								,FP1_TC_exp=''
								,FP1_TC_aprob=''
								,FP2=''
								,FP2_Val=0
								,FP2_TC=''
								,FP2_TC_number=''
								,FP2_TC_exp=''
								,FP2_TC_aprob=''
								,Descripcion = CASE WHEN e.id=19 THEN rtrim(e.campo) ELSE '' END
								,am_iva = ISNULL(v.am_IVA,0) --inicio rgelis 2017/02/10 req.47238
								,am_tua = ISNULL(v.am_Tasas,0)
								,am_comb = ISNULL(v.am_CMB,0)
								,am_vat = ISNULL(v.am_Otr,0) --fin rgelis 2017/02/10 req.47238
								,am_iva2 = ISNULL(v.am_iva2,0)
						FROM Table_Aux_GDS e 
						OUTER APPLY dbo.fnza_ValoresCargoImpEMD_Table(@VarAux) AS v --rgelis 2017/02/10 req.47238
						WHERE Campo IS NOT NULL
					) AS T
					SET @CountAux= @CountAux + 1
				END
				
				SET @CountAux = 1

				UPDATE @TableEMDValores
				SET am_tarifaLocal = 0, am_tarifa= 0, am_total= 0
				WHERE descripcion = 'RESIDUAL VALUE'

				UPDATE @TableEMDValores
				SET	 am_tarifalocal	= ABS(isnull((am_total - (am_iva + am_tua + am_comb + am_vat + am_iva2)),0))	
				WHERE (am_tarifalocal + am_iva + am_tua + am_comb + am_vat) <> am_total
						
				While @CountAux <= @MaxFilaAux
				BEGIN 
					TRUNCATE TABLE Table_Aux_GDS
					Set @VarAux = '' 	
					Select @VarAux = Fila From #TableValoresAux Where (LEFT(fila,3) IN ('ICW','MFP') OR LEFT(fila,4) IN ('TMCD','TMCN')) AND id = @CountAux
					Insert Into Table_Aux_GDS
					EXEC SpSplitMejorado @VarAux,';',0	
					Select @MaxFila = @@ROWCOUNT
					SELECT @am_tarifaEMD = 0
							,@cd_campo =''
							,@Count = 1;

					IF LEFT(@VarAux,3)= 'ICW'
					BEGIN
					   SELECT @cd_AerolineaEMD='',@cd_indexEMD='',@cd_indexEMD=''	
					   SELECT @cd_AerolineaEMD=substring(Campo,4,3),@cd_tiqueteEMD=substring(Campo,7,10) FROM Table_Aux_GDS WHERE id=1  
					   Select @cd_indexEMD=substring(Campo,1,LEN(Campo)) FROM Table_Aux_GDS WHERE id	= 2
					   UPDATE @TableEMDValores
					   SET cd_Aerolinea=ISNULL(@cd_AerolineaEMD,'')
						  ,cd_tiquete=ISNULL(@cd_tiqueteEMD,'')
					   WHERE cd_index=@cd_indexEMD
					END
					IF LEFT(@VarAux,4)IN ('TMCD','TMCN')
					BEGIN
					   SELECT @cd_AerolineaPenalidadEMD='',@cd_PenalidadEMD='',@cd_indexEMD=''	
					   SELECT @cd_AerolineaPenalidadEMD=substring(Campo,5,3),@cd_PenalidadEMD=substring(Campo,9,10) FROM Table_Aux_GDS WHERE id=1  
					   Select @cd_indexEMD=substring(Campo,1,LEN(Campo)) FROM Table_Aux_GDS WHERE id	= 3
					   UPDATE @TableEMDValores
					   SET cd_AerolineaPenalidad=ISNULL(@cd_AerolineaPenalidadEMD,'')
						  ,cd_Penalidad=ISNULL(@cd_PenalidadEMD,'')
					   WHERE cd_index=@cd_indexEMD
					END
					IF LEFT(@VarAux,3)= 'MFP'
					BEGIN
						 ----------------------------------------
						--Obtenemos la cadena a evaluar
						select @FP1EMD='',@FP1_ValEMD=0,@FP1_TCEMD='',@FP1_TC_numberEMD='',@FP1_TC_expEMD='',@FP1_TC_aprobEMD='',@FP2EMD='',@FP2_ValEMD=0,@FP2_TCEMD='',@FP2_TC_numberEMD='',@FP2_TC_expEMD='',@FP2_TC_aprobEMD=''
						Select @Cadena = campo From Table_Aux_GDS Where id = 1
						Select @cd_indexEMD = substring(Campo,1,LEN(Campo)) From Table_Aux_GDS Where id = 4						
						
						SELECT TOP 1 @am_totalEMD = am_total 
						FROM @TableEMDValores
						WHERE cd_index=@cd_indexEMD 
						ORDER BY id DESC
						
						If substring(@Cadena,4,1) = 'O'
						Begin
							
							Set @PosPlusBarra = charindex('+/',@Cadena)
							Set @Cadena = substring(@cadena,@PosPlusBarra+2,len(@cadena))
							Set @PosPlusBarra = charindex('+',@Cadena)
							If @PosPlusBarra = 0
							Begin 
								EXECUTE dbo.spza_EvaluaFPGDS 
									@Cadena
									, @FP1EMD OUT
									, @FP1_ValEMD OUT
									, @FP1_TCEMD OUT
									, @FP1_TC_numberEMD OUT
									, @FP1_TC_expEMD OUT
									, @FP1_TC_aprobEMD OUT
		
								UPDATE @TableEMDValores
								Set   FP1 = @FP1EMD
									, FP1_Val = CASE WHEN @FP1_ValEMD = 0 THEN @am_totalEMD Else @FP1_ValEMD End 
									, FP1_TC = @FP1_TCEMD
									, FP1_TC_number = @FP1_TC_numberEMD
									, FP1_TC_exp = @FP1_TC_expEMD
									, FP1_TC_aprob = @FP1_TC_aprobEMD
									, FP1_TC_voucher = @FP1_TC_aprobEMD
								Where cd_index = @cd_indexEMD	
							End
							Else If charindex('+/',@Cadena) > 0
							Begin 
								Set @Cadena = substring(@Cadena,charindex('/',@Cadena)+1,len(@Cadena))
								EXECUTE dbo.spza_EvaluaFPGDS 
									@Cadena
									, @FP1EMD OUT
									, @FP1_ValEMD OUT
									, @FP1_TCEMD OUT
									, @FP1_TC_numberEMD OUT
									, @FP1_TC_expEMD OUT
									, @FP1_TC_aprobEMD OUT
				  
								UPDATE @TableEMDValores
								Set   FP1 = @FP1EMD
									, FP1_Val = CASE WHEN @FP1_ValEMD = 0 THEN @am_totalEMD Else @FP1_ValEMD End 
									, FP1_TC = @FP1_TCEMD
									, FP1_TC_number = @FP1_TC_numberEMD
									, FP1_TC_exp = @FP1_TC_expEMD
									, FP1_TC_aprob = @FP1_TC_aprobEMD
									, FP1_TC_voucher = @FP1_TC_aprobEMD
								Where cd_index = @cd_indexEMD		
								------------------------------------------------
								-- Insertamo la Segunda Forma de pago, si tiene
								Set @Cadena = substring(@Cadena,charindex('+/',@Cadena)+2,len(@Cadena))
								EXECUTE dbo.spza_EvaluaFPGDS 
									@cadena 
									, @FP2EMD OUT
									, @FP2_ValEMD OUT
									, @FP2_TCEMD OUT
									, @FP2_TC_numberEMD OUT
									, @FP2_TC_expEMD OUT
									, @FP2_TC_aprobEMD OUT
				  
								UPDATE @TableEMDValores
								Set FP2 = @FP2EMD
									, FP2_Val = CASE WHEN @FP2_ValEMD = 0 THEN @am_totalEMD Else @FP2_ValEMD End 
									, FP2_TC = @FP2_TCEMD
									, FP2_TC_number = @FP2_TC_numberEMD
									, FP2_TC_exp = @FP2_TC_expEMD
									, FP2_TC_aprob = @FP2_TC_aprobEMD
									, FP2_TC_voucher = @FP2_TC_aprobEMD
								Where cd_index = @cd_indexEMD												
							End 						
							Else
							Begin 
								Set @Cadena = substring(@Cadena,charindex('+',@Cadena)-1,len(@Cadena))
								EXECUTE dbo.spza_EvaluaFPGDS 
									@Cadena
									, @FP1EMD OUT
									, @FP1_ValEMD OUT
									, @FP1_TCEMD OUT
									, @FP1_TC_numberEMD OUT
									, @FP1_TC_expEMD OUT
									, @FP1_TC_aprobEMD OUT
				  
								UPDATE @TableEMDValores
								Set   FP1 = @FP1EMD
									, FP1_Val = CASE WHEN @FP1_ValEMD = 0 THEN @am_totalEMD Else @FP1_ValEMD End 
									, FP1_TC = @FP1_TCEMD
									, FP1_TC_number = @FP1_TC_numberEMD
									, FP1_TC_exp = @FP1_TC_expEMD
									, FP1_TC_aprob = @FP1_TC_aprobEMD
									, FP1_TC_voucher = @FP1_TC_aprobEMD
								Where cd_index = @cd_indexEMD	
								------------------------------------------------
								-- Insertamo la Segunda Forma de pago, si tiene
								Set @Cadena = substring(@Cadena,charindex('+',@Cadena)+1,len(@Cadena))
								EXECUTE dbo.spza_EvaluaFPGDS 
									@cadena 
									, @FP2EMD OUT
									, @FP2_ValEMD OUT
									, @FP2_TCEMD OUT
									, @FP2_TC_numberEMD OUT
									, @FP2_TC_expEMD OUT
									, @FP2_TC_aprobEMD OUT
				  
								UPDATE @TableEMDValores
								Set FP2 = @FP2EMD
									, FP2_Val = CASE WHEN @FP2_ValEMD = 0 THEN @am_totalEMD Else @FP2_ValEMD End 
									, FP2_TC = @FP2_TCEMD
									, FP2_TC_number = @FP2_TC_numberEMD
									, FP2_TC_exp = @FP2_TC_expEMD
									, FP2_TC_aprob = @FP2_TC_aprobEMD
									, FP2_TC_voucher = @FP2_TC_aprobEMD
								Where cd_index = @cd_indexEMD												
							End 									
						End 
						Else If charindex('+',@Cadena) > 0
						Begin
							Set  @Cadena =substring(@Cadena,3,len(@Cadena))
							INSERT INTO @TablaFPEMD(ds_StrFP)
							EXEC SpSplitMejorado @Cadena,'+',0
							IF EXISTS(SELECT * FROM @TablaFPEMD WHERE id=1)
							BEGIN
								SELECT @Cadena=ds_StrFP FROM @TablaFPEMD WHERE id=1
								EXECUTE dbo.spza_EvaluaFPGDS 
									@Cadena
									, @FP1EMD OUT
									, @FP1_ValEMD OUT
									, @FP1_TCEMD OUT
									, @FP1_TC_numberEMD OUT
									, @FP1_TC_expEMD OUT
									, @FP1_TC_aprobEMD OUT
								
								UPDATE @TableEMDValores
								Set   FP1 = @FP1EMD
									, FP1_Val = CASE WHEN @FP1_ValEMD = 0 THEN @am_totalEMD Else @FP1_ValEMD End 
									, FP1_TC = @FP1_TCEMD
									, FP1_TC_number = @FP1_TC_numberEMD
									, FP1_TC_exp = @FP1_TC_expEMD
									, FP1_TC_aprob = @FP1_TC_aprobEMD
									, FP1_TC_voucher = @FP1_TC_aprobEMD
								Where cd_index = @cd_indexEMD	  
							END
							------------------------------------------------
							IF EXISTS(SELECT * FROM @TablaFPEMD WHERE id=2)
							BEGIN

								SELECT @Cadena=ds_StrFP FROM @TablaFPEMD WHERE id=2
								EXECUTE dbo.spza_EvaluaFPGDS 
									@cadena 
									, @FP2EMD OUT
									, @FP2_ValEMD OUT
									, @FP2_TCEMD OUT
									, @FP2_TC_numberEMD OUT
									, @FP2_TC_expEMD OUT
									, @FP2_TC_aprobEMD OUT 
								
								UPDATE @TableEMDValores
								Set FP2 = @FP2EMD
									, FP2_Val = CASE WHEN @FP2_ValEMD = 0 THEN @am_totalEMD Else @FP2_ValEMD End 
									, FP2_TC = @FP2_TCEMD
									, FP2_TC_number = @FP2_TC_numberEMD
									, FP2_TC_exp = @FP2_TC_expEMD
									, FP2_TC_aprob = @FP2_TC_aprobEMD
									, FP2_TC_voucher = @FP2_TC_aprobEMD
								Where cd_index = @cd_indexEMD	 
							END	
							
							If (@FP1_ValEMD + @FP2_ValEMD) > @am_totalEMD
							Begin
								If @FP1_ValEMD = @am_total
								Begin
									UPDATE @TableEMDValores
									Set  FP1_Val = abs(@FP2_ValEMD - @FP1_ValEMD) 
									Where cd_index = @cd_indexEMD							
								End 
								Else If @FP2_ValEMD = @am_total
								Begin
									UPDATE @TableEMDValores
									Set  FP1_Val = abs(@FP2_ValEMD - @FP1_ValEMD) 
									Where cd_index = @cd_indexEMD																					
								End 							
							End									
						End 
						Else
						Begin  
							-------------------------------------------------					
							-- Segun la forma de pago, obtenemos los valores.
							Set @Cadena = substring(@Cadena,4,len(@Cadena))
							EXECUTE dbo.spza_EvaluaFPGDS 
									@Cadena
									, @FP1 OUT
									, @FP1_Val OUT
									, @FP1_TC OUT
									, @FP1_TC_number OUT
									, @FP1_TC_exp OUT
									, @FP1_TC_aprob OUT
							
							UPDATE @TableEMDValores
							Set   FP1 = @FP1
								, FP1_Val = CASE WHEN @FP1_Val = 0 THEN @am_totalEMD Else @FP1_Val End 
								, FP1_TC = @FP1_TC
								, FP1_TC_number = @FP1_TC_number
								, FP1_TC_exp = @FP1_TC_exp
								, FP1_TC_aprob = @FP1_TC_aprob
								, FP1_TC_voucher = @FP1_TC_aprob
							Where cd_index = @cd_indexEMD																			   
						End				
					END
					
					IF NOT EXISTS(SELECT P.id
								FROM  @TableEMDValores  p 
								INNER JOIN @Table_Pax t ON (t.Tkt = p.cd_tiquete OR t.TktRevisado = p.cd_tiquete OR t.Tkt = p.cd_Penalidad OR t.TktRevisado = p.cd_Penalidad)
								WHERE p.cd_index=@cd_indexEMD)
					BEGIN
						INSERT INTO @Table_Pax(PaxApe,PaxName,PaxPrefix,Tkt,TktPrefix,TktRevisado,TktRevisadoPrefix,FP1,FP1_Val,FP1_TC,FP1_TC_number,FP1_TC_exp,FP1_TC_aprob,FP1_TC_voucher,FP2,FP2_Val,FP2_TC,FP2_TC_number,FP2_TC_exp,FP2_TC_aprob,FP2_TC_voucher,Tao,TaoIva,Recargo,RecargoIva,TktId,Pasaporte,FPTAO,FPTAO_Val,FPTAO_TC,FPTAO_TC_number,FPTAO_TC_exp,FPTAO_TC_aprob,in_cantpax,cd_Pseudo)
						SELECT PaxApe=t.PaxApe,PaxName=t.PaxName,PaxPrefix=t.PaxPrefix,Tkt=p.cd_tiquete,TktPrefix=P.cd_AerolineaPenalidad,TktRevisado='',TktRevisadoPrefix='',FP1=p.FP1,FP1_Val=p.FP1_Val,FP1_TC=p.FP1_TC,FP1_TC_number=p.FP1_TC_number,FP1_TC_exp=p.FP1_TC_exp,FP1_TC_aprob=p.FP1_TC_aprob,FP1_TC_voucher=p.FP1_TC_voucher,FP2=p.FP2,FP2_Val=p.FP2_Val,FP2_TC=p.FP2_TC,FP2_TC_number=p.FP2_TC_number,FP2_TC_exp=p.FP2_TC_exp,FP2_TC_aprob=p.FP2_TC_aprob,FP2_TC_voucher=p.FP2_TC_voucher,Tao=0,TaoIva=0,Recargo=0,RecargoIva=0,TktId='',Pasaporte='',FPTAO='',FPTAO_Val=0,FPTAO_TC='',FPTAO_TC_number='',FPTAO_TC_exp='',FPTAO_TC_aprob='',in_cantpax=t.in_cantpax,cd_Pseudo=t.cd_Pseudo
						FROM @Table_Pax t
						INNER JOIN @TableEMDValores P ON p.cd_index=@cd_indexEMD
						WHERE t.id=1
					END

					SET @CountAux = @CountAux + 1
				END	
				/*fin rgelis 2014/07/11 req.20502*/
				--------------------------------------------------------------------------------------		
				-------------- Segemento 'I-' -- 'T-' -- 'FO' -- 'FP' -- 'RM' -- 'ENDX' --------------
				---- Extrae informacion de Cliente, Pasajeros, tiquetes, formas de pago y tarifas ---- 
				--------------------------------------------------------------------------------------
		
				--Para evaluar las formas de Pago.	
				Declare @cd_FpCode CHAR (3)
				Declare @am_FpVal MONEY
				Declare @am_FpVal2 MONEY
				Declare @cd_FpTC CHAR (2)
				Declare @cd_FpTC_Number CHAR (16)
				Declare @cd_FpTC_exp CHAR (5)
				Declare @cd_FpTC_aprob CHAR (6)
				Declare @NumTktConjuncion INT
				/*inicio rgelis 2013/07/08 req.---- Informacion de ahorro para gematour*/
				DECLARE @am_highfare MONEY
				DECLARE @am_lowfare MONEY
				DECLARE @am_fare MONEY
				DECLARE @ds_reasoncode CHAR(2)
				/*fin rgelis 2013/07/08 req.---- Informacion de ahorro para gematour*/
				/*inicio rgelis 2013/07/13 req.15354*/
				DECLARE @ds_Evento VARCHAR(250) /*Inicio rgelis 2015/08/19 req.25878 Evento gematour*/
				DECLARE @TablaFP Table(id INT IDENTITY,ds_StrFP VARCHAR(500))
				/*fin rgelis 2013/07/13 req.15354*/
				Set @in_PaxActual = 0
					
				--Inicializamos la tabla donde se guardaran los segmentos que se necesitan.
				TRUNCATE TABLE Table_Aux_GDS
				--Obtenemos los segementos de Cliente, Pasajeros, tiquetes, formas de pago y tarifas
				Insert Into Table_Aux_GDS
				Select Fila 
				From @TableReserva 
				Where LEFT(fila,2) = 'I-'
				OR LEFT(fila,2) = 'T-'
				OR LEFT(fila,2) = 'FO'
				OR LEFT(fila,2) = 'FP'
				OR LEFT(fila,2) = 'RM'
				OR LEFT(fila,4) = 'ENDX'
				OR LEFT(fila,3) = 'RIF'
				OR LEFT(fila,2) = 'FT' --Over Ecuador
				OR LEFT(fila,5) = 'FT*F*' --Over Colombia
				OR LEFT(fila,4) IN ('TMCD','TMCN') --R88490 - Jramirez - EMD 7D(Terranova)
				OR LEFT(fila,3) = 'MFP' --R88490 - Jramirez - EMD 7D(Terranova)
				--Obtenemos el numero de segementos obtenidos e inicializamos el contador
				Select @MaxFila = @@ROWCOUNT
				Set @Count = 1						
			   	While @Count <= @MaxFila
				Begin 
					--Inicializamos las variables 
					Select @Cadena =''
						, @cd_FpCode =''
						, @am_FpVal =''
						, @cd_FpTC =''
						, @cd_FpTC_Number =''
						, @cd_FpTC_exp =''
						, @cd_FpTC_aprob =''
									
					Select @cd_Segmento = substring(Campo,1,2) From Table_Aux_GDS Where id = @Count
					--SELECT @cd_Segmento AS '@cd_Segmento'
					--Codigo del Cliente 
					--Aplica para Ecuador
					If (Select substring(Campo,1,3) From Table_Aux_GDS Where id = @Count) = 'RIF'
					BEGIN
						Select 
							@cd_Cliente = substring(Campo,4,len(Campo)-3)
						From Table_Aux_GDS Where id = @Count
						
					END 	   
					--Codigo del Cliente 
					--Aplica para Ecuador (Over)
					If @cd_Segmento ='FT'
					BEGIN
						Select 
							@cd_over = substring(Campo,3,len(Campo)-2)
						From Table_Aux_GDS Where id = @Count
					END 	
					--Aplica para Colombia (Over)
					If @cd_Segmento ='FT*F*'
					BEGIN
						Select 
							@cd_over = substring(Campo,6,len(Campo)-5)
						From Table_Aux_GDS Where id = @Count
					END 	
					--Pasajero
					If @cd_Segmento ='I-'
					BEGIN
						Set @in_PaxActual = @in_PaxActual + 1
						Select 
							@Cadena = substring(Campo,9,len(Campo))
						From Table_Aux_GDS Where id = @Count
						
						Set @PosBarra = CHARINDEX('/',@Cadena)
						Set @PosPuntoComa = CHARINDEX(';',@Cadena)
			 			----------------------------------------
			 			-- Insertamos el registro del pasajero
						IF(ISNULL(@PosBarra,0)>0 AND ISNULL(@PosPuntoComa,0)>0)
						BEGIN
			 				Insert Into @Table_Pax ( PaxApe, PaxName)	
							Select 
								left(substring(@Cadena,1,@PosBarra-1),30) 							AS 'PaxApe',
								left(substring(@Cadena,@PosBarra+1,@PosPuntoComa-@PosBarra-1),30) 	AS 'PaxName'
							
							UPDATE @Table_Pax
							Set PaxPrefix = 'MRS',
								PaxName = replace(PaxName,'MRS','')
							Where PaxName like '%MRS%'
	
							update @Table_Pax
							Set PaxPrefix = 'MR',
								PaxName = replace(PaxName,'MR','')
							Where PaxName like '%MR%'
						END
					End
					--Tiquetes
					Else If @cd_Segmento ='TM' AND @AIROPT = '7D' --R88490 - Jramirez - EMD 7D(Terranova)
					Begin
						--Solo aplica para reservas con AIROPT tipo 7D
						Select @Cadena = substring(Campo,5,len(Campo))
						From Table_Aux_GDS 
						Where id = @Count AND substring(Campo,1,4) IN ('TMCD','TMCN')

						UPDATE @Table_Pax 
						Set Tkt = substring(@Cadena,5,10),
							TktPrefix = substring(@Cadena,1,3)
						Where id = @in_PaxActual


					End
					Else If @cd_Segmento ='T-' 
					Begin
						--Obtenemos la informacion de la linea
						Select @Cadena = substring(Campo,4,len(Campo))
						From Table_Aux_GDS Where id = @Count
												
						If  charindex('-',substring(@Cadena,5,len(@Cadena))) > 0					
						Begin
							-- FALTA!!!!!!!!!!!
							---------------------------------------
							-- Todo lo de Tiquetes en conjuncion --
							---------------------------------------
							UPDATE @Table_Pax 
							Set Tkt = substring(@Cadena,5,10),
								TktPrefix = substring(@Cadena,1,3)
							Where id = @in_PaxActual
							Set @NumTktConjuncion = 1	
	--						Set @Cadena=''
						End 
						Else 
						Begin
							--Obtenemos el numero del Tkt y el Prefijo		
							UPDATE @Table_Pax 
							Set Tkt = substring(@Cadena,5,len(@Cadena)),
								TktPrefix = substring(@Cadena,1,3)
							Where id = @in_PaxActual
						End 
					End
					------------------------------------------ 
					-- Tiquete Revisado
					------------------------------------------
					Else If @cd_Segmento ='FO'
					Begin	
						Select 
							@Cadena = Campo
						From Table_Aux_GDS Where id = @Count
						--Debug
						--Select @Cadena as 'Tiquete Revisado'
						If @Cadena NOT LIKE '%FOID%' or @Cadena NOT LIKE '%FOI%'
						Begin
							UPDATE @Table_Pax 
							Set TktRevisado  = substring(@Cadena,7,10),
								TktRevisadoPrefix  = substring(@Cadena,3,3)
							Where id = @in_PaxActual
						End
						If @Cadena LIKE '%FOID%' or @Cadena LIKE '%FOI%'
						Begin
							Set @PosPlus = charindex('FOID-',@Cadena)+5
							Set @PosPuntoComa = CHARINDEX(';',@Cadena)
							Set @PosIndex = CASE WHEN ISNUMERIC(substring(@Cadena,charindex(';P',@Cadena)+2,1))=1 THEN substring(@Cadena,charindex(';P',@Cadena)+2,1) ELSE 0 END
							UPDATE @Table_Pax 
							Set Pasaporte = CASE WHEN @PosPlus>0 AND @PosPuntoComa>@PosPlus THEN substring(@Cadena,@PosPlus,@PosPuntoComa-@PosPlus) ELSE '' END
							Where id = @PosIndex
								--AND id = @in_PaxActual	   	
						End
					End 
					------------------------------------------ 
					-- Formas de pago
					------------------------------------------				
					Else If @cd_Segmento ='FP' OR ((Select substring(Campo,1,3) From Table_Aux_GDS Where id = @Count) = 'MFP' AND @AIROPT = '7D')
					Begin
						----------------------------------------
						--Obtenemos la cadena a evaluar
						Select 
							@Cadena = campo
						From Table_Aux_GDS Where id = @Count

						/*inicio rgelis 2013/12/10 req.17703*/
						SELECT TOP 1 @am_total = am_total 
						FROM @TableValores
						WHERE id <= @in_PaxActual
						ORDER BY id DESC
						/*inicio rgelis 2013/12/10 req.17703*/

						If substring(@Cadena,3,1) = 'O'
						Begin
							
							Set @PosPlusBarra = charindex('+/',@Cadena)
							Set @Cadena = substring(@cadena,@PosPlusBarra+2,len(@cadena))
							Set @PosPlusBarra = charindex('+',@Cadena)
							If @PosPlusBarra = 0
							Begin 
								--Set @Cadena = substring(@Cadena,4,len(@Cadena))
								EXECUTE dbo.spza_EvaluaFPGDS 
									@Cadena
									, @cd_FpCode OUT
									, @am_FpVal OUT
									, @cd_FpTC OUT
									, @cd_FpTC_Number OUT
									, @cd_FpTC_exp OUT
									, @cd_FpTC_aprob OUT
								
								UPDATE @Table_Pax
								Set FP1 = @cd_FpCode
									, FP1_Val = CASE WHEN @am_FpVal = 0 THEN @am_total Else @am_FpVal End 
									, FP1_TC = @cd_FpTC
									, FP1_TC_number = @cd_FpTC_Number
									, FP1_TC_exp = @cd_FpTC_exp
									, FP1_TC_aprob = @cd_FpTC_aprob
									, FP1_TC_voucher = @cd_FpTC_aprob
								Where Id = @in_PaxActual
																
							End
							Else If charindex('+/',@Cadena) > 0
							Begin 
								Set @Cadena = substring(@Cadena,charindex('/',@Cadena)+1,len(@Cadena))
								EXECUTE dbo.spza_EvaluaFPGDS 
									@Cadena
									, @cd_FpCode OUT
									, @am_FpVal OUT
									, @cd_FpTC OUT
									, @cd_FpTC_Number OUT
									, @cd_FpTC_exp OUT
									, @cd_FpTC_aprob OUT
				  
								UPDATE @Table_Pax
								Set FP1 = @cd_FpCode
									, FP1_Val = CASE WHEN @am_FpVal = 0 THEN @am_total Else @am_FpVal End 
									, FP1_TC = @cd_FpTC
									, FP1_TC_number = @cd_FpTC_Number
									, FP1_TC_exp = @cd_FpTC_exp
									, FP1_TC_aprob = @cd_FpTC_aprob
									, FP1_TC_voucher = @cd_FpTC_aprob
								Where Id = @in_PaxActual
								
								 
								------------------------------------------------
								-- Insertamo la Segunda Forma de pago, si tiene
								Set @Cadena = substring(@Cadena,charindex('+/',@Cadena)+2,len(@Cadena))
								EXECUTE dbo.spza_EvaluaFPGDS 
									@cadena 
									, @cd_FpCode OUT
									, @am_FpVal OUT
									, @cd_FpTC OUT
									, @cd_FpTC_Number OUT
									, @cd_FpTC_exp OUT
									, @cd_FpTC_aprob OUT
				  
								UPDATE @Table_Pax
								Set FP2 = @cd_FpCode
									, FP2_Val = CASE WHEN @am_FpVal = 0 THEN @am_total Else @am_FpVal End 
									, FP2_TC = @cd_FpTC
									, FP2_TC_number = @cd_FpTC_Number
									, FP2_TC_exp = @cd_FpTC_exp
									, FP2_TC_aprob = @cd_FpTC_aprob
									, FP2_TC_voucher = @FP2_TC_aprob
								Where Id = @in_PaxActual
								
								
							End 						
							Else
							Begin 
								Set @Cadena = substring(@Cadena,charindex('+',@Cadena)-1,len(@Cadena))
								EXECUTE dbo.spza_EvaluaFPGDS 
									@Cadena
									, @cd_FpCode OUT
									, @am_FpVal OUT
									, @cd_FpTC OUT
									, @cd_FpTC_Number OUT
									, @cd_FpTC_exp OUT
									, @cd_FpTC_aprob OUT
				  
								UPDATE @Table_Pax
								Set FP1 = @cd_FpCode
									, FP1_Val = CASE WHEN @am_FpVal = 0 THEN @am_total Else @am_FpVal End 
									, FP1_TC = @cd_FpTC
									, FP1_TC_number = @cd_FpTC_Number
									, FP1_TC_exp = @cd_FpTC_exp
									, FP1_TC_aprob = @cd_FpTC_aprob
									, FP1_TC_voucher = @cd_FpTC_aprob
								Where Id = @in_PaxActual	
								------------------------------------------------
								-- Insertamo la Segunda Forma de pago, si tiene
								Set @Cadena = substring(@Cadena,charindex('+',@Cadena)+1,len(@Cadena))
								EXECUTE dbo.spza_EvaluaFPGDS 
									@cadena 
									, @cd_FpCode OUT
									, @am_FpVal OUT
									, @cd_FpTC OUT
									, @cd_FpTC_Number OUT
									, @cd_FpTC_exp OUT
									, @cd_FpTC_aprob OUT
				  
								UPDATE @Table_Pax
								Set FP2 = @cd_FpCode
									, FP2_Val = CASE WHEN @am_FpVal = 0 THEN @am_total Else @am_FpVal End 
									, FP2_TC = @cd_FpTC
									, FP2_TC_number = @cd_FpTC_Number
									, FP2_TC_exp = @cd_FpTC_exp
									, FP2_TC_aprob = @cd_FpTC_aprob
									, FP2_TC_voucher = @cd_FpTC_aprob
								Where Id = @in_PaxActual												
							End 									
						End 
						Else If charindex('+',@Cadena) > 0
						Begin
							/*inicio rgelis 2013/07/13 req.15354*/
							Set  @Cadena =substring(@Cadena,3,len(@Cadena))
							INSERT INTO @TablaFP(ds_StrFP)
							EXEC SpSplitMejorado @Cadena,'+',0
							IF EXISTS(SELECT * FROM @TablaFP WHERE id=1)
							BEGIN
								SELECT @Cadena=ds_StrFP FROM @TablaFP WHERE id=1
								EXECUTE dbo.spza_EvaluaFPGDS 
									@Cadena
									, @cd_FpCode OUT
									, @am_FpVal OUT
									, @cd_FpTC OUT
									, @cd_FpTC_Number OUT
									, @cd_FpTC_exp OUT
									, @cd_FpTC_aprob OUT
				  				
			  					Set @am_FpVal = CASE WHEN @am_FpVal = 0 THEN @am_total Else @am_FpVal End 
								
								UPDATE @Table_Pax
								Set FP1 = @cd_FpCode
									, FP1_Val = @am_FpVal
									, FP1_TC = @cd_FpTC
									, FP1_TC_number = @cd_FpTC_Number
									, FP1_TC_exp = @cd_FpTC_exp
									, FP1_TC_aprob = @cd_FpTC_aprob
									, FP1_TC_voucher = @cd_FpTC_aprob
								Where Id = @in_PaxActual  
							END
							------------------------------------------------
							IF EXISTS(SELECT * FROM @TablaFP WHERE id=2)
							BEGIN
								-- Insertamo la Segunda Forma de pago, si tiene
								--Set @Cadena = substring(@Cadena,charindex('+',@Cadena)+1,len(@Cadena))
								SELECT @Cadena=ds_StrFP FROM @TablaFP WHERE id=2
								EXECUTE dbo.spza_EvaluaFPGDS 
									@cadena 
									, @cd_FpCode OUT
									, @am_FpVal2 OUT
									, @cd_FpTC OUT
									, @cd_FpTC_Number OUT
									, @cd_FpTC_exp OUT
									, @cd_FpTC_aprob OUT

			  					Set @am_FpVal2 = CASE WHEN @am_FpVal2 = 0 THEN @am_total Else @am_FpVal2 End  
								
								UPDATE @Table_Pax
								
								Set FP2 = @cd_FpCode
									, FP2_Val = @am_FpVal2
									, FP2_TC = @cd_FpTC
									, FP2_TC_number = @cd_FpTC_Number
									, FP2_TC_exp = @cd_FpTC_exp
									, FP2_TC_aprob = @cd_FpTC_aprob
									, FP2_TC_voucher = @cd_FpTC_aprob
								Where Id = @in_PaxActual  
							END
							/*fin rgelis 2013/07/13 req.15354*/
													

							If (@am_FpVal + @am_FpVal2) > @am_total
							Begin
								If @am_FpVal = @am_total
								Begin
									UPDATE @Table_Pax
									Set  FP1_Val = abs(@am_FpVal2 - @am_FpVal) 
									Where Id = @in_PaxActual							
								End 
								Else If @am_FpVal2 = @am_total
								Begin
									UPDATE @Table_Pax
									Set  FP1_Val = abs(@am_FpVal2 - @am_FpVal) 
									Where Id = @in_PaxActual																					
								End 							
							End 									
						End 
						Else
						Begin  
							-------------------------------------------------					
							-- Segun la forma de pago, obtenemos los valores.
							IF LEFT(@Cadena,3) = 'MFP'
								Set @Cadena = substring(@Cadena,4,len(@Cadena)) --rgelis 2019/09/10 ticket:
							ELSE
								Set @Cadena = substring(@Cadena,3,len(@Cadena))

							EXECUTE dbo.spza_EvaluaFPGDS 
								@Cadena
								, @cd_FpCode OUT
								, @am_FpVal OUT
								, @cd_FpTC OUT
								, @cd_FpTC_Number OUT
								, @cd_FpTC_exp OUT
								, @cd_FpTC_aprob OUT	
							--select @cd_FpTC_exp
							UPDATE @Table_Pax
							Set FP1 = @cd_FpCode
								, FP1_Val = CASE WHEN @am_FpVal = 0 THEN @am_total Else @am_FpVal End 
								, FP1_TC = @cd_FpTC
								, FP1_TC_number = @cd_FpTC_Number
								, FP1_TC_exp = @cd_FpTC_exp
								, FP1_TC_aprob = @cd_FpTC_aprob
								, FP1_TC_voucher = @cd_FpTC_aprob
							Where Id = @in_PaxActual																		   
						End								
					End 
					-------------------------------------------------------
					-- Remarks de usuario (TAO, IVA_TAO, Recargo adicional, Cliente)
					-------------------------------------------------------
					
					Else If @cd_Segmento ='RM'
					Begin
						
						Select 
							@Cadena = campo
						From Table_Aux_GDS Where id = @Count
	
						If substring(@Cadena,1,11) = 'RM*FV/TA/V1' --TAO
						Begin
							UPDATE @Table_Pax 
							Set TAO  = substring(@Cadena,12,charindex('/',substring(@Cadena,12,LEN(@Cadena)))-1)
							Where id = @in_PaxActual				
						End 
						If substring(@Cadena,1,11) = 'RM*FV/IV/V1' --IVA_TAO
						Begin
							UPDATE @Table_Pax 
							Set TaoIva  = substring(@Cadena,12,charindex('/',substring(@Cadena,12,LEN(@Cadena)))-1)
							Where id = @in_PaxActual				   
						End 
						
						If substring(@Cadena,1,11) = 'RM*FV/CA/V1' --Recargo (Fee)		
						Begin
							If ISNUMERIC(substring(@Cadena,13,1))=1
							Begin 
								Set @Cadena = substring(@Cadena,13,len(@Cadena))
							End 
							Else
							Begin 
								Set @Cadena = substring(@Cadena,14,len(@Cadena))
							End 
						
							Set @PosPlus = charindex('+',@Cadena)
							Set @PosBarra = charindex('/',@Cadena)
							Set @PosBarra2 = charindex('/',@Cadena,@PosBarra+1)
							If @PosBarra2 = 0
							Begin
								Set @PosBarra2 = len(@Cadena)+1
							End
						
							UPDATE @Table_Pax 
							Set Recargo  = substring(@Cadena,1,@PosBarra-1),
								RecargoIva = substring(@Cadena,@PosPlus+1,@PosBarra2-1-@PosPlus)
							Where id = @in_PaxActual					
						End 	
						
						If substring(@Cadena,1,11) = 'RM*FV/FE/V1' --Recargo (Fee)		
						Begin
							Set @Cadena = substring(@Cadena,13,len(@Cadena))
							Set @PosPlus = charindex('+',@Cadena)
							Set @PosBarra = charindex('/',@Cadena)
							Set @PosBarra2 = charindex('/',@Cadena,@PosBarra+1)
									
							UPDATE @Table_Pax 
							Set Recargo  = substring(@Cadena,1,@PosBarra-1),
								RecargoIva = substring(@Cadena,@PosPlus+1,@PosBarra2-1-@PosPlus)
							Where id = @in_PaxActual					
						End 
						
						If substring(@Cadena,1,6) = 'RM*NC-' AND ISNULL(@cd_Cliente,'') = '' --Identificacion del Cliente
						Begin
							If charindex('/',@Cadena) > 0
							Begin					
								Set @cd_Cliente=substring(@Cadena,charindex('-',@Cadena)+1,charindex('/',@Cadena)-7)
								Set @cd_Cliente = replace(@cd_Cliente,'/','')
							End
						End 
						If substring(@Cadena,1,7) = 'RM**NC-' AND ISNULL(@cd_Cliente,'') = '' --Identificacion del Cliente
						Begin
							If charindex('/',@Cadena) > 0
							Begin					
								Set @cd_Cliente=substring(@Cadena,charindex('-',@Cadena)+1,charindex('/',@Cadena)-8)
								Set @cd_Cliente = replace(@cd_Cliente,'/','')
							End
						End 
						If substring(@Cadena,1,8) = 'RM***NC-' AND ISNULL(@cd_Cliente,'') = '' --Identificacion del Cliente
						Begin
							If charindex('/',@Cadena) > 0
							Begin					
								Set @cd_Cliente=substring(@Cadena,charindex('-',@Cadena)+1,charindex('/',@Cadena)-9)
								Set @cd_Cliente = replace(@cd_Cliente,'/','')
							End
						End 																	
						/*inicio rgelis 2013/07/08 req.---- informacion de ahorro para gematour*/
						IF substring(@Cadena,1,6) = 'RM*LF='
						BEGIN
							SET @am_lowfare = CASE WHEN ISNUMERIC(substring(@Cadena,7,LEN(@Cadena)))=1 THEN CONVERT(MONEY,substring(@Cadena,7,LEN(@Cadena))) ELSE 0 END --rgelis 2018/02/05 tiquet:8818
						END
						IF substring(@Cadena,1,6) = 'RM*FF='
						BEGIN
							SET @am_highfare = CASE WHEN ISNUMERIC(substring(@Cadena,7,LEN(@Cadena)))=1 THEN CONVERT(MONEY,substring(@Cadena,7,LEN(@Cadena))) ELSE 0 END --rgelis 2018/02/05 tiquet:8818
						END
						SET @am_fare = 0
						IF substring(@Cadena,1,6) = 'RM*SVD'
						BEGIN
							Set @ds_reasoncode = substring(@Cadena,6,2)
						END
						/*fin rgelis 2013/07/08 req.---- informacion de ahorro para gematour*/
						/*inicio rgelis 2015/08/19 req.25878 Evento gematour*/
						IF substring(@Cadena,1,10) = 'RM EVENTO/'
						BEGIN
							Set @ds_Evento = substring(@Cadena,11,LEN(@Cadena)-10)
							set @ds_Evento = SUBSTRING(@ds_Evento,1,charindex('/',@ds_Evento)-1)
						END
						/*fin rgelis 2015/08/19 req.25878 Evento gematour*/

						/*inicio rgelis 2017/02/21 req.47359*/
						IF substring(@Cadena,1,41) = 'RM COMPROBANTE PAGO TARIFA ADMINISTRATIVA'
						BEGIN
							UPDATE @Table_Pax 
							Set FPTAO = FP1 
							   ,FPTAO_Val = ISNULL(Tao,0) + ISNULL(TaoIva,0)
							   ,FPTAO_TC = FP1_TC
							   ,FPTAO_TC_number = FP1_TC_number
							   ,FPTAO_TC_exp = NULL--FP1_TC_exp
							   ,FPTAO_TC_aprob  = substring(@Cadena,43,6)
							Where id = @in_PaxActual
						END
						/*fin rgelis 2017/02/21 req.47359 */
						IF substring(@Cadena,1,13) = 'RM*FV/77/CON-'
						BEGIN
							Set @ds_Observaciones = substring(@Cadena,14,LEN(@Cadena)-13)
						END
					End 
					
					Set @Count = @Count + 1
				End
				
				--Select * From @Table_Pax
				--------------------------------------
				---- Estableciendo la Tarifa Real ----
				--------------------------------------
				/*DECLARE @am_tarifalocalAux Money
				Set @am_tarifalocalAux = isnull((@am_total - (@am_IVA + @am_Tasas + @am_CMB + @am_Otr)),0)
				
				IF @am_tarifalocalAux > @am_tarifalocal AND @am_tarifalocal > 0 
				BEGIN
					SET @am_Otr = @am_Otr + (@am_tarifalocalAux-@am_tarifalocal)
				END */
				--Set @am_tarifalocal = ABS(isnull((@am_total - (@am_IVA + @am_Tasas + @am_CMB + @am_Otr)),0)) 	/*rgelis 2013/12/09 req.17703*/
				--select * from @TableValores
				UPDATE @TableValores
				SET	 am_tarifalocal	= ABS(isnull((am_total - (am_iva + am_tua + am_comb + am_vat + am_iva2)),0))	/*rgelis 2013/12/09 req.17703*/
				WHERE (am_tarifalocal + am_iva + am_tua + am_comb + am_vat) <> am_total

				IF EXISTS (SELECT * FROM dbo.Parametros WHERE id = 240 AND (RTRIM(Valor)='Ecuador' OR RTRIM(Valor)='República Dominicana' ))
				BEGIN 
					/*inicio rgelis 2013/12/09 req.17703*/
					--IF @am_tarifalocal > @am_tarifa
					--BEGIN 
					--	SET @am_Otr = @am_Otr + (@am_tarifalocal-@am_tarifa)
					--	SET @am_tarifalocal = @am_tarifa
					--END
					UPDATE @TableValores
						SET am_vat = am_vat + (am_tarifalocal-am_tarifa)
						,am_tarifalocal = am_tarifa
					WHERE am_tarifalocal > am_tarifa
					/*fin rgelis 2013/12/09 req.17703*/ 						
				END 

				DECLARE  @cd_FormaPago VARCHAR(3)
						,@cd_TarjetaCredito VARCHAR(2)
						,@cd_NumeroTarjeta VARCHAR(16)
						,@cd_VencimientoTarjeta VARCHAR(5)
						,@in_CuotasTarjeta INT
						,@cd_FormaPagoTAO VARCHAR(3)
						,@cd_TarjetaCreditoTAO VARCHAR(2)
						,@cd_NumeroTarjetaTAO VARCHAR(16)
						,@cd_VencimientoTarjetaTAO VARCHAR(5)
						
				--inicio rgelis 2017/03/10 req.48084
				SELECT	 @Sucursal			= CASE WHEN ISNULL(F.sucursal,'')<>''			THEN F.sucursal				ELSE @Sucursal				END --
						,@Implante 			= CASE WHEN ISNULL(F.implante,'')<>''			THEN F.implante				ELSE @Implante 				END
						,@tiqueteador 		= CASE WHEN ISNULL(F.Tiqueteador,'')<>''		THEN F.Tiqueteador			ELSE @tiqueteador			END --
						,@vendedor 			= CASE WHEN ISNULL(F.Vendedor,'')<>''			THEN F.Vendedor				ELSE @vendedor 				END --
						,@cd_cliente 		= CASE WHEN ISNULL(F.Cliente,'')<>''			THEN F.Cliente				ELSE @cd_cliente 			END --
						,@cd_centrocosto	= CASE WHEN ISNULL(F.centrocosto,'')<>''		THEN F.centrocosto			ELSE @cd_centrocosto		END --
						,@ds_Evento			= CASE WHEN ISNULL(F.Evento,'')<>''				THEN F.Evento				ELSE @ds_Evento				END --
						,@cd_over			= CASE WHEN ISNULL(F.[over],'')<>''				THEN F.[over]				ELSE @cd_over				END --
						,@cd_iata			= CASE WHEN ISNULL(F.CodigoIata,'')<>''			THEN F.CodigoIata			ELSE @cd_iata				END --
						,@in_cantpax		= CASE WHEN ISNULL(F.CantidadPasajero,0)>0		THEN F.CantidadPasajero		ELSE @in_cantpax			END --rgelis 2017/08/24 req.35871
						,@cd_Pseudo			= CASE WHEN ISNULL(F.Pseudo,'')<>''				THEN F.Pseudo				ELSE @cd_Pseudo				END --rgelis 2017/08/30 req.52081			
						--,@cd_conceptofacturacion	= CASE WHEN ISNULL(F.conceptofacturacion,'')<>''	THEN F.conceptofacturacion	ELSE @cd_conceptofacturacion	END --ini rgelis 2019/09/26 req.103173
						--,@cd_TipoServicio			= CASE WHEN ISNULL(F.Tiposervicio,'')<>''			THEN F.Tiposervicio			ELSE @cd_TipoServicio			END 
						--,@cd_Proveedores			= CASE WHEN ISNULL(F.Proveedor,'')<>''				THEN F.Proveedor			ELSE @cd_Proveedores			END 
						--,@ds_Descrip				= CASE WHEN ISNULL(F.Descripcionservicios,'')<>''	THEN F.Descripcionservicios ELSE @ds_Descrip				END
						--,@ds_pax_firstnm			= CASE WHEN ISNULL(F.PasajerosNombres,'')<>''		THEN F.PasajerosNombres		ELSE @ds_pax_firstnm			END 
						--,@ds_pax_lastnm			= CASE WHEN ISNULL(F.PasajerosApellidos,'')<>''		THEN F.PasajerosApellidos	ELSE @ds_pax_lastnm				END 
						--,@ds_pax_lastnm			= CASE WHEN ISNULL(F.Pasajeros,'')<>''				THEN F.Pasajeros			ELSE @ds_pax_lastnm				END --fin rgelis 2019/09/26 req.103173
						--,@ds_clidir 			= CASE WHEN ISNULL(F.DireccionCliente,'')<>''	THEN F.DireccionCliente		ELSE @ds_clidir				END
						--,@ds_clicity 			= CASE WHEN ISNULL(F.CiudadCliente,'')<>''		THEN F.CiudadCliente		ELSE @ds_clicity 			END
						--,@ds_cliid 			= CASE WHEN ISNULL(F.Cliente,'')<>''			THEN F.Cliente				ELSE @ds_cliid 				END
						--,@ds_clirazoncial 	= CASE WHEN ISNULL(F.RazonSocialCliente,'')<>'' THEN F.RazonSocialCliente	ELSE @ds_clirazoncial 		END
						--,@ds_clitel			= CASE WHEN ISNULL(F.TelefonoCliente,'')<>''	THEN F.TelefonoCliente		ELSE @ds_clitel				END
						--,@cd_clipais			= CASE WHEN ISNULL(F.PaisCliente,'')<>''		THEN F.PaisCliente			ELSE @cd_clipais			END
						--,@ds_ClienteEmail 	= CASE WHEN ISNULL(F.EmailCliente,'')<>''		THEN F.EmailCliente			ELSE @ds_ClienteEmail 		END
						--,@cd_tourcode			= CASE WHEN ISNULL(F.tourcodereserva,'')<>''	THEN F.tourcodereserva		ELSE @cd_tourcode			END
						--,@cd_Categoria		= CASE WHEN ISNULL(F.Categoria,'')<>''			THEN F.Categoria			ELSE @cd_Categoria			END	
				FROM @CamposGDSValores AS F
				--fin rgelis 2017/03/10 req.48084


				SET @in_cantpax=ISNULL(@in_cantpax,1) --rgelis 2017/10/02 req.53548

				UPDATE @Table_Pax 
				Set in_cantpax =ISNULL(@in_cantpax,1) --rgelis 2017/08/24 req.35871
				   ,cd_Pseudo  =@cd_Pseudo --rgelis 2017/08/30 req.52081
				--Where id = @in_PaxActual --rgelis 2018/11/27 req.74659 se comentarea para que actualice todos los pasajeros

				--------------------------------------------------------------------------
				-------------------- Insertando la reserva de AMADEUS --------------------
				--------------------------------------------------------------------------
		
				----------------------------------------------------------
				------------ Insertando cabecera de la reserva -----------
				----------------------------------------------------------
				/*rgelis 2013/03/22 cambia para que actualice solo al tiquete y no la reserva*/
				--If NOT EXISTS (Select * From ReservasGDS Where cd_codigo = @CodigoReserva AND iden_gds=2)
				--Begin
					Insert Into dbo.ReservasGDS																																																																																																																																																																																																																																																																																																																					
					(
					iden_gds,
					cd_codigo,
					ds_fecha,
					cd_tiqueteador,
					cd_vendedor,
					cd_cliente,
					reserva,
					am_highfare,
					am_lowfare,
					am_fare,
					ds_reasoncode,/*rgelis 2013/05/08 req.---- informacion de ahora gematour*/				
					ds_itinerario,
					ds_clases,
					in_nacionalidad,
					cd_sucursal,
					cd_TipoTransaccion,
					cd_centrocosto,
					ds_solicita,
					cd_over,
					bl_ahorro,
					ds_Evento,
					cd_iata,
					ds_Observaciones
					)
					Select 
						2 							AS 'iden_gds',
						@CodigoReserva				AS 'Codigo',
						@FechaReserva				AS 'Fecha',
						@tiqueteador 				AS 'cd_tiqueteador',
						@vendedor    				AS 'cd_vendedor',
						isnull(@cd_cliente,'')		AS 'Cliente',
						@GDS						AS 'Reserva',
						ISNULL(@am_highfare,0)		AS 'am_highfare',/*inicio rgelis 2013/05/08 req.---- informacion de ahora gematour*/
						ISNULL(@am_lowfare,0)		AS 'am_lowfare',
						ISNULL(@am_fare,0)			AS 'am_fare',
						ISNULL(@ds_reasoncode,'')	AS 'ds_reasoncode',/*inicio rgelis 2013/05/08 req.---- informacion de ahora gematour*/												
						@Itinerarios				AS 'ds_itinerario',
						@Clases						AS 'ds_clases',
						@Nacionalidad				AS 'in_nacionalidad',
						@Sucursal					AS 'cd_sucursal',
						1							AS 'cd_TipoTransaccion',
						@cd_centrocosto			    AS 'cd_centrocosto',
						@ds_solicita				AS 'ds_solicita',
						@cd_over					AS 'cd_over',
						0							AS 'bl_ahorro',
						@ds_Evento					AS 'ds_Evento',
						@cd_iata					AS 'cd_iata',
						@ds_Observaciones			AS 'ds_Observaciones'
					Set @Id_ReservasGDS = scope_identity()
				/*rgelis 2013/03/22 cambia para que actualice solo al tiquete y no la reserva*/	
				--End 
				--Else
				--Begin 
				--	UPDATE dbo.ReservasGDS
				--	Set 
				--	ds_fecha=@FechaReserva,
				--	cd_tiqueteador=@tiqueteador,
				--	cd_vendedor=@vendedor,
				--	cd_cliente=isnull(@cd_cliente,''),
				--	reserva=@GDS,
				--  am_highfare=ISNULL(@am_highfare,0),--inicio rgelis 2013/05/08 req.---- informacion de ahora gematour
				--  am_lowfare=ISNULL(@am_lowfare,0),
				--  am_fare=ISNULL(@am_fare,0),
				--  ds_reasoncode=ISNULL(@ds_reasoncode,''),--fin rgelis 2013/05/08 req.---- informacion de ahora gematour	
				--	ds_itinerario=@Itinerarios,
				--	ds_clases=@Clases,
				--	in_nacionalidad=@Nacionalidad,
				--	cd_sucursal=@Sucursal,
				--	cd_TipoTransaccion=1,
				--	cd_centrocosto = @cd_centrocosto,
				--	ds_solicita = @ds_solicita,
				--	cd_over = @cd_over
				--	Where cd_codigo = @CodigoReserva AND iden_gds=2
					
				--	--Obtenemos el id de la reserva actualizada
				--	Select @Id_ReservasGDS = id 
				--	From dbo.ReservasGDS
				--	Where cd_codigo = @CodigoReserva AND iden_gds=2
					
				--End 
				-----------------------------------------------------
				------------ Insertando detalles del tkt ------------
				-----------------------------------------------------			
				Select @MaxFila = max(id) From @Table_Pax
				Set @Count = 1	
				Declare @Diferencia MONEY
			   	While @Count <= @MaxFila
				Begin 
				
					SET @Diferencia = 0 
					
					Select @Id = Id
						,@PaxApe = PaxApe
						,@PaxName = PaxName
						,@PaxPrefix = PaxPrefix
						,@Tkt = Tkt
						,@TktPrefix = TktPrefix
						,@TktRevisado = TktRevisado
						,@TktRevisadoPrefix = TktRevisadoPrefix
						,@FP1 = FP1
						,@FP1_Val = FP1_Val
						,@FP1_TC = FP1_TC
						,@FP1_TC_number = FP1_TC_number
						,@FP1_TC_exp = FP1_TC_exp
						,@FP1_TC_aprob = FP1_TC_aprob
						,@FP2 = FP2
						,@FP2_Val = isnull(FP2_Val,0)
						,@FP2_TC = FP2_TC
						,@FP2_TC_number = FP2_TC_number
						,@FP2_TC_exp = FP2_TC_exp
						,@FP2_TC_aprob = FP2_TC_aprob
						,@Tao = Tao
						,@TaoIva = TaoIva
						,@Recargo = Recargo
						,@RecargoIva = RecargoIva
						,@TktId = TktId
						,@cd_PasaportePax = Pasaporte
						,@FPTAO = FPTAO --inicio rgelis 2017/02/21 req.47359
						,@FPTAO_Val = FPTAO_Val
						,@FPTAO_TC = FPTAO_TC
						,@FPTAO_TC_number = FPTAO_TC_number
						,@FPTAO_TC_exp = NULL--FPTAO_TC_exp
						,@FPTAO_TC_aprob = FPTAO_TC_aprob /*fin rgelis 2017/02/21 req.47359*/
						,@FP1_TC_voucher = FP1_TC_aprob --inicio rgelis 2017/06/05 req.48084
						,@FP2_TC_voucher = FP2_TC_aprob
						,@FPTAO_TC_voucher = FPTAO_TC_aprob --fin rgelis 2017/06/05 req.48084
						,@in_cantpax = in_cantpax --rgelis 2017/08/24 req.35871
						,@cd_Pseudo  = cd_Pseudo --rgelis 2017/08/30 req.52081
					From @Table_Pax
					Where Id = @Count

					/*inicio rgelis 2013/12/09 req.17703*/
					SELECT top 1 @cd_MonedaTarifalocal=ds_moneda
						   ,@am_tarifalocal=am_tarifalocal
						   ,@am_iva=am_iva
						   ,@am_tasas=am_tua
						   ,@am_CMB=am_comb
						   ,@am_Otr=am_vat
						   ,@am_iva2=am_iva2
					FROM @TableValores
					WHERE Id <= @Count
					ORDER BY Id DESC
					
					SELECT @am_tarifalocal=ISNULL(@am_tarifalocal,0)
						   ,@am_iva=ISNULL(@am_iva,0)
						   ,@am_tasas=ISNULL(@am_tasas,0)
						   ,@am_CMB=ISNULL(@am_CMB,0)
						   ,@am_Otr=ISNULL(@am_Otr,0) 
						   ,@am_iva2=ISNULL(@am_iva2,0)
					/*fin rgelis 2013/12/09 req.17703*/

					--select @cd_MonedaTarifalocal as '@cd_MonedaTarifalocal',@am_tarifalocal as '@am_tarifalocal',@am_iva as '@am_iva', @am_tasas as '@am_tasas', @am_CMB as '@am_CMB',@am_Otr as '@am_Otr'-- FROM #TableValores	Where Id <= @Count order BY id desc	--Debug
					--select @Tkt as '@Tkt'--From @Table_Pax Where Id = @Count --Debug

					--Inicializamos el valor contado y credito del tkt
					Set @am_TarifaCredito = 0--isnull(@am_TarifaCredito,0)
					Set @am_IvaCredito = 0--isnull(@am_IvaCredito,0)
					Set @am_OtrosCredito = 0--isnull(@am_OtrosCredito,0) 
	
					Set @am_Tarifacontado = 0--isnull(@am_Tarifacontado,0)
					Set @am_Ivacontado = 0--isnull(@am_Ivacontado,0)
					Set @am_Otroscontado = 0--isnull(@am_Otroscontado,0) 
					
					
					If @FP1_Val >= 0 AND @FP2_Val = 0
					Begin 
						If @FP1_TC IS NOT NULL AND @FP1_TC <> ''
						BEGIN	
								Set @am_TarifaCredito = @am_tarifalocal
								Set @am_IvaCredito = @am_iva
								Set @am_OtrosCredito = @am_tasas + @am_cmb + @am_otr
						End 
						Else
						Begin
								Set @am_Tarifacontado = @am_tarifalocal
								Set @am_Ivacontado = @am_iva
								Set @am_Otroscontado = @am_tasas + @am_cmb + @am_otr
						End 
					End 
					Else If @FP1_Val > 0 AND @FP2_Val > 0
					BEGIN
						--Dos formas de pago
						--SELECT @id AS '@id','Dos formas de pago' as 'Msj'
						IF ISNULL(@FP1_TC,'') <> ''
						Begin 
							--Descargamos la FP1
							If @am_tarifalocal = @FP1_Val
							Begin 
								If @FP1_TC IS NOT NULL AND @FP1_TC <> ''
								Begin
									Set @am_TarifaCredito = @FP1_Val
								End 
								Else
								Begin
									Set @am_Tarifacontado = @FP1_Val
								End 
							End 
							Else
							Begin
							
								If ISNULL(@FP1_TC,'') <> ''
								Begin
									Set @am_TarifaCredito = @am_tarifalocal
								End 
								Else
								Begin
									Set @am_Tarifacontado = @am_tarifalocal
								End 
								
								Set @diferencia = @FP1_Val - @am_tarifalocal
								
								--Debug
								--SELECT @am_tarifalocal AS '@am_tarifalocal', @FP1_Val AS '@FP1_Val', @FP2_Val AS '@FP2_Val', @am_TarifaCredito AS '@am_TarifaCredito', @am_Tarifacontado AS '@am_Tarifacontado', @diferencia AS '@diferencia'
									
								If @diferencia < 0 AND @am_TarifaCredito > 0
									SET @am_TarifaCredito = @am_TarifaCredito + @diferencia
								
								ELSE If @diferencia < 0 AND @am_Tarifacontado > 0
									SET @am_Tarifacontado = @am_Tarifacontado + @diferencia
								   
								--Debug
								--SELECT @am_tarifalocal AS '@am_tarifalocal', @FP1_Val AS '@FP1_Val', @FP2_Val AS '@FP2_Val', @am_TarifaCredito AS '@am_TarifaCredito', @am_Tarifacontado AS '@am_Tarifacontado', @diferencia AS '@diferencia'
								
								If @diferencia > 0
								Begin
									--Comprobamos el iva con la FP1
									If @diferencia > @am_iva
									Begin
										If @FP1_TC IS NOT NULL AND @FP1_TC <> ''
										Begin
											Set @am_IvaCredito = @am_iva
										End 
										Else
										Begin
											Set @am_Ivacontado = @am_iva
										End 	 
										Set @diferencia = @diferencia - @am_iva							
									End	 
									Else
									Begin
										If @FP1_TC IS NOT NULL AND @FP1_TC <> ''
										Begin
											Set @am_IvaCredito = @diferencia
										End 
										Else
										Begin
											Set @am_Ivacontado = @diferencia
										End 								
										Set @diferencia = 0
									End	 
									--Compromvamos la tasa, el combustible y otros
									If @diferencia < (@am_tasas + @am_cmb + @am_otr)
									Begin
										If @FP1_TC IS NOT NULL AND @FP1_TC <> ''
										Begin
											Set @am_OtrosCredito = @diferencia
										End 
										Else
										Begin
											Set @am_Otroscontado = @diferencia
										End 								
										Set @diferencia = 0																					
									End 
								End 
							End 
							--Desargamos la FP2
							If NOT (@am_TarifaCredito + @am_TarifaContado) = @am_tarifalocal
							Begin
								--Calculamos la diferencia de lo que falta para completar la tarifa
								Set @Diferencia =  @am_tarifalocal - (@am_TarifaCredito + @am_TarifaContado)
								--Descargamos lo que hace falta de la tarifa de la FP2
								If @FP2_TC IS NOT NULL AND @FP2_TC <> ''
								Begin
									Set @am_TarifaCredito = @am_TarifaCredito + ABS(@Diferencia)
								End 
								Else
								Begin
									Set @am_Tarifacontado = @am_Tarifacontado + ABS(@Diferencia)
								End 						
							End
							If @FP2_TC IS NOT NULL AND @FP2_TC <> ''
							Begin
									Set @am_IvaCredito = @am_iva
									Set @am_OtrosCredito = @am_tasas + @am_cmb + @am_otr
							End 
							Else
							Begin
									IF @diferencia > 0
									BEGIN 
										Set @am_Ivacontado = @am_iva
									END
									Set @am_Otroscontado = @am_tasas + @am_cmb + @am_otr
							End 
						End
						ELSE
						BEGIN 
							--Descargamos la FP2
							If @am_tarifalocal = @FP2_Val
							Begin 
								If @FP2_TC IS NOT NULL AND @FP2_TC <> ''
								Begin
									Set @am_TarifaCredito = @FP2_Val
								End 
								Else
								Begin
									Set @am_Tarifacontado = @FP2_Val
								End 
							End 
							Else
							BEGIN
								--Debug
								--SELECT @am_TarifaCredito AS '@am_TarifaCredito',@am_IvaCredito AS '@am_IvaCredito', @am_Ivacontado AS '@am_Ivacontado', @am_OtrosCredito AS '@am_OtrosCredito', @am_Otroscontado AS '@am_Otroscontado', @am_tarifalocal AS '@am_tarifalocal'
								If ISNULL(@FP2_TC,'') <> ''
								Begin
									Set @am_TarifaCredito = @am_tarifalocal
								End 
								Else
								Begin
									Set @am_Tarifacontado = @am_tarifalocal
								End 
								
								Set @diferencia = @FP2_Val - @am_tarifalocal
								
								If @diferencia < 0 AND @am_TarifaCredito > 0
									SET @am_TarifaCredito = @am_TarifaCredito + @diferencia
								
								If @diferencia < 0 AND @am_Tarifacontado > 0
									SET @am_Tarifacontado = @am_Tarifacontado + @diferencia
									
								If @diferencia > 0
								Begin
									--Comprobamos el iva con la FP2
									If @diferencia > @am_iva
									Begin
										If @FP2_TC IS NOT NULL AND @FP2_TC <> ''
										Begin
											Set @am_IvaCredito = @am_iva
										End 
										Else
										Begin
											Set @am_Ivacontado = @am_iva
										End 	 
										Set @diferencia = @diferencia - @am_iva							
									End	 
									Else
									Begin
										If @FP2_TC IS NOT NULL AND @FP2_TC <> ''
										Begin
											Set @am_IvaCredito = @diferencia
										End 
										Else
										Begin
											Set @am_Ivacontado = @diferencia
										End 								
										Set @diferencia = 0
									End	 
									--Debug
									--SELECT @am_TarifaCredito AS '@am_TarifaCredito', @am_TarifaContado AS '@am_TarifaContado',@am_IvaCredito AS '@am_IvaCredito', @am_Ivacontado AS '@am_Ivacontado', @am_OtrosCredito AS '@am_OtrosCredito', @am_Otroscontado AS '@am_Otroscontado', @am_tarifalocal AS '@am_tarifalocal'
									--SELECT @diferencia AS '@diferencia1', @am_tasas + @am_cmb + @am_otr AS 'otros'
									--Compromvamos la tasa, el combustible y otros
									If @diferencia < (@am_tasas + @am_cmb + @am_otr)
									Begin
										If @FP2_TC IS NOT NULL AND @FP2_TC <> ''
										Begin
											Set @am_OtrosCredito = @am_OtrosCredito + @diferencia
										End 
										Else
										Begin
											Set @am_Otroscontado = @am_Otroscontado + @diferencia
										End 								
										Set @diferencia = 0																					
									End 
								End 
							End 
							--Debug
							--SELECT @am_TarifaCredito AS '@am_TarifaCredito',@am_IvaCredito AS '@am_IvaCredito', @am_Ivacontado AS '@am_Ivacontado', @am_OtrosCredito AS '@am_OtrosCredito', @am_Otroscontado AS '@am_Otroscontado', @am_tarifalocal AS '@am_tarifalocal'
							--Desargamos la FP1
							If NOT (@am_TarifaCredito + @am_TarifaContado) = @am_tarifalocal
							Begin
								--Calculamos la diferencia de lo que falta para completar la tarifa
								Set @Diferencia =  @am_tarifalocal - (@am_TarifaCredito + @am_TarifaContado)
								--Descargamos lo que hace falta de la tarifa de la FP1
								If @FP1_TC IS NOT NULL AND @FP1_TC <> ''
								Begin
									Set @am_TarifaCredito = @Diferencia
								End 
								Else
								Begin
									Set @am_Tarifacontado = @Diferencia
								End 						
							End
							If @FP1_TC IS NOT NULL AND @FP1_TC <> ''
							Begin
									Set @am_IvaCredito = @am_iva
									Set @am_OtrosCredito = @am_tasas + @am_cmb + @am_otr
							End 
							Else
							BEGIN
									IF @am_IvaCredito < @am_iva
										Set @am_Ivacontado = @am_iva-@am_IvaCredito
										
									IF @am_OtrosCredito < (@am_tasas + @am_cmb + @am_otr)
										Set @am_Otroscontado = @am_tasas + @am_cmb + @am_otr - @am_OtrosCredito
							END
							--Debug
							--SELECT @am_TarifaCredito  AS '@am_TarifaCredito', @am_IvaCredito   AS '@am_IvaCredito', @am_Ivacontado   AS '@am_Ivacontado', @am_OtrosCredito AS '@am_OtrosCredito', @am_Otroscontado AS '@am_Otroscontado', @am_tarifalocal  AS '@am_tarifalocal2'
						End																				
					End 
					
					IF EXISTS(SELECT id FROM @Table_Pax)
							BEGIN
								INSERT INTO @ReservaGDS_FormasPagos(in_orden,cd_reserva,cd_consecutivo,cd_tipoitem,cd_codigo,ds_nombre,cd_tipotarjeta,ds_numerotarjeta,ds_vouchertarjeta,ds_expiraciontarjeta,ds_autorizaciontarjeta,in_coutas,cd_banco,ds_cheque,ds_plaza,ds_referencia,ds_Poliza,ds_PolizaAnexo,am_valor)
								SELECT in_orden					= 0
									  ,cd_reserva				= @CodigoReserva
									  ,cd_consecutivo			= CONVERT(VARCHAR(25),id)
									  ,cd_tipoitem				= 'Tiquete'
									  ,cd_codigo				= FP1
									  ,ds_nombre				= FP1
									  ,cd_tipotarjeta			= FP1_TC
									  ,ds_numerotarjeta			= FP1_TC_number
									  ,ds_vouchertarjeta		= FP1_TC_voucher
									  ,ds_expiraciontarjeta		= CASE WHEN ISNULL(FP1_TC_exp,'')<>'' THEN FP1_TC_exp ELSE '__/__' END
									  ,ds_autorizaciontarjeta	= FP1_TC_aprob
									  ,in_coutas				= 0
									  ,cd_banco					= '' 
									  ,ds_cheque				= '' 
									  ,ds_plaza					= '' 
									  ,ds_referencia			= '' 
									  ,ds_Poliza				= '' 
									  ,ds_PolizaAnexo			= '' 
									  ,am_valor					= FP1_Val 
								FROM @Table_Pax
								WHERE ISNULL(FP1,'')<>'' AND ISNULL(FP1_Val,0)<>0
								
								UNION ALL

								SELECT in_orden					= 0
									  ,cd_reserva				= @CodigoReserva
									  ,cd_consecutivo			= CONVERT(VARCHAR(25),id)
									  ,cd_tipoitem				= 'Tiquete'
									  ,cd_codigo				= FP2
									  ,ds_nombre				= FP2
									  ,cd_tipotarjeta			= FP2_TC
									  ,ds_numerotarjeta			= FP2_TC_number
									  ,ds_vouchertarjeta		= FP2_TC_voucher
									  ,ds_expiraciontarjeta		= CASE WHEN ISNULL(FP2_TC_exp,'')<>'' THEN FP2_TC_exp ELSE '__/__' END
									  ,ds_autorizaciontarjeta	= FP2_TC_aprob
									  ,in_coutas				= 0
									  ,cd_banco					= '' 
									  ,ds_cheque				= '' 
									  ,ds_plaza					= '' 
									  ,ds_referencia			= '' 
									  ,ds_Poliza				= '' 
									  ,ds_PolizaAnexo			= '' 
									  ,am_valor					= FP2_Val 
								FROM @Table_Pax
								WHERE ISNULL(FP2,'')<>'' AND ISNULL(FP2_Val,0)<>0
							END
							
							IF EXISTS(SELECT * FROM @TablaFP WHERE id>2)
							BEGIN
								-- Insertamo la Segunda Forma de pago, si tiene
								SET @CountAux=3
								SELECT @MaxFilaAux=COUNT(*) FROM @TablaFP
								WHILE(@MaxFilaAux>=@CountAux)
								BEGIN
									SELECT @Cadena=ds_StrFP FROM @TablaFP WHERE id=@CountAux
									EXECUTE dbo.spza_EvaluaFPGDS 
										@cadena 
										, @cd_FpCode OUT
										, @am_FpVal2 OUT
										, @cd_FpTC OUT
										, @cd_FpTC_Number OUT
										, @cd_FpTC_exp OUT
										, @cd_FpTC_aprob OUT

			  						--Set @am_FpVal2 = CASE WHEN @am_FpVal2 = 0 THEN @am_total Else @am_FpVal2 End  
								
									INSERT INTO @ReservaGDS_FormasPagos(in_orden,cd_reserva,cd_consecutivo,cd_tipoitem,cd_codigo,ds_nombre,cd_tipotarjeta,ds_numerotarjeta,ds_vouchertarjeta,ds_expiraciontarjeta,ds_autorizaciontarjeta,in_coutas,cd_banco,ds_cheque,ds_plaza,ds_referencia,ds_Poliza,ds_PolizaAnexo,am_valor)
									SELECT in_orden					= 0
										  ,cd_reserva				= @CodigoReserva
										  ,cd_consecutivo			= CONVERT(VARCHAR(25),@in_PaxActual)
										  ,cd_tipoitem				= 'Tiquete'
										  ,cd_codigo				= @cd_FpCode
										  ,ds_nombre				= @cd_FpCode
										  ,cd_tipotarjeta			= @cd_FpTC
										  ,ds_numerotarjeta			= @cd_FpTC_Number
										  ,ds_vouchertarjeta		= @cd_FpTC_aprob
										  ,ds_expiraciontarjeta		= CASE WHEN ISNULL(@cd_FpTC_exp,'')<>'' THEN @cd_FpTC_exp ELSE '__/__' END
										  ,ds_autorizaciontarjeta	= @cd_FpTC_aprob
										  ,in_coutas				= 0
										  ,cd_banco					= '' 
										  ,ds_cheque				= '' 
										  ,ds_plaza					= '' 
										  ,ds_referencia			= '' 
										  ,ds_Poliza				= '' 
										  ,ds_PolizaAnexo			= '' 
										  ,am_valor					= @am_FpVal2

									SET @CountAux= @CountAux + 1	
								END		  
							END

					--Debug
					--SELECT @am_TarifaCredito  AS '@am_TarifaCredito', @am_IvaCredito   AS '@am_IvaCredito', @am_Ivacontado   AS '@am_Ivacontado', @am_OtrosCredito AS '@am_OtrosCredito', @am_Otroscontado AS '@am_Otroscontado', @am_tarifalocal  AS '@am_tarifalocal2'
					--SELECT @am_OtrosCredito AS '@am_OtrosCredito_FinWhile'
					/*rgelis 2013/03/22 cambia para que actualice solo al tiquete y no la reserva*/
					--If EXISTS ( Select * From dbo.ReservaGDS_Detalles r Where r.id_reserva = @Id_ReservasGDS AND r.ds_tkt_number = @Tkt)

					--inicio rgelis 2017/03/10 req.48084
					SELECT	 @cd_PasaportePax	= CASE WHEN ISNULL(F.PasaportePax,'')<>''		THEN F.PasaportePax			ELSE @cd_PasaportePax	END --
							,@FP1_TC_aprob		= CASE WHEN ISNULL(F.Autorizacion,'')<>''		THEN F.Autorizacion			ELSE @FP1_TC_aprob		END --inicio rgelis 2017/06/05 req.48084
							,@FP2_TC_aprob		= CASE WHEN ISNULL(F.Autorizacion2,'')<>''		THEN F.Autorizacion2		ELSE @FP2_TC_aprob		END
							,@FPTAO_TC_aprob	= CASE WHEN ISNULL(F.AutorizacionTAO,'')<>''	THEN F.AutorizacionTAO		ELSE @FPTAO_TC_aprob	END
							,@FP1_TC_voucher	= CASE WHEN ISNULL(F.Voucher,'')<>''			THEN F.Voucher				ELSE @FP1_TC_voucher	END
							,@FP2_TC_voucher	= CASE WHEN ISNULL(F.Voucher2,'')<>''			THEN F.Voucher2				ELSE @FP2_TC_voucher	END
							,@FPTAO_TC_voucher	= CASE WHEN ISNULL(F.VoucherTAO,'')<>''			THEN F.VoucherTAO			ELSE @FPTAO_TC_voucher	END --fin rgelis 2017/06/05 req.48084					
							,@in_cantpax		= CASE WHEN ISNULL(F.CantidadPasajero,0)>0		THEN F.CantidadPasajero		ELSE @in_cantpax		END--rgelis 2017/08/24 req.35871in_cantpax --rgelis 2017/08/24 req.35871
							,@cd_Pseudo			= CASE WHEN ISNULL(F.Pseudo,'')<>''				THEN F.Pseudo				ELSE @cd_Pseudo			END --rgelis 2017/08/30 req.52081
							,@FPTAO				= CASE WHEN ISNULL(F.FormaPagoTAO,'')<>''		THEN F.FormaPagoTAO			ELSE @FPTAO				END
							,@FPTAO_TC			= CASE WHEN ISNULL(F.TarjetaCreditoTAO,'')<>''	THEN F.TarjetaCreditoTAO	ELSE @FPTAO_TC			END
							,@FPTAO_TC_number	= CASE WHEN ISNULL(F.NumeroTarjetaTAO,'')<>''	THEN F.NumeroTarjetaTAO		ELSE @FPTAO_TC_number	END
							,@FPTAO_TC_aprob	= CASE WHEN ISNULL(F.AutorizacionTAO,0)<>0		THEN F.AutorizacionTAO		ELSE @FPTAO_TC_aprob	END
							,@FPTAO_TC_aprob	= CASE WHEN ISNULL(F.VoucherTAO,0)<>0			THEN F.VoucherTAO			ELSE @FPTAO_TC_voucher	END
							,@in_cuotasTarjetaTAO = CASE WHEN ISNULL(F.CuotasTarjetaTAO,0)<>0	THEN F.CuotasTarjetaTAO		ELSE @in_cuotasTarjetaTAO END
							,@FPTAO_TC_exp	= CASE WHEN ISNULL(F.VencimientoTarjetaTAO,'')<>''	THEN F.VencimientoTarjetaTAO ELSE @FPTAO_TC_exp		END
							,@cd_FormaPago		= CASE WHEN ISNULL(F.FormaPago,'')<>''			THEN F.FormaPago			ELSE @cd_FormaPago			END
							,@cd_TarjetaCredito	= CASE WHEN ISNULL(F.TarjetaCredito,'')<>''		THEN F.TarjetaCredito		ELSE @cd_TarjetaCredito		END
							,@cd_NumeroTarjeta	= CASE WHEN ISNULL(F.NumeroTarjeta,'')<>''		THEN F.NumeroTarjeta		ELSE @cd_NumeroTarjeta		END
							,@cd_VencimientoTarjeta	= CASE WHEN ISNULL(F.VencimientoTarjeta,'')<>''	THEN F.VencimientoTarjeta	ELSE @cd_VencimientoTarjeta	END	
							,@in_CuotasTarjeta	= CASE WHEN ISNULL(F.CuotasTarjeta,'')<>''		THEN F.CuotasTarjeta		ELSE @in_CuotasTarjeta		END
							--,@cd_FormaPagoTAO	= CASE WHEN ISNULL(F.FormaPagoTAO,'')<>''		THEN F.FormaPagoTAO			ELSE @cd_FormaPagoTAO		END
							--,@cd_TarjetaCreditoTAO	= CASE WHEN ISNULL(F.TarjetaCreditoTAO,'')<>''	THEN F.TarjetaCreditoTAO ELSE @cd_TarjetaCreditoTAO	END
							--,@cd_NumeroTarjetaTAO	= CASE WHEN ISNULL(F.NumeroTarjetaTAO,'')<>'' THEN F.NumeroTarjetaTAO	ELSE @cd_NumeroTarjetaTAO	END
							--,@cd_VencimientoTarjetaTAO	= CASE WHEN ISNULL(F.VencimientoTarjetaTAO,'')<>'' THEN F.VencimientoTarjetaTAO	ELSE @cd_VencimientoTarjetaTAO	END	
							--,@in_CuotasTarjetaTAO	= CASE WHEN ISNULL(F.CuotasTarjetaTAO,'')<>'' THEN F.CuotasTarjetaTAO		ELSE @in_CuotasTarjetaTAO END			
							--,@ds_Observaciones  = CASE WHEN ISNULL(F.ds_Observaciones,'')<>''	THEN F.ds_Observaciones		ELSE @ds_Observaciones		END	
							--,@cd_tourcode2  = CASE WHEN ISNULL(F.tourcodetiquete,'')<>''	THEN F.tourcodetiquete ELSE @cd_tourcode2	 END
							--,Categoria
					FROM @CamposGDSValores AS F
					--fin rgelis 2017/03/10 req.48084
					
					IF (ISNULL(@cd_FormaPago,'')='CA')
					BEGIN
						SET @cd_FormaPago='EFE'
					END
					IF (ISNULL(@cd_FormaPago,'')='PO')
					BEGIN
						SET @cd_FormaPago='POL'
					END
					IF ISNULL(@cd_FormaPago,'')<>''
					BEGIN
						SET @FP1=@cd_FormaPago
					END
					IF ISNULL(@cd_TarjetaCredito,'')<>''
					BEGIN
						SET @FP1_TC=@cd_TarjetaCredito
					END
					IF ISNULL(@cd_NumeroTarjeta,'')<>''
					BEGIN
						SET @FP1_TC_number=@cd_NumeroTarjeta
					END
					IF ISNULL(@cd_VencimientoTarjeta,'')<>''
					BEGIN
						SET @FP1_TC_exp=@cd_VencimientoTarjeta
					END
					IF ISNULL(@in_CuotasTarjeta,0)<>0
					BEGIN
						SET @in_CuotasTarjeta=@in_CuotasTarjeta
					END

					--IF (ISNULL(@cd_FormaPagoTAO,'')='CA')
					--BEGIN
					--	SET @cd_FormaPagoTAO='EFE'
					--END
					--IF (ISNULL(@cd_FormaPagoTAO,'')='PO')
					--BEGIN
					--	SET @cd_FormaPagoTAO='POL'
					--END
					--IF ISNULL(@cd_FormaPagoTAO,'')<>''
					--BEGIN
					--	SET @FPTAO=@cd_FormaPagoTAO
					--END
					--IF ISNULL(@cd_TarjetaCreditoTAO,'')<>''
					--BEGIN
					--	SET @FPTAO_TC=@cd_TarjetaCreditoTAO
					--END
					--IF ISNULL(@cd_NumeroTarjetaTAO,'')<>''
					--BEGIN
					--	SET @FPTAO_TC_number=@cd_NumeroTarjetaTAO
					--END
					--IF ISNULL(@cd_VencimientoTarjetaTAO,'')<>''
					--BEGIN
					--	SET @FPTAO_TC_exp=@cd_VencimientoTarjetaTAO
					--END
					--IF ISNULL(@in_CuotasTarjetaTAO,0)<>0
					--BEGIN
					--	SET @in_cuotasTarjetaTAO=@in_CuotasTarjetaTAO
					--END

					SET @in_cantpax=ISNULL(@in_cantpax,1) --rgelis 2017/10/02 req.53548
					
					If EXISTS ( Select * From dbo.ReservaGDS_Detalles r Where r.ds_tkt_number = @Tkt)
					Begin 
						UPDATE 	dbo.ReservaGDS_Detalles	
						Set  				
								ds_pax_number=@Count,
								ds_pax_firstnm =rtrim(@PaxName),
								ds_pax_lastnm=rtrim(@PaxApe),
								ds_pax_prefix=rtrim(@PaxPrefix),
								--Declare @AerolineaExterna CHAR(3),@CodAerolineaExterna CHAR(2)
								ds_tkt_prefix= Case When @bl_externo = 1 Then @AerolineaExterna Else @TktPrefix End,
								ds_aero_code=Case When @bl_externo = 1 Then @CodAerolineaExterna Else @CodigoAerolinea End,
								ds_moneda=@cd_MonedaTarifalocal,
								am_tarifa=@am_tarifalocal,
								am_iva=@am_iva,
								am_tua=@am_tasas,
								am_comb=@am_CMB,
								am_vat=@am_Otr,
								ds_cc_code=@FP1_TC,
								ds_cc_number=@FP1_TC_number,
								am_tao=@tao,
								am_ivatao=@taoiva,
								am_cap=@Recargo,
								am_ivacap=@RecargoIva,
								am_Comision = 0, --Falta el calculo de la comision
								NumTktConj = isnull(@NumTktConjuncion,0),
								cd_Pax_CC = @cd_Pax_CC,
								ds_lapsoviaje=@ds_lapsoviaje,
								ds_cc_code2=@FP2_TC,/*rgelis 2013/07/13 req.15354*/
								ds_cc_number2=@FP2_TC_number,/*rgelis 2013/07/13 req.15354*/
								am_fp1=isnull(@FP1_Val,0),
								am_fp2=isnull(@FP2_Val,0),													
								am_TarifaContado=@am_TarifaContado,
								am_IvaContado=@am_IvaContado,
								am_OtrosContado=@am_OtrosContado,
								am_TarifaCredito=@am_TarifaCredito,
								am_IvaCredito=@am_IvaCredito,
								am_OtrosCredito=@am_OtrosCredito,					
								ds_tkt_prefixIata= Case When @bl_externo = 1 Then  @TktPrefix  Else NULL End,
								ds_aero_codeIata=Case When @bl_externo = 1 Then @CodigoAerolinea Else NULL End,
								id_reserva = @Id_ReservasGDS, /*rgelis 2013/03/22 cambia para que actualice solo al tiquete y no la reserva*/
								bl_usada=0,
								cd_PasaportePax = @cd_PasaportePax,
								ds_cc_autorizacion = @FP1_TC_aprob, --inicio rgelis 2017/02/21 req.47359
								ds_cc_autorizacion2 = @FP2_TC_voucher, --rgelis 2017/06/05 req.48084
								ds_cc_voucher = @FP1_TC_voucher, --inicio rgelis 2017/02/21 req.47359
								ds_cc_voucher2 = @FP2_TC_voucher, --rgelis 2017/06/05 req.48084
								cd_FormaPagoTAO = @FPTAO, 
								am_fptao = @FPTAO_Val,
								cd_TarjetaCreditoTAO = @FPTAO_TC,
								cd_NumeroTarjetaTAO = @FPTAO_TC_number,
								cd_VencimientoTarjetaTAO = NULL,--@FPTAO_TC_exp, --Jramirez, esta info es peligrosa no se debe subir al sistema.
								ds_AutorizacionTarjetaTAO = @FPTAO_TC_aprob,  /*rgelis 2017/02/21 req.47359*/ 
								ds_VoucherTarjetaTAO = @FPTAO_TC_voucher, --rgelis 2017/06/05 req.48084
								in_cantpax = @in_cantpax, --rgelis 2017/08/24 req.35871
								cd_Pseudo = @cd_Pseudo, --rgelis 2017/08/30 req.52081
								ds_cc_vence = @FP1_TC_exp,
								ds_cc_vence2 = @FP2_TC_exp,
								am_iva2 = @am_iva2,
								in_cuotasTarjetaTAO=@in_cuotasTarjetaTAO
						Where  	ds_tkt_number = @Tkt; /*rgelis 2013/03/22 cambia para que actualice solo al tiquete y no la reserva*/ 
					End   
					Else If ISNULL(@Tkt,'') <> ''
					Begin
						/*rgelis 2013/03/22 cambia para que actualice solo al tiquete y no la reserva*/ 	
						--If EXISTS ( Select * From dbo.ReservaGDS_Detalles r Where r.ds_tkt_number = @Tkt)						
						--Begin
						--	DELETE From dbo.ReservaGDS_Detalles Where ds_tkt_number = @Tkt
						--End 
						
						Insert Into dbo.ReservaGDS_Detalles
							(
								id_reserva,
								ds_pax_number,
								ds_pax_firstnm,
								ds_pax_lastnm,
								ds_pax_prefix,
								ds_tkt_number,
								ds_tkt_prefix,
								ds_aero_code,
								ds_moneda,
								am_tarifa,
								am_iva,
								am_tua,
								am_comb,
								am_vat,
								ds_cc_code,
								ds_cc_number,
								am_tao,
								am_ivatao,
								am_cap,
								am_ivacap,
								ds_cc_code2,
								ds_cc_number2,
								am_fp1,
								am_fp2,
								cd_tktrevisado,
								am_TarifaContado,
								am_IvaContado,
								am_OtrosContado,
								am_TarifaCredito,
								am_IvaCredito,
								am_OtrosCredito,
								am_Comision, 
								NumTktConj,
								cd_Pax_CC,
								ds_lapsoviaje,
								ds_tkt_prefixIata,
								ds_aero_codeIata,
								bl_usada,
								in_CantidadTarifaTAO,
								in_CantidadSegmentoTAO,
								cd_PasaportePax,
								ds_cc_autorizacion, --inicio rgelis 2017/02/21 req.47359
								ds_cc_autorizacion2,
								ds_cc_voucher,
								ds_cc_voucher2,
								cd_FormaPagoTAO,
								am_fptao,
								cd_TarjetaCreditoTAO, 
								cd_NumeroTarjetaTAO,
								cd_VencimientoTarjetaTAO,
								ds_AutorizacionTarjetaTAO,
								ds_VoucherTarjetaTAO, /*rgelis 2017/02/21 req.47359*/
								in_cantpax, --rgelis 2017/08/24 req.35871
								cd_Pseudo, --rgelis 2017/08/30 req.52081
								ds_cc_vence,
								ds_cc_vence2,
								am_iva2,
								in_cuotasTarjetaTAO
							)
						VALUES 
							(
								@Id_ReservasGDS,
								@Count,
								rtrim(@PaxName),
								rtrim(@PaxApe),
								rtrim(@PaxPrefix),
								@tkt,
								Case When @bl_externo = 1 Then @AerolineaExterna Else @TktPrefix End,
								Case When @bl_externo = 1 Then @CodAerolineaExterna Else @CodigoAerolinea End,	
								@cd_MonedaTarifalocal,
								@am_tarifalocal,
								@am_iva,
								@am_Tasas,
								@am_cmb,
								@am_Otr,
								@FP1_TC,
								@FP1_TC_number,
								@tao,
								@taoiva,
								@Recargo,
								@RecargoIva,
								@FP2_TC,
								@FP2_TC_number,
								isnull(@FP1_Val,0),
								isnull(@FP2_Val,0),
								@tktrevisado,
								@am_TarifaContado,
								@am_IvaContado,
								@am_OtrosContado,
								@am_TarifaCredito,
								@am_IvaCredito,
								@am_OtrosCredito,
								isnull(@am_Comision,0),
								isnull(@NumTktConjuncion,0),
								@cd_Pax_CC,
								@ds_lapsoviaje,
								Case When @bl_externo = 1 Then  @TktPrefix  Else NULL End,
								Case When @bl_externo = 1 Then @CodigoAerolinea Else NULL End,
								0 ,
								0 ,
								0 ,
								@cd_PasaportePax,
								@FP1_TC_aprob, --inicio rgelis 2017/02/21 req.47359
								@FP2_TC_aprob,
								@FP1_TC_voucher, --rgelis 2017/06/05 req.48084
								@FP2_TC_voucher, --rgelis 2017/06/05 req.48084
								@FPTAO, 
								@FPTAO_Val,
								@FPTAO_TC,
								@FPTAO_TC_number,
								@FPTAO_TC_exp,
								@FPTAO_TC_aprob,
								@FPTAO_TC_voucher,  --rgelis 2017/06/05 req.48084 /*rgelis 2017/02/21 req.47359*/
								@in_cantpax, --rgelis 2017/08/24 req.35871
								@cd_Pseudo, --rgelis 2017/08/30 req.52081
								@FP1_TC_exp,
								@FP2_TC_exp,
								@am_iva2,
								@in_cuotasTarjetaTAO
							)
					End
					
					/*inicio rgelis 2014/02/24 req.18784*/			
					UPDATE rd
					SET rd.bl_usada=1
					FROM dbo.ReservaGDS_Detalles rd 
					 INNER JOIN dbo.TIQUETES t on t.cd_tiquete = rd.ds_tkt_number
					WHERE (t.id_fac_factura is not null Or t.id_fac_remision is not null)
						  AND rd.bl_usada=0
						  AND rd.id_reserva = @Id_ReservasGDS
					/*fin rgelis 2014/02/24 req.18784*/   
					--Avanzamos el contador del ciclo	
					
					Set @Count = @Count + 1	
				End 
				--Debug
				--select * from ReservaGDS_Detalles where id_reserva = @Id_ReservasGDS
				IF EXISTS(SELECT * FROM Parametros WHERE (Id=240 AND Valor='Ecuador') OR (Id=296 AND Valor='S')) /*rgelis 2013/11/29 req.17873*/
				BEGIN
					IF @Itinerarios <> ''
					BEGIN
						SET @Nacionalidad = dbo.fnza_Get_ReservaGdsNacionalidad(@Itinerarios)
						
						UPDATE dbo.ReservasGDS
						Set in_nacionalidad=@Nacionalidad
						Where id = @Id_ReservasGDS AND iden_gds=2
					END 
				END 
					
				----------------------------------------------------
				------------ Insertando los Itinerarios ------------
				----------------------------------------------------
				If NOT EXISTS (Select * From ReservaGDS_Itinerarios Where id_reserva = @Id_ReservasGDS)
				Begin
					Insert Into [dbo].[ReservaGDS_Itinerarios]
			           ([id_reserva]
			           ,[orden]
			           ,[cd_origen]
			           ,[cd_destino]
			           ,[cd_clase]
			           ,[fecha_salida]
			           ,[hora_salida]
			           ,[hora_llegada]
			           ,[terminal]
			           ,[cd_aero_siglas]
			           ,[cd_farebasis]
					   ,[ds_NumVuelo]
					   ,[am_co2])
					Select
		       			@Id_ReservasGDS,
						id AS 'Orden', 
						cd_origen, 
						cd_destino, 
						cd_clase, 
						fecha_salida, 
						hora_salida, 
						hora_llegada, 
						terminal,
						cd_aero_siglas,
						cd_farebasis,
						ds_NumVuelo,
						am_co2
					From @Table_Itinerarios
				End 
				Else
				Begin
					Delete From ReservaGDS_Itinerarios Where id_reserva = @Id_ReservasGDS
					
					Insert Into [dbo].[ReservaGDS_Itinerarios]
			           ([id_reserva]
			           ,[orden]
			           ,[cd_origen]
			           ,[cd_destino]
			           ,[cd_clase]
			           ,[fecha_salida]
			           ,[hora_salida]
			           ,[hora_llegada]
			           ,[terminal]
			           ,[cd_aero_siglas]
			           ,[cd_farebasis]
					   ,[ds_NumVuelo]
					   ,[am_co2])
					Select
		       			@Id_ReservasGDS,
						id AS 'Orden', 
						cd_origen, 
						cd_destino, 
						cd_clase, 
						fecha_salida, 
						hora_salida, 
						hora_llegada, 
						terminal,
						cd_aero_siglas,
						cd_farebasis,
						ds_NumVuelo,
						am_co2
					From @Table_Itinerarios	
				End
				/*inicio rgelis 2014/07/14 req.20502*/
				DELETE FROM @TableEMDValores WHERE cd_Penalidad IS NULL
				IF Exists(SELECT * FROM @TableEMDValores)
				BEGIN
					Select @MaxFila = max(id) From @TableEMDValores
					Set @Count = 1	
					While @Count <= @MaxFila
					Begin
						
						If EXISTS ( Select * From dbo.ReservaGDS_Detalles r 
										INNER JOIN @TableEMDValores p ON p.cd_penalidad=r.ds_tkt_number
									WHERE p.id = @Count	
								)
						Begin 
							UPDATE 	R
							Set  				
									R.ds_pax_number=@Count,
									R.ds_pax_firstnm =rtrim(t.PaxApe),
									R.ds_pax_lastnm=rtrim(t.PaxApe),
									R.ds_pax_prefix=rtrim(t.PaxPrefix),
									R.ds_tkt_prefix=Case When @bl_externo = 1 Then @AerolineaExterna Else p.cd_AerolineaPenalidad End,
									R.ds_aero_code=Case When @bl_externo = 1 Then @CodAerolineaExterna Else @CodigoAerolinea End,
									R.ds_moneda=p.ds_Moneda ,
									R.am_tarifa=p.am_tarifa ,
									R.am_iva=p.am_iva, /*inicio rgelis 2017/02/09 req.47238*/
									R.am_tua=p.am_tua,
									R.am_comb=p.am_comb,
									R.am_vat=p.am_vat, /*fin rgelis 2017/02/09 req.47238*/
									R.ds_cc_code=p.FP1_TC,
									R.ds_cc_number=p.FP1_TC_number,
									R.am_tao=0,
									R.am_ivatao=0,
									R.am_cap=0,
									R.am_ivacap=0,
									R.am_Comision = 0, 
									R.NumTktConj = 0,
									R.cd_Pax_CC = @cd_Pax_CC,
									R.ds_lapsoviaje=@ds_lapsoviaje,
									R.ds_cc_code2=p.FP2_TC,
									R.ds_cc_number2=p.FP2_TC_number,
									R.am_fp1=isnull(p.FP1_Val,0),
									R.am_fp2=isnull(p.FP2_Val,0),													
									R.am_TarifaContado=CASE WHEN ISNULL(p.FP1_TC,'')='' AND ISNULL(p.FP2_TC,'')='' THEN p.am_Tarifa ELSE 0 END,
									R.am_IvaContado=CASE WHEN ISNULL(p.FP1_TC,'')='' AND ISNULL(p.FP2_TC,'')='' THEN p.am_Iva ELSE 0 END,
									R.am_OtrosContado=0,
									R.am_TarifaCredito=CASE WHEN ISNULL(p.FP1_TC,'')='' AND ISNULL(p.FP2_TC,'')='' THEN 0 ELSE p.am_Tarifa END,
									R.am_IvaCredito=CASE WHEN ISNULL(p.FP1_TC,'')='' AND ISNULL(p.FP2_TC,'')='' THEN 0 ELSE p.am_Iva END,
									R.am_OtrosCredito=0,					
									R.ds_tkt_prefixIata= Case When @bl_externo = 1 Then  p.cd_AerolineaPenalidad  Else NULL End,
									R.ds_aero_codeIata=Case When @bl_externo = 1 Then @CodigoAerolinea Else NULL End,
									R.id_reserva = @Id_ReservasGDS, 
									R.bl_usada=0,
									R.cd_Penalidad = p.cd_Aerolinea + p.cd_tiquete,
									R.ds_cc_autorizacion = p.FP1_TC_aprob, --rgelis 2017/02/21 req.47359
									R.ds_cc_autorizacion2 = p.FP2_TC_aprob,
									R.ds_cc_voucher = p.FP1_TC_aprob, --inicio rgelis 2017/02/21 req.47359
									R.ds_cc_voucher2 = p.FP2_TC_aprob,
									R.in_cantpax = t.in_cantpax,
									R.cd_Pseudo = t.cd_Pseudo, --rgelis 2017/08/30 req.52081 
									R.ds_cc_vence = p.FP1_TC_exp, --rgelis 2017/02/21 req.47359
									R.ds_cc_vence2 = p.FP2_TC_exp, --Jramirez Correccion 20190313
									R.am_iva2 = P.am_iva2
							FROM dbo.ReservaGDS_Detalles R
							INNER JOIN @TableEMDValores  p ON p.cd_penalidad = R.ds_tkt_number
							INNER JOIN @Table_Pax t ON (t.Tkt = p.cd_tiquete OR t.TktRevisado = p.cd_tiquete OR t.Tkt = p.cd_Penalidad OR t.TktRevisado = p.cd_Penalidad) /*rgelis 2016/11/01 req... para que tome la penalidad de un revisado*/			 
							Where p.id = @Count;  
						End   
						Else 
						Begin
						    Insert Into dbo.ReservaGDS_Detalles
								(
									id_reserva,
									ds_pax_number,
									ds_pax_firstnm,
									ds_pax_lastnm,
									ds_pax_prefix,
									ds_tkt_number,
									ds_tkt_prefix,
									ds_aero_code,
									ds_moneda,
									am_tarifa,
									am_iva,
									am_tua,
									am_comb,
									am_vat,
									ds_cc_code,
									ds_cc_number,
									am_tao,
									am_ivatao,
									am_cap,
									am_ivacap,
									ds_cc_code2,
									ds_cc_number2,
									am_fp1,
									am_fp2,
									cd_tktrevisado,
									am_TarifaContado,
									am_IvaContado,
									am_OtrosContado,
									am_TarifaCredito,
									am_IvaCredito,
									am_OtrosCredito,
									am_Comision, 
									NumTktConj,
									cd_Pax_CC,
									ds_lapsoviaje,
									ds_tkt_prefixIata,
									ds_aero_codeIata,
									bl_usada,
									cd_Penalidad,
									in_CantidadTarifaTAO,
									in_CantidadSegmentoTAO,
									R.ds_cc_autorizacion, --rgelis 2017/02/21 req.47359
									R.ds_cc_autorizacion2,
									R.ds_cc_voucher, --rgelis 2017/02/21 req.47359
									R.ds_cc_voucher2,
									in_cantpax, --rgelis 2017/08/24 req.35871
									cd_Pseudo, --rgelis 2017/08/30 req.52081
									ds_cc_vence, 
									ds_cc_vence2,
									am_iva2
								)
							SELECT
									@Id_ReservasGDS AS 'id_reserva',
									@Count As 'ds_pax_number',
									rtrim(t.PaxName) AS 'ds_pax_firstnm' ,
									rtrim(t.PaxApe) As 'ds_pax_lastnm' ,
									rtrim(t.PaxPrefix) As 'ds_pax_prefix' ,
									P.cd_Penalidad AS 'ds_tkt_number',
									Case When @bl_externo = 1 Then @AerolineaExterna Else P.cd_AerolineaPenalidad End AS 'ds_tkt_prefix',
									Case When @bl_externo = 1 Then @CodAerolineaExterna Else @CodigoAerolinea End AS 'ds_aero_code',	
									p.ds_Moneda,
									p.am_tarifa,
									p.am_iva AS 'am_iva',/*inicio rgelis 2017/02/09 req.47238*/
									p.am_tua AS 'am_Tasas',
									p.am_comb AS 'am_cmb',
									p.am_vat AS 'am_Otr',/*fin rgelis 2017/02/09 req.47238*/
									p.FP1_TC,
									p.FP1_TC_number,
									0 As 'tao',
									0 AS 'taoiva',
									0 AS 'Recargo',
									0 AS 'RecargoIva',
									p.FP2_TC,
									p.FP2_TC_number,
									isnull(p.FP1_Val,0) AS 'FP1_Val',
									isnull(p.FP2_Val,0) AS 'FP2_Val',
									'' AS 'cd_tktrevisado',
									CASE WHEN ISNULL(p.FP1_TC,'')='' AND ISNULL(p.FP2_TC,'')='' THEN p.am_Tarifa ELSE 0 END AS 'am_TarifaContado',
									CASE WHEN ISNULL(p.FP1_TC,'')='' AND ISNULL(p.FP2_TC,'')='' THEN p.am_Iva ELSE 0 END AS 'am_IvaContado',
									0 AS 'am_OtrosContado',
									CASE WHEN ISNULL(p.FP1_TC,'')='' AND ISNULL(p.FP2_TC,'')='' THEN 0 ELSE p.am_Tarifa END AS 'am_TarifaCredito',
									CASE WHEN ISNULL(p.FP1_TC,'')='' AND ISNULL(p.FP2_TC,'')='' THEN 0 ELSE p.am_Iva END  AS 'am_IvaCredito',
									0 AS 'am_OtrosCredito',
									0 AS 'am_Comision' ,
									0 AS 'NumTktConj' , --rgelis 2018/11/29 req.74745
									@cd_Pax_CC AS 'cd_Pax_CC',
									@ds_lapsoviaje AS 'ds_lapsoviaje',
									Case When @bl_externo = 1 Then  P.cd_AerolineaPenalidad  Else NULL End AS 'ds_tkt_prefixIata',
									Case When @bl_externo = 1 Then @CodigoAerolinea Else NULL End 'ds_aero_codeIata',
									0 AS 'bl_usada',
									p.cd_Aerolinea+p.cd_tiquete  AS 'cd_Penalidad',
									0 As 'in_CantidadTarifaTAO',
									0 AS 'in_CantidadSegmentoTAO',
									p.FP1_TC_aprob AS 'ds_cc_autorizacion', --rgelis 2017/02/21 req.47359
									p.FP2_TC_aprob AS 'ds_cc_autorizacion2',
									p.FP1_TC_aprob AS 'ds_cc_voucher',
									p.FP2_TC_aprob AS 'ds_cc_voucher2',
									t.in_cantpax   AS 'in_cantpax', --rgelis 2017/08/24 req.35871
									t.cd_Pseudo	   AS 'cd_Pseudo', --rgelis 2017/08/30 req.52081		
									p.FP1_TC_exp, 
									p.FP2_TC_exp,
									p.am_iva2
						 FROM  @TableEMDValores  p 
							INNER JOIN @Table_Pax t ON (t.Tkt = p.cd_tiquete OR t.TktRevisado = p.cd_tiquete OR t.Tkt = p.cd_Penalidad OR t.TktRevisado = p.cd_Penalidad) /*rgelis 2016/11/01 req... para que tome la penalidad de un revisado*/
						 Where p.id = @Count; 
						END
						SET @Count = @Count + 1
					END			
				END
				/*fin rgelis 2014/07/14 req.20502*/
				 
			END 
			ELSE
			BEGIN
				Set @in_PaxActual = 0
				--Inicializamos la tabla donde se guardaran los segmentos que se necesitan.
				TRUNCATE TABLE Table_Aux_GDS
				--Obtenemos los segementos de Cliente, Pasajeros, tiquetes, formas de pago y tarifas
				Insert Into Table_Aux_GDS
				Select Fila 
				From @TableReserva 
				Where LEFT(fila,2) = 'I-'
				OR LEFT(fila,2) = 'T-'
				OR LEFT(fila,4) = 'ENDX'
				--Obtenemos el numero de segementos obtenidos e inicializamos el contador
				Select @MaxFila = @@ROWCOUNT
				Set @Count = 1						
			   	While @Count <= @MaxFila
				Begin 
					--Inicializamos las variables 
					SET @Cadena =''

					Select @cd_Segmento = substring(Campo,1,2) From Table_Aux_GDS Where id = @Count
					--Pasajero
					If @cd_Segmento ='I-'
					Begin
						Set @in_PaxActual = @in_PaxActual + 1
						Select 
							@Cadena = substring(Campo,9,len(Campo))
						From Table_Aux_GDS Where id = @Count
						
						Set @PosBarra = CHARINDEX('/',@Cadena)
						Set @PosPuntoComa = CHARINDEX(';',@Cadena)
			 			----------------------------------------
			 			-- Insertamos el registro del pasajero
			 			Insert Into @Table_Pax ( PaxApe, PaxName)	
						Select 
							left(substring(@Cadena,1,@PosBarra-1),30) 							AS 'PaxApe',
							left(substring(@Cadena,@PosBarra+1,@PosPuntoComa-@PosBarra-1),30) 	AS 'PaxName'
							
						UPDATE @Table_Pax
						Set PaxPrefix = 'MRS',
							PaxName = replace(PaxName,'MRS','')
						Where PaxName like '%MRS%'
	
						update @Table_Pax
						Set PaxPrefix = 'MR',
							PaxName = replace(PaxName,'MR','')
						Where PaxName like '%MR%'
					End
					--Tiquetes
					Else If @cd_Segmento ='T-'
					BEGIN
						--Obtenemos la informaicon de la linea
						Select @Cadena = substring(Campo,4,len(Campo))
						From Table_Aux_GDS Where id = @Count
												
						If  charindex('-',substring(@Cadena,5,len(@Cadena))) > 0					
						Begin
							-- FALTA!!!!!!!!!!!
							---------------------------------------
							-- Todo lo de Tiquetes en conjuncion --
							---------------------------------------
							UPDATE @Table_Pax 
							Set Tkt = substring(@Cadena,5,10),
								TktPrefix = substring(@Cadena,1,3)
							Where id = @in_PaxActual
							Set @NumTktConjuncion = 1	
	--						Set @Cadena=''
						End 
						Else 
						Begin
							--Obtenemos el numero del Tkt y el Prefijo		
							UPDATE @Table_Pax 
							Set Tkt = substring(@Cadena,5,len(@Cadena)),
								TktPrefix = substring(@Cadena,1,3)
							Where id = @in_PaxActual
						End 
					End						
					Set @Count = @Count + 1
				END
				
				--Obtenemos la Fecha de Anulacion
				SELECT @FechaReserva = 
					CONVERT(VARCHAR(4),YEAR(GETDATE())) +
					CASE substring(Fila,26,3)  
									WHEN 'JAN' THEN  '01'
									WHEN 'FEB' THEN  '02'
									WHEN 'MAR' THEN  '03'
									WHEN 'APR' THEN  '04'
									WHEN 'MAY' THEN  '05'
									WHEN 'JUN' THEN  '06'
									WHEN 'JUL' THEN  '07'
									WHEN 'AUG' THEN  '08'
									WHEN 'SEP' THEN  '09'
									WHEN 'OCT' THEN  '10'
									WHEN 'NOV' THEN  '11'
									WHEN 'DEC' THEN  '12'
								End	
					+ substring(Fila,24,2) 			
				From @TableReserva Where id = 2
						 
				Select @PaxApe = PaxApe
					,@PaxName = PaxName
					,@PaxPrefix = PaxPrefix
					,@Tkt = Tkt
					,@TktPrefix = TktPrefix
					,@TktRevisado = TktRevisado
					,@TktRevisadoPrefix = TktRevisadoPrefix
				From @Table_Pax
				Where Id = 1
								
				--------------------------------------------------------------------------
				-------------------- Insertando la reserva de AMADEUS --------------------
				--------------------------------------------------------------------------
				
				----------------------------------------------------------
				------------ Insertando cabecera de la reserva -----------
				----------------------------------------------------------
				If NOT EXISTS (Select * From ReservasGDS Where cd_codigo = @CodigoReserva AND iden_gds=2)
				Begin
				Insert Into dbo.ReservasGDS
				(
				iden_gds,
				cd_codigo,
				ds_fecha,
				cd_tiqueteador,
				cd_vendedor,
				cd_cliente,
				reserva,
				am_highfare,
				am_lowfare,
				am_fare,			
				ds_itinerario,
				ds_clases,
				in_nacionalidad,
				cd_sucursal,
				cd_TipoTransaccion,
				cd_centrocosto,
				ds_solicita,
				bl_ahorro,
				cd_iata
				)
				Select 
					2 							AS 'iden_gds',
					@CodigoReserva				AS 'Codigo',
					@FechaReserva				AS 'Fecha',
					@tiqueteador 				AS 'cd_tiqueteador',
					@vendedor    				AS 'cd_vendedor',
					isnull(@cd_cliente,'')		AS 'Cliente',
					@GDS						AS 'Reserva',
					0							AS 'am_highfare',
					0							AS 'am_lowfare',
					0							AS 'am_fare',				
					@Itinerarios				AS 'ds_itinerario',
					@Clases						AS 'ds_clases',
					@Nacionalidad				AS 'in_nacionalidad',
					@Sucursal					AS 'cd_sucursal',
					1							AS 'cd_TipoTransaccion',
					@cd_centrocosto		        AS 'cd_centrocosto',
					@ds_solicita				AS 'ds_solicita',
					0							AS 'bl_ahorro',
					@cd_iata					AS 'cd_iata'
				
				Set @Id_ReservasGDS = scope_identity()
				End 
				Else
				Begin 
					UPDATE dbo.ReservasGDS
					Set 
					ds_fecha=@FechaReserva,
					cd_tiqueteador=@tiqueteador,
					cd_vendedor=@vendedor,
					reserva=@GDS,
					cd_sucursal=@Sucursal,
					cd_TipoTransaccion=1,
					cd_centrocosto = @cd_centrocosto,
					ds_solicita = @ds_solicita
					Where cd_codigo = @CodigoReserva AND iden_gds=2
					
					--Obtenemos el id de la reserva actualizada
					Select @Id_ReservasGDS = id 
					From dbo.ReservasGDS
					Where cd_codigo = @CodigoReserva AND iden_gds=2
					
				End 
				If EXISTS ( Select * From dbo.ReservaGDS_Detalles r Where r.id_reserva = @Id_ReservasGDS AND r.ds_tkt_number = @Tkt)
				Begin 
					UPDATE 	dbo.ReservaGDS_Detalles	
					Set  				
							ds_pax_number=1,
							ds_pax_firstnm =rtrim(@PaxName),
							ds_pax_lastnm=rtrim(@PaxApe),
							ds_pax_prefix=rtrim(@PaxPrefix),
							--Declare @AerolineaExterna CHAR(3),@CodAerolineaExterna CHAR(2)
							ds_tkt_prefix= Case When @bl_externo = 1 Then @AerolineaExterna Else @TktPrefix End,
							ds_aero_code=Case When @bl_externo = 1 Then @CodAerolineaExterna Else @CodigoAerolinea End,
							cd_Pax_CC = @cd_Pax_CC,
							ds_lapsoviaje=@ds_lapsoviaje,					
							ds_tkt_prefixIata= Case When @bl_externo = 1 Then  @TktPrefix  Else NULL End,
							ds_aero_codeIata=Case When @bl_externo = 1 Then @CodigoAerolinea Else NULL End
					Where  	id_reserva = @Id_ReservasGDS AND ds_tkt_number = @Tkt;
				End   
				Else 
				Begin 
					If EXISTS ( Select * From dbo.ReservaGDS_Detalles r Where r.ds_tkt_number = @Tkt)						
					Begin
						DELETE From dbo.ReservaGDS_Detalles Where ds_tkt_number = @Tkt
					End 
					
					Insert Into dbo.ReservaGDS_Detalles
						(
							id_reserva,
							ds_pax_number,
							ds_pax_firstnm,
							ds_pax_lastnm,
							ds_pax_prefix,
							ds_tkt_number,
							ds_tkt_prefix,
							ds_aero_code,
							cd_tktrevisado,
							NumTktConj,
							cd_Pax_CC,
							ds_lapsoviaje,
							ds_tkt_prefixIata,
							ds_aero_codeIata,
							bl_usada,
							in_CantidadTarifaTAO,
							in_CantidadSegmentoTAO
						)
					VALUES 
						(
							@Id_ReservasGDS,
							1,
							rtrim(@PaxName),
							rtrim(@PaxApe),
							rtrim(@PaxPrefix),
							@tkt,
							Case When @bl_externo = 1 Then @AerolineaExterna Else @TktPrefix End,
							Case When @bl_externo = 1 Then @CodAerolineaExterna Else @CodigoAerolinea End,	
							'',
							0,
							@cd_Pax_CC,
							@ds_lapsoviaje,
							Case When @bl_externo = 1 Then  @TktPrefix  Else NULL End,
							Case When @bl_externo = 1 Then @CodigoAerolinea Else NULL END,
							1, 
							0,
							0
						)
				End  				
				
				EXEC @Error = spza_GDS_TiqueteAnular @tkt, @CodigoReserva,@FechaReserva
  			
			END 
			DROP TABLE #TableValoresAux	/*rgelis 2013/12/09 req.17703*/
			--------------------------------------------------------------------------	
			--inicio rgelis 2019/01/24 req.75925
			IF EXISTS(SELECT * FROM dbo.Parametros Where id=565 AND LTRIM(RTRIM(Valor)) = 'S')  
			BEGIN
				UPDATE r
				SET r.cd_formapago_cliente =(SELECT TOP(1) cd_formapago_cliente=c.cd_codigo_fp 
											 FROM dbo.Configuracion_remisiones_FPago c
											 INNER JOIN dbo.Configuracion_remisiones e ON e.id_cliente = c.id_cliente 
											 WHERE (c.id_cliente = r.cd_cliente OR c.id_cliente = r.ds_cliid)
													AND e.bl_forma_pago = 1)
				FROM dbo.ReservasGDS r
				WHERE r.id = @Id_ReservasGDS 
			END 
			--fin rgelis 2019/01/24 req.75925

			IF EXISTS(SELECT id FROM @ReservaGDS_FormasPagos)
			BEGIN
				--DELETE FROM dbo.ReservaGDS_FormasPagos WHERE id_reserva=@Id_ReservasGDS
								
				INSERT INTO dbo.ReservaGDS_FormasPagos(id_reserva,id_reservaGDS_detalles,id_reservaGDS_servicios,in_orden,cd_codigo,ds_nombre,cd_tipotarjeta,ds_numerotarjeta,ds_vouchertarjeta,ds_expiraciontarjeta,ds_autorizaciontarjeta,in_coutas,cd_banco,ds_cheque,ds_plaza,ds_referencia,ds_Poliza,ds_PolizaAnexo,am_valor)
				SELECT id_reserva=@Id_ReservasGDS,id_reservaGDS_detalles=D.id,id_reservaGDS_servicios=NULL,in_orden=FP.id,cd_codigo=FP.cd_codigo,ds_nombre=FP.ds_nombre,cd_tipotarjeta=FP.cd_tipotarjeta,ds_numerotarjeta=FP.ds_numerotarjeta,ds_vouchertarjeta=FP.ds_vouchertarjeta,ds_expiraciontarjeta=FP.ds_expiraciontarjeta,ds_autorizaciontarjeta=FP.ds_autorizaciontarjeta,in_coutas=FP.in_coutas,cd_banco=FP.cd_banco,ds_cheque=FP.ds_cheque,ds_plaza=FP.ds_plaza,ds_referencia=FP.ds_referencia,ds_Poliza=FP.ds_Poliza,ds_PolizaAnexo=FP.ds_PolizaAnexo,am_valor=FP.am_valor
				FROM @ReservaGDS_FormasPagos FP
				INNER JOIN @Table_Pax P ON P.id = CONVERT(INT,FP.cd_consecutivo)
				INNER JOIN dbo.ReservaGDS_Detalles D ON D.id_reserva=@Id_ReservasGDS AND ds_tkt_number=P.Tkt 
			END
 		 	--Si la transaccion fue creada en el procedimiento entonces se actualiza--

			If NOT (@@ERROR<> 0)
			Begin 
				COMMIT TRAN;	

	        	Insert Into dbo.ReservasGDS_log (cd_sucursal,cd_implante,ds_mensaje,ds_archivo,cd_reserva, ds_reserva,bl_error)
	        	Select 
					cd_sucursal
					,cd_implante
					,'Reserva procesada exitosamente'
					,ds_archivo
					,@CodigoReserva
					,ds_reserva
					,0
				From dbo.ReservasGDS_Temp Where Id=@IdReserva				
				-----------------------------------------------------------------------------------------
				-- Si la facturacion automatica de amadeus esta habilitada, insertamos el registro
				If @Implante = ''
				Begin 
					Set @Implante= null
				End

				-----------------------------
				-- Solo GEMA TOURS ----------
				-----------------------------
					IF @tiqueteador = '1143AO'
					BEGIN
						SET @Implante = '01E'
					END 
				-----------------------------
				-- FIN Solo GEMA TOURS ------
				-----------------------------


				If EXISTS(Select * From dbo.sucursales S
							INNER JOIN Sucursal_GDSFacAuto SG ON SG.id_Sucursal = S.id  /*rgelis 2015/08/24 req.27386*/ 
							Where S.cd_codigo=@Sucursal and (SG.id_GDS = 2 and SG.bl_FacAuto = 1) /*bl_facauto_amadeus=1*/)
				Begin
					IF (EXISTS(SELECT id FROM dbo.ConfiguracionClientesFacAuto WHERE cd_codigo = @cd_cliente)
						OR NOT EXISTS(SELECT id FROM dbo.Parametros WHERE id = 525 AND RTRIM(LTRIM(Valor)) = 'S')
					   )
					BEGIN
						SET @bl_usada = 1 --inicio rgelis 2018/12/12 req.74918
						SELECT @bl_usada = bl_usada
						FROM dbo.ReservaGDS_Detalles
						INNER JOIN dbo.ReservasGDS on ReservasGDS.id = ReservaGDS_Detalles.id_reserva
						WHERE ReservasGDS.id = @Id_ReservasGDS
						AND ReservaGDS_Detalles.bl_usada = 0

						IF @bl_usada = 0
						BEGIN
							If EXISTS(Select * From dbo.ReservasGDS_FacAuto Where cd_sucursal = @sucursal and Id_Reserva = @Id_ReservasGDS )
							Begin
								UPDATE dbo.ReservasGDS_FacAuto
								Set cd_sucursal = @Sucursal
									, cd_implante = @Implante
									, ds_Archivo = @Archivo
								Where id_reserva = @Id_ReservasGDS
							End
							Else
							Begin			
								Insert Into dbo.ReservasGDS_FacAuto (cd_sucursal,cd_implante,Id_reserva,ds_archivo)
								VALUES(@Sucursal,@Implante,@Id_ReservasGDS,@Archivo)
							End
						END --fin rgelis 2018/12/12 req.74918
					END
				End
				-----------------------------------------------------------------------------------------

				------------------------------------------------------------------
				
				--R88490 - Jramirez - EMD 7D(Terranova)
				UPDATE ReservaGDS_Detalles
				SET ds_aero_code = cd_siglas
				FROM ReservaGDS_Detalles
				INNER JOIN ReservasGDS ON ReservasGDS.id = ReservaGDS_Detalles.id_reserva
				INNER JOIN Entidades ON Entidades.cd_codigo = ReservaGDS_Detalles.ds_tkt_prefix
				WHERE ReservasGDS.Id = @Id_ReservasGDS
				AND ds_aero_code IS NULL

				--Borramos de la tabla de amadesu temporal la reserva procesada
				DELETE From dbo.ReservasGDS_Temp Where Id = @IdReserva
				--select * from ReservaGDS_Detalles where id_reserva=@Id_ReservasGDS 
				--IF @@trancount > 0
				--	ROLLBACK TRAN; 
				--RETURN 0;

				IF @@trancount > 0
					COMMIT TRAN						

				Select 1 AS 'Consecutivo';
				RETURN 0;
			End 
			   
		End TRY			   
		
    	-- Bloque CATCH (Manejo de excepciones)
    	Begin CATCH 

			If (@@TRANCOUNT > 0)
        	Begin 
	        	ROLLBACK; 
	        	

				IF @@trancount > 0
					ROLLBACK; 

	        	Declare @TipoError CHAR(1),@Descripcion VARCHAR(max)
	        	-- 1: Error manejado
	        	-- 2: Error no manejado
				Set @retval = 1;
				--If ERROR_NUMBER() = 5001 or @estado = 0
				--Begin
				--	Set @TipoError = '1'
				--	Set @msg =	'Ha ocurrido un error.'			+ CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
				--				'Zeus Agencia Minorista SQL ha detectado errores en el archivo (Estructura incorrecta)' + CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
				--				'Reserva no confirmada.';
				--	Set @Descripcion = 'Reserva no confirmada.'
				--End				
				--Else If @CodigoReserva IS NULL OR @CodigoReserva = ''
				--Begin
				--	Set @TipoError = '1'
				--	Set @msg =	'Ha ocurrido un error.'			+ CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
				--				'Zeus Agencia Minorista SQL ha detectado errores en el archivo (Estructura incorrecta)' + CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
				--				'No se encontro codigo de reserva.';
				--	Set @Descripcion = 'No se encontro codigo de reserva.'
				--End   
				--Else If @tkt IS NULL OR @tkt = ''
				--Begin
				--	Set @TipoError = '1'
				--	Set @msg =	'Ha ocurrido un error.'			+ CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
				--				'Zeus Agencia Minorista SQL ha detectado errores en el archivo (Estructura incorrecta)' + CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
				--				'No se encontraron tiquetes en la reserva.';
				--	Set @Descripcion = 'No se encontraron tiquetes en la reserva.'
				--End 					
				--Else 
				--Begin 
					Set @TipoError = '2'
	 				Set @msg =	'Ha ocurrido un error. Información para soporte tecnico:'			+ CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
							    'Numero: ' + isnull(CAST(ERROR_NUMBER()   AS VARCHAR(10)),'') 		+ CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
								'Mensaje: ' + isnull(ERROR_MESSAGE(),'') 					   		+ CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
							 	'Severidad: ' + isnull(CAST(ERROR_SEVERITY() AS VARCHAR(10)),'') 	+ CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
							 	'Estado: ' + isnull(CAST(ERROR_STATE()  AS VARCHAR(10)),'') 		+ CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
								'Procedimiento: ' + isnull(ERROR_PROCEDURE(),'')					+ CHAR(13)+ CHAR(10) + CHAR(13)+ CHAR(10) +
								'Linea: ' + isnull(CAST(ERROR_LINE() 	   AS VARCHAR(10)),''); 							        	
					Set @Descripcion = 'Ha ocurrido un error. Contacte a zeus para soporte tecnico'
								
				--End 

	        	Insert Into dbo.ReservasGDS_log (cd_sucursal,cd_implante,ds_mensaje,ds_archivo,cd_reserva, ds_reserva,bl_error )
	        	Select cd_sucursal,cd_implante,@msg,ds_archivo,@CodigoReserva, ds_reserva, 1 From ReservasGDS_Temp Where Id=@IdReserva
	        	
				Delete From dbo.ReservasGDS_Temp
	        	
				Select 
						Error=@TipoError,
						Descripcion=@msg,
						Referencia= @Archivo       			
						
					
				
   	        End  
   	     End CATCH
   	        
	RETURN 0    
End
GO
