using LazyPDF.App.Services;

namespace LazyPDF.App;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        // The decode child shows no window and takes no part in the single instance, so it is settled before WPF starts.
        if (args is [JpxChild.Switch]) return JpxChild.Run();
        var app = new App();
        app.InitializeComponent();
        app.Run();
        return 0;
    }
}
