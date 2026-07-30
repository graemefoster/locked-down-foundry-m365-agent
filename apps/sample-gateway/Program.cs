using System.Text;
using Yarp.ReverseProxy.Configuration;
using Yarp.ReverseProxy.Transforms;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddReverseProxy()
    .ConfigureHttpClient((_, handler) => handler.ActivityHeadersPropagator = null)
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"));

var app = builder.Build();

app.MapReverseProxy();

Console.WriteLine($"Yarp! Environment Name: {app.Environment.EnvironmentName}");

app.Run();
