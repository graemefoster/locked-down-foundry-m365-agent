var builder = WebApplication.CreateBuilder(args);

builder.Services.AddReverseProxy()
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"));

var app = builder.Build();

app.MapReverseProxy();

Console.WriteLine($"Yarp! Environment Name: {app.Environment.EnvironmentName}");

app.Run();
