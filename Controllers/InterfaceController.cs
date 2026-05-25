using Microsoft.AspNetCore.Mvc;
using Npgsql;
using System.Data;

namespace InterfaceFile.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class InterfaceController : ControllerBase
    {
        private readonly IConfiguration _configuration;

        public InterfaceController(IConfiguration configuration)
        {
            _configuration = configuration;
        }

        public class ProcessFileRequest
        {
            public string FilePath { get; set; } = string.Empty;
        }

        [HttpPost("ProcessFile")]
        public async Task<IActionResult> ProcessFile([FromBody] ProcessFileRequest request)
        {
            if (string.IsNullOrEmpty(request.FilePath) || !System.IO.File.Exists(request.FilePath))
            {
                return BadRequest("El archivo no existe o la ruta es inválida.");
            }

            try
            {
                var fileName = Path.GetFileName(request.FilePath);
                var fileContent = await System.IO.File.ReadAllTextAsync(request.FilePath);
                
                var connectionString = _configuration.GetConnectionString("DefaultConnection");

                using (var connection = new NpgsqlConnection(connectionString))
                {
                    await connection.OpenAsync();

                    using (var command = new NpgsqlCommand("spInterfaceFile", connection))
                    {
                        command.CommandType = CommandType.StoredProcedure;
                        command.Parameters.AddWithValue("op", "procesar");
                        command.Parameters.AddWithValue("Booking", fileContent);
                        command.Parameters.AddWithValue("file", fileName);

                        await command.ExecuteNonQueryAsync();
                    }
                }

                return Ok(new { Message = "Archivo procesado exitosamente.", FileName = fileName });
            }
            catch (Exception ex)
            {
                return StatusCode(500, $"Error procesando el archivo: {ex.Message}");
            }
        }
    }
}
