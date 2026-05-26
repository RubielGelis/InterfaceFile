using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Configuration;
using Npgsql;
using System.Data;

namespace InterfaceFile.Services
{
    public class FileWatcherService : BackgroundService
    {
        private readonly ILogger<FileWatcherService> _logger;
        private readonly IConfiguration _configuration;
        private FileSystemWatcher? _watcher;

        public FileWatcherService(ILogger<FileWatcherService> logger, IConfiguration configuration)
        {
            _logger = logger;
            _configuration = configuration;
        }

        protected override Task ExecuteAsync(CancellationToken stoppingToken)
        {
            var watchPath = _configuration.GetValue<string>("FileWatcher:WatchDirectory") ?? @"C:\GDS_Files";

            if (!Directory.Exists(watchPath))
            {
                Directory.CreateDirectory(watchPath);
                _logger.LogInformation($"Directorio creado: {watchPath}");
            }

            _watcher = new FileSystemWatcher(watchPath)
            {
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite,
                EnableRaisingEvents = true
            };

            _watcher.Created += async (sender, e) => await ProcessFileAsync(e.FullPath, stoppingToken);

            _logger.LogInformation($"Servicio FileWatcher iniciado. Observando directorio: {watchPath}");

            // Procesar los archivos que ya existan en la carpeta antes de iniciar
            Task.Run(async () =>
            {
                var existingFiles = Directory.GetFiles(watchPath);
                foreach (var file in existingFiles)
                {
                    _logger.LogInformation($"Encontrado archivo existente al iniciar: {Path.GetFileName(file)}");
                    await ProcessFileAsync(file, stoppingToken);
                }
            }, stoppingToken);

            return Task.CompletedTask;
        }

        private async Task ProcessFileAsync(string filePath, CancellationToken stoppingToken)
        {
            // Pequeña pausa para asegurar que el archivo haya sido escrito completamente
            await Task.Delay(1000, stoppingToken);

            try
            {
                if (File.Exists(filePath))
                {
                    var fileName = Path.GetFileName(filePath);
                    var fileContent = await File.ReadAllTextAsync(filePath, stoppingToken);

                    _logger.LogInformation($"Procesando archivo: {fileName}");

                    var connectionString = _configuration.GetConnectionString("DefaultConnection");
                    _logger.LogInformation($"Connection String: {connectionString}");

                    using (var connection = new NpgsqlConnection(connectionString))
                    {
                        await connection.OpenAsync(stoppingToken);

                        using (var command = new NpgsqlCommand("spInterfaceFile", connection))
                        {
                            command.CommandType = CommandType.StoredProcedure;
                            command.Parameters.AddWithValue("op", "procesar");
                            command.Parameters.AddWithValue("booking", fileContent);
                            command.Parameters.AddWithValue("file", fileName);

                            await command.ExecuteNonQueryAsync(stoppingToken);
                        }
                    }

                    _logger.LogInformation($"Archivo {fileName} procesado y enviado a la base de datos exitosamente.");
                    
                    // Opcional: mover el archivo a una carpeta de "Procesados"
                    var processedPath = Path.Combine(Path.GetDirectoryName(filePath)!, "Procesados");
                    if (!Directory.Exists(processedPath)) Directory.CreateDirectory(processedPath);
                    File.Move(filePath, Path.Combine(processedPath, fileName), true);
                }
            }
            catch (Exception ex)
            {
                _logger.LogError($"Error al procesar el archivo {filePath}: {ex.Message}");
                
                try
                {
                    if (File.Exists(filePath))
                    {
                        var errorPath = Path.Combine(Path.GetDirectoryName(filePath)!, "Errores");
                        if (!Directory.Exists(errorPath)) Directory.CreateDirectory(errorPath);
                        var fileName = Path.GetFileName(filePath);
                        File.Move(filePath, Path.Combine(errorPath, fileName), true);
                        _logger.LogInformation($"Archivo movido a la carpeta de Errores: {fileName}");
                    }
                }
                catch (Exception moveEx)
                {
                    _logger.LogError($"No se pudo mover el archivo con error {filePath}: {moveEx.Message}");
                }
            }
        }

        public override void Dispose()
        {
            _watcher?.Dispose();
            base.Dispose();
        }
    }
}
