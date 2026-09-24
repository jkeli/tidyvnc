// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using System.Globalization;
using TidyVNC.Testing;

var port = 5900;
string? password = null;
ushort width = 1024, height = 768;
for (var i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--port" when i + 1 < args.Length: port = int.Parse(args[++i], CultureInfo.InvariantCulture); break;
        case "--password" when i + 1 < args.Length: password = args[++i]; break;
        case "--size" when i + 1 < args.Length:
            var parts = args[++i].Split('x');
            width = ushort.Parse(parts[0], CultureInfo.InvariantCulture);
            height = ushort.Parse(parts[1], CultureInfo.InvariantCulture);
            break;
        default:
            Console.Error.WriteLine("usage: tidyvnc-testserver [--port N] [--password P] [--size WxH]");
            return 2;
    }
}

await using var server = new RfbTestServer(width, height, password, port) { Log = line => Console.WriteLine(line) };
Console.WriteLine($"Serving {width}x{height} on {server.Endpoint}{(password is null ? "" : " with VncAuth")}; Ctrl+C stops.");
using var stop = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; stop.Cancel(); };
try
{
    while (true)
    {
        await Task.Delay(200, stop.Token);
        server.Tick();
    }
}
catch (OperationCanceledException) { }
return 0;
